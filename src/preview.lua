local ouro = require("ouro")
local bar = require("bar")
local launcher = require("launcher")
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
    local launcher_state = launcher.new {
      phase = "ready",
      dismiss = function() end,
      entries = {
        { id = "org.gnome.Nautilus.desktop", name = "Files", icon = "system-file-manager", exec = "nautilus", visible = true },
        { id = "dev.rockorager.monstar.desktop", name = "Monstar", icon = "utilities-terminal", exec = "monstar", visible = true },
        { id = "org.mozilla.firefox.desktop", name = "Firefox", icon = "firefox", exec = "firefox", visible = true },
        { id = "org.gnome.Settings.desktop", name = "Settings", icon = "org.gnome.Settings", exec = "gnome-control-center", visible = true },
      },
    }
    windows[#windows + 1] = ouro.layer_surface {
      id = "launcher", namespace = "ouroshell-preview-launcher", layer = "overlay",
      width = 720, height = 560, anchors = {}, keyboard_interactivity = "exclusive",
      content = function() return launcher.content(launcher_state) end,
    }
    return { windows = windows }
  end,
}
