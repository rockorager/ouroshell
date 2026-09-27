local ouro = require("ouro")
local center = require("notification_center")
local notification_image = require("notification_image")
local support = require("dbus_support")
local M = {}
local interface = "org.freedesktop.Notifications"
local path = "/org/freedesktop/Notifications"

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

local function invalid(message)
  return nil, { name = "org.freedesktop.DBus.Error.InvalidArgs", message = message }
end

local function limited(message)
  return nil, { name = "org.freedesktop.DBus.Error.LimitsExceeded", message = message }
end

-- The daemon controller outlives D-Bus connections. History is the single
-- source of truth: a notification is live while its stored item is current
-- and unexpired. `overlay` is the shell's one exclusive overlay: nil, or
-- { kind = "launcher" | "notifications" | "popup", id = popup_id }.
--
-- options.overlay: shared overlay signal (created when omitted)
-- options.applications: returns desktop entries used to resolve app icons
function M.new(options)
  options = options or {}
  local store = center.new()
  local overlay = options.overlay or ouro.signal(nil)
  local applications = options.applications or function() return {} end
  local state = { store = store, overlay = overlay,
    message = ouro.signal("Connecting to the notification service…") }
  -- The connection signals are emitted on, with its pending expiry timers.
  local link = nil

  local function live(id)
    local item = store.get(id)
    if item and not item.expired then return item end
  end
  local function showing(kind)
    local current = overlay()
    return current ~= nil and current.kind == kind
  end
  function state.center_open() return showing("notifications") end
  function state.popup()
    local current = overlay()
    if showing("popup") and not store.quiet() then return live(current.id) end
  end
  function state.toggle() overlay:set(not showing("notifications") and { kind = "notifications" } or nil) end
  function state.close_center() if showing("notifications") then overlay:set(nil) end end

  local function emit(member, signature, args, destination)
    if not link then return false end
    local ok = link.bus:emit { path = path, interface = interface, member = member,
      signature = signature, args = args, destination = destination }
    if not ok then
      state.message:set("Notification connection lost; reconnecting…")
      link.bus:close()
    end
    return ok
  end

  -- Ends a live notification, or drops one already expired. Retained
  -- notifications stay in history as expired items.
  local function finish(id, reason, retain)
    local item = live(id)
    if retain and item and not item.transient then store.expire(id) else store.remove(id) end
    if item then emit("NotificationClosed", "uu", { id, reason }) end
  end

  function state.dismiss(id) finish(id, 2, false) end
  function state.clear()
    for _, item in ipairs(store.items()) do finish(item.id, 2, false) end
    state.message:set("Notification history cleared.")
  end
  function state.activate(item, key)
    if live(item.id) ~= item then return end
    for _, action in ipairs(item.actions) do
      if action.key == key then
        local token = ouro.activation_token()
        -- Token acquisition yields: replacement, expiry or disconnect may win.
        if live(item.id) ~= item then return end
        if token and not emit("ActivationToken", "us", { item.id, token }, item.sender) then return end
        if not emit("ActionInvoked", "us", { item.id, key }, item.sender) then return end
        if not showing("launcher") then overlay:set(nil) end
        if not item.resident then finish(item.id, 2, false) end
        return
      end
    end
  end

  function state.attach(bus) link = { bus = bus, timers = 0 } end
  -- Without a connection no action can be delivered, so every live
  -- notification expires into history.
  function state.disconnect()
    link = nil
    for _, item in ipairs(store.items()) do
      if not item.expired then finish(item.id, 4, true) end
    end
  end

  function state.notify(request)
    local connection = link
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
    local image = notification_image.load(hints, app_icon)
      or resolve_app_icon(applications(), app, hint("desktop-entry", "s"))
    -- Import yields. Check the connection, live IDs, history and timer capacity afterwards.
    if not connection or link ~= connection then
      return nil, { name = "org.freedesktop.DBus.Error.Failed", message = "Notification service disconnected" }
    end
    local delay = urgency == 2 and 0 or (timeout == -1 and 6000 or timeout)
    if delay > 0 and connection.timers >= 64 then return limited("Too many pending expiration timers") end
    local replacement = live(replaces) and replaces or nil
    if not replacement and #store.items() >= 100 then
      finish(store.items()[#store.items()].id, 4, false)
    end
    local item = store.add({ app = display(app == "" and "Application" or app, 64),
      title = display(title == "" and "Notification" or title, 128), body = display(body, 1024),
      image = image, actions = buttons, urgent = urgency == 2,
      resident = hint("resident", "b") == true, transient = hint("transient", "b") == true,
      sender = request.sender, default_action = keys.default == true,
    }, replacement)
    if item.id > 4294967295 then
      store.remove(item.id)
      return limited("Notification IDs exhausted")
    end
    -- Popups never cover the launcher or the open notification center.
    if not store.quiet() and (overlay() == nil or showing("popup")) then
      overlay:set({ kind = "popup", id = item.id })
    end
    state.message:set("Notifications are handled by Ouroshell.")
    if delay > 0 then
      connection.timers = connection.timers + 1
      ouro.spawn(function()
        ouro.sleep(delay)
        connection.timers = connection.timers - 1
        if live(item.id) == item then finish(item.id, 1, true) end
      end)
    end
    return { item.id }
  end

  function state.close(id)
    if not live(id) then return invalid("Unknown notification") end
    finish(id, 3, false)
    return {}
  end
  return state
end

-- Binds `state` to `bus`. The export scope owns expiration tasks, so closing
-- a popup cannot cancel them.
function M.export(bus, state)
  state.attach(bus)
  return bus:export { path = path, interface = interface,
    signals = { NotificationClosed = "uu", ActionInvoked = "us", ActivationToken = "us" }, methods = {
      GetCapabilities = { input = "", output = "as",
        handler = function() return { { "body", "actions", "icon-static", "persistence" } } end },
      GetServerInformation = { input = "", output = "ssss",
        handler = function() return { "Ouroshell", "Ouro", "0.1", "1.3" } end },
      Notify = { input = "susssasa{sv}i", output = "u", handler = state.notify },
      CloseNotification = { input = "u", output = "",
        handler = function(request) return state.close(request.args[1]) end },
    },
  }
end

function M.connect(state)
  support.supervise { bus = "session", max_retry = 10000,
    session = function(bus, healthy)
      local owners <close> = support.need(bus:subscribe { sender = "org.freedesktop.DBus",
        path = "/org/freedesktop/DBus", interface = "org.freedesktop.DBus", member = "NameOwnerChanged" })
      local service <close> = support.need(M.export(bus, state))
      local name <close> = support.need(bus:own_name(interface))
      healthy()
      state.message:set("Notifications are handled by Ouroshell.")
      while true do
        local event = support.need(owners:next())
        if event.args[1] == interface and event.args[3] == "" then error("Notification name lost") end
      end
    end,
    down = function(failure)
      state.disconnect()
      state.message:set(tostring(failure):find("NameUnavailable", 1, true)
        and "Another notification daemon is running." or "Notification service unavailable; reconnecting…")
    end,
  }
end

function M.window(state)
  if state.center_open() then
    return ouro.layer_surface { id = "notifications", namespace = "ouroshell-notifications", layer = "overlay",
      width = 420, height = 0, anchors = { "top", "bottom", "right" },
      margins = { top = 56, bottom = 16, right = 16 }, exclusive_zone = -1,
      keyboard_interactivity = "on_demand", background = ouro.tokens.palette.transparent,
      content = function() return center.content(state.store, {
        close = state.close_center, clear = state.clear, dismiss = state.dismiss,
        activate = state.activate, message = state.message,
      }) end,
    }
  end
  local item = state.popup()
  if item then
    -- Actions share the header; native menus never enlarge the banner.
    return ouro.layer_surface { id = "notification-popup", namespace = "ouroshell-notification-popup", layer = "overlay",
      width = 420, height = 160, anchors = { "top", "right" },
      margins = { top = 56, right = 16 }, exclusive_zone = -1, keyboard_interactivity = "none",
      background = ouro.tokens.palette.transparent,
      content = function() return center.popup(item, {
        dismiss = function() state.dismiss(item.id) end,
        activate = function(key) state.activate(item, key) end,
      }) end,
    }
  end
end

return M
