-- The status charts behind the bar: battery, volume feedback, clock and
-- appearance. Services are fakes driven through the manual scheduler.
local o = require("ouro")
local machine = o.machine
local appearance = require("appearance")
local battery = require("battery")
local clock_module = require("clock")
local volume = require("volume")

local function never() error("a real service ran in a test") end

local function properties(percentage, state, present, warning, kind)
  return {
    { "IconName", { value = state == 1 and "battery-good-charging-symbolic" or "battery-good-symbolic" } },
    { "State", { value = state } }, { "Percentage", { value = percentage } },
    { "WarningLevel", { value = warning or 1 } }, { "Type", { value = kind or 2 } },
    { "IsPresent", { value = present ~= false } },
  }
end

local function output(fields)
  local snapshot = { available = true, identity = "speaker", volume = 0.5, muted = false, description = "Speakers" }
  for key, value in pairs(fields or {}) do snapshot[key] = value end
  return snapshot
end

return {
  ["battery snapshots follow UPower's display device"] = function()
    local normal = battery.snapshot(properties(67.49, 2))
    assert(normal.percentage == 67 and not normal.charging and not normal.low)
    local charging = battery.snapshot(properties(67.5, 1))
    assert(charging.percentage == 68 and charging.charging and charging.icon == "battery-good-charging-symbolic")
    assert(battery.snapshot(properties(100, 4)).percentage == 100 and not battery.snapshot(properties(100, 4)).charging)
    assert(battery.snapshot(properties(40, 5)).charging and battery.snapshot(properties(12, 2, true, 3)).low)
    assert(battery.snapshot(properties(40, 2, true, 2, 3)).low == false)
    assert(battery.snapshot(properties(40, 2, false)) == nil and battery.snapshot(properties(40, 2, true, 1, 1)) == nil)
    for _, invalid in ipairs({ -1, 101, 0 / 0, math.huge, "87" }) do
      assert(battery.snapshot(properties(invalid, 2)) == nil)
    end
  end,

  ["battery state hides while UPower is away and reconnects with backoff"] = function()
    local clock = machine.manual_scheduler()
    local actor = battery.chart { upower = never }:start { scheduler = clock }
    clock.emit("upower", { type = "POWER", power = battery.snapshot(properties(50, 2)) })
    assert(actor:context().power.percentage == 50)
    clock.reject("upower", "ServiceUnknown")
    assert(actor:matches("upower.offline") and actor:context().power == nil)
    -- Each failed session doubles the wait, on the logical clock, up to 30 s.
    for _, wait in ipairs({ 1000, 2000, 4000, 8000, 16000, 30000 }) do
      clock.advance(wait - 1)
      assert(actor:matches("upower.offline"), "still waiting " .. wait)
      clock.advance(1)
      assert(actor:matches("upower.online"))
      clock.reject("upower", "ServiceUnknown")
    end
    assert(actor:context().retry == 30000, "backoff is capped: " .. actor:context().retry)
    clock.advance(30000)
    clock.emit("upower", { type = "POWER" })
    assert(actor:context().retry == 1000 and actor:context().power == nil, "an absent battery is nil, and healthy")
  end,

  ["volume feedback shows confirmed changes, not connections or device swaps"] = function()
    local s = machine.manual_scheduler()
    local adjusted = {}
    local actor = volume.chart {
      follow = function() machine.sleep(machine.max_delay_ms) end,
      adjust = function(request)
        assert(request.handle.fake == "output")
        adjusted[#adjusted + 1] = request.delta
        if request.delta < 0 then error("VolumeAdjustFailed", 0) end
      end,
    }:start { scheduler = s }
    assert(not actor:can("UP"), "no requests before the output exists")
    s.emit("follow", { type = "CONNECTED", handle = { fake = "output" } })
    assert(actor:inspectable().context.handle["$h"], "the transient handle inspects as a marker")
    assert(actor:persist().context.handle == nil, "and is never persisted")
    actor:send { type = "OUTPUT", output = output() }
    assert(actor:matches("feedback.hidden"), "the initial snapshot is not an adjustment")
    actor:send { type = "OUTPUT", output = output { volume = 0.6 } }
    assert(actor:matches("feedback.shown"))
    s.advance(1000)
    actor:send { type = "OUTPUT", output = output { volume = 0.6, muted = true } }
    s.advance(1000)
    assert(actor:matches("feedback.shown"), "each change restarts the timer")
    s.advance(500)
    assert(actor:matches("feedback.hidden"), "feedback lasts about 1.5 s")
    actor:send { type = "OUTPUT", output = output { volume = 0.6004, muted = true } }
    assert(actor:matches("feedback.hidden"), "sub-percent changes are not shown")
    actor:send("UP")
    assert(actor:matches("feedback.shown"), "key requests show the level even at the limits")
    s.run_tasks()
    assert(adjusted[1] == 0.05)
    actor:send { type = "OUTPUT", output = output { identity = "headset", volume = 0.2 } }
    assert(actor:matches("feedback.hidden"), "a device replacement retires the popup")
    actor:send("DOWN")
    s.run_tasks()
    assert(adjusted[2] == -0.05 and actor:context().error == "VolumeAdjustFailed", "failures appear in the heading")
    actor:send { type = "OUTPUT", output = output { identity = "headset", volume = 0.2, error = "ServerLost" } }
    assert(actor:context().error == "ServerLost")
    actor:send("DISMISS")
    assert(actor:matches("feedback.hidden"))
    s.resolve("follow", nil)
    assert(actor:matches("pipewire.closed") and not actor:context().output.available and not actor:can("UP"))
  end,

  ["the clock waits for each minute boundary and re-reads on resume"] = function()
    local clock = machine.manual_scheduler()
    local actor = clock_module.chart { date = never, sleeps = never }:start { scheduler = clock }
    clock.resolve("date", { time = "Thu Sep 10  04:32 PM", second = 45 })
    assert(actor:context().time == "Thu Sep 10  04:32 PM" and actor:matches("tick.waiting"))
    clock.advance(14999)
    assert(actor:matches("tick.waiting"))
    clock.advance(1)
    assert(actor:matches("tick.reading"), "the minute boundary, on the logical clock")
    clock.resolve("date", { time = "Thu Sep 10  04:33 PM", second = 0 })
    assert(actor:context().time == "Thu Sep 10  04:33 PM")
    clock.advance(30000)
    clock.emit("sleeps", "RESUMED")
    assert(actor:matches("tick.reading"), "resume reads the time again")
    clock.resolve("date", { time = "Fri Sep 11  09:00 AM", second = 10 })
    clock.advance(30000)
    assert(actor:matches("tick.waiting"), "the stale wait was cancelled; the new one has 20 s left")
  end,

  ["appearance follows the portal and falls back to light"] = function()
    assert(appearance.scheme_of { signature = "u", value = 1 } == "dark")
    for _, value in ipairs({ { signature = "u", value = 0 }, { signature = "u", value = 2 },
      { signature = "s", value = "dark" } }) do
      assert(appearance.scheme_of(value) == "light")
    end
    assert(appearance.scheme_of(nil) == "light")
    local s = machine.manual_scheduler()
    local actor = appearance.chart { portal = never }:start { scheduler = s }
    s.emit("portal", { type = "SCHEME", value = "dark" })
    assert(actor:context().scheme == "dark")
    s.reject("portal", "bus lost")
    assert(actor:context().scheme == "light", "losing the bus falls back to light")
  end,
  ["the volume card fades in on each opening"] = function(t)
    local s = machine.manual_scheduler()
    local actor = volume.chart { follow = function() machine.sleep(machine.max_delay_ms) end, adjust = never }
      :start { scheduler = s }
    s.emit("follow", { type = "CONNECTED", handle = { fake = "output" } })
    actor:send { type = "OUTPUT", output = output() }
    local popover, transition, box = o.popover, o.transition, o.box
    local opened, fade, opacity
    o.popover = function(props) opened = props; return popover(props) end
    o.transition = function(props) fade = props; return transition(props) end
    o.box = function(props)
      if props.key == "volume-card" then opacity = props.opacity end
      return box(props)
    end
    local ok, failure = pcall(function()
      t:mount(function() return volume.content(actor, "light") end, { width = 40, height = 40, padding = 0 })
      assert(opened and not opened.open, "hidden until feedback or hover")
      actor:send { type = "OUTPUT", output = output { volume = 0.6 } }
      t:settle()
      assert(opened.open, "a confirmed change opens the card")
      opened.content()
      assert(fade.key == "fade" and fade.initial == 0 and fade.target == 1
        and fade.duration == 120 and fade.easing == "ease_out", "the card uses the tooltip's 120 ms ease-out fade")
      for _, value in ipairs({ 0, .4, 1 }) do
        fade.render(value)
        assert(opacity == value, "the fade applies to the whole card")
      end
    end)
    o.popover, o.transition, o.box = popover, transition, box
    assert(ok, failure)
  end,
}
