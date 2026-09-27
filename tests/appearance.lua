package.path = "src/?.lua;tests/?.lua;" .. package.path
local tasks, streams, reads, offline, delay = {}, {}, 0, false, nil
local service, namespace = "org.freedesktop.portal.Desktop", "org.freedesktop.appearance"
local ouro = require("fake_ouro").install {
  tokens = { light = {}, dark = {}, palette = { light = {}, dark = {} } },
  spawn = function(fn) tasks[#tasks + 1] = coroutine.create(fn) end,
  sleep = function(ms) delay = ms; coroutine.yield() end,
}
local bus = {}
function bus:close() self.closed = true end
function bus:subscribe(match)
  assert(not self.closed)
  local stream = {}
  function stream:close() self.closed = true end
  function stream:next() return coroutine.yield() end
  if match.member == "NameOwnerChanged" then
    assert(match.sender == "org.freedesktop.DBus" and match.path == "/org/freedesktop/DBus")
  else
    assert(match.member == "SettingChanged" and match.sender == service)
    assert(match.path == "/org/freedesktop/portal/desktop" and match.interface == "org.freedesktop.portal.Settings")
  end
  streams[match.member] = stream
  return setmetatable(stream, { __close = stream.close })
end
function bus:call(request)
  assert(streams.NameOwnerChanged and streams.SettingChanged, "subscribe before reading")
  assert(request.destination == service and request.path == "/org/freedesktop/portal/desktop")
  assert(request.interface == "org.freedesktop.portal.Settings" and request.member == "ReadAll")
  assert(request.signature == "as" and #request.args[1] == 1 and request.args[1][1] == namespace)
  assert(request.timeout_ms == 5000)
  reads = reads + 1
  return coroutine.yield()
end
ouro.dbus.connect = function(which)
  assert(which == "session")
  if offline then return nil, { message = "offline" } end
  return setmetatable(bus, { __close = bus.close })
end
local appearance = require("appearance")
local function resume(task, message)
  local ok, err = coroutine.resume(tasks[task], message)
  assert(ok, err)
end
local function expect(name)
  local colors, palette = appearance.colors()
  assert(colors == ouro.tokens[name] and palette == ouro.tokens.palette[name], "expected " .. name)
end
local function variant(value, signature) return { signature = signature or "u", value = value } end
local function snapshot(value, sender)
  return { sender = sender or ":1.2", signature = "a{sa{sv}}", args = { {
    { "unrelated.namespace", { { "color-scheme", variant(1) } } },
    { namespace, value and { { "contrast", variant(1) }, { "color-scheme", value } } or {} },
  } } }
end
local function changed(value, key, sender)
  resume(2, { sender = sender or ":1.2", signature = "ssv", args = { namespace, key or "color-scheme", value } })
end
local function owner(previous, current)
  resume(1, { signature = "sss", args = { service, previous, current } })
end

expect("light")
appearance.connect()
resume(1) -- Register matches and wait for owners.
resume(2) -- Wait for preference changes.
resume(3) -- Initial asynchronous read.
resume(3, snapshot(variant(1)))
expect("dark")
changed(variant(2)); expect("light")
changed(variant(1)); expect("dark")
changed(variant(0)); expect("light")
changed(variant(1, "s")); expect("light")
changed(variant(99)); expect("light")
changed(variant(1)); expect("dark")
changed(variant(2), "contrast"); expect("dark")
resume(2, { sender = ":1.2", signature = "ssv", args = { "unrelated.namespace", "color-scheme", variant(2) } })
expect("dark")
assert(reads == 1, "signals must not poll or reread")

owner(":1.2", ""); expect("light")
changed(variant(1)); expect("light") -- Queued signal from departed owner.
assert(#tasks == 3, "absence must wait for an owner, not poll")
owner("", ":1.3")
resume(4)
owner(":1.3", ":1.4") -- Replace owner while its read is pending.
resume(5)
resume(5, snapshot(variant(2), ":1.4"))
resume(4, snapshot(variant(1), ":1.3")); expect("light")
changed(variant(1), nil, ":1.3"); expect("light")
changed(variant(1), nil, ":1.4"); expect("dark")

owner(":1.4", ":1.5")
resume(6)
changed(variant(1), nil, ":1.5")
resume(6, snapshot(variant(2), ":1.5")); expect("dark") -- Signal beats stale snapshot.
owner(":1.5", ":1.6")
resume(7)
resume(7, snapshot(nil, ":1.6")); expect("light") -- Missing key.
owner(":1.6", ":1.7")
resume(8)
resume(8); expect("light") -- Failed read; still listening.
changed(variant(1), nil, ":1.7"); expect("dark")
owner(":1.7", ":1.8")
resume(9)
resume(1); expect("light") -- Disconnect retires outstanding reads.
resume(9, snapshot(variant(1), ":1.8")); expect("light")
resume(2)
assert(bus.closed and streams.NameOwnerChanged.closed and streams.SettingChanged.closed)
assert(delay == 1000, "bus loss must reconnect after a backoff")
offline = true
resume(1); expect("light")
assert(delay == 2000, "an unavailable bus must back off, not block startup")
offline, bus.closed, streams = false, false, {}
resume(1) -- Reconnect: register matches, then listen and read again.
resume(10)
resume(11)
resume(11, snapshot(variant(1), ":1.9")); expect("dark")
assert(reads == 8, "reconnect must read the portal again")
print("PASS: portal initial read, typed live settings, fallback, owner replacement, stale replies, and disconnect")
