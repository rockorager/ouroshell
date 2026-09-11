local ouro = require("ouro")
local bar = require("bar")
local selected = ouro.signal("2")
local time = "Thu Sep 10  04:32 PM"

local function workspace_content()
  local workspaces = {}
  for _, name in ipairs({ "10", "4", "1", "3", "2" }) do
    workspaces[#workspaces + 1] = {
      id = name, name = name, active = selected() == name,
      urgent = name == "4", can_activate = true,
      activate = function() selected:set(name) end,
    }
  end
  return bar.content({ available = true, workspaces = workspaces }, time)
end

return ouro.app {
  id = "dev.ouro.shell.preview",
  theme = { color_scheme = "dark" },
  run = function()
    local cases = {
      { name = "workspaces", content = workspace_content },
      { name = "narrow", width = 280, content = workspace_content },
      { name = "unavailable", content = function()
        return bar.content({ available = false, workspaces = {} }, time)
      end },
      { name = "empty", content = function()
        return bar.content({ available = true, workspaces = {} }, time)
      end },
    }
    local windows = {}
    for index, case in ipairs(cases) do
      windows[#windows + 1] = ouro.layer_surface {
        id = case.name, namespace = "ouroshell-preview", layer = "top",
        width = case.width or 0, height = bar.height,
        anchors = case.width and { "top", "left" } or { "top", "left", "right" },
        margins = { top = (index - 1) * 48 },
        keyboard_interactivity = "none",
        content = case.content,
      }
    end
    return { windows = windows }
  end,
}
