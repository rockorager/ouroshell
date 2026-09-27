local ouro = require("ouro")
local support = require("dbus_support")
local M = { format = "%a %b %d  %I:%M %p" }

-- Minute-aligned local time. ouro.sleep uses CLOCK_MONOTONIC, which stops
-- during suspend, so logind's resume signal refreshes and realigns it.
function M.connect()
  local clock = ouro.signal(ouro.date(M.format))
  local generation = 0
  local function restart()
    generation = generation + 1
    local current = generation
    clock:set(ouro.date(M.format))
    ouro.spawn(function()
      while true do
        ouro.sleep((60 - ouro.time() % 60) * 1000)
        if generation ~= current then return end -- Superseded after resume.
        clock:set(ouro.date(M.format))
      end
    end)
  end
  restart()
  support.supervise { bus = "system", session = function(bus, healthy)
    local sleeps <close> = support.need(bus:subscribe {
      sender = "org.freedesktop.login1", path = "/org/freedesktop/login1",
      interface = "org.freedesktop.login1.Manager", member = "PrepareForSleep",
    })
    healthy()
    while true do
      local message = support.need(sleeps:next())
      if message.signature == "b" and message.args[1] == false then restart() end
    end
  end }
  return clock
end

return M
