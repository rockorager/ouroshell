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
local foreground, red = "light:foreground", "light:red"
package.loaded.appearance = { colors = function()
  return { sidebar_foreground = foreground }, { red = { step_11 = red } }
end }
local battery = require("battery")
local function properties(percentage, state, present, warning, kind)
  return {
    { "IconName", { value = state == 1 and "battery-good-charging-symbolic" or "battery-good-symbolic" } },
    { "State", { value = state } }, { "Percentage", { value = percentage } },
    { "WarningLevel", { value = warning or 1 } }, { "Type", { value = kind or 2 } },
    { "IsPresent", { value = present ~= false } },
  }
end

local normal = battery.snapshot(properties(67.49, 2))
assert(normal.percentage == 67 and not normal.charging and not normal.low)
local charging = battery.snapshot(properties(67.5, 1))
assert(charging.percentage == 68 and charging.charging and charging.icon == "battery-good-charging-symbolic")
assert(battery.snapshot(properties(100, 4)).percentage == 100)
assert(not battery.snapshot(properties(100, 4)).charging)
assert(battery.snapshot(properties(0, 3)).percentage == 0)
assert(battery.snapshot(properties(40, 5)).charging)
assert(battery.snapshot(properties(40, 2, true, 2, 3)).low == false)
local low = battery.snapshot(properties(12, 2, true, 3))
assert(low.low)
assert(battery.snapshot(properties(40, 2, false)) == nil)
assert(battery.snapshot(properties(40, 2, true, 1, 1)) == nil)
for _, invalid in ipairs({ -1, 101, 0/0, math.huge, "87" }) do
  assert(battery.snapshot(properties(invalid, 2)) == nil)
end
assert(battery.snapshot({}) == nil and battery.content(nil) == nil)
local view = battery.content(charging)
assert(view.children[1].alt == "Battery charging" and view.children[2].text == "68%")
assert(view.children[1].tint == foreground and view.children[2].foreground == foreground)
view = battery.content(low)
assert(view.children[1].tint == red and view.children[2].foreground == red)
foreground, red = "dark:foreground", "dark:red"
assert(battery.content(normal).children[2].foreground == "dark:foreground")
assert(battery.content(low).children[1].tint == "dark:red")

local current = properties(87, 2)
local current_bus, offline, reads, subscribed = nil, false, 0, false
ouro.dbus.connect = function(which)
  assert(which == "system")
  if offline then return nil, { message = "offline" } end
  local bus = { closed = false, streams = {} }
  current_bus = bus
  function bus:close() self.closed = true end
  function bus:subscribe(match)
    assert(match.sender == "org.freedesktop.UPower" or match.sender == "org.freedesktop.DBus")
    local stream = { closed = false }
    function stream:close() self.closed = true end
    function stream:next()
      local message = coroutine.yield()
      if bus.closed then return nil, { message = "closed" } end
      return message
    end
    if match.member == "PropertiesChanged" then
      assert(match.path == "/display" and match.interface == "org.freedesktop.DBus.Properties")
      subscribed = true
    else assert(match.member == "NameOwnerChanged") end
    self.streams[#self.streams + 1] = stream
    return setmetatable(stream, { __close = stream.close })
  end
  function bus:call(request)
    assert(request.destination == "org.freedesktop.UPower")
    if request.member == "GetDisplayDevice" then
      assert(request.path == "/org/freedesktop/UPower" and request.signature == "" and #request.args == 0)
      return { args = { "/display" } }
    end
    assert(subscribed, "read before match registration loses updates")
    assert(request.member == "GetAll" and request.path == "/display")
    assert(request.signature == "s" and request.args[1] == "org.freedesktop.UPower.Device")
    reads = reads + 1
    return { args = { current } }
  end
  return setmetatable(bus, { __close = bus.close })
end
local state = battery.connect()
assert(state() == nil)
assert(coroutine.resume(tasks[1]))
assert(state().percentage == 87 and reads == 1)
assert(coroutine.resume(tasks[2])) -- Owner watcher waits independently.
local changed = { args = { "org.freedesktop.UPower.Device", {}, { "Percentage", "State" } } }
current = properties(32, 1)
assert(coroutine.resume(tasks[1], changed))
assert(state().percentage == 32 and state().charging and reads == 2, "invalidated properties must be reread")
assert(coroutine.resume(tasks[1], { args = { "unrelated.Interface" } }))
assert(reads == 2)
current = properties(32, 1, false)
assert(coroutine.resume(tasks[1], changed))
assert(state() == nil, "removed battery remained visible")
current = properties(11, 2, true, 4)
assert(coroutine.resume(tasks[1], changed))
assert(state().low)
local old_bus = current_bus
assert(coroutine.resume(tasks[2], { args = { "org.freedesktop.UPower", ":1.2", "" } }))
assert(old_bus.closed)
assert(coroutine.resume(tasks[1]))
assert(state() == nil and delay == 1000, "service loss must clear stale charge")
assert(old_bus.streams[1].closed and old_bus.streams[2].closed)
offline = true
assert(coroutine.resume(tasks[1]))
assert(delay == 2000 and state() == nil)
offline = false
current = properties(99, 4)
assert(coroutine.resume(tasks[1]))
assert(state().percentage == 99 and current_bus ~= old_bus, "reconnect did not read the new owner")
print("PASS: battery variants, rounding, charging/low/absent states, signals, invalidation, and reconnection")
