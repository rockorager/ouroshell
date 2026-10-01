local ouro = require("ouro")
local appearance = require("appearance")
local config = require("config")
local support = require("dbus_support")
local f = ouro.tokens.foundation
local M = {}
local networkd = "org.freedesktop.network1"
local iwd = "net.connman.iwd"
local levels = { "excellent", "good", "ok", "weak", "none" }
local thresholds = { -55, -67, -75, -85 }

-- Report connected physical links, not a guessed primary route. Routable means
-- an address is configured; it does not prove Internet access or detect portals.
function M.snapshot(links, stations)
  if not links then return nil end
  local connected, descriptions, tooltips = {}, {}, {}
  local carrier, local_only, connecting, has_wifi
  local wifi_off = true
  for _, link in ipairs(links) do
    local wireless = link.Type == "wlan"
    if link.AdministrativeState ~= "linger" and
      (wireless or link.Type == "wwan" or (link.Type == "ether" and not link.Kind)) then
      local station = (stations or {})[link.Name]
      local label = wireless and "Wi-Fi" or link.Type == "ether" and "Ethernet" or "Mobile"
      local kind = wireless and "wireless" or link.Type == "ether" and "wired" or "cellular"
      has_wifi = has_wifi or wireless
      if wireless and (not station or station.powered ~= false) then wifi_off = false end
      if link.OperationalState == "routable" then
        local icon = "network-" .. kind .. "-symbolic"
        local description = label .. " (" .. link.Name .. ")"
        local tooltip = label
        if wireless then
          if station and station.name then description = description .. ": " .. station.name end
          tooltip = station and station.name or label
          if station and station.rssi then
            -- Match NetworkManager's dBm quality scale: -100 = 0%, -40 = 100%.
            local rssi = math.max(-100, math.min(-40, station.rssi))
            tooltip = tooltip .. " (" .. (100 - math.floor(100 * (-40 - rssi) / 60)) .. "%)"
          end
          if station and levels[(station.level or -1) + 1] then
            description = description .. ", " .. levels[station.level + 1] .. " signal"
            icon = "network-wireless-signal-" .. levels[station.level + 1] .. "-symbolic"
          end
        end
        connected[label] = connected[label] or icon
        descriptions[#descriptions + 1] = description
        tooltips[#tooltips + 1] = tooltip
      end
      if link.CarrierState == "carrier" then carrier = carrier or kind end
      if link.CarrierState == "carrier" and link.AddressState == "degraded" then local_only = local_only or kind end
      if link.CarrierState == "carrier" and link.AdministrativeState == "configuring" then connecting = kind end
      if station and (station.state == "connecting" or station.state == "roaming") then connecting = kind end
    end
  end
  local labels, icons = {}, {}
  for _, label in ipairs({ "Ethernet", "Wi-Fi", "Mobile" }) do
    if connected[label] then
      labels[#labels + 1] = label
      icons[#icons + 1] = connected[label]
    end
  end
  if #labels > 0 then
    table.sort(descriptions)
    table.sort(tooltips)
    return {
      label = table.concat(labels, " + "), icons = icons,
      description = table.concat(descriptions, "; ") .. "; internet access unverified",
      tooltip = table.concat(tooltips, "; "),
    }
  elseif local_only and not connecting then
    return { icons = { "network-" .. local_only .. "-no-route-symbolic" }, label = "Local only", warning = true,
      description = "Only link-local addressing is available; internet access unverified" }
  elseif carrier or connecting then
    local kind = connecting or carrier
    return { icons = { "network-" .. kind .. "-acquiring-symbolic" }, connecting = kind,
      label = "Connecting", muted = true }
  elseif has_wifi and wifi_off then
    return { icons = { "network-wireless-disabled-symbolic" }, label = "Wi-Fi off", muted = true }
  end
  return { icons = { has_wifi and "network-wireless-offline-symbolic" or "network-wired-disconnected-symbolic" },
    label = "Offline", muted = true }
end

function M.read_links(bus)
  local reply = support.need(bus:call {
    destination = networkd, path = "/org/freedesktop/network1", interface = networkd .. ".Manager",
    member = "Describe", signature = "", args = {}, timeout_ms = 5000,
  })
  return ouro.json.decode(reply.args[1]).Interfaces
end

function M.read_stations(bus)
  local reply = support.need(bus:call {
    destination = iwd, path = "/", interface = "org.freedesktop.DBus.ObjectManager",
    member = "GetManagedObjects", signature = "", args = {}, timeout_ms = 5000,
  })
  local objects, stations = support.variants(reply.args[1]), {}
  for path, interfaces in pairs(objects) do
    interfaces = support.variants(interfaces)
    if interfaces[iwd .. ".Device"] then
      local device = support.properties(interfaces[iwd .. ".Device"])
      local station = support.properties(interfaces[iwd .. ".Station"] or {})
      local network = support.variants(objects[station.ConnectedNetwork] or {})[iwd .. ".Network"]
      stations[device.Name] = {
        path = path, state = station.State, network = station.ConnectedNetwork, ap = station.ConnectedAccessPoint,
        name = network and support.properties(network).Name, powered = device.Powered,
        available = interfaces[iwd .. ".Station"] ~= nil,
      }
    end
  end
  return stations
end

function M.connect()
  local state = ouro.signal(nil)
  local links, stations
  local function publish() state:set(M.snapshot(links, stations)) end
  support.supervise { bus = "system",
    session = function(bus, healthy)
      local changes <close> = support.need(bus:subscribe {
        sender = networkd, interface = "org.freedesktop.DBus.Properties",
        member = "PropertiesChanged", close_on_owner_change = true,
      })
      while true do
        links = M.read_links(bus)
        publish()
        healthy()
        support.need(changes:next())
      end
    end,
    down = function() links = nil; publish() end,
  }
  -- Separate sessions keep Ethernet status working when iwd is unavailable.
  support.supervise { bus = "system",
    session = function(bus, healthy)
      local changes <close> = support.need(bus:subscribe { sender = iwd, close_on_owner_change = true })
      local owner = support.need(bus:call {
        destination = "org.freedesktop.DBus", path = "/org/freedesktop/DBus", interface = "org.freedesktop.DBus",
        member = "GetNameOwner", signature = "s", args = { iwd }, timeout_ms = 5000,
      }).args[1]
      local registered = {}
      local agent_path = "/dev/ouro/shell/SignalLevelAgent"
      local function read_rssi(station)
        local diagnostics = bus:call {
          destination = iwd, path = station.path, interface = iwd .. ".StationDiagnostic",
          member = "GetDiagnostics", signature = "", args = {}, timeout_ms = 5000,
        }
        local rssi = diagnostics and support.properties(diagnostics.args[1]).RSSI
        station.rssi = type(rssi) == "number" and rssi or nil
      end
      local agent <close> = support.need(bus:export {
        path = agent_path, interface = iwd .. ".SignalLevelAgent",
        methods = {
          Changed = { input = "oy", output = "", handler = function(request)
            if request.sender ~= owner then
              return nil, { name = "org.freedesktop.DBus.Error.AccessDenied", message = "Not iwd" }
            end
            for _, station in pairs(stations or {}) do
              if station.path == request.args[1] and (station.state == "connected" or station.state == "roaming") then
                station.level = request.args[2]
                read_rssi(station)
              end
            end
            publish()
            return {}
          end },
          Release = { input = "o", output = "", handler = function(request)
            if request.sender ~= owner then
              return nil, { name = "org.freedesktop.DBus.Error.AccessDenied", message = "Not iwd" }
            end
            registered[request.args[1]] = nil
            for _, station in pairs(stations or {}) do
              if station.path == request.args[1] then station.level, station.rssi = nil, nil end
            end
            publish()
            return {}
          end },
        },
      })
      local function refresh()
        local previous = stations or {}
        stations = M.read_stations(bus)
        for name, station in pairs(stations) do
          local old = previous[name]
          if old and old.path == station.path and old.network == station.network and old.ap == station.ap
            and (station.state == "connected" or station.state == "roaming") then
            station.level, station.rssi = old.level, old.rssi
          end
          -- Seed the level after a connection/roam even if RSSI stayed in the
          -- same band and iwd did not send a Changed callback. No periodic scans.
          if station.state == "connected" and station.level == nil then
            read_rssi(station)
            if station.rssi then
              station.level = 0
              for _, threshold in ipairs(thresholds) do
                if station.rssi < threshold then station.level = station.level + 1 end
              end
            end
          end
        end
        publish()
        for _, station in pairs(stations) do
          if station.available and not registered[station.path] then
            -- Some drivers do not support RSSI events, or another client owns
            -- the single agent slot. Connection status must still work.
            registered[station.path] = bus:call {
              destination = iwd, path = station.path, interface = iwd .. ".Station",
              member = "RegisterSignalLevelAgent", signature = "oan",
              args = { agent_path, thresholds }, timeout_ms = 5000,
            } ~= nil
          end
        end
        healthy()
      end
      refresh()
      while true do
        local message = support.need(changes:next())
        local interface = message.args[1]
        if message.member == "PropertiesChanged" and
          (interface == iwd .. ".Device" or interface == iwd .. ".Station" or interface == iwd .. ".Network") then
          refresh()
        elseif message.member == "InterfacesAdded" or message.member == "InterfacesRemoved" then
          for _, value in ipairs(message.args[2]) do
            local added_interface = type(value) == "table" and value[1] or value
            if added_interface == iwd .. ".Device" or added_interface == iwd .. ".Station" then
              registered[message.args[1]] = nil
              refresh()
              break
            end
          end
        end
      end
    end,
    down = function() stations = nil; publish() end,
  }
  return state
end

function M.content(state)
  if not state then return nil end
  local theme, palette = appearance.colors()
  local color = state.warning and palette.amber.step_11
    or state.muted and theme.muted_foreground or theme.sidebar_foreground
  local function icon(name, key)
    return ouro.xdg.icon { key = key, name = name, theme = config.icon_theme,
      width = f.spacing_4, height = f.spacing_4, tint = color, alt = state.description or state.label }
  end
  local children = {}
  for index, name in ipairs(state.icons) do children[index] = icon(name, "icon" .. index) end
  if state.connecting then
    children = { ouro.animation { key = "connecting-" .. state.connecting, duration = 1200, loop = true,
      render = function(progress)
        -- Reduced motion supplies the terminal frame: keep the acquiring icon.
        if state.connecting ~= "wired" and progress < 1 then
          local frame = levels[5 - math.floor(progress * 5)]
          return icon("network-" .. state.connecting .. "-signal-" .. frame .. "-symbolic", "icon")
        end
        return ouro.box { key = "pulse", opacity = 0.4 + 0.6 * math.abs(2 * progress - 1),
          children = { icon(state.icons[1], "icon") } }
      end,
    } }
  end
  return ouro.tooltip { key = "network", text = state.tooltip or state.label,
    -- The anchor is the 16px icon, centered within the 40px bar.
    gap = 16, children = {
      ouro.row { key = "icons", gap = f.spacing_1, cross_alignment = "center", children = children },
    } }
end

return M
