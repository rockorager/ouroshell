local ouro = require("ouro")
local appearance = require("appearance")
local config = require("config")
local support = require("dbus_support")
local f = ouro.tokens.foundation
local M = {}
local service = "org.freedesktop.NetworkManager"
local root = "/org/freedesktop/NetworkManager"

function M.snapshot(manager, strength)
  local state = manager.State or 0
  if manager.NetworkingEnabled == false or state == 10 then
    return { icon = "network-offline-symbolic", label = "Network off", muted = true }
  elseif state == 20 or state == 30 then
    return { icon = "network-offline-symbolic", label = "Offline", muted = true }
  elseif state == 40 then
    local icon = manager.PrimaryConnectionType == "802-11-wireless" and "network-wireless-acquiring-symbolic"
      or manager.PrimaryConnectionType == "802-3-ethernet" and "network-wired-acquiring-symbolic"
      or "network-transmit-receive-symbolic"
    return { icon = icon, label = "Connecting", muted = true }
  elseif state ~= 50 and state ~= 60 and state ~= 70 then
    return { icon = "network-offline-symbolic", label = "Unknown", muted = true }
  end

  local wifi = manager.PrimaryConnectionType == "802-11-wireless"
  local label, icon = "Network", "network-transmit-receive-symbolic"
  if wifi then
    label, icon = "Wi-Fi", "network-wireless-symbolic"
    if type(strength) == "number" and strength >= 0 and strength <= 100 then
      local level = strength > 75 and "excellent" or strength > 50 and "good"
        or strength > 25 and "ok" or strength > 0 and "weak" or "none"
      icon = "network-wireless-signal-" .. level .. "-symbolic"
    end
  elseif manager.PrimaryConnectionType == "802-3-ethernet" then
    label, icon = "Ethernet", "network-wired-symbolic"
  elseif manager.PrimaryConnectionType == "gsm" or manager.PrimaryConnectionType == "cdma" then
    label, icon = "Mobile", "network-cellular-symbolic"
  end

  local connectivity = manager.Connectivity or 0
  if connectivity == 2 then
    return { icon = wifi and "network-wireless-no-route-symbolic" or "network-wired-no-route-symbolic",
      label = "Sign in", warning = true, description = label .. ": captive portal sign-in required" }
  elseif state == 50 or state == 60 or connectivity == 1 or connectivity == 3 then
    return { icon = wifi and "network-wireless-no-route-symbolic" or "network-wired-no-route-symbolic",
      label = (state == 50 or connectivity == 1) and "No internet" or "Limited",
      warning = true, description = label .. ": limited connectivity" }
  end
  return { icon = icon, label = label,
    description = label .. (wifi and strength and (", signal " .. strength .. "%") or "")
      .. (connectivity == 4 and ": internet available" or ": internet access unverified") }
end

function M.read(bus)
  local watched = {}
  local function get(path, interface)
    watched[path] = true
    return support.properties(support.need(bus:call {
      destination = service, path = path, interface = "org.freedesktop.DBus.Properties",
      member = "GetAll", signature = "s", args = { interface }, timeout_ms = 5000,
    }).args[1])
  end
  local manager = get(root, service)
  local strength
  -- PrimaryConnection points at the underlying connection even with a VPN.
  -- Do not scan or choose another adapter when Ethernet is the primary route.
  if (manager.State or 0) >= 50 and manager.PrimaryConnectionType == "802-11-wireless"
    and manager.PrimaryConnection and manager.PrimaryConnection ~= "/" then
    local active = get(manager.PrimaryConnection, service .. ".Connection.Active")
    local device = active.Devices and active.Devices[1]
    if device and device ~= "/" then
      local wireless = get(device, service .. ".Device.Wireless")
      if wireless.ActiveAccessPoint and wireless.ActiveAccessPoint ~= "/" then
        strength = get(wireless.ActiveAccessPoint, service .. ".AccessPoint").Strength
      end
    end
  end
  return M.snapshot(manager, strength), watched
end

function M.connect()
  local state = ouro.signal(nil)
  support.supervise { bus = "system",
    session = function(bus, healthy)
      -- A NetworkManager restart closes the stream, ending the session and reconnecting.
      local changes <close> = support.need(bus:subscribe {
        sender = service, interface = "org.freedesktop.DBus.Properties",
        member = "PropertiesChanged", close_on_owner_change = true,
      })
      local watched
      local function refresh()
        local snapshot
        snapshot, watched = M.read(bus)
        state:set(snapshot)
        healthy()
      end
      refresh() -- Subscribe before reading, including AP changes during a roam.
      while true do
        local message = support.need(changes:next())
        if watched[message.path] then refresh() end
      end
    end,
    down = function() state:set(nil) end,
  }
  return state
end

function M.content(state)
  if not state then return nil end
  local theme, palette = appearance.colors()
  local color = state.warning and palette.amber.step_11
    or state.muted and theme.muted_foreground or theme.sidebar_foreground
  return ouro.row { key = "network", gap = f.spacing_1, cross_alignment = "center", children = {
    ouro.xdg.icon { key = "icon", name = state.icon, theme = config.icon_theme,
      width = f.spacing_4, height = f.spacing_4, tint = color, alt = state.description or state.label },
    state.label ~= "Wi-Fi" and ouro.text {
      key = "label", text = state.label, foreground = color, size = f.typography_3, max_lines = 1,
    } or nil,
  } }
end

return M
