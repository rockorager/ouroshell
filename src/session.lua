local ouro = require("ouro")
local config = require("config")
local support = require("dbus_support")
local machine = ouro.machine
local assign, unset, raise = machine.assign, machine.unset, machine.raise
local M = {}
local service = "org.freedesktop.login1"
local path = "/org/freedesktop/login1"
local manager = service .. ".Manager"
local session_interface = service .. ".Session"
local recovery = " End this graphical session from a trusted VT or SSH session."

-- An error for people: without the Lua source position.
local function message(err) return (tostring(err):gsub("^[%w_%.%-]+:%d+: ", "")) end

-- Headless session policy: native idle timers and display power, the session
-- lock and its PAM conversation, and logind's sleep, Lock signal and
-- inhibitors. Every native resource (lock ownership, the conversation, the
-- inhibitor FDs, idle timers, output power) lives in an invoke of the state
-- that needs it, so leaving the state releases it. The lock handle stays
-- reachable in context (closing it never unlocks, docs/session.md), and the
-- prompt carries the conversation the masked field binds to; both are
-- transient: inspected as markers, never persisted (reload is refused while
-- a lock is held anyway).
--
-- Only a successful PAM result from the auth invoke of the current lock
-- reaches `unlocking`. Submission, cancellation and errors never do.
--
--   services.logind(_, send): serves logind (IDENTITY, SLEEP, WAKE, LOCK, CONNECTED)
--   services.inhibit({what, why, mode, event}, send): holds an inhibitor FD; sends `event` once held
--   services.own(_, send, receive): owns the session lock (OWNED, LOCKED) and
--     unlocks it on UNLOCK from the chart; returns "unlocked" or "refused"
--   services.auth({username, service}, send): one PAM conversation (PROMPT, AUTH_MESSAGE);
--     returns { success, prompted }
--   services.idle({stage, ms}, send): one idle timer (IDLED, RESUMED)
--   services.power(on, send): holds every output's power at `on` (REPORT)
--   services.suspend(): asks logind to suspend
--   services.hint({session, locked}): logind's advisory LockedHint
-- Locking tells the actor with system id "shell" to DISMISS its overlays.
function M.chart(services)
  local function secured(state) return state.matches("lock.held.secured") end
  local function awake(state) return state.matches("sleep.awake") end
  local function caffeinated(state) return state.matches("logind.online.caffeine.on.held") end
  local function hint(locked)
    return machine.spawn("hint", { input = function(c) return { session = c.session, locked = locked } end })
  end
  local function idle_timer(stage, ms)
    return { id = "idle_" .. stage, src = "idle", input = function() return { stage = stage, ms = ms } end,
      on_error = { actions = "report_error" } }
  end
  local function inhibitor(what, why, mode, event, on_error)
    return { id = what, src = "inhibit", input = function() return { what = what, why = why, mode = mode, event = event } end,
      on_error = on_error }
  end

  return machine.create {
    id = "session", type = "parallel",
    order = { "logind", "sleep", "lock", "idle", "displays", "suspend" },
    context = { retry = support.retry, power_due = false, suspend_due = false },
    transient = { "owner", "prompt" },
    delays = support.delays("retry"),
    events = {
      -- From logind.
      IDENTITY = { username = "string", session = "string" },
      SLEEP = {}, WAKE = {}, CONNECTED = {}, INHIBITED = {},
      -- From the idle timers, output power and the lock.
      IDLED = { stage = "string" }, RESUMED = { stage = "string" },
      REPORT = { message = "string" },
      OWNED = { owner = "any" }, LOCKED = {},
      PROMPT = { conversation = "any", id = "any", text = "string?" },
      AUTH_MESSAGE = { text = "string" },
      -- From the lock screen, the launcher, the bar and MCP.
      LOCK = {}, SUBMITTED = {}, CANCEL_AUTH = {}, STALE = {}, RETRY = {},
      CAFFEINATE = {}, DECAFFEINATE = {},
    },
    actors = {
      logind = services.logind, inhibit = services.inhibit, own = services.own,
      auth = services.auth, idle = services.idle, power = services.power, suspend = services.suspend,
      hint = services.hint,
    },
    guards = {
      new_identity = function(c, e) return c.username ~= e.username end,
      owned = function(c) return c.owner ~= nil end,
      unlocking = function(_, _, state) return state.matches("lock.held.unlocking") end,
      refused = function(_, e) return e.output == "refused" end,
      success = function(_, e) return e.output.success == true end,
      prompted = function(_, e) return e.output.prompted == true end,
      can_authenticate = function(c, _, state) return c.username ~= nil and awake(state) end,
      -- Lock-before-sleep: the delay FD may only close once the compositor
      -- acknowledged the lock.
      release_delay = function(_, _, state) return not awake(state) and secured(state) end,
      preparing = function(_, _, state) return not awake(state) end,
      paused = function(_, _, state) return not awake(state) or caffeinated(state) end,
      watching = function(_, _, state) return awake(state) and not caffeinated(state) end,
      blank = function(c, _, state) return c.power_due and secured(state) and awake(state) and not caffeinated(state) end,
      unblank = function(c) return not c.power_due end,
      suspend = function(c, _, state) return c.suspend_due and secured(state) and awake(state) and not caffeinated(state) end,
      logind_online = function(_, _, state) return state.matches("logind.online") end,
    },
    actions = {
      identity = assign(function(_, e) return { username = e.username, session = e.session } end),
      connected = support.reset("retry"),
      logind_lost = assign { status = "Logind is disconnected; lock-before-suspend and idle suspend are unavailable." },
      report = assign { status = function(_, e) return e.message end },
      report_error = assign { status = function(_, e) return message(e.error) end },
      clear_status = assign { status = unset, caffeine_error = unset },
      caffeine_failed = assign { caffeine_error = function(_, e) return message(e.error) end },
      -- Idle stages. Restarting the timers clears what they made due.
      clear_due = assign { power_due = false, suspend_due = false },
      idled = assign(function(_, e)
        if e.stage == "power" then return { power_due = true } end
        if e.stage == "suspend" then return { suspend_due = true } end
      end),
      resumed = assign(function(_, e)
        if e.stage == "power" then return { power_due = false } end
        if e.stage == "suspend" then return { suspend_due = false } end
      end),
      -- An explicit lock request is activity: show the displays.
      lock_now = assign { power_due = false },
      take_suspend = assign { suspend_due = false },
      suspend_unavailable = assign { status = "Idle suspend is unavailable; logind is disconnected." },
      suspend_failed = assign { status = function(_, e) return "Idle suspend failed: " .. message(e.error) end },
      -- The lock.
      dismiss = machine.send_to({ system = "shell" }, "DISMISS"),
      securing = assign { message = "Securing session…" },
      owned = assign { owner = function(_, e) return e.owner end },
      released = assign { owner = unset, message = unset, prompt = unset },
      refused = assign { owner = unset, power_due = false, suspend_due = false,
        status = "The compositor refused the session lock." },
      lock_failed = assign(function(_, e)
        return { power_due = false, suspend_due = false, status = "Session locking failed: " .. message(e.error) }
      end),
      lock_lost = assign(function(_, e)
        return { message = "Lock control was lost." .. recovery, power_due = false, suspend_due = false,
          status = "Session locking failed: " .. message(e.error) }
      end),
      unlock_failed = assign { message = "Unlock failed." .. recovery },
      -- Authentication. `notice` replaces the usual guidance for one attempt.
      clear_notice = assign { notice = unset },
      begin = assign { message = function(c) return c.notice or "Authenticating…" end },
      prompt = assign(function(c, e)
        return { prompt = { conversation = e.conversation, id = e.id, text = e.text },
          message = c.notice or "Enter your credentials to unlock." }
      end),
      auth_message = assign { message = function(_, e) return e.text end },
      submitted = assign { prompt = unset, message = "Authenticating…" },
      forget_prompt = assign { prompt = unset },
      denied_retry = assign { notice = "Authentication failed. Try again." },
      denied = assign { message = "Authentication failed. Try again." },
      unavailable = assign { message = "Authentication is unavailable. Try again." },
      no_identity = assign { message = "Session identity is unavailable. Try again when logind reconnects." },
      sleeping = assign { message = "Preparing for sleep…" },
      unlocking = assign { message = "Unlocking…" },
      surface_failed = assign { status = function(_, e) return "Lock screen failed (" .. tostring(e.reason) .. "): " .. tostring(e.message) end },
    },
    on = {
      -- Bound lock surfaces report back; only a failure needs attention.
      ["surface.failed.*"] = { actions = "surface_failed" },
      ["surface.*"] = {},
      REPORT = { actions = "report" },
    },
    states = {
      logind = support.reconnecting { src = "logind", retry = "retry", down = "logind_lost",
        online = {
          type = "parallel", order = { "delay", "caffeine" },
          on = { CONNECTED = { actions = "connected" } },
          states = {
            delay = { initial = "holding", states = {
              holding = {
                -- Without the delay inhibitor, lock-before-suspend is not
                -- guaranteed: reconnect, as for any logind failure.
                invoke = inhibitor("sleep", "Lock the session before sleep", "delay", nil,
                  { target = "#logind.offline", actions = "report_error" }),
                always = { target = "released", guard = "release_delay" },
              },
              released = { on = { WAKE = "holding" } },
            } },
            caffeine = { initial = "off", states = {
              off = { on = { CAFFEINATE = { target = "on", actions = "clear_status" } } },
              on = { initial = "acquiring",
                invoke = inhibitor("idle", "Caffeinated from the launcher", "block", "INHIBITED",
                  { target = "off", actions = "caffeine_failed" }),
                on = { DECAFFEINATE = { target = "off", actions = "clear_status" } },
                states = {
                  acquiring = { on = { INHIBITED = "held" } },
                  held = {},
                },
              },
            } },
          },
        } },
      sleep = { initial = "awake", states = {
        awake = { on = { SLEEP = "preparing" } },
        preparing = { on = { WAKE = "awake" } },
      } },
      lock = { initial = "unlocked",
        on = { IDENTITY = { guard = "new_identity", actions = "identity" } },
        states = {
          unlocked = {
            -- Suspend may arrive while authentication queued an unlock: lock
            -- again before the delay inhibitor can be released.
            always = { target = "held", guard = "preparing" },
            on = { LOCK = "held", IDLED = "held" },
          },
          held = { initial = "locking", entry = { "securing", "dismiss" },
            invoke = { id = "own", src = "own",
              on_done = {
                { target = "unlocked", guard = "refused", actions = "refused" },
                { target = "unlocked", actions = { "released", hint(false), raise("UNLOCKED") } },
              },
              on_error = {
                { target = ".failed", guard = "unlocking", actions = "unlock_failed" },
                { target = ".failed", guard = "owned", actions = "lock_lost" },
                { target = "unlocked", actions = { "released", "lock_failed" } },
              } },
            on = { OWNED = { actions = "owned" } },
            states = {
              locking = { on = { LOCKED = { target = "secured", actions = hint(true) } } },
              secured = { initial = "waiting",
                on = {
                  RETRY = { { target = ".authenticating", guard = "can_authenticate", actions = "clear_notice" },
                            { actions = "no_identity" } },
                  SLEEP = { target = ".waiting", actions = "sleeping" },
                  IDENTITY = { target = ".waiting", guard = "new_identity", actions = "identity" },
                },
                states = {
                  waiting = { entry = "clear_notice",
                    always = { target = "authenticating", guard = "can_authenticate" } },
                  authenticating = { entry = "begin", exit = "forget_prompt",
                    invoke = { id = "auth", src = "auth",
                      input = function(c) return { username = c.username, service = config.pam_service } end,
                      on_done = {
                        { target = "#lock.held.unlocking", guard = "success", actions = "unlocking" },
                        { target = "authenticating", reenter = true, guard = "prompted", actions = "denied_retry" },
                        { target = "stopped", actions = "denied" },
                      },
                      on_error = { target = "stopped", actions = "unavailable" } },
                    on = {
                      PROMPT = { actions = "prompt" },
                      AUTH_MESSAGE = { actions = "auth_message" },
                      SUBMITTED = { actions = "submitted" },
                      -- Escape clears the field and starts a fresh conversation.
                      CANCEL_AUTH = { target = "authenticating", reenter = true, actions = "clear_notice" },
                      STALE = { target = "stopped", actions = "unavailable" },
                    } },
                  -- No automatic retry: a denial without any prompt (for
                  -- example a locked account) waits for Try again.
                  stopped = {},
                } },
              -- The own invoke unlocks the exact handle it acquired.
              unlocking = { entry = machine.send_to("own", { type = "UNLOCK" }) },
              -- Fail closed: keep the owner and the lock surface.
              failed = {},
            } },
        } },
      idle = { initial = "watching", states = {
        watching = { entry = "clear_due", exit = "clear_due",
          invoke = { idle_timer("lock", config.idle.lock_ms), idle_timer("power", config.idle.power_ms),
                     idle_timer("suspend", config.idle.suspend_ms) },
          always = { target = "paused", guard = "paused" },
          on = {
            IDLED = { actions = "idled" }, RESUMED = { actions = "resumed" },
            UNLOCKED = { target = "watching", reenter = true },
            LOCK = { actions = "lock_now" },
          } },
        paused = { always = { target = "watching", guard = "watching" } },
      } },
      displays = { initial = "on", states = {
        on = { invoke = { src = "power", input = function() return true end }, always = { target = "off", guard = "blank" } },
        off = { invoke = { src = "power", input = function() return false end }, always = { target = "on", guard = "unblank" } },
      } },
      suspend = { initial = "idle", states = {
        idle = { always = {
          { target = "requesting", guard = "suspend", actions = "take_suspend" },
        } },
        requesting = {
          always = { target = "idle", guard = function(_, _, state) return not state.matches("logind.online") end,
            actions = "suspend_unavailable" },
          invoke = { src = "suspend", on_done = "idle", on_error = { target = "idle", actions = "suspend_failed" } },
          on = { RESUMED = "idle", WAKE = "idle" },
        },
      } },
    },
  }
