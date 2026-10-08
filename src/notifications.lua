local ouro = require("ouro")
local notification_image = require("notification_image")
local support = require("dbus_support")
local machine = ouro.machine
local assign, unset = machine.assign, machine.unset
local M = { history_limit = 100, timer_limit = 64, max_id = 4294967295, grace_ms = 1500 }
local interface = "org.freedesktop.Notifications"
local path = "/org/freedesktop/Notifications"

-- History, newest first. Items are immutable: every change stores a new
-- table with a new `revision`, so a view can tell whether its item is still
-- current. An expired item stays readable but can no longer be activated.
local function copy(item)
  local result = {}
  for key, value in pairs(item) do result[key] = value end
  return result
end

function M.get(items, id)
  for _, item in ipairs(items or {}) do
    if item.id == id then return item end
  end
end

function M.live(items, id)
  local item = M.get(items, id)
  if item and not item.expired then return item end
end

-- Notifications grouped by application, in history order.
function M.groups(items)
  local groups, by_app = {}, {}
  for _, item in ipairs(items) do
    local group = by_app[item.app]
    if not group then
      group = { app = item.app, items = {} }
      by_app[item.app] = group
      groups[#groups + 1] = group
    end
    group.items[#group.items + 1] = item
  end
  return groups
end

-- Pending expiry timers, the daemon's bounded resource.
function M.timers(items)
  local count = 0
  for _, item in ipairs(items) do
    if item.timer and not item.expired then count = count + 1 end
  end
  return count
end

local function without(items, id)
  local result = {}
  for _, item in ipairs(items) do
    if item.id ~= id then result[#result + 1] = item end
  end
  return result
end

local function replace(items, id, fn)
  local result = {}
  for index, item in ipairs(items) do
    if item.id == id then item = copy(item); fn(item) end
    result[index] = item
  end
  return result
end

local function closed(id, reason)
  return { member = "NotificationClosed", signature = "uu", args = { id, reason } }
end

-- Ends a live notification, or drops one already expired. Retained
-- notifications stay in history as expired items. Returns the new items and
-- the NotificationClosed signal, if the notification was live.
function M.finish(items, id, reason, retain)
  local item = M.live(items, id)
  if retain and item and not item.transient then
    items = replace(items, id, function(expired) expired.expired, expired.timer, expired.pending = true, nil, nil end)
  else
    items = without(items, id)
  end
  return items, item and closed(id, reason) or nil
end

local function finish_all(items, reason, retain, filter)
  local signals = {}
  for _, item in ipairs(items) do
    if not filter or filter(item) then
      local signal
      items, signal = M.finish(items, item.id, reason, retain)
      signals[#signals + 1] = signal
    end
  end
  return items, signals
end

-- Guards also run for inspection (`accepted`) without a payload.
function M.can_notify(c, e)
  if not e.notification then return false end
  local replacing = M.live(c.items, e.replaces) ~= nil
  if not replacing and c.next_id + 1 > M.max_id then return false end
  return (e.delay or 0) <= 0 or M.timers(c.items) < M.timer_limit
end

-- Headless notification daemon. The D-Bus methods (services.serve) validate
-- and import requests, then send NOTIFY or CLOSE and reply from the
-- committed context; outgoing signals are queued in `outbox` and emitted by
-- the `emit` task. Expiry timers are spawned per notification, owned by the
-- connected state, so a disconnect cancels them and expires every live
-- notification into history. Expiry waits while the popup is hovered or
-- focused (HOLD), then resumes after a short grace period.
--   services.serve(_, send): owns the bus name and exports the interface (CONNECTED)
--   services.emit({bus, signals}): emits signals in order; raises if the bus is gone
--   services.expire(ms): waits `ms` (machine.sleep: the logical clock)
-- The bus is a transient context field: inspected as a marker, never
-- persisted. Each arrival is told to the actor with system id "shell".
function M.chart(services)
  -- Expiry timers are spawned under the id the preceding assign chose.
  local function arm(delay)
    return machine.spawn("expire", { id = function(c) return c.armed end, input = delay })
  end
  local emit = machine.spawn("emit", { input = function(c) return { bus = c.bus, signals = c.outbox } end })
  return machine.create {
    id = "notifications", initial = "service",
    context = { items = {}, next_id = 0, serial = 0, quiet = false, retry = support.retry, outbox = {},
      message = "Connecting to the notification service…" },
    transient = { "bus" },
    events = {
      CONNECTED = { bus = "any" }, RESTORED = {},
      NOTIFY = { notification = "table", replaces = "integer", delay = "integer" },
      CLOSE = { id = "integer" },
      DISMISS = { id = "integer" },
      CLEAR = {},
      ACTIVATE = { id = "integer", revision = "integer", key = "string", token = "string?" },
      QUIET = { value = "boolean" },
      HOLD = { id = "integer", active = "boolean" },
    },
    actors = { serve = services.serve, emit = services.emit, expire = services.expire },
    delays = support.delays("retry"),
    guards = {
      live = function(c, e) return M.live(c.items, e.id) ~= nil end,
      known = function(c, e) return M.get(c.items, e.id) ~= nil end,
      any = function(c) return #c.items > 0 end,
      can_notify_timed = function(c, e) return (e.delay or 0) > 0 and M.can_notify(c, e) end,
      can_notify = function(c, e) return M.can_notify(c, e) end,
      can_activate = function(c, e)
        local item = M.live(c.items, e.id)
        if not item or item.revision ~= e.revision then return false end
        for _, action in ipairs(item.actions or {}) do
          if action.key == e.key then return true end
        end
        return false
      end,
      -- An expiry timer fired for the current revision of a live item.
      due = function(c, e)
        for _, item in ipairs(c.items) do
          if item.timer == e.id and not item.expired then return true end
        end
        return false
      end,
      held = function(c, e)
        for _, item in ipairs(c.items) do
          if item.timer == e.id then return c.held == item.id end
        end
        return false
      end,
      releases_pending = function(c, e)
        local id = e.type == "HOLD" and e.id or c.held
        if e.type == "HOLD" and (e.active or c.held ~= e.id) then return false end
        local item = M.live(c.items, id)
        return item ~= nil and item.pending == true
      end,
    },
    actions = {
      connected = assign(function(_, e) return { bus = e.bus, message = unset, retry = support.retry } end),
      -- Without a connection no action can be delivered, so every live
      -- notification expires into history.
      disconnected = assign(function(c)
        local items = finish_all(c.items, 4, true, function(item) return not item.expired end)
        return { items = items, bus = unset, held = unset, outbox = {} }
      end),
      down = assign { message = function(_, e)
        return tostring(e.error):find("NameUnavailable", 1, true) and "Another notification daemon is running."
          or "Notification service unavailable; reconnecting…"
      end },
      notify = assign(function(c, e)
        local items, outbox = c.items, {}
        local replacement = M.live(items, e.replaces) and e.replaces or nil
        if not replacement and #items >= M.history_limit then
          local signal
          items, signal = M.finish(items, items[#items].id, 4, false)
          outbox[#outbox + 1] = signal
        end
        local next_id = replacement and c.next_id or c.next_id + 1
        local serial = c.serial + 1
        local added = copy(e.notification)
        added.id, added.revision = replacement or next_id, serial
        if e.delay > 0 then added.timer = "expire." .. added.id .. "." .. serial end
        local result = { added }
        for _, previous in ipairs(items) do
          if previous.id ~= added.id then result[#result + 1] = previous end
        end
        -- A new popup replaces the held one; hover is reported afresh.
        return { items = result, next_id = next_id, serial = serial, last = added.id, armed = added.timer or unset,
          replaced = replacement ~= nil, outbox = outbox, message = unset, held = unset }
      end),
      -- Popups never cover the launcher or the open center: the shell decides.
      arrived = machine.send_to({ system = "shell" }, function(c)
        return { type = "NOTIFIED", id = c.last, replaced = c.replaced, quiet = c.quiet }
      end),
      arm = arm(function(_, e) return e.delay end),
      arm_grace = arm(function() return M.grace_ms end),
      emit = emit,
      close = assign(function(c, e)
        local items, signal = M.finish(c.items, e.id, 3, false)
        return { items = items, outbox = { signal } }
      end),
      dismiss = assign(function(c, e)
        local items, signal = M.finish(c.items, e.id, 2, false)
        return { items = items, outbox = { signal } }
      end),
      clear = assign(function(c)
        local items, signals = finish_all(c.items, 2, false)
        return { items = items, outbox = signals, message = "Notification history cleared." }
      end),
      activate = assign(function(c, e)
        local item = M.live(c.items, e.id)
        local outbox = {}
        if e.token then
          outbox[1] = { member = "ActivationToken", signature = "us", args = { e.id, e.token }, destination = item.sender }
        end
        outbox[#outbox + 1] = { member = "ActionInvoked", signature = "us", args = { e.id, e.key }, destination = item.sender }
        local items = c.items
        if not item.resident then
          local signal
          items, signal = M.finish(items, e.id, 2, false)
          outbox[#outbox + 1] = signal
        end
        return { items = items, outbox = outbox }
      end),
      expire = assign(function(c, e)
        for _, item in ipairs(c.items) do
          if item.timer == e.id then
            local items, signal = M.finish(c.items, item.id, 1, true)
            return { items = items, outbox = { signal } }
          end
        end
      end),
      -- The popup is held: wait for the hold to end.
      pend = assign { items = function(c, e)
        for _, item in ipairs(c.items) do
          if item.timer == e.id then return replace(c.items, item.id, function(held) held.pending = true end) end
        end
        return c.items
      end },
      hold = assign { held = function(c, e)
        if e.active then return e.id end
        if c.held == e.id then return unset end
        return c.held
      end },
      -- The hold ended on a notification whose expiry came due: give it a
      -- short grace period, under a fresh timer id.
      grace = assign(function(c, e)
        local id = e.type == "HOLD" and e.id or c.held
        local serial = c.serial + 1
        local timer = "grace." .. id .. "." .. serial
        return { held = unset, serial = serial, armed = timer,
          items = replace(c.items, id, function(item) item.pending, item.timer = nil, timer end) }
      end),
      unhold = assign { held = unset },
      lost = assign { message = "Notification connection lost; reconnecting…" },
    },
    states = {
      service = support.reconnecting { src = "serve", retry = "retry",
        down = "disconnected", failed = "down",
        online = { on = {
          CONNECTED = { actions = "connected" },
          NOTIFY = {
            { guard = "can_notify_timed", actions = { "notify", "emit", "arm", "arrived" } },
            { guard = "can_notify", actions = { "notify", "emit", "arrived" } },
          },
          CLOSE = { guard = "live", actions = { "close", "emit" } },
          ACTIVATE = { guard = "can_activate", actions = { "activate", "emit" } },
          ["done.actor.expire.*"] = {
            { guard = "held", actions = "pend" },
            { guard = "due", actions = { "expire", "emit" } },
            {},
          },
          ["done.actor.grace.*"] = {
            { guard = "held", actions = "pend" },
            { guard = "due", actions = { "expire", "emit" } },
            {},
          },
          ["done.actor.emit.*"] = {},
          ["error.actor.emit.*"] = { actions = "lost" },
          HOLD = { { guard = "releases_pending", actions = { "grace", "arm_grace" } }, { actions = "hold" } },
          -- The popup closed under the pointer: nothing holds it any more.
          ["surface.closed.notification-popup"] = {
            { guard = "releases_pending", actions = { "grace", "arm_grace" } }, { actions = "unhold" } },
        } } },
    },
    on = {
      -- After a source reload the old connection and its expiry timers are
      -- gone: like a disconnect, live notifications expire into history.
      RESTORED = { actions = "disconnected" },
      DISMISS = { guard = "known", actions = { "dismiss", "emit" } },
      CLEAR = { guard = "any", actions = { "clear", "emit" } },
      -- Do Not Disturb hides the popup, so nothing holds it any more.
      QUIET = { actions = assign(function(_, e) return { quiet = e.value, held = unset } end) },
      HOLD = { actions = "hold" },
      ["surface.*"] = {},
    },
  }
end

local function display(value, limit)
  if #value <= limit then return value end
  return value:sub(1, utf8.offset(value, 0, limit + 1) - 1) .. "…"
end

local function resolve_app_icon(entries, app, desktop_entry)
  local function named(value)
    return type(value) == "string" and value ~= "" and not value:find("/", 1, true) and value or nil
  end
  if desktop_entry then
    local id = desktop_entry:gsub("%.desktop$", "") .. ".desktop"
    for _, entry in ipairs(entries) do
      if entry.id == id and not entry.hidden and named(entry.icon) then return { name = entry.icon } end
    end
  end
  for _, entry in ipairs(entries) do
    if not entry.hidden and entry.name:lower() == app:lower() and named(entry.icon) then return { name = entry.icon } end
  end
end

local function catalog_entries()
  local catalog = machine.system("catalog")
  return catalog and catalog:context().entries or {}
end

local function invalid(message)
  return nil, { name = "org.freedesktop.DBus.Error.InvalidArgs", message = message }
end

local function limited(message)
  return nil, { name = "org.freedesktop.DBus.Error.LimitsExceeded", message = message }
end

local function failed(message)
  return nil, { name = "org.freedesktop.DBus.Error.Failed", message = message }
end

-- The Notify method: validate, import the image (which yields), then let the
-- chart allocate the ID. `daemon` is the notifications actor; application
-- icons resolve from the actor with system id "catalog", when there is one.
function M.notify(daemon, request)
  local app, replaces, app_icon, title, body, actions, hints, timeout = table.unpack(request.args)
  if timeout < -1 or #actions % 2 ~= 0 then return invalid("Invalid timeout or action pairs") end
  if #app > 4096 or #title > 8192 or #body > 32768 or #app_icon > 4096 or #actions > 8 then
    return limited("Notification text or action count exceeds limits")
  end
  local values = support.variants(hints)
  local function hint(key, signature)
    local value = values[key]
    if value and value.signature == signature then return value.value end
  end
  local urgency = hint("urgency", "y") or 1
  local buttons, keys = {}, {}
  for index = 1, #actions, 2 do
    local key, label = actions[index], actions[index + 1]
    if key == "" or keys[key] then return invalid("Action keys must be non-empty and unique") end
    if #key > 256 or #label > 4096 then return limited("Action text exceeds limits") end
    keys[key] = true
    buttons[#buttons + 1] = { key = key, label = display(label == "" and "Open" or label, 64) }
  end
  -- Import before replying: senders can delete their temporary image as soon
  -- as the notification closes. History owns the resulting thumbnail.
  local image = notification_image.load(hints, app_icon)
    or resolve_app_icon(catalog_entries(), app, hint("desktop-entry", "s"))
  -- The import yields: check the connection, live IDs and limits afterwards,
  -- from the committed context, with no yield before the send.
  local c = daemon:context()
  if not daemon:matches("service.online") or machine.raw(c.bus) ~= request.bus then
    return failed("Notification service disconnected")
  end
  local delay = urgency == 2 and 0 or (timeout == -1 and 6000 or timeout)
  if delay > 0 and M.timers(c.items) >= M.timer_limit then return limited("Too many pending expiration timers") end
  local replaced = M.live(c.items, replaces) ~= nil
  if not replaced and c.next_id + 1 > M.max_id then return limited("Notification IDs exhausted") end
  local accepted = daemon:send { type = "NOTIFY", replaces = replaces, delay = delay, notification = {
    app = display(app == "" and "Application" or app, 64),
    title = display(title == "" and "Notification" or title, 128), body = display(body, 1024),
    image = image, actions = buttons, urgent = urgency == 2,
    resident = hint("resident", "b") == true, transient = hint("transient", "b") == true,
    sender = request.sender, default_action = keys.default == true,
  } }
  if not accepted then return failed("Notification rejected") end
  return { daemon:context().last }
end

function M.close(daemon, request)
  local id = request.args[1]
  if not daemon:send { type = "CLOSE", id = id } then return invalid("Unknown notification") end
  return {}
end

-- One daemon session: export the interface, own the name, and serve until
-- the name or the bus is lost. Method handlers run in this export's scope.
function M.serve(daemon, send)
  local bus <close> = support.connect("session")
  local owners <close> = support.need(bus:subscribe { sender = "org.freedesktop.DBus",
    path = "/org/freedesktop/DBus", interface = "org.freedesktop.DBus", member = "NameOwnerChanged" })
  local export <close> = support.need(bus:export { path = path, interface = interface,
    signals = { NotificationClosed = "uu", ActionInvoked = "us", ActivationToken = "us" }, methods = {
      GetCapabilities = { input = "", output = "as",
        handler = function() return { { "body", "actions", "icon-static", "persistence" } } end },
      GetServerInformation = { input = "", output = "ssss",
        handler = function() return { "Ouroshell", "Ouro", "0.1", "1.3" } end },
      Notify = { input = "susssasa{sv}i", output = "u", handler = function(request)
        request.bus = bus
        return M.notify(daemon, request)
      end },
      CloseNotification = { input = "u", output = "", handler = function(request) return M.close(daemon, request) end },
    },
  })
  local name <close> = support.need(bus:own_name(interface))
  send { type = "CONNECTED", bus = bus }
  while true do
    local event = support.need(owners:next())
    if event.args[1] == interface and event.args[3] == "" then error("Notification name lost") end
  end
end

M.services = {
  serve = function(_, send) return M.serve(machine.system("notifications"), send) end,
  emit = function(request)
    if not request.bus then return end
    for _, signal in ipairs(request.signals) do
      local ok = request.bus:emit { path = path, interface = interface, member = signal.member,
        signature = signal.signature, args = signal.args, destination = signal.destination }
      if not ok then
        request.bus:close()
        error("Notification connection lost")
      end
    end
  end,
  expire = function(ms) machine.sleep(ms) end,
}

return M
