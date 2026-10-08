-- Headless session policy: idle timers, display power, the lock and its PAM
-- conversation, logind sleep and inhibitors. No service runs: the manual
-- scheduler's controls stand in for them (resolve, reject, emit), and a
-- stub shell (system id "shell") hears DISMISS.
local o = require("ouro")
local machine = o.machine
local session = require("session")
local config = require("config")

local function never() error("a real service ran in a test") end
local services = {}
for _, name in ipairs({ "logind", "inhibit", "own", "auth", "idle", "power", "suspend", "hint" }) do
  services[name] = never
end
local chart = session.chart(services)

local stub = machine.create {
  id = "shell", initial = "open", context = { dismissed = 0 },
  states = { open = { on = { DISMISS = { actions = machine.assign { dismissed = function(c) return c.dismissed + 1 end } } } } },
}

-- Pending invokes and tasks matching an id or src, in the given state.
local function pending(clock, name, state)
  local found = {}
  for _, item in ipairs(clock.pending_invokes()) do
    if (item.id == name or item.src == name) and (not state or item.state == state) then found[#found + 1] = item end
  end
  return found
end

local function fixture()
  local clock = machine.manual_scheduler()
  local shell = stub:start { system_id = "shell", scheduler = clock }
  local actor = chart:start { scheduler = clock }
  local records = {}
  actor:observe(function(record) records[#records + 1] = record end)
  return actor, clock, shell, records
end

local owner = { fake = "lock" }

-- Online with an identity, as after logind answers.
local function online()
  local actor, clock, shell, records = fixture()
  clock.emit("logind", { type = "IDENTITY", username = "alice", session = "/session/1" })
  clock.emit("logind", "WAKE")
  clock.emit("logind", "CONNECTED")
  return actor, clock, shell, records
end

-- Locked and acknowledged by the compositor, with authentication pending.
local function locked()
  local actor, clock, shell, records = online()
  clock.emit("idle_lock", { type = "IDLED", stage = "lock" })
  clock.emit("own", { type = "OWNED", owner = owner })
  clock.emit("own", "LOCKED")
  return actor, clock, shell, records
end

return {
  ["startup watches idle, powers displays and holds the sleep delay"] = function()
    local actor, clock = fixture()
    assert(actor:matches("lock.unlocked") and actor:matches("idle.watching") and actor:matches("displays.on"))
    assert(actor:matches("logind.online.delay.holding") and actor:matches("logind.online.caffeine.off"))
    for _, name in ipairs({ "idle_lock", "idle_power", "idle_suspend", "power", "logind", "sleep" }) do
      assert(#pending(clock, name) == 1, name)
    end
    assert(not session.caffeinated(actor) and not session.visible(actor))
  end,

  ["an idle lock waits for acknowledgement, then authenticates as the logind account"] = function()
    local actor, clock, shell = online()
    clock.emit("idle_lock", { type = "IDLED", stage = "lock" })
    assert(actor:matches("lock.held.locking") and session.visible(actor))
    assert(shell:context().dismissed == 1, "locking dismisses the shell's overlays")
    assert(actor:context().message == "Securing session…")
    clock.emit("own", { type = "OWNED", owner = owner })
    assert(not actor:can("SUBMITTED"), "no conversation before the compositor acknowledges")
    clock.emit("own", "LOCKED")
    assert(actor:matches("lock.held.secured.authenticating"))
    assert(#pending(clock, "hint") == 1, "LockedHint follows the acknowledgement")
    assert(#pending(clock, "auth") == 1)
    local inspect = actor:inspectable()
    assert(inspect.context.owner["$h"], "the transient lock handle inspects as a marker")
  end,

  ["prompts, submission and a denied response restart the conversation"] = function()
    local actor, clock = locked()
    local conversation = { fake = "conversation" }
    clock.emit("auth", { type = "PROMPT", conversation = conversation, id = 7, text = "Password:" })
    local c = actor:context()
    assert(c.prompt.id == 7 and c.prompt.text == "Password:" and c.prompt.conversation.fake == "conversation")
    assert(c.message == "Enter your credentials to unlock.")
    actor:send("SUBMITTED")
    assert(actor:context().prompt == nil and actor:context().message == "Authenticating…")
    clock.resolve("auth", { success = false, prompted = true })
    assert(actor:matches("lock.held.secured.authenticating"))
    assert(actor:context().message == "Authentication failed. Try again.")
    assert(#pending(clock, "auth") == 1, "a fresh conversation starts without a pointer")
    clock.emit("auth", { type = "PROMPT", conversation = conversation, id = 8, text = "Password:" })
    assert(actor:context().message == "Authentication failed. Try again.", "the new prompt keeps the denial visible")
    -- Escape clears the field and starts over, dropping the denial notice.
    actor:send("CANCEL_AUTH")
    assert(actor:context().message == "Authenticating…" and actor:context().prompt == nil)
  end,

  ["only a success from the current conversation unlocks"] = function()
    local actor, clock, _, records = locked()
    clock.resolve("idle_lock", nil)
    assert(#pending(clock, "idle_lock") == 0)
    actor:send("CANCEL_AUTH")
    assert(#pending(clock, "auth") == 1, "the cancelled conversation is gone; only the new one is pending")
    clock.resolve("auth", { success = true, prompted = true })
    assert(actor:matches("lock.held.unlocking") and actor:context().message == "Unlocking…")
    local sent = records[#records].sent[1]
    assert(sent.invoke and sent.to == "session/own" and sent.event == "UNLOCK", "the own invoke unlocks its handle")
    clock.resolve("own", "unlocked")
    assert(actor:matches("lock.unlocked") and actor:context().owner == nil and actor:context().message == nil)
    assert(#pending(clock, "idle_lock") == 1, "unlocking restarts the idle timers")
  end,

  ["a failed unlock fails closed"] = function()
    local actor, clock = locked()
    clock.resolve("auth", { success = true, prompted = true })
    clock.reject("own", "unlock refused")
    assert(actor:matches("lock.held.failed") and actor:context().message:find("Unlock failed", 1, true))
  end,

  ["a denial without a prompt waits for Try again"] = function()
    local actor, clock = locked()
    clock.resolve("auth", { success = false, prompted = false })
    assert(actor:matches("lock.held.secured.stopped") and #pending(clock, "auth") == 0)
    assert(actor:context().message == "Authentication failed. Try again.")
    assert(actor:send("RETRY") and actor:matches("lock.held.secured.authenticating"))
    clock.reject("auth", "worker_failed")
    assert(actor:matches("lock.held.secured.stopped") and actor:context().message == "Authentication is unavailable. Try again.")
  end,

  ["sleep locks first and releases the delay only after acknowledgement"] = function()
    local actor, clock = online()
    clock.emit("logind", "SLEEP")
    assert(actor:matches("lock.held.locking"), "preparing for sleep requests the lock")
    assert(actor:matches("logind.online.delay.holding"), "the delay stays until the compositor acknowledges")
    clock.emit("own", { type = "OWNED", owner = owner })
    clock.emit("own", "LOCKED")
    assert(actor:matches("logind.online.delay.released") and actor:matches("lock.held.secured.waiting"))
    assert(#pending(clock, "sleep") == 0 and #pending(clock, "auth") == 0, "FD released, no authentication while sleeping")
    clock.emit("logind", "WAKE")
    assert(actor:matches("logind.online.delay.holding") and actor:matches("lock.held.secured.authenticating"))
    assert(#pending(clock, "sleep") == 1, "resume takes a fresh delay inhibitor")
  end,

  ["sleep during authentication cancels it and keeps the session locked"] = function()
    local actor, clock = locked()
    clock.emit("logind", "SLEEP")
    assert(actor:matches("lock.held.secured.waiting") and actor:context().message == "Preparing for sleep…")
    assert(#pending(clock, "auth") == 0, "the conversation was cancelled")
  end,

  ["display power-off and suspend wait for the acknowledged lock"] = function()
    local actor, clock = online()
    clock.emit("idle_power", { type = "IDLED", stage = "power" })
    assert(actor:matches("lock.held.locking") and actor:matches("displays.on"), "power-off waits for locking")
    clock.emit("own", { type = "OWNED", owner = owner })
    clock.emit("own", "LOCKED")
    assert(actor:matches("displays.off") and #pending(clock, "power", "displays.off") == 1)
    clock.emit("idle_power", { type = "RESUMED", stage = "power" })
    assert(actor:matches("displays.on"), "input restores display power")
    clock.emit("idle_suspend", { type = "IDLED", stage = "suspend" })
    assert(actor:matches("suspend.requesting") and not actor:context().suspend_due)
    clock.resolve("suspend", nil)
    assert(actor:matches("suspend.idle"))
  end,

  ["caffeine pauses idle timers but not explicit locking"] = function()
    local actor, clock = online()
    assert(actor:send("CAFFEINATE") and actor:matches("logind.online.caffeine.on.acquiring"))
    assert(not session.caffeinated(actor), "the label changes only once the inhibitor is held")
    clock.emit("idle", "INHIBITED")
    assert(session.caffeinated(actor) and actor:matches("idle.paused"), "caffeinated sessions close their idle timers")
    assert(#pending(clock, "idle_lock") == 0)
    actor:send("LOCK")
    assert(actor:matches("lock.held.locking"), "explicit locking still works")
    clock.emit("own", { type = "OWNED", owner = owner })
    clock.emit("own", "LOCKED")
    assert(actor:matches("suspend.idle"), "no idle suspend while caffeinated")
    actor:send("DECAFFEINATE")
    assert(not session.caffeinated(actor) and actor:matches("idle.watching"))
    assert(#pending(clock, "inhibit") == 1, "only the sleep-delay inhibitor is still held")
  end,

  ["a denied inhibitor keeps caffeine off and reports why"] = function()
    local actor, clock = online()
    actor:send("CAFFEINATE")
    clock.reject("idle", "session.lua:300: org.freedesktop.DBus.Error.AccessDenied: denied")
    assert(actor:matches("logind.online.caffeine.off"))
    assert(actor:context().caffeine_error == "org.freedesktop.DBus.Error.AccessDenied: denied", actor:context().caffeine_error)
    assert(actor:send("CAFFEINATE") and actor:context().caffeine_error == nil, "a retry clears the error")
  end,

  ["the compositor refusing the lock is reported, not treated as locked"] = function()
    local actor, clock = online()
    actor:send("LOCK")
    clock.emit("own", { type = "OWNED", owner = owner })
    clock.resolve("own", "refused")
    assert(actor:matches("lock.unlocked") and actor:context().status == "The compositor refused the session lock.")
  end,

  ["losing a held lock fails closed and keeps the owner"] = function()
    local actor, clock = locked()
    clock.reject("own", "Session lock ownership failed")
    assert(actor:matches("lock.held.failed") and session.visible(actor))
    assert(actor:context().owner.fake == "lock" and actor:context().message:find("trusted VT", 1, true))
    assert(not actor:can("RETRY"))
    actor:send("LOCK")
    assert(actor:matches("lock.held.failed"), "never acquires a replacement lock")
  end,

  ["losing logind releases caffeine and reconnects with backoff on the logical clock"] = function()
    local actor, clock = online()
    actor:send("CAFFEINATE")
    clock.emit("idle", "INHIBITED")
    clock.reject("logind", "bus closed")
    assert(actor:matches("logind.offline") and not session.caffeinated(actor))
    assert(actor:context().status:find("Logind is disconnected", 1, true))
    clock.advance(999)
    assert(actor:matches("logind.offline"))
    clock.advance(1)
    assert(actor:matches("logind.online.caffeine.off") and actor:context().retry == 2000)
    clock.emit("logind", "CONNECTED")
    assert(actor:context().retry == 1000)
  end,
}
