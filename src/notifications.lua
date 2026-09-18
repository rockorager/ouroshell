local ouro = require("ouro")
local center = require("notification_center")
local M = {}
local interface = "org.freedesktop.Notifications"
local path = "/org/freedesktop/Notifications"

local function display(value, limit)
  if #value <= limit then return value end
  return value:sub(1, utf8.offset(value, 0, limit + 1) - 1) .. "…"
end

function M.new(applications)
  local state = center.new()
  state.applications = applications or function() return {} end
  state.visible = ouro.signal(false)
  state.popup = ouro.signal(nil)
  state.message = ouro.signal("Connecting to the notification service…")
  state.ready = ouro.signal(false)
  state.remove = state.dismiss
  function state.toggle()
    state.visible:set(not state.visible())
    state.popup:set(nil)
  end
  function state.close_center() state.visible:set(false) end
  return state
end

local function resolve_app_icon(state, app, supplied, desktop_entry)
  local function named(value)
    return type(value) == "string" and value ~= "" and not value:find("/", 1, true) and value or nil
  end
  local entries = state.applications()
  if desktop_entry then
    local id = desktop_entry:gsub("%.desktop$", "") .. ".desktop"
    for _, entry in ipairs(entries) do
      if entry.id == id and not entry.hidden and named(entry.icon) then return entry.icon end
    end
  end
  if named(supplied) then return supplied end
  for _, entry in ipairs(entries) do
    if not entry.hidden and entry.name:lower() == app:lower() and named(entry.icon) then return entry.icon end
  end
end

