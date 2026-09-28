package.path = "src/?.lua;tests/?.lua;" .. package.path
local tasks, next_task = {}, 1
local candidate = true
local function spawn(fn) tasks[#tasks + 1] = coroutine.create(fn) end
local function resume(task, ...)
  local ok, value = coroutine.resume(task, ...)
  assert(ok, value)
end
local function run()
  while next_task <= #tasks do
    local task = tasks[next_task]; next_task = next_task + 1
    resume(task)
  end
end
local ouro = require("fake_ouro").install {
  spawn = spawn,
  spawn_app = function(fn)
    assert(not candidate, "startup must inherit app scope; spawn_app rejects reload candidates")
    spawn(fn)
  end,
  sleep = function() coroutine.yield("sleep") end,
}
local function resource(initial)
  local result = { initial = initial }
  function result:close() self.closed = true end
  function result:next()
    if self.initial ~= nil then local value = self.initial; self.initial = nil; return value end
    self.reader = coroutine.running()
    return coroutine.yield()
  end
  return setmetatable(result, { __close = result.close })
end
local function emit(stream, ...)
  local reader = assert(stream.reader, "no stream reader")
  stream.reader = nil
  resume(reader, ...)
  run()
end
local timers, powers, owners, buses, calls, fds = {}, {}, {}, {}, {}, {}
local snapshots = resource({ "eDP-1", "DP-2" })
ouro.session = {
  idle = function(ms)
    local timer = resource(); timer.ms = ms; timers[#timers + 1] = timer; return timer
  end,
  outputs = function() return snapshots end,
  power = function(name)
    local power = resource("on")
    power.values = {}
    function power:set(value) self.values[#self.values + 1] = value end
    powers[name] = power
    return power
  end,
  lock = function()
    local owner = resource()
    function owner:unlock() self.unlocked = true end
    owners[#owners + 1] = owner
    return owner
  end,
}
ouro.auth = { start = function() return nil, "No fixture PAM" end }
local deny_caffeine, hold_caffeine = false, false
local pending_caffeine
ouro.dbus.connect = function(which)
  assert(which == "system")
  local bus = resource()
  function bus:subscribe(match)
    assert(match.sender == "org.freedesktop.login1" and match.close_on_owner_change)
    assert(match.path == nil and match.interface == nil, "sleep and session events must share one ordered stream")
    self.events = resource()
    return self.events
  end
  function bus:call(request)
    assert(request.destination == "org.freedesktop.login1" and request.timeout_ms == 5000)
    calls[#calls + 1] = request
    if request.member == "Inhibit" then
      local what, who, why, mode = table.unpack(request.args)
      assert(who == "Ouroshell" and request.signature == "ssss")
      if what == "idle" then
        assert(mode == "block" and why == "Caffeinated from the launcher")
        if deny_caffeine then return nil, { message = "inhibitor denied" } end
        if hold_caffeine then pending_caffeine = coroutine.running(); return coroutine.yield() end
      else
        assert(what == "sleep" and mode == "delay", "never take a lid or sleep block inhibitor")
      end
      local fd = { what = what, close = function(self) self.closed = true end }
      fds[#fds + 1] = fd
      return { signature = "h", args = { fd } }
    elseif request.member == "GetSession" then
      assert(request.args[1] == "auto"); return { args = { "/org/freedesktop/login1/session/c7" } }
    elseif request.member == "GetAll" then
      return { args = { { { "Name", { value = "trusted-user", signature = "s" } } } } }
    elseif request.member == "Get" then
      assert(request.args[2] == "PreparingForSleep"); return { args = { { signature = "b", value = false } } }
    elseif request.member == "SetLockedHint" then
      assert(request.signature == "b"); return { args = {} }
    elseif request.member == "Suspend" then
      assert(request.signature == "b" and request.args[1] == false)
      return { args = {} }
    end
    error("Unexpected D-Bus call: " .. request.member)
  end
  buses[#buses + 1] = bus
  return bus
end
local state = require("idle").connect { dismiss = function() end }
-- Ordinary task bodies may execute during candidate evaluation. Startup must
-- create only stageable native resources, not call spawn_app indirectly.
run()
candidate = false
assert(#timers == 3 and timers[1].ms == 300000 and timers[2].ms == 600000 and timers[3].ms == 1800000)
assert(fds[1].what == "sleep" and not fds[1].closed)
assert(state.locker.username() == "trusted-user")
local function count(member)
  local n = 0
  for _, call in ipairs(calls) do if call.member == member then n = n + 1 end end
  return n
end
local function sleep_signal(value)
  emit(buses[#buses].events, { path = "/org/freedesktop/login1", interface = "org.freedesktop.login1.Manager",
    member = "PrepareForSleep", signature = "b", args = { value } })
end

-- Display-off and suspend cannot overtake an unacknowledged lock. Activity
-- while acquisition is pending cancels only the pending inactivity actions.
emit(timers[2], "idled"); emit(timers[3], "idled")
assert(#owners == 1 and not state.locker.secured() and count("Suspend") == 0)
assert(powers["DP-2"].values[#powers["DP-2"].values] == true)
emit(timers[3], "resumed")
emit(owners[1], "locked")
assert(state.locker.secured() and count("Suspend") == 0 and not fds[1].closed)
assert(powers["DP-2"].values[#powers["DP-2"].values] == false)
emit(snapshots, { "DP-2", "HDMI-A-1" })
assert(powers["eDP-1"].closed and powers["HDMI-A-1"].values[1] == false,
  "hotplug must follow blanked state and release removed outputs")
emit(timers[2], "resumed")
assert(powers["HDMI-A-1"].values[#powers["HDMI-A-1"].values] == true)

-- Caffeine closes the actual native timers, retains the sleep delay, and
-- drops queued old-generation events. Denial leaves the policy enabled.
deny_caffeine = true
assert(not pcall(state.toggle) and not state.caffeinated() and not timers[1].closed)
deny_caffeine = false
local old = { timers[1], timers[2], timers[3] }
state.toggle(); run()
local caffeine = fds[#fds]
assert(state.caffeinated() and caffeine.what == "idle" and not fds[1].closed)
for _, timer in ipairs(old) do assert(timer.closed) end
emit(old[3], "idled")
assert(count("Suspend") == 0)
sleep_signal(true)
assert(fds[1].closed and not caffeine.closed, "caffeine must not suppress lock-before-suspend")
sleep_signal(false)
local delay = fds[#fds]
assert(delay.what == "sleep" and not delay.closed and #timers == 3)
state.toggle(); run()
assert(caffeine.closed and not state.caffeinated() and #timers == 6)
emit(timers[6], "idled")
assert(count("Suspend") == 1)

-- A fresh external sleep request cannot release its delay until lock-ready.
emit(owners[1], "unlocked") -- Unit-level protocol completion; auth is tested separately.
sleep_signal(true)
assert(#owners == 2 and not delay.closed)
emit(owners[2], "locked")
assert(delay.closed)
sleep_signal(false)
delay = fds[#fds]
local owners_before = #owners
emit(buses[1].events, { path = "/org/freedesktop/login1/session/c7", interface = "org.freedesktop.login1.Session",
  member = "Unlock", signature = "", args = {} })
assert(state.locker.secured() and #owners == owners_before and not owners[#owners].unlocked)

-- Suspend can arrive between successful PAM and the queued unlock event.
-- The old acknowledgement no longer secures the new sleep operation.
local authentication
ouro.auth.start = function()
  authentication = resource()
  authentication.cancel = authentication.close
  return authentication
end
state.locker.authenticate(); run()
emit(authentication, { type = "result", success = true })
assert(state.locker.phase() == "unlocking")
sleep_signal(true)
assert(not delay.closed, "an unlock already queued must invalidate the old lock acknowledgement")
emit(owners[#owners], "unlocked")
assert(#owners == owners_before + 1 and not delay.closed)
emit(owners[#owners], "locked")
assert(delay.closed)
sleep_signal(false)
delay = fds[#fds]

-- Bus/owner loss releases both FDs, resets caffeine, and rejects a late FD
-- from a retired connection instead of reviving the old preference.
state.toggle(); run(); caffeine = fds[#fds]
local supervisor = buses[1].events.reader
emit(buses[1].events, nil, { message = "owner changed" })
assert(caffeine.closed and delay.closed and not state.caffeinated())
assert(not pcall(state.toggle))
resume(supervisor); run()
assert(#buses == 2 and not state.caffeinated())
hold_caffeine = true
spawn(state.toggle); run()
assert(pending_caffeine)
emit(buses[2].events, nil, { message = "disconnected" })
local stale = { close = function(self) self.closed = true end }
local ok = coroutine.resume(pending_caffeine, { signature = "h", args = { stale } })
assert(not ok and stale.closed and not state.caffeinated())
print("PASS: native idle stages, lock-before-power/suspend, hotplug, caffeine, sleep delay, stale events and reconnection")
