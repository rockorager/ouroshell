package.path = "src/?.lua;" .. package.path
local tasks, delay = {}, nil
local ouro = { tokens = { foundation = { spacing_1 = 4, spacing_4 = 16, typography_3 = 16 } }, xdg = {}, dbus = {} }
ouro.signal = function(value)
  return setmetatable({ set = function(_, next_value) value = next_value end }, { __call = function() return value end })
end
ouro.spawn = function(fn) tasks[#tasks + 1] = coroutine.create(fn) end
ouro.sleep = function(ms) delay = ms; coroutine.yield() end
ouro.row = function(props) return props end
ouro.text = function(props) return props end
ouro.xdg.icon = function(props) return props end
package.loaded.ouro = ouro
local scheme = "light"
package.loaded.appearance = { colors = function()
  return { sidebar_foreground = scheme .. ":foreground", muted_foreground = scheme .. ":muted" },
    { amber = { step_11 = scheme .. ":warning" } }
end }
local network = require("network")
local manager = { State = 70, Connectivity = 4, PrimaryConnectionType = "802-11-wireless", PrimaryConnection = "/active" }
for _, case in ipairs({ { 0, "none" }, { 1, "weak" }, { 25, "weak" }, { 26, "ok" },
  { 50, "ok" }, { 51, "good" }, { 75, "good" }, { 76, "excellent" }, { 100, "excellent" } }) do
  local snapshot = network.snapshot(manager, case[1])
  assert(snapshot.icon == "network-wireless-signal-" .. case[2] .. "-symbolic")
  assert(snapshot.label == "Wi-Fi" and snapshot.description:find("internet available", 1, true))
  local content = network.content(snapshot)
  assert(#content.children == 1 and content.children[1].name == snapshot.icon, "Wi-Fi must be icon-only")
  assert(content.children[1].alt == snapshot.description, "retain the accessible connection description")
end
assert(network.snapshot(manager).icon == "network-wireless-symbolic", "unknown strength is not zero strength")
manager.Connectivity = 0
assert(network.snapshot(manager, 80).description:find("unverified", 1, true), "disabled checks cannot prove internet access")
manager.Connectivity = 2
local portal = network.snapshot(manager, 80)
assert(portal.label == "Sign in" and portal.warning)
manager.Connectivity = 3
assert(network.snapshot(manager, 80).label == "Limited")
manager.Connectivity = 4
manager.State = 50
assert(network.snapshot(manager, 80).label == "No internet", "local connectivity is not internet access")
manager.State = 60
assert(network.snapshot(manager, 80).label == "Limited")
for _, case in ipairs({ { 0, "Unknown" }, { 10, "Network off" }, { 20, "Offline" }, { 30, "Offline" }, { 40, "Connecting" } }) do
  manager.State = case[1]
  assert(network.snapshot(manager).label == case[2])
end
manager.State, manager.NetworkingEnabled = 70, false
assert(network.snapshot(manager).label == "Network off")
manager.NetworkingEnabled = true
manager.PrimaryConnectionType = "802-3-ethernet"
assert(network.snapshot(manager, 95).icon == "network-wired-symbolic", "Wi-Fi strength must not override a wired primary")
assert(network.snapshot(manager).label == "Ethernet")
manager.PrimaryConnectionType = "gsm"
assert(network.snapshot(manager).label == "Mobile")
assert(network.content(nil) == nil)
local view = network.content(portal)
assert(view.children[1].tint == "light:warning" and view.children[2].text == "Sign in")
scheme = "dark"
assert(network.content(portal).children[2].foreground == "dark:warning")
assert(network.content(network.snapshot({ State = 20 })).children[1].tint == "dark:muted")

local service, root = "org.freedesktop.NetworkManager", "/org/freedesktop/NetworkManager"
manager.PrimaryConnectionType = "802-11-wireless"
local ap = "/ap1"
local reads, subscribed, offline, current_bus = 0, false, false, nil
ouro.dbus.connect = function(which)
  assert(which == "system")
  if offline then return nil, { message = "offline" } end
  subscribed = false
  local bus = { streams = {} }
  current_bus = bus
  function bus:close() self.closed = true end
  function bus:subscribe(match)
    local stream = {}
    function stream:close() self.closed = true end
    function stream:next()
      local message = coroutine.yield()
      if bus.closed then return nil, { message = "closed" } end
      return message
    end
    if match.member == "PropertiesChanged" then
      assert(match.sender == service and match.path == nil, "AP/device signals must be included")
      subscribed = true
    else assert(match.member == "NameOwnerChanged" and match.sender == "org.freedesktop.DBus") end
    self.streams[#self.streams + 1] = stream
    return setmetatable(stream, { __close = stream.close })
  end
  function bus:call(request)
    assert(subscribed, "subscribe before reading the connection chain")
    assert(request.member == "GetAll" and request.interface == "org.freedesktop.DBus.Properties")
    assert(request.destination == service and request.signature == "s")
    reads = reads + 1
    local objects = {
      [root] = { service, manager },
      ["/active"] = { service .. ".Connection.Active", { Devices = { "/wifi" } } },
      ["/wifi"] = { service .. ".Device.Wireless", { ActiveAccessPoint = ap } },
      ["/ap1"] = { service .. ".AccessPoint", { Strength = 82 } },
      ["/ap2"] = { service .. ".AccessPoint", { Strength = 17 } },
    }
    local object = assert(objects[request.path], "unexpected object")
    assert(request.args[1] == object[1], "wrong property interface")
    local values = {}
    for key, value in pairs(object[2]) do values[#values + 1] = { key, { value = value } } end
    return { args = { values } }
  end
  return setmetatable(bus, { __close = bus.close })
end
local state = network.connect()
assert(coroutine.resume(tasks[1]))
assert(reads == 4 and state().icon == "network-wireless-signal-excellent-symbolic")
assert(coroutine.resume(tasks[2]))
assert(coroutine.resume(tasks[1], { path = "/unrelated-ap" }))
assert(reads == 4, "unrelated AP updates caused a refresh")
ap = "/ap2"
assert(coroutine.resume(tasks[1], { path = "/wifi", args = { service .. ".Device.Wireless", {}, { "ActiveAccessPoint" } } }))
assert(reads == 8 and state().icon == "network-wireless-signal-weak-symbolic", "roaming retained old AP strength")
assert(coroutine.resume(tasks[1], { path = "/ap1" }))
assert(reads == 8)
assert(coroutine.resume(tasks[1], { path = "/ap2" }))
assert(reads == 12)
manager.Connectivity = 2
assert(coroutine.resume(tasks[1], { path = root }))
assert(state().label == "Sign in")
manager.Connectivity, manager.PrimaryConnectionType = 4, "802-3-ethernet"
assert(coroutine.resume(tasks[1], { path = root }))
assert(reads == 17 and state().label == "Ethernet")
assert(coroutine.resume(tasks[1], { path = "/ap2" }))
assert(reads == 17, "old Wi-Fi events should not affect Ethernet")
local old_bus = current_bus
assert(coroutine.resume(tasks[2], { args = { service, ":1.2", "" } }))
assert(old_bus.closed)
assert(coroutine.resume(tasks[1]))
assert(state() == nil and delay == 1000)
assert(old_bus.streams[1].closed and old_bus.streams[2].closed)
offline = true
assert(coroutine.resume(tasks[1]))
assert(delay == 2000)
offline, manager.State = false, 20
assert(coroutine.resume(tasks[1]))
assert(state().label == "Offline" and current_bus ~= old_bus)
print("PASS: network connectivity, strength boundaries, primary route, roaming, signals, and reconnection")