-- Export scope owns expiration tasks, so closing a popup cannot cancel them.
function M.export(bus, state)
  local active, timers = {}, 0
  local function emit(member, signature, args, destination)
    local ok, failure = bus:emit { path = path, interface = interface, member = member,
      signature = signature, args = args, destination = destination }
    if not ok then
      state.message:set("Notification connection lost; reconnecting…")
      bus:close()
    end
    return ok, failure
  end
  local function finish(id, reason, retain, send)
    local item = active[id]
    active[id] = nil -- Invalidate before emitting NotificationClosed.
    if state.popup() and state.popup().id == id then state.popup:set(nil) end
    if retain and item and not item.transient then
      local items = {}
      for _, previous in ipairs(state.items()) do
        if previous.id == id then
          local archived = {}
          for key, value in pairs(previous) do archived[key] = value end
          archived.actions = {} -- A closed ID must never invoke stale actions.
          archived.default_action = false
          items[#items + 1] = archived
        else items[#items + 1] = previous end
      end
      state.items:set(items)
    else state.remove(id) end
    if item and send then emit("NotificationClosed", "uu", { id, reason }) end
  end
  function state.dismiss(id) finish(id, 2, false, true) end
  function state.clear()
    local items = state.items()
    for _, item in ipairs(items) do state.dismiss(item.id) end
    state.message:set("Notification history cleared.")
  end
  function state.activate(item, key)
    if active[item.id] ~= item then return end
    for _, action in ipairs(item.actions) do
      if action.key == key then
        local token = ouro.activation_token()
        -- Token acquisition yields: replacement, expiry or disconnect may win.
        if active[item.id] ~= item then return end
        if token and not emit("ActivationToken", "us", { item.id, token }, item.sender) then return end
        if emit("ActionInvoked", "us", { item.id, key }, item.sender) then
          state.visible:set(false)
          state.popup:set(nil)
        else return end
        if not item.resident then
          finish(item.id, 2, false, true)
        end
        return
      end
    end
  end
  function state.disconnect()
    local ids = {}
    for id in pairs(active) do ids[#ids + 1] = id end
    for _, id in ipairs(ids) do finish(id, 4, true, false) end
  end
  local function invalid(message)
    return nil, { name = "org.freedesktop.DBus.Error.InvalidArgs", message = message }
  end
  local function limited(message)
    return nil, { name = "org.freedesktop.DBus.Error.LimitsExceeded", message = message }
  end
  return bus:export { path = path, interface = interface,
    signals = { NotificationClosed = "uu", ActionInvoked = "us", ActivationToken = "us" }, methods = {
      GetCapabilities = { input = "", output = "as", handler = function() return { { "body", "actions" } } end },
      GetServerInformation = { input = "", output = "ssss",
        handler = function() return { "Ouroshell", "Ouro", "0.1", "1.3" } end },
      Notify = { input = "susssasa{sv}i", output = "u", handler = function(request)
        local app, replaces, app_icon, title, body, actions, hints, timeout = table.unpack(request.args)
        if timeout < -1 or #actions % 2 ~= 0 then return invalid("Invalid timeout or action pairs") end
        if #app > 4096 or #title > 8192 or #body > 32768 or #app_icon > 4096 or #actions > 8 then
          return limited("Notification text or action count exceeds limits")
        end
        local urgency, resident, transient = 1, false, false
        local desktop_entry
        for _, pair in ipairs(hints) do
          local hint = pair[2]
          if pair[1] == "urgency" and hint.signature == "y" then urgency = hint.value
          elseif pair[1] == "resident" and hint.signature == "b" then resident = hint.value
          elseif pair[1] == "transient" and hint.signature == "b" then transient = hint.value
          elseif pair[1] == "desktop-entry" and hint.signature == "s" then desktop_entry = hint.value end
        end
        local delay = urgency == 2 and 0 or (timeout == -1 and 6000 or timeout)
        if delay > 0 and timers >= 64 then return limited("Too many pending expiration timers") end
        local buttons, keys = {}, {}
        for index = 1, #actions, 2 do
          local key, label = actions[index], actions[index + 1]
          if key == "" or keys[key] then return invalid("Action keys must be non-empty and unique") end
          if #key > 256 or #label > 4096 then return limited("Action text exceeds limits") end
          keys[key] = true
          buttons[#buttons + 1] = { key = key, label = display(label == "" and "Open" or label, 64) }
        end
        local replacement = active[replaces] and replaces or nil
        if not replacement and #state.items() >= 100 then
          finish(state.items()[#state.items()].id, 4, false, true)
        end
        local item = state.add({ app = display(app == "" and "Application" or app, 64),
          title = display(title == "" and "Notification" or title, 128), body = display(body, 1024),
          icon = resolve_app_icon(state, app, app_icon, desktop_entry),
          actions = buttons, urgent = urgency == 2, resident = resident, transient = transient,
          sender = request.sender, default_action = keys.default == true,
        }, replacement)
        if item.id > 4294967295 then
          state.remove(item.id)
          return limited("Notification IDs exhausted")
        end
        active[item.id] = item
        if not state.quiet() and not state.visible() then state.popup:set(item)
        elseif state.popup() and state.popup().id == item.id then state.popup:set(nil) end
        state.message:set("Notifications are handled by Ouroshell.")
        if delay > 0 then
          timers = timers + 1
          ouro.spawn(function()
            ouro.sleep(delay)
            timers = timers - 1
            if active[item.id] == item then finish(item.id, 1, true, true) end
          end)
        end
        return { item.id }
      end },
      CloseNotification = { input = "u", output = "", handler = function(request)
        local id = request.args[1]
        if not active[id] then return invalid("Unknown notification") end
        finish(id, 3, false, true)
        return {}
      end },
    },
  }
end

function M.connect(state)
  ouro.spawn(function()
    local retry = 1000
    while true do
      local ok, failure = pcall(function()
        local connection, err = ouro.dbus.connect("session")
        assert(connection, err and err.message)
        local bus <close> = connection
        local stream, stream_error = bus:subscribe { sender = "org.freedesktop.DBus", path = "/org/freedesktop/DBus",
          interface = "org.freedesktop.DBus", member = "NameOwnerChanged" }
        assert(stream, stream_error and stream_error.message)
        local owners <close> = stream
        local exported, export_error = M.export(bus, state)
        assert(exported, export_error and export_error.message)
        local service <close> = exported
        local owned, name_error = bus:own_name(interface)
        assert(owned, name_error and name_error.name)
        local name <close> = owned
        state.ready:set(true)
        state.message:set("Notifications are handled by Ouroshell.")
        retry = 1000
        while true do
          local event = owners:next()
          if not event or (event.args[1] == interface and event.args[3] == "") then error("Notification bus disconnected") end
        end
      end)
      state.ready:set(false)
      if state.disconnect then state.disconnect() end
      state.popup:set(nil)
      state.message:set(not ok and tostring(failure):find("NameUnavailable", 1, true)
        and "Another notification daemon is running." or "Notification service unavailable; reconnecting…")
      ouro.sleep(retry)
      retry = math.min(retry * 2, 10000)
    end
  end)
end

function M.window(state)
  if state.visible() then
    return ouro.layer_surface { id = "notifications", namespace = "ouroshell-notifications", layer = "overlay",
      width = 420, height = 0, anchors = { "top", "bottom", "right" },
      margins = { top = 56, bottom = 16, right = 16 }, exclusive_zone = -1,
      keyboard_interactivity = "on_demand", background = ouro.tokens.palette.transparent,
      content = function() return center.content(state, {
        close = state.close_center, clear = state.clear, activate = state.activate, message = state.message,
      }) end,
    }
  end
  local item = state.popup()
  if item and not state.quiet() then
    return ouro.layer_surface { id = "notification-popup", namespace = "ouroshell-notification-popup", layer = "overlay",
      width = 420, height = 160 + #item.actions * 40 - (item.default_action and 16 or 0), anchors = { "top", "right" },
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
