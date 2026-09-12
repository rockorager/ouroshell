local ouro = require("ouro")
local bar = require("bar")
local launcher = require("launcher")

-- This must outlive builds: windows() reads it reactively and never yields.
local launcher_visible = ouro.signal(false)
local launcher_state

local function dismiss_launcher() launcher_visible:set(false) end
local function toggle_launcher()
  launcher_visible:set(not launcher_visible())
  return {}
end

return ouro.app {
  id = "dev.ouro.shell",
  actions = {
    ["launcher.toggle"] = {
      description = "Show or dismiss the application launcher.",
      inputSchema = { type = "object", properties = {}, additionalProperties = false },
      outputSchema = { type = "object", properties = {}, additionalProperties = false },
      handler = toggle_launcher,
    },
  },
  theme = { color_scheme = "dark" },
  run = function()
    local workspaces = ouro.shell.workspaces.connect()
    local clock_format = "%a %b %d  %I:%M %p"
    local clock = ouro.signal(ouro.date(clock_format))
    launcher_state = launcher.new { dismiss = dismiss_launcher }
    launcher_state.load()
    ouro.spawn(function()
      while true do
        ouro.sleep((60 - ouro.time() % 60) * 1000)
        clock:set(ouro.date(clock_format))
      end
    end)

    local panel = ouro.layer_surface {
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
    }
    return { windows = function()
      local windows = { panel }
      if launcher_visible() then
        windows[#windows + 1] = ouro.layer_surface {
          id = "launcher", namespace = "ouroshell-launcher", layer = "overlay",
          width = 620, height = 480, anchors = {}, exclusive_zone = 0,
          keyboard_interactivity = "exclusive",
          content = function() return launcher.content(launcher_state) end,
        }
      end
      return windows
    end }
  end,
}
