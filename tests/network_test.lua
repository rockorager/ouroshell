-- The network indicator: the plain snapshot function, the headless chart
-- that merges networkd and iwd state. tests/network_service.lua drives the
-- D-Bus service itself.
local o = require("ouro")
local machine = o.machine
local network = require("network")

local wifi = { Name = "wlan0", Type = "wlan", OperationalState = "routable", CarrierState = "carrier", AddressState = "routable" }
local ethernet = { Name = "enp1s0", Type = "ether", OperationalState = "routable" }
local virtual = { Name = "veth0", Type = "ether", Kind = "veth", OperationalState = "routable" }
local vpn = { Name = "tailscale0", Type = "none", Kind = "tun", OperationalState = "routable" }

local function with(link, fields)
  local copy = {}
  for key, value in pairs(link) do copy[key] = value end
  for key, value in pairs(fields) do copy[key] = value end
  return copy
end

return {
  ["snapshots report physical links, signal and RSSI"] = function()
    for level, name in ipairs({ "excellent", "good", "ok", "weak", "none" }) do
      local snapshot = network.snapshot({ wifi }, { wlan0 = { name = "Test Wi-Fi", level = level - 1 } })
      assert(snapshot.icons[1] == "network-wireless-signal-" .. name .. "-symbolic")
      assert(snapshot.label == "Wi-Fi" and snapshot.description:find("internet access unverified", 1, true))
      assert(snapshot.tooltip == "Test Wi-Fi", "unknown RSSI must not invent a percentage")
    end
    for _, case in ipairs({ { -110, 0 }, { -100, 0 }, { -99, 2 }, { -81, 32 }, { -74, 44 },
      { -66, 57 }, { -48, 87 }, { -41, 99 }, { -40, 100 }, { -30, 100 } }) do
      local snapshot = network.snapshot({ wifi }, { wlan0 = { name = "Bothe Consulting", rssi = case[1] } })
      assert(snapshot.tooltip == "Bothe Consulting (" .. case[2] .. "%)")
    end
    assert(network.snapshot({ wifi }).icons[1] == "network-wireless-symbolic", "unknown signal is not zero")
    local both = network.snapshot({ vpn, virtual, wifi, ethernet }, { wlan0 = { level = 0 } })
    assert(both.label == "Ethernet + Wi-Fi" and both.icons[1] == "network-wired-symbolic")
    assert(both.icons[2] == "network-wireless-signal-excellent-symbolic" and both.tooltip == "Ethernet; Wi-Fi")
    assert(not both.description:find("tailscale") and not both.description:find("veth"))
    assert(network.snapshot({ vpn, virtual }).label == "Offline", "virtual interfaces cannot imply a physical connection")
    assert(network.snapshot({ with(ethernet, { AdministrativeState = "linger" }) }).label == "Offline")
    local acquiring = network.snapshot({ with(wifi, { OperationalState = "carrier", AddressState = "off" }) })
    assert(acquiring.label == "Connecting" and acquiring.connecting == "wireless")
    local limited = network.snapshot({ with(wifi, { OperationalState = "degraded", AddressState = "degraded" }) })
    assert(limited.label == "Local only" and limited.warning and limited.icons[1] == "network-wireless-no-route-symbolic")
    assert(network.snapshot({ with(wifi, { OperationalState = "degraded", AddressState = "degraded",
      AdministrativeState = "configuring" }) }).connecting == "wireless", "link-local IPv6 during DHCP is still connecting")
    local offline = with(wifi, { OperationalState = "no-carrier", CarrierState = "no-carrier", AddressState = "off" })
    assert(network.snapshot({ offline }).icons[1] == "network-wireless-offline-symbolic")
    assert(network.snapshot({ with(offline, { AddressState = "degraded" }) }).label == "Offline")
    assert(network.snapshot({}).icons[1] == "network-wired-disconnected-symbolic")
    local disabled = network.snapshot({ offline }, { wlan0 = { powered = false } })
    assert(disabled.label == "Wi-Fi off" and disabled.icons[1] == "network-wireless-disabled-symbolic")
    assert(network.snapshot({ offline, { Name = "wlan1", Type = "wlan" } }, { wlan0 = { powered = false } }).label == "Offline",
      "one disabled adapter does not imply all Wi-Fi is off")
    assert(network.snapshot(nil) == nil)
  end,

  ["the chart keeps signal levels across refreshes and seeds them after a roam"] = function()
    local clock = machine.manual_scheduler()
    local function never() error("a real service ran in a test") end
    local actor = network.chart { networkd = never, iwd = never }:start { scheduler = clock }
    local function station(fields)
      return with({ path = "/station", state = "connected", network = "/network", ap = "/ap1", name = "Test Wi-Fi",
        powered = true, available = true }, fields)
    end
    clock.emit("networkd", { type = "LINKS", links = { wifi } })
    clock.emit("iwd", { type = "STATIONS", stations = { wlan0 = station { rssi = -54 } } })
    local function now() local c = actor:context(); return network.snapshot(c.links, c.stations) end
    assert(now().icons[1] == "network-wireless-signal-excellent-symbolic" and now().tooltip == "Test Wi-Fi (77%)")
    actor:send { type = "LEVEL", path = "/station", level = 3, rssi = -78 }
    assert(now().icons[1] == "network-wireless-signal-weak-symbolic" and now().tooltip == "Test Wi-Fi (37%)")
    actor:send { type = "STATIONS", stations = { wlan0 = station { rssi = -54 } } }
    assert(now().icons[1] == "network-wireless-signal-weak-symbolic", "a property refresh keeps the agent's level")
    actor:send { type = "LEVEL", path = "/station", level = 2 }
    assert(now().tooltip == "Test Wi-Fi", "failed diagnostics clear the old percentage")
    for index, case in ipairs({ { -55, "excellent" }, { -56, "good" }, { -67, "good" },
      { -68, "ok" }, { -75, "ok" }, { -76, "weak" }, { -85, "weak" }, { -86, "none" } }) do
      actor:send { type = "STATIONS", stations = { wlan0 = station { ap = "/ap" .. (index + 1), rssi = case[1] } } }
      assert(now().icons[1] == "network-wireless-signal-" .. case[2] .. "-symbolic", case[2])
    end
    actor:send { type = "STATIONS", stations = { wlan0 = { path = "/station", state = "disconnected", ap = "/ap9",
      powered = true, available = true } } }
    actor:send { type = "LEVEL", path = "/station", level = 0, rssi = -40 }
    assert(now().icons[1] == "network-wireless-symbolic" and now().tooltip == "Wi-Fi",
      "a late callback does not revive a disconnected signal")
    actor:send { type = "RELEASED", path = "/station" }
    -- iwd loss keeps Ethernet; networkd loss hides the indicator.
    actor:send { type = "LINKS", links = { ethernet } }
    clock.resolve("iwd", nil)
    assert(actor:matches("iwd.offline") and now().label == "Ethernet")
    clock.reject("networkd", "ServiceDisappeared")
    assert(actor:matches("networkd.offline") and now() == nil)
    clock.advance(1000)
    assert(actor:matches("networkd.online") and actor:matches("iwd.online"), "both reconnect after their backoff")
    assert(actor:context().networkd_retry == 2000 and actor:context().iwd_retry == 2000)
    clock.emit("networkd", { type = "LINKS", links = {} })
    assert(now().label == "Offline" and actor:context().networkd_retry == 1000)
  end,

}
