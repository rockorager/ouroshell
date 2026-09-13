local ouro = require("ouro")
local bar = require("bar")
local launcher = require("launcher")
local selected = ouro.signal("2")
local time = "Thu Sep 10  04:32 PM"
local visible = ouro.signal(true)
local launcher_state

local function toggle()
  if not visible() then launcher_state.open() end
  visible:set(not visible())
end

local function workspace_content()
  local workspaces = {}
  for _, name in ipairs({ "10", "4", "1", "3", "2" }) do
    workspaces[#workspaces + 1] = {
      id = name, name = name, active = selected() == name,
      urgent = name == "4", can_activate = true,
      activate = function() selected:set(name) end,
    }
  end
  return bar.content({ available = true, workspaces = workspaces }, time, nil, toggle)
end

return ouro.app {
  id = "dev.ouro.shell.preview",
  theme = { color_scheme = "dark" },
  run = function()
    launcher_state = launcher.new {
      phase = "ready",
      dismiss = function() visible:set(false) end,
      prepare_launch = function(entry) return { argv = { entry.exec } } end,
      -- Preview is deliberately incapable of executing apps or session actions.
      call = function() return { result = { isError = true, structuredContent = {
        error = { message = "Preview only — no command was executed" },
      } } } end,
      entries = {
        { id = "org.gnome.Nautilus.desktop", name = "Files", generic_name = "File manager", icon = "system-file-manager", exec = "nautilus", visible = true },
        { id = "dev.rockorager.monstar.desktop", name = "Monstar", generic_name = "Terminal", icon = "utilities-terminal", exec = "monstar", visible = true },
        { id = "org.mozilla.firefox.desktop", name = "Firefox", generic_name = "Web browser", icon = "web-browser", exec = "firefox", visible = true },
        { id = "org.gnome.Settings.desktop", name = "Settings", icon = "org.gnome.Settings", exec = "gnome-control-center", visible = true },
      },
    }
    local panel = ouro.layer_surface {
      id = "panel", namespace = "ouroshell-preview", layer = "top",
      width = 0, height = bar.height, anchors = { "top", "left", "right" },
      exclusive_zone = bar.height, keyboard_interactivity = "none", content = workspace_content,
    }
    return { windows = function()
      local windows = { panel }
      if visible() then
        windows[#windows + 1] = ouro.layer_surface {
          id = "launcher", namespace = "ouroshell-preview-launcher", layer = "overlay",
          width = 0, height = 0, anchors = { "top", "bottom", "left", "right" },
          background = launcher.background, background_effect = "blur", keyboard_interactivity = "exclusive",
          content = function(_, height) return launcher.content(launcher_state, height) end,
        }
      end
      return windows
    end }
  end,
}
