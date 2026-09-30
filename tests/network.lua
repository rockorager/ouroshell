package.path = "src/?.lua;tests/?.lua;" .. package.path
local tasks, delay = {}, nil
local ouro = require("fake_ouro").install {
  tokens = { foundation = { spacing_1 = 4, spacing_4 = 16, typography_3 = 16 } },
  spawn = function(fn) tasks[#tasks + 1] = coroutine.create(fn) end,
  sleep = function(ms) delay = ms; coroutine.yield() end,
  animation = function(props) props.kind = "animation"; return props end,
}
local scheme = "light"
package.loaded.appearance = { colors = function()
  return { sidebar_foreground = scheme .. ":foreground", muted_foreground = scheme .. ":muted" },
    { amber = { step_11 = scheme .. ":warning" } }
end }
local network = require("network")
local wifi = { Name = "wlan0", Type = "wlan", OperationalState = "routable", CarrierState = "carrier", AddressState = "routable" }
local ethernet = { Name = "enp1s0", Type = "ether", OperationalState = "routable" }
local virtual = { Name = "veth0", Type = "ether", Kind = "veth", OperationalState = "routable" }
local vpn = { Name = "tailscale0", Type = "none", Kind = "tun", OperationalState = "routable" }
for level, name in ipairs({ "excellent", "good", "ok", "weak", "none" }) do
  local snapshot = network.snapshot({ wifi }, { wlan0 = { name = "Test Wi-Fi", level = level - 1 } })
  assert(snapshot.icons[1] == "network-wireless-signal-" .. name .. "-symbolic")
  assert(snapshot.label == "Wi-Fi" and snapshot.description:find("internet access unverified", 1, true))
  assert(snapshot.description:find("Test Wi-Fi", 1, true))
  local content = network.content(snapshot)
  assert(#content.children == 1 and content.children[1].alt == snapshot.description)
end
assert(network.snapshot({ wifi }).icons[1] == "network-wireless-symbolic", "unknown signal is not zero")
local both = network.snapshot({ vpn, virtual, wifi, ethernet }, { wlan0 = { level = 0 } })
assert(both.label == "Ethernet + Wi-Fi" and both.icons[1] == "network-wired-symbolic")
assert(both.icons[2] == "network-wireless-signal-excellent-symbolic")
local both_view = network.content(both)
assert(#both_view.children == 2 and both_view.children[1].kind == "icon" and both_view.children[2].kind == "icon")
assert(not both.description:find("tailscale") and not both.description:find("veth"))
assert(network.snapshot({ vpn, virtual }).label == "Offline", "virtual interfaces cannot imply a physical connection")
assert(network.snapshot({ ethernet }).label == "Ethernet")
ethernet.AdministrativeState = "linger"
assert(network.snapshot({ ethernet }).label == "Offline", "a removed link must not stay connected")
ethernet.AdministrativeState = nil
wifi.OperationalState, wifi.AddressState = "carrier", "off"
local acquiring = network.snapshot({ wifi })
assert(acquiring.label == "Connecting")
local animation = network.content(acquiring).children[1]
assert(animation.kind == "animation" and animation.loop and animation.duration == 1200)
assert(animation.render(0).name == "network-wireless-signal-none-symbolic")
assert(animation.render(0.199).name == "network-wireless-signal-none-symbolic")
assert(animation.render(0.2).name == "network-wireless-signal-weak-symbolic")
assert(animation.render(0.999).name == "network-wireless-signal-excellent-symbolic")
assert(animation.render(1).children[1].name == "network-wireless-acquiring-symbolic", "reduced motion keeps acquiring icon")
local wired_animation = network.content(network.snapshot({ {
  Name = "eth0", Type = "ether", CarrierState = "carrier",
} })).children[1]
assert(wired_animation.render(0.5).opacity == 0.4 and wired_animation.render(1).opacity == 1)
assert(wired_animation.render(0).children[1].name == "network-wired-acquiring-symbolic")
wifi.OperationalState, wifi.AddressState = "degraded", "degraded"
local limited = network.snapshot({ wifi })
assert(limited.label == "Local only" and limited.warning)
assert(network.content(limited).children[1].tint == "light:warning")
scheme = "dark"
assert(network.content(limited).children[1].tint == "dark:warning")
assert(limited.icons[1] == "network-wireless-no-route-symbolic")
wifi.AdministrativeState = "configuring"
assert(network.snapshot({ wifi }).connecting == "wireless", "link-local IPv6 during DHCP is still connecting")
wifi.AdministrativeState = nil
assert(network.content(network.snapshot({})).children[1].tint == "dark:muted")
assert(network.content(nil) == nil and network.snapshot(nil) == nil)
wifi.OperationalState, wifi.CarrierState, wifi.AddressState = "no-carrier", "no-carrier", "off"
assert(network.snapshot({ wifi }).label == "Offline")
assert(network.snapshot({ wifi }).icons[1] == "network-wireless-offline-symbolic")
wifi.AddressState = "degraded"
assert(network.snapshot({ wifi }).label == "Offline", "retained link-local addresses do not imply a connected link")
wifi.AddressState = "off"
assert(network.snapshot({}).icons[1] == "network-wired-disconnected-symbolic")
local disabled = network.snapshot({ wifi }, { wlan0 = { powered = false } })
assert(disabled.label == "Wi-Fi off" and disabled.icons[1] == "network-wireless-disabled-symbolic")
assert(network.snapshot({ wifi, { Name = "wlan1", Type = "wlan" } }, { wlan0 = { powered = false } }).label == "Offline",
  "one disabled adapter does not imply all Wi-Fi is off")
assert(network.snapshot({ wifi }, { wlan0 = { state = "connecting" } }).label == "Connecting")
wifi.OperationalState, wifi.CarrierState, wifi.AddressState = "routable", "carrier", "routable"

local networkd, iwd = "org.freedesktop.network1", "net.connman.iwd"
local current_links, connections, unavailable = { wifi, vpn }, {}, {}
local station_state, ap, rssi, device_present = "connected", "/ap1", -54, true
local registration_supported, diagnostic_supported = true, true
local owner = ":1.42"
local function properties(values)
  local result = {}
  for key, value in pairs(values) do result[#result + 1] = { key, { value = value } } end
  return result
end
ouro.json.decode = function(value)
  assert(value == "networkd-json")
  return { Interfaces = current_links }
end
ouro.dbus.connect = function(which)
  assert(which == "system")
  local bus = { reads = 0, registrations = 0 }
  function bus:close() self.closed = true end
  function bus:subscribe(match)
    assert(match.close_on_owner_change and match.path == nil)
    self.service = match.sender
    assert(self.service == networkd or self.service == iwd)
    connections[self.service] = self
    if unavailable[self.service] then return nil, { message = "unavailable" } end
    if self.service == networkd then assert(match.member == "PropertiesChanged") end
    self.stream = setmetatable({ close = function(stream) stream.closed = true end,
      next = function()
        local message = coroutine.yield()
        if message == "owner-changed" then return nil, { name = "ServiceDisappeared", message = "gone" } end
        return message
      end,
    }, { __close = function(stream) stream:close() end })
    return self.stream
  end
  function bus:export(declaration)
    assert(self.service == iwd and declaration.interface == iwd .. ".SignalLevelAgent")
    self.agent = declaration
    self.export = setmetatable({}, { __close = function(export) export.closed = true end })
    return self.export
  end
  function bus:call(request)
    assert(self.stream, "subscribe before reading")
    assert(request.timeout_ms == 5000)
    if request.member == "Describe" then
      assert(request.destination == networkd and request.path == "/org/freedesktop/network1")
      assert(request.interface == networkd .. ".Manager" and request.signature == "")
      self.reads = self.reads + 1
      return { args = { "networkd-json" } }
    elseif request.member == "GetNameOwner" then
      assert(request.destination == "org.freedesktop.DBus" and request.args[1] == iwd)
      return { args = { owner } }
    elseif request.member == "GetManagedObjects" then
      assert(request.destination == iwd and request.path == "/" and request.interface == "org.freedesktop.DBus.ObjectManager")
      self.reads = self.reads + 1
      return { args = { device_present and {
        { "/station", {
          { iwd .. ".Device", properties { Name = "wlan0", Powered = true } },
          { iwd .. ".Station", properties { State = station_state,
            ConnectedNetwork = station_state ~= "disconnected" and "/network" or nil, ConnectedAccessPoint = ap } },
        } },
        { "/network", { { iwd .. ".Network", properties { Name = "Test Wi-Fi" } } } },
      } or {} } }
    elseif request.member == "GetDiagnostics" then
      assert(request.destination == iwd and request.path == "/station" and request.interface == iwd .. ".StationDiagnostic")
      if not diagnostic_supported then return nil, { message = "NotSupported" } end
      return { args = { properties { RSSI = rssi } } }
    elseif request.member == "RegisterSignalLevelAgent" then
      assert(self.agent and request.path == "/station" and request.signature == "oan")
      assert(request.args[1] == self.agent.path)
      assert(table.concat(request.args[2], ",") == "-55,-67,-75,-85", "thresholds must be descending dBm")
      self.registrations = self.registrations + 1
      if not registration_supported then return nil, { message = "NotSupported" } end
      return { args = {} }
    end
    error("Unexpected method: " .. request.member)
  end
  return setmetatable(bus, { __close = bus.close })
end
local function resume(task, message)
  local ok, failure = coroutine.resume(tasks[task], message)
  assert(ok, failure)
end
local function changed()
  resume(2, { member = "PropertiesChanged", args = { iwd .. ".Station", {}, {} } })
end
local state = network.connect()
assert(#tasks == 2)
resume(1)
assert(state().label == "Wi-Fi" and state().icons[1] == "network-wireless-symbolic")
resume(2)
local iwbus = connections[iwd]
assert(state().icons[1] == "network-wireless-signal-excellent-symbolic" and iwbus.registrations == 1)
assert(iwbus.agent.methods.Changed.handler { sender = owner, args = { "/station", 3 } })
assert(state().icons[1] == "network-wireless-signal-weak-symbolic")
local reply, failure = iwbus.agent.methods.Changed.handler { sender = ":1.attacker", args = { "/station", 0 } }
assert(reply == nil and failure.name == "org.freedesktop.DBus.Error.AccessDenied")
assert(state().icons[1] == "network-wireless-signal-weak-symbolic")
changed()
assert(state().icons[1] == "network-wireless-signal-weak-symbolic" and iwbus.registrations == 1)
-- Roam without a signal callback, then exercise each side of the dBm boundaries.
for index, case in ipairs({ { -55, "excellent" }, { -56, "good" }, { -67, "good" },
  { -68, "ok" }, { -75, "ok" }, { -76, "weak" }, { -85, "weak" }, { -86, "none" } }) do
  ap, rssi = "/ap" .. (index + 1), case[1]
  changed()
  assert(state().icons[1] == "network-wireless-signal-" .. case[2] .. "-symbolic")
end
local reads = iwbus.reads
resume(2, { member = "InterfacesAdded", args = { "/bss", { { iwd .. ".BasicServiceSet", {} } } } })
assert(iwbus.reads == reads, "scan results should not refresh device state")
device_present = false
resume(2, { member = "InterfacesRemoved", args = { "/station", { iwd .. ".Station", iwd .. ".Device" } } })
assert(state().icons[1] == "network-wireless-symbolic")
device_present = true
resume(2, { member = "InterfacesAdded", args = { "/station", { { iwd .. ".Station", {} } } } })
assert(iwbus.registrations == 2, "a hotplugged device needs a new agent")
station_state = "disconnected"
changed()
assert(state().icons[1] == "network-wireless-symbolic", "disconnect must clear stale signal")
assert(iwbus.agent.methods.Changed.handler { sender = owner, args = { "/station", 0 } })
assert(state().icons[1] == "network-wireless-symbolic", "late callback must not revive disconnected signal")
current_links = { ethernet }
resume(1, { args = {} })
assert(state().label == "Ethernet")
resume(2, "owner-changed")
assert(iwbus.closed and iwbus.stream.closed and iwbus.export.closed and delay == 1000)
assert(state().label == "Ethernet", "iwd loss must not hide Ethernet")
unavailable[iwd] = true
resume(2)
assert(delay == 2000 and state().label == "Ethernet")
unavailable[iwd], station_state, registration_supported, diagnostic_supported = false, "connected", false, false
owner = ":1.43"
resume(2)
assert(connections[iwd] ~= iwbus and state().label == "Ethernet")
current_links = { wifi }
resume(1, { args = {} })
assert(state().icons[1] == "network-wireless-symbolic", "unsupported signal APIs must not hide Wi-Fi")
local ndbus = connections[networkd]
resume(1, "owner-changed")
assert(ndbus.closed and ndbus.stream.closed and state() == nil)
current_links = {}
resume(1)
assert(state().label == "Offline" and connections[networkd] ~= ndbus)
print("PASS: networkd/iwd links, RSSI boundaries, roaming, hotplug, agent authentication, independent recovery")
