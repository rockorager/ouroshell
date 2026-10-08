-- Headless notification daemon: the Notify/CloseNotification handlers and
-- the chart behind them, with fake D-Bus emission and expiry timers.
local o = require("ouro")
local machine = o.machine
local notifications = require("notifications")

-- Stubs for the actors the daemon talks to by system id.
local shell_stub = machine.create {
  id = "shell", initial = "open", context = { arrivals = {} },
  events = { NOTIFIED = { id = "integer", replaced = "boolean", quiet = "boolean" } },
  states = { open = { on = { NOTIFIED = { actions = machine.assign { arrivals = function(c, e)
    local arrivals = machine.plain(c.arrivals)
    arrivals[#arrivals + 1] = { id = e.id, replaced = e.replaced, quiet = e.quiet }
    return arrivals
  end } } } } },
}
local catalog_stub = machine.create {
  id = "catalog", initial = "ready",
  context = { entries = { { id = "org.example.Chat.desktop", name = "Chat", icon = "chat-icon", hidden = false } } },
  states = { ready = {} },
}

local bus = { fake = "bus" }

-- Fakes run in the manual scheduler: serve parks like a live connection,
-- expiry sleeps on the virtual clock, emit records what it would send.
local function fixture()
  local emitted = {}
  local clock = machine.manual_scheduler()
  local shell = shell_stub:start { system_id = "shell", scheduler = clock }
  catalog_stub:start { system_id = "catalog", scheduler = clock }
  local daemon = notifications.chart {
    serve = function() machine.sleep(machine.max_delay_ms) end,
    emit = function(request)
      assert(request.bus.fake == "bus")
      for _, signal in ipairs(request.signals) do emitted[#emitted + 1] = machine.plain(signal) end
    end,
    expire = function(ms) machine.sleep(ms) end,
  }:start { scheduler = clock }
  daemon:send { type = "CONNECTED", bus = bus }
  local function notify(fields)
    fields = fields or {}
    local hints = fields.hints or {}
    local reply, failure = notifications.notify(daemon, { bus = bus, sender = ":1.7", args = {
      fields.app or "Chat", fields.replaces or 0, fields.icon or "", fields.title or "Hello", fields.body or "Body",
      fields.actions or {}, hints, fields.timeout or -1,
    } })
    clock.run_tasks()
    return reply, failure
  end
  local function arrivals() return shell:context().arrivals end
  -- Lets `ms` of virtual time pass and runs what it started (emits).
  function clock.wait(ms)
    clock.run_tasks()
    clock.advance(ms)
    clock.run_tasks()
  end
  return daemon, clock, notify, emitted, arrivals
end

local function variant(signature, value) return { signature = signature, value = value } end

return {
  ["Notify assigns IDs, replaces live notifications and tells the shell"] = function()
    local daemon, _, notify, _, arrived = fixture()
    local reply = notify { title = "First" }
    assert(reply[1] == 1 and arrived()[1].id == 1 and not arrived()[1].replaced and not arrived()[1].quiet)
    assert(notify { title = "Second" }[1] == 2)
    assert(notify { title = "Again", replaces = 1 }[1] == 1 and arrived()[3].replaced)
    local items = daemon:context().items
    assert(#items == 2 and items[1].title == "Again" and items[2].title == "Second")
    assert(items[1].image.name == "chat-icon", "a matching application supplies the icon")
    assert(notify { replaces = 99 }[1] == 3, "unknown replacement IDs allocate a new notification")
  end,

  ["a replacement owns the expiry; archived items close only once"] = function()
    local daemon, clock, notify, emitted = fixture()
    notify { title = "Old", icon = "old-icon" }
    notify { title = "New", replaces = 1, timeout = 0 }
    local item = daemon:context().items[1]
    assert(item.title == "New" and item.image.name == "chat-icon", "the replacement brings its own image")
    clock.wait(6000)
    assert(not daemon:context().items[1].expired, "the old timeout never expires its replacement")
    notify { title = "Brief" }
    clock.wait(6000)
    local before = #emitted
    daemon:send { type = "DISMISS", id = 2 }
    clock.run_tasks()
    assert(#emitted == before and #daemon:context().items == 1, "dismissing history sends no second closure")
  end,

  ["invalid and oversized requests are refused"] = function()
    local _, _, notify = fixture()
    local _, failure = notify { timeout = -2 }
    assert(failure.name == "org.freedesktop.DBus.Error.InvalidArgs")
    _, failure = notify { actions = { "default" } }
    assert(failure.name == "org.freedesktop.DBus.Error.InvalidArgs")
    _, failure = notify { actions = { "a", "A", "a", "B" } }
    assert(failure.message == "Action keys must be non-empty and unique")
    _, failure = notify { title = string.rep("x", 8193) }
    assert(failure.name == "org.freedesktop.DBus.Error.LimitsExceeded")
  end,

  ["expiry retains history, transient notifications vanish"] = function()
    local daemon, clock, notify, emitted = fixture()
    notify { title = "Kept" }
    notify { title = "Gone", hints = { { "transient", variant("b", true) } } }
    notify { title = "Urgent", hints = { { "urgency", variant("y", 2) } } }
    assert(notifications.timers(daemon:context().items) == 2, "critical notifications never expire")
    clock.wait(6000)
    local items = daemon:context().items
    assert(#items == 2 and items[1].title == "Urgent" and items[2].title == "Kept" and items[2].expired)
    local reasons = {}
    for _, signal in ipairs(emitted) do
      if signal.member == "NotificationClosed" then reasons[#reasons + 1] = signal.args[1] .. ":" .. signal.args[2] end
    end
    assert(table.concat(reasons, ",") == "1:1,2:1", table.concat(reasons, ","))
    assert(not daemon:can { type = "ACTIVATE", id = 1, revision = items[2].revision, key = "default" })
  end,

  ["a held popup waits, then expires after a grace period"] = function()
    local daemon, clock, notify = fixture()
    notify { title = "Hovered" }
    daemon:send { type = "HOLD", id = 1, active = true }
    clock.wait(6000)
    local item = daemon:context().items[1]
    assert(not item.expired and item.pending, "hover holds the expiry")
    daemon:send { type = "HOLD", id = 1, active = false }
    assert(daemon:context().items[1].timer:find("^grace%."), "releasing starts a grace timer")
    daemon:send { type = "HOLD", id = 1, active = true }
    clock.wait(1500)
    assert(daemon:context().items[1].pending, "hovering again holds it again")
    daemon:deliver({ type = "surface.closed.notification-popup", id = "notification-popup" }, "surface")
    clock.wait(1500)
    assert(daemon:context().items[1].expired, "the popup closing ends the hold")
  end,

  ["Do Not Disturb releases the hold and is reported to the shell"] = function()
    local daemon, clock, notify, _, live_arrivals = fixture()
    notify {}
    daemon:send { type = "HOLD", id = 1, active = true }
    daemon:send { type = "QUIET", value = true }
    assert(daemon:context().quiet and daemon:context().held == nil)
    clock.wait(6000)
    assert(daemon:context().items[1].expired)
    notify {}
    assert(live_arrivals()[2].quiet)
  end,

  ["CloseNotification, dismissal and clearing emit their reasons"] = function()
    local daemon, clock, notify, emitted = fixture()
    notify {}; notify {}; notify {}
    assert(notifications.close(daemon, { args = { 2 } })[1] == nil)
    local _, failure = notifications.close(daemon, { args = { 2 } })
    assert(failure.message == "Unknown notification")
    daemon:send { type = "DISMISS", id = 3 }
    daemon:send("CLEAR")
    clock.run_tasks()
    local reasons = {}
    for _, signal in ipairs(emitted) do reasons[#reasons + 1] = signal.args[1] .. ":" .. signal.args[2] end
    assert(table.concat(reasons, ",") == "2:3,3:2,1:2", table.concat(reasons, ","))
    assert(#daemon:context().items == 0 and daemon:context().message == "Notification history cleared.")
    assert(not daemon:can("CLEAR"), "nothing left to clear")
  end,

  ["activation sends the token first and only for the current revision"] = function()
    local daemon, clock, notify, emitted = fixture()
    notify { actions = { "default", "", "reply", "Reply" } }
    notify { title = "Resident", actions = { "open", "Open" }, hints = { { "resident", variant("b", true) } } }
    local items = daemon:context().items
    local resident, first = items[1], items[2]
    assert(first.default_action and first.actions[1].label == "Open", "an empty label becomes Open")
    assert(not daemon:send { type = "ACTIVATE", id = 1, revision = first.revision + 1, key = "default" }, "stale revision")
    assert(not daemon:send { type = "ACTIVATE", id = 1, revision = first.revision, key = "missing" })
    assert(daemon:send { type = "ACTIVATE", id = 1, revision = first.revision, key = "default", token = "xdg-token" })
    assert(daemon:send { type = "ACTIVATE", id = 2, revision = resident.revision, key = "open" })
    clock.run_tasks()
    local members = {}
    for _, signal in ipairs(emitted) do members[#members + 1] = signal.member .. (signal.destination and "@" .. signal.destination or "") end
    assert(table.concat(members, ",") == "ActivationToken@:1.7,ActionInvoked@:1.7,NotificationClosed,ActionInvoked@:1.7",
      table.concat(members, ","))
    assert(#daemon:context().items == 1 and daemon:context().items[1].title == "Resident", "resident notifications stay")
  end,

  ["history and timers are bounded"] = function()
    local daemon, _, notify = fixture()
    for _ = 1, 64 do notify {} end
    local _, failure = notify {}
    assert(failure.message == "Too many pending expiration timers")
    assert(notify { timeout = 0 }[1] == 65, "persistent notifications need no timer")
    for _ = 66, 100 do notify { timeout = 0 } end
    assert(#daemon:context().items == 100)
    notify { timeout = 0 }
    local items = daemon:context().items
    assert(#items == 100 and items[1].id == 101 and items[100].id == 2, "the oldest notification makes room")
  end,

  ["losing the connection expires live notifications into history"] = function()
    local daemon, clock, notify = fixture()
    notify {}
    notify { hints = { { "transient", variant("b", true) } } }
    clock.reject("serve", "connection lost")
    assert(daemon:matches("service.offline"))
    local items = daemon:context().items
    assert(#items == 1 and items[1].expired, "transient notifications are dropped, the rest expire")
    assert(daemon:context().message == "Notification service unavailable; reconnecting…")
    local _, failure = notify {}
    assert(failure.message == "Notification service disconnected")
    clock.wait(6000)
    assert(#daemon:context().items == 1, "expiry timers ended with the connection")
  end,
}
