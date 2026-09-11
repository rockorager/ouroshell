local ouro = require("ouro")
local bar = require("bar")

return ouro.app {
  id = "dev.ouro.shell",
  actions = {},
  theme = { color_scheme = "dark" },
  run = function()
    local workspaces = ouro.shell.workspaces.connect()
    local clock_format = "%a %b %d  %I:%M %p"
    local clock = ouro.signal(ouro.date(clock_format))
    ouro.spawn(function()
      while true do
        ouro.sleep((60 - ouro.time() % 60) * 1000)
        clock:set(ouro.date(clock_format))
      end
    end)

    return { windows = {
      ouro.layer_surface {
        id = "panel",
        namespace = "ouroshell-panel",
        outputs = "all",
        layer = "top",
        width = 0,
        height = bar.height,
        anchors = { "top", "left", "right" },
        exclusive_zone = bar.height,
        exclusive_edge = "top",
        keyboard_interactivity = "none",
        content = function(output)
          return bar.content(workspaces(), clock(), output)
        end,
      },
    } }
  end,
}