end

-- Snapshot helpers shared by the views, the launcher and MCP.
function M.caffeinated(session) return session:matches("logind.online.caffeine.on.held") end
function M.visible(session) return not session:matches("lock.unlocked") end

local function call(bus, target, interface, member, signature, args)
  return support.need(bus:call { destination = service, path = target, interface = interface,
    member = member, signature = signature, args = args, timeout_ms = 5000 })
end

M.services = {
  logind = function(_, send)
    local bus <close> = support.connect("system")
    -- One ordered stream covers sleep and this session's explicit Lock signal.
    local events <close> = support.need(bus:subscribe { sender = service, close_on_owner_change = true })
    local session = call(bus, path, manager, "GetSession", "s", { "auto" }).args[1]
    local properties = call(bus, session, "org.freedesktop.DBus.Properties", "GetAll", "s", { session_interface })
    local username = support.properties(properties.args[1]).Name
    assert(type(username) == "string" and username ~= "", "Logind returned no session account")
    send { type = "IDENTITY", username = username, session = session }
    local preparing = call(bus, path, "org.freedesktop.DBus.Properties", "Get", "ss", { manager, "PreparingForSleep" }).args[1]
    assert(preparing.signature == "b", "Invalid logind sleep state")
    send(preparing.value and "SLEEP" or "WAKE")
    send("CONNECTED")
    while true do
      local message = support.need(events:next())
      if message.path == path and message.interface == manager and message.member == "PrepareForSleep"
        and message.signature == "b" then
        send(message.args[1] and "SLEEP" or "WAKE")
      elseif message.path == session and message.interface == session_interface and message.member == "Lock" then
        send("LOCK")
      end
      -- Session.Unlock and LockedHint are never authorization to unlock.
    end
  end,
  -- A callback invoke: the FD is held until the owning state exits and the
  -- returned cleanup closes it.
  inhibit = function(request, send)
    local bus <close> = support.connect("system")
    local reply = call(bus, path, manager, "Inhibit", "ssss", { request.what, "Ouroshell", request.why, request.mode })
    assert(reply.signature == "h" and reply.args[1], "Invalid logind inhibitor reply")
    local fd = reply.args[1]
    if request.event then send(request.event) end
    return function() fd:close() end
  end,
  own = function(_, send, receive)
    local owner = ouro.session.lock()
    send { type = "OWNED", owner = owner }
    -- Only the chart's `unlocking` state, reached by a PAM success, asks.
    receive(function(event)
      if event.type == "UNLOCK" then owner:unlock() end
    end)
    local acknowledged = false
    while true do
      local event = owner:next()
      if event == "locked" then
        acknowledged = true
        send("LOCKED")
      elseif event == "unlocked" then
        owner:close()
        return "unlocked"
      elseif event == "finished" and not acknowledged then
        owner:close()
        return "refused"
      else
        -- After a lock request, failure is not evidence of an unlocked
        -- desktop. The chart keeps the owner and never acquires a replacement.
        error("Session lock ownership failed")
      end
    end
  end,
  auth = function(request, send)
    local auth, failure = ouro.auth.start(request.service, request.username)
    if not auth then error(failure) end
    local conversation <close> = auth
    local prompted = false
    while true do
      local event = conversation:next()
      if not event then error("Authentication conversation closed") end
      if event.type == "prompt" then
        prompted = true
        send { type = "PROMPT", conversation = auth, id = event.id, text = event.text }
      elseif event.type == "info" or event.type == "error" then
        send { type = "AUTH_MESSAGE", text = tostring(event.text) }
      elseif event.type == "result" then
        return { success = event.success == true, prompted = prompted }
      end
    end
  end,
  idle = function(request, send)
    local timer <close> = ouro.session.idle(request.ms)
    while true do
      local event = timer:next()
      if event == "idled" then send { type = "IDLED", stage = request.stage }
      elseif event == "resumed" then send { type = "RESUMED", stage = request.stage }
      else error("Idle notifications unavailable") end
    end
  end,
  -- Full native output snapshots, independent of workspaces or UI builds.
  -- Each output's power control reconnects on its own.
  power = function(on, send)
    local stream <close> = ouro.session.outputs()
    local outputs = {}
    while true do
      local names = stream:next()
      if not names then send { type = "REPORT", message = "Output discovery is unavailable." }; return end
      local present = {}
      for _, name in ipairs(names) do present[name] = true end
      for name in pairs(outputs) do
        if not present[name] then outputs[name] = nil end
      end
      for _, name in ipairs(names) do
        if not outputs[name] then
          local output = {}
          outputs[name] = output
          ouro.spawn(function()
            local retry = 1000
            while outputs[name] == output do
              local ok = pcall(function()
                local power <close> = ouro.session.power(name)
                local first = true
                while outputs[name] == output do
                  local event = power:next()
                  if outputs[name] ~= output then return end
                  if event ~= "on" and event ~= "off" then error("Power control unavailable") end
                  if first then
                    if not pcall(power.set, power, on) then
                      send { type = "REPORT", message = "Display power control failed for " .. name }
                    end
                    first = false
                  end
                  retry = 1000
                end
              end)
              if outputs[name] ~= output then return end
              if not ok then send { type = "REPORT", message = "Display power control unavailable for " .. name } end
              machine.sleep(retry)
              retry = math.min(retry * 2, 30000)
            end
          end)
        end
      end
    end
  end,
  suspend = function()
    local bus <close> = support.connect("system")
    call(bus, path, manager, "Suspend", "b", { false })
  end,
  hint = function(request)
    if not request.session then return end
    -- LockedHint is advisory. Never use it as lock acknowledgement.
    local bus <close> = support.connect("system")
    pcall(call, bus, request.session, session_interface, "SetLockedHint", "b", { request.locked })
  end,
}

return M
