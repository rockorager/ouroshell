local ouro = require("ouro")
local support = require("dbus_support")
local machine = ouro.machine
local M = { format = "%a %b %d  %I:%M %p" }

-- Headless minute-aligned local time. Each read records the second within
-- the minute, and the named `minute` delay waits for the next boundary on
-- the logical clock. Timers stop during suspend (CLOCK_MONOTONIC), so
-- logind's resume signal reads the time again, which cancels the stale wait.
--   services.date(): { time = formatted local time, second = seconds into the minute }
--   services.sleeps(_, send): serves logind's PrepareForSleep (sends RESUMED, CONNECTED)
function M.chart(services)
  return machine.create {
    id = "clock", type = "parallel", order = { "tick", "logind" },
    context = { time = "", second = 0, retry = support.retry },
    events = { RESUMED = {}, CONNECTED = {} },
    actors = { date = services.date, sleeps = services.sleeps },
    delays = {
      minute = function(c) return (60 - c.second) * 1000 end,
      retry = function(c) return c.retry end,
    },
    actions = { show = machine.assign(function(_, e) return { time = e.output.time, second = e.output.second } end) },
    states = {
      tick = { initial = "reading",
        on = { RESUMED = ".reading" },
        states = {
          reading = { invoke = { src = "date", on_done = { target = "waiting", actions = "show" } } },
          waiting = { after = { minute = "reading" } },
        } },
      logind = support.reconnecting { src = "sleeps", retry = "retry",
        online = { on = { CONNECTED = { actions = support.reset("retry") } } } },
    },
  }
end

M.services = {
  date = function()
    return { time = ouro.date(M.format), second = math.floor(ouro.time()) % 60 }
  end,
  sleeps = function(_, send)
    local bus <close> = support.connect("system")
    local sleeps <close> = support.need(bus:subscribe {
      sender = "org.freedesktop.login1", path = "/org/freedesktop/login1",
      interface = "org.freedesktop.login1.Manager", member = "PrepareForSleep",
    })
    send("CONNECTED")
    while true do
      local message = support.need(sleeps:next())
      if message.signature == "b" and message.args[1] == false then send("RESUMED") end
    end
  end,
}

return M
