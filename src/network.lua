local ouro = require("ouro")
local appearance = require("appearance")
local config = require("config")
local support = require("dbus_support")
local f = ouro.tokens.foundation
local machine = ouro.machine
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

local function seed(rssi)
  local level = 0
  for _, threshold in ipairs(thresholds) do
    if rssi < threshold then level = level + 1 end
  end
  return level
end

local function associated(station)
  return station.state == "connected" or station.state == "roaming"
end

-- A fresh iwd read merged over the previous stations: a station still on the
-- same network and access point keeps its signal level from iwd's agent;
-- after a connection or roam the level is seeded from the RSSI read with it,
-- even if it stayed in the same band and iwd sent no Changed callback.
function M.merge(previous, fresh)
  local stations = {}
  for name, station in pairs(fresh) do
    local merged = {}
    for key, value in pairs(station) do merged[key] = value end
    local old = (previous or {})[name]
    if old and old.path == merged.path and old.network == merged.network and old.ap == merged.ap
      and associated(merged) then
      merged.level = old.level
      merged.rssi = merged.rssi or old.rssi
    end
    if merged.state == "connected" and merged.level == nil and merged.rssi then merged.level = seed(merged.rssi) end
    stations[name] = merged
  end
  return stations
end

-- Applies fn(copy) to the station at `path`, returning new stations.
local function update_station(stations, path, fn)
  local updated = {}
  for name, station in pairs(stations or {}) do
    if station.path == path then
      local copy = {}
      for key, value in pairs(station) do copy[key] = value end
      fn(copy)
      station = copy
    end
    updated[name] = station
  end
  return updated
end

-- Headless link and Wi-Fi state. `links` is networkd's description (nil
-- while networkd is unavailable) and `stations` iwd's, by interface name
-- (nil while iwd is unavailable). Each service reconnects independently,
-- so Ethernet status keeps working without iwd. The indicator is the plain
-- function M.snapshot(links, stations).
--   services.networkd(_, send): serves networkd (sends LINKS)
--   services.iwd(_, send): serves iwd and its signal agent (sends STATIONS, LEVEL, RELEASED)
function M.chart(services)
  local assign, unset = machine.assign, machine.unset
  return machine.create {
    id = "network", type = "parallel", order = { "networkd", "iwd" },
    context = { networkd_retry = support.retry, iwd_retry = support.retry },
    events = {
      LINKS = { links = "table?" },
      STATIONS = { stations = "table" },
      LEVEL = { path = "string", level = "integer", rssi = "number?" },
      RELEASED = { path = "string" },
    },
    actors = { networkd = services.networkd, iwd = services.iwd },
    delays = support.delays("networkd_retry", "iwd_retry"),
    actions = {
      links = assign(function(_, e) return { links = e.links or unset, networkd_retry = support.retry } end),
      stations = assign(function(c, e) return { stations = M.merge(c.stations, e.stations), iwd_retry = support.retry } end),
      level = assign { stations = function(c, e)
        return update_station(c.stations, e.path, function(station)
          if associated(station) then station.level, station.rssi = e.level, e.rssi end
        end)
      end },
      released = assign { stations = function(c, e)
        return update_station(c.stations, e.path, function(station) station.level, station.rssi = nil, nil end)
      end },
      networkd_lost = assign { links = unset },
      iwd_lost = assign { stations = unset },
    },
    states = {
      networkd = support.reconnecting { src = "networkd", retry = "networkd_retry", down = "networkd_lost",
        online = { on = { LINKS = { actions = "links" } } } },
      iwd = support.reconnecting { src = "iwd", retry = "iwd_retry", down = "iwd_lost",
        online = { on = {
          STATIONS = { actions = "stations" },
          LEVEL = { actions = "level" },
          RELEASED = { actions = "released" },
        } } },
    },
  }
end

-- Services over `connect(bus)` (support.connect, or a fake in tests).
function M.make_services(connect)
  local services = {}

  function services.networkd(_, send)
    local bus <close> = connect("system")
    local changes <close> = support.need(bus:subscribe {
      sender = networkd, interface = "org.freedesktop.DBus.Properties",
      member = "PropertiesChanged", close_on_owner_change = true,
    })
    while true do
      send { type = "LINKS", links = M.read_links(bus) }
      support.need(changes:next())
    end
  end

  local function read_rssi(bus, path)
    local diagnostics = bus:call {
      destination = iwd, path = path, interface = iwd .. ".StationDiagnostic",
      member = "GetDiagnostics", signature = "", args = {}, timeout_ms = 5000,
    }
    local rssi = diagnostics and support.properties(diagnostics.args[1]).RSSI
    return type(rssi) == "number" and rssi or nil
  end

  function services.iwd(_, send)
    local bus <close> = connect("system")
    local changes <close> = support.need(bus:subscribe { sender = iwd, close_on_owner_change = true })
    local owner = support.need(bus:call {
      destination = "org.freedesktop.DBus", path = "/org/freedesktop/DBus", interface = "org.freedesktop.DBus",
      member = "GetNameOwner", signature = "s", args = { iwd }, timeout_ms = 5000,
    }).args[1]
    -- Which station objects accepted the agent, for this connection only.
    local registered = {}
    local agent_path = "/dev/ouro/shell/SignalLevelAgent"
    local function deny() return nil, { name = "org.freedesktop.DBus.Error.AccessDenied", message = "Not iwd" } end
    local agent <close> = support.need(bus:export {
      path = agent_path, interface = iwd .. ".SignalLevelAgent",
      methods = {
        Changed = { input = "oy", output = "", handler = function(request)
          if request.sender ~= owner then return deny() end
          local path = request.args[1]
          send { type = "LEVEL", path = path, level = request.args[2], rssi = read_rssi(bus, path) }
          return {}
        end },
        Release = { input = "o", output = "", handler = function(request)
          if request.sender ~= owner then return deny() end
          registered[request.args[1]] = nil
          send { type = "RELEASED", path = request.args[1] }
          return {}
        end },
      },
    })
    local function refresh()
      local stations = M.read_stations(bus)
      for _, station in pairs(stations) do
        if station.state == "connected" then station.rssi = read_rssi(bus, station.path) end
      end
      send { type = "STATIONS", stations = stations }
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
  end

  return services
end

M.services = M.make_services(support.connect)

function M.content(state, scheme)
  if not state then return nil end
  local theme, palette = appearance.colors(scheme)
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
