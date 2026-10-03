package.path = "src/?.lua;tests/?.lua;" .. package.path
local tasks, timers = {}, {}
local ouro = require("fake_ouro").install {
  spawn = function(fn) tasks[#tasks + 1] = coroutine.create(fn) end,
  spawn_app = function(fn) timers[#timers + 1] = coroutine.create(fn) end,
  sleep = function(ms) assert(ms == 100); coroutine.yield() end,
  stateful = function(initialize)
    local renderers = {}
    return function(props)
      renderers[props.state] = renderers[props.state] or {}
      local mounted = renderers[props.state]
      if mounted.key ~= props.key then mounted.key, mounted.render = props.key, initialize(props) end
      return mounted.render(props)
    end
  end,
}
local scheme = "light"
package.loaded.appearance = { colors = function()
  return { sidebar_foreground = scheme .. ":foreground", muted_foreground = scheme .. ":muted",
    primary = scheme .. ":primary", switch_track = scheme .. ":track" },
    { red = { step_11 = "red" } }
end }
local volume = require("volume")
local function snapshot(value, muted, identity)
  return { connected = true, available = true, volume = value, muted = muted or false, identity = identity or 7 }
end
local output = ouro.signal(snapshot(0.42))
local adjustments, rejected = {}, false
function output:adjust_volume(delta)
  adjustments[#adjustments + 1] = delta
  if rejected then return nil, "OutputUnavailable" end
  return true
end
local state = volume.new(output)
local function update(value)
  output:set(value)
  state.observe(value)
end
local function resume(task)
  local ok, failure = coroutine.resume(task)
  assert(ok, failure)
end
local function finish_timer()
  local timer = timers[#timers]
  for _ = 1, 16 do
    if coroutine.status(timer) == "dead" then return end
    resume(timer)
  end
  assert(coroutine.status(timer) == "dead", "OSD timer failed to expire")
end

for _, case in ipairs({ { 0, 0, "muted" }, { .0049, 0, "muted" }, { .0051, 1, "low" },
  { .3349, 33, "low" }, { .3351, 34, "medium" }, { .6649, 66, "medium" },
  { .6651, 67, "high" }, { 1, 100, "high" }, { 1.25, 125, "high" } }) do
  output:set(snapshot(case[1]))
  local view = volume.content(state)
  assert(view.children[1].alt == "Volume: " .. case[2] .. "%")
  assert(view.children[1].name == "audio-volume-" .. case[3] .. "-symbolic")
  assert(view.children[1].theme == "Adwaita")
  assert(not view.open and view.gap == 16, "idle volume must not open until hovered")
end
output:set(snapshot(.78, true))
assert(volume.content(state).children[1].alt == "Muted (78%)")
assert(volume.content(state).children[1].name == "audio-volume-muted-symbolic")
scheme = "dark"
assert(volume.content(state).children[1].tint == "dark:foreground")
output:set({ connected = false, available = false })
assert(volume.content(state).children[1].alt == "Audio unavailable")
assert(volume.content(state).children[1].tint == "dark:muted")

-- Startup, metadata changes, and floating-point noise must not flash the OSD.
update(snapshot(.42))
update(snapshot(.42001))
local renamed = snapshot(.42)
renamed.description = "Speakers"
update(renamed)
assert(not state.shown() and #timers == 0)
update(snapshot(.47))
assert(state.shown() and #timers == 1 and volume.content(state).open == true)
resume(timers[1]) -- Start the first 100ms sleep.
for _ = 1, 10 do resume(timers[1]) end
for index = 1, 100 do
  update(snapshot(index % 2 == 0 and .52 or .47))
end
assert(#timers == 1, "key repeat must not create unbounded sleeping tasks")
for _ = 1, 14 do resume(timers[1]) end
assert(state.shown(), "old deadline dismissed a more recent adjustment")
resume(timers[1])
assert(not state.shown() and not volume.content(state).open, "unhovered OSD must close after expiry")
assert(coroutine.status(timers[1]) == "dead")

update(snapshot(.52, true))
assert(state.shown() and volume.content(state).children[1].alt == "Muted (52%)")
finish_timer()
update(snapshot(.52, false))
assert(state.shown(), "unmuting at unchanged volume must show the OSD")
update(snapshot(.81, false, 8))
assert(not state.shown(), "device replacement must dismiss the previous device's OSD")
update(snapshot(.86, false, 8))
assert(state.shown(), "a change on the new device must display its level")
update({ connected = false, available = false })
assert(not state.shown() and not volume.content(state).open)
update(snapshot(.23, false, 9))
assert(not state.shown(), "reconnect must not flash a volume change")
finish_timer()

-- Actions use native serialized deltas, never a stale read-modify-write.
assert(state.adjust(.05) and state.adjust(-.05))
assert(adjustments[1] == .05 and adjustments[2] == -.05)
assert(output().volume == .23, "queued requests must not fabricate confirmed volume")
finish_timer()
update(snapshot(1, false, 9))
finish_timer()
assert(state.adjust(.05) and state.shown(), "the maximum still needs key feedback")
finish_timer()
update(snapshot(0, false, 9))
finish_timer()
assert(state.adjust(-.05) and state.shown(), "the minimum still needs key feedback")
finish_timer()
rejected = true
local ok, failure = state.adjust(.05)
assert(not ok and failure == "OutputUnavailable" and not state.shown())

-- Integration consumes the native stream, not a polling loop or render effect.
local next_calls = 0
function output:next()
  next_calls = next_calls + 1
  return coroutine.yield()
end
ouro.audio = { default_output = function() return output end }
local connected = volume.connect()
assert(connected.output == output and #tasks == 1)
resume(tasks[1])
assert(coroutine.resume(tasks[1], snapshot(.27)))
assert(not connected.shown())
assert(coroutine.resume(tasks[1], snapshot(.32)))
assert(connected.shown() and next_calls == 3)
resume(tasks[1]) -- Closed stream returns nil.
assert(not connected.shown() and coroutine.status(tasks[1]) == "dead")
finish_timer()

-- Only hovering the icon holds the display open after key-feedback expiry.
rejected = false
update(snapshot(.37, false, 9))
state.dismiss()
local view = volume.content(state)
assert(view.interactive == false, "volume display must be pointer-transparent")
view.on_interaction_change(true)
assert(volume.content(state).open, "hover must open the level display")
state.show()
finish_timer()
assert(volume.content(state).open, "expiry must not close while hovering")
view.on_interaction_change(false)
assert(not volume.content(state).open, "leaving must close the hover display")
view.on_interaction_change(true)
view.on_close()
assert(not volume.content(state).open, "native dismissal must clear controlled visibility")

local named = snapshot(.72, true, 9)
named.description = "Laptop speakers"
update(named)
local card = volume.content(state).content()
assert(card.children[1].children[1].text == "Laptop speakers")
local controls = card.children[1].children[2].children
assert(controls[1].name == "audio-volume-muted-symbolic" and controls[3].name == "audio-volume-high-symbolic")
assert(controls[2].label == "Volume level, 0%", "muted output must display silence")
for _, case in ipairs({ { 0, nil, 100 }, { .31, 31, 69 }, { 1, 100, nil }, { 1.25, 100, nil } }) do
  update(snapshot(case[1], false, 9))
  local level = volume.popup(state).children[1].children[2].children[2]
  assert(not level.range and not level.on_change and not level.on_press,
    "level bar must have neither native range input nor click handlers")
  local rail = level.children[1].children[1].children
  assert(rail[1].flex == case[2] and rail[2].flex == case[3], "fill must follow confirmed level and clamp amplification")
  assert(rail[1].background == "dark:primary" and level.children[1].background == "dark:track",
    "filled portion must use the accent color over a muted track")
end
rejected = true
assert(not state.adjust(.05))
assert(volume.popup(state).children[1].children[1].text == "OutputUnavailable",
  "failed volume requests must be visible")
volume.content(state).on_interaction_change(true)
update(snapshot(.19, false, 10))
assert(not volume.content(state).open, "a new output must not inherit the old output's hover")
print("PASS: volume icons, stream updates, bounded OSD timing, relative actions, passive level display and hover lifetime")
