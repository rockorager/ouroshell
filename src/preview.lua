local ouro = require("ouro")
local bar = require("bar")
local launcher = require("launcher")
local appearance = require("appearance")
local catalog = require("catalog")
local network = require("network")
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
  return bar.content {
    workspaces = { available = true, workspaces = workspaces }, time = time, open_launcher = toggle,
    power = { percentage = 67, icon = "battery-good-charging-symbolic", charging = true, low = false },
    connectivity = network.snapshot({ { Name = "wlan0", Type = "wlan", OperationalState = "routable" } },
      { wlan0 = { name = "Preview Wi-Fi", level = 0 } }),
  }
end

return ouro.app {
  id = "dev.ouro.shell.preview",
  run = function()
    appearance.connect()
    local caffeinated = ouro.signal(false)
    launcher_state = launcher.new {
      dismiss = function() visible:set(false) end,
      idle = { caffeinated = caffeinated, toggle = function() caffeinated:set(not caffeinated()) end,
        lock = function() error("Preview only — no lock was requested") end },
      prepare_launch = function(entry) return { argv = { entry.exec } } end,
      -- Preview is deliberately incapable of executing apps or session actions.
      call = function() return { result = { isError = true, structuredContent = {
        error = { message = "Preview only — no command was executed" },
      } } } end,
      catalog = catalog.fixed {
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
          background = launcher.background(), background_effect = "blur", keyboard_interactivity = "exclusive",
          content = function(width, height) return launcher.content(launcher_state, height, width) end,
        }
      end
      return windows
    end }
  end,
}
