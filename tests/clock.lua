package.path = "src/?.lua;tests/?.lua;" .. package.path
local tasks, delays, now = {}, {}, 119
local function resume(task, ...)
  local ok, err = coroutine.resume(task, ...)
  assert(ok, err)
end
local ouro = require("fake_ouro").install {
  spawn = function(fn) tasks[#tasks + 1] = coroutine.create(fn) end,
  sleep = function(ms) delays[coroutine.running()] = ms; coroutine.yield() end,
  time = function() return now end,
  date = function(format)
    assert(format == "%a %b %d  %I:%M %p")
    return "minute " .. math.floor(now / 60)
  end,
}
local bus = { streams = {} }
function bus:close() self.closed = true end
function bus:subscribe(match)
  assert(match.sender == "org.freedesktop.login1" and match.path == "/org/freedesktop/login1")
  assert(match.interface == "org.freedesktop.login1.Manager" and match.member == "PrepareForSleep")
  local stream = {}
  function stream:close() self.closed = true end
  function stream:next() return coroutine.yield() end
  self.streams[#self.streams + 1] = stream
  return setmetatable(stream, { __close = stream.close })
end
ouro.dbus.connect = function(which)
  assert(which == "system")
  return setmetatable(bus, { __close = bus.close })
end

local clock = require("clock").connect()
assert(clock() == "minute 1" and #tasks == 2)
local ticker, logind = tasks[1], tasks[2]
resume(ticker)
assert(delays[ticker] == 1000, "clock did not align with the next minute")
resume(logind) -- Subscribes and waits for sleep signals.
now = 120
resume(ticker)
assert(clock() == "minute 2" and delays[ticker] == 60000)

-- Suspend at 10s into the minute; resume 30 minutes later. The monotonic
-- timer would otherwise keep the old deadline and show stale time.
now = 130
resume(logind, { signature = "b", args = { true } })
assert(clock() == "minute 2" and #tasks == 2, "entering sleep must not restart the clock")
now = 1930 + 25
resume(logind, { signature = "b", args = { false } })
assert(clock() == "minute 32", "resume must refresh the clock immediately")
assert(#tasks == 3)
local realigned = tasks[3]
resume(realigned)
assert(delays[realigned] == 25000, "resume must realign to the next minute boundary")
resume(ticker)
assert(coroutine.status(ticker) == "dead", "the pre-suspend timer must retire")
assert(clock() == "minute 32")
now = 1980
resume(realigned)
assert(clock() == "minute 33")
resume(logind, { signature = "s", args = { "false" } })
assert(#tasks == 3, "malformed signals must be ignored")
print("PASS: minute-aligned clock and refresh after suspend")
