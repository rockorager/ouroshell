-- The networkd and iwd D-Bus services over a scripted bus. Runs under a
-- standalone Lua (`lua tests/network_service.lua`): fakes need setmetatable
-- for <close>, which Ourokit's sandbox does not provide. The chart that
-- consumes these events is tested in tests/network_test.lua.
package.path = "src/?.lua;tests/?.lua;" .. package.path
local ouro = require("fake_ouro").install {}
local network = require("network")
local iwd = "net.connman.iwd"

local function closable(value)
  return setmetatable(value, { __close = function(self) self.closed = true end })
end

local function properties(values)
  local result = {}
  for key, value in pairs(values) do result[#result + 1] = { key, { value = value } } end
  return result
end

-- `script` lists stream messages, or functions run in place of one (to call
-- exported handlers mid-session). When it runs out the stream closes.
local function fake_bus(world, script)
  local bus = closable { reads = 0, registrations = 0 }
  function bus:subscribe(match)
    assert(match.close_on_owner_change)
    self.sender = match.sender
    local step = 0
    self.stream = closable { next = function()
      while true do
        step = step + 1
        local item = script[step]
        if item == nil then return nil, { name = "ServiceDisappeared", message = "gone" } end
        if type(item) ~= "function" then return item end
        item(bus)
      end
    end }
    return self.stream
  end
  function bus:export(declaration)
    assert(declaration.interface == iwd .. ".SignalLevelAgent")
    self.agent = declaration
    self.exported = closable {}
    return self.exported
  end
  function bus:call(request)
    assert(request.timeout_ms == 5000)
    if request.member == "Describe" then self.reads = self.reads + 1; return { args = { "networkd-json" } } end
    if request.member == "GetNameOwner" then return { args = { ":1.42" } } end
    if request.member == "GetManagedObjects" then
      self.reads = self.reads + 1
      return { args = { world.present and {
        { "/station", {
          { iwd .. ".Device", properties { Name = "wlan0", Powered = true } },
          { iwd .. ".Station", properties { State = world.state,
            ConnectedNetwork = world.state ~= "disconnected" and "/network" or nil, ConnectedAccessPoint = world.ap } },
        } },
        { "/network", { { iwd .. ".Network", properties { Name = "Test Wi-Fi" } } } },
      } or {} } }
    end
    if request.member == "GetDiagnostics" then
      if not world.rssi then return nil, { message = "NotSupported" } end
      return { args = { properties { RSSI = world.rssi } } }
    end
    if request.member == "RegisterSignalLevelAgent" then
      assert(table.concat(request.args[2], ",") == "-55,-67,-75,-85", "thresholds must be descending dBm")
      self.registrations = self.registrations + 1
      return { args = {} }
    end
    error("Unexpected method: " .. request.member)
  end
  return bus
end

local function run(service, bus)
  local sent = {}
  local services = network.make_services(function(which) assert(which == "system"); return bus end)
  local ok = pcall(services[service], nil, function(event) sent[#sent + 1] = event end)
  assert(not ok, "a session ends with its stream")
  assert(bus.closed and bus.stream.closed, "the connection closes with the session")
  return sent
end

local function types(sent)
  local result = {}
  for _, event in ipairs(sent) do result[#result + 1] = event.type end
  return table.concat(result, ",")
end

-- iwd: the agent only answers iwd, refreshes follow device changes only.
local world = { present = true, state = "connected", ap = "/ap1", rssi = -54 }
local denied
local bus = fake_bus(world, {
  function(b)
    local _, failure = b.agent.methods.Changed.handler { sender = ":1.attacker", args = { "/station", 0 } }
    denied = failure
    world.rssi = -78
    assert(b.agent.methods.Changed.handler { sender = ":1.42", args = { "/station", 3 } })
    world.rssi = nil
    assert(b.agent.methods.Changed.handler { sender = ":1.42", args = { "/station", 2 } })
  end,
  { member = "PropertiesChanged", args = { iwd .. ".Station", {}, {} } },
  { member = "InterfacesAdded", args = { "/bss", { { iwd .. ".BasicServiceSet", {} } } } },
  { member = "InterfacesAdded", args = { "/station", { { iwd .. ".Station", {} } } } },
  function(b) assert(b.agent.methods.Release.handler { sender = ":1.42", args = { "/station" } }) end,
})
local sent = run("iwd", bus)
assert(denied.name == "org.freedesktop.DBus.Error.AccessDenied")
assert(types(sent) == "STATIONS,LEVEL,LEVEL,STATIONS,STATIONS,RELEASED", types(sent))
assert(sent[1].stations.wlan0.rssi == -54 and sent[1].stations.wlan0.name == "Test Wi-Fi")
assert(sent[2].level == 3 and sent[2].rssi == -78, "signal callbacks refresh RSSI, not convert the bucket")
assert(sent[3].rssi == nil, "failed diagnostics clear the old percentage")
assert(bus.reads == 3, "scan results do not refresh device state")
assert(bus.registrations == 2, "a hotplugged station gets the agent again")
assert(bus.exported.closed, "the agent is withdrawn with the session")

-- networkd: every change re-reads the description.
ouro.json.decode = function(value) assert(value == "networkd-json"); return { Interfaces = { { Name = "eth0" } } } end
bus = fake_bus(world, { { member = "PropertiesChanged", args = {} } })
sent = run("networkd", bus)
assert(types(sent) == "LINKS,LINKS" and sent[1].links[1].Name == "eth0" and bus.reads == 2)

print("PASS: iwd agent authentication, RSSI refresh, device-only refreshes, hotplug, networkd re-reads")
