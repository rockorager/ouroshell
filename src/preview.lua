local ouro = require("ouro")
local machine = ouro.machine
local appearance = require("appearance")
local bar = require("bar")
local catalog = require("catalog")
local launcher = require("launcher")
local network = require("network")
local overlay = require("overlay")
local shell = require("shell")
local volume = require("volume")

-- A safe visual fixture: the real bar, launcher and shell charts over fixed
-- data. Every request is intercepted, so it cannot launch applications,
-- lock, log out or power off.
local time = "Thu Sep 10  04:32 PM"

-- The fixture's own state: a pretend Caffeinate.
local fixture = machine.create {
  id = "preview", initial = "running",
  context = { caffeinated = false },
  events = { TOGGLE_CAFFEINE = {} },
  states = { running = { on = {
    TOGGLE_CAFFEINE = { actions = machine.assign { caffeinated = function(c) return not c.caffeinated end } },
  } } },
}:actor { id = "preview" }

-- Fixture workspaces with the watch snapshot's shape; ACTIVATE selects one.
local function workspace_list(selected)
  local list = {}
  for _, name in ipairs({ "10", "4", "1", "3", "2" }) do
    list[#list + 1] = { id = name, handle = name, name = name, active = selected == name,
      urgent = name == "4", can_activate = true }
  end
  return list
end
local desks = machine.create {
  id = "workspaces", initial = "watching",
  context = { available = true, workspaces = workspace_list("2") },
  events = { ACTIVATE = { handle = "string" } },
  states = { watching = { on = {
    ACTIVATE = { actions = machine.assign { workspaces = function(_, e) return workspace_list(e.handle) end } },
  } } },
}:actor { id = "workspaces" }

local applications = catalog.chart { entries = {
  { id = "org.gnome.Nautilus.desktop", name = "Files", generic_name = "File manager", icon = "system-file-manager", exec = "nautilus", visible = true },
  { id = "dev.rockorager.monstar.desktop", name = "Monstar", generic_name = "Terminal", icon = "utilities-terminal", exec = "monstar", visible = true },
  { id = "org.mozilla.firefox.desktop", name = "Firefox", generic_name = "Web browser", icon = "web-browser", exec = "firefox", visible = true },
  { id = "org.gnome.Settings.desktop", name = "Settings", icon = "org.gnome.Settings", exec = "gnome-control-center", visible = true },
} }:actor { id = "catalog" }

local ui = shell.chart { launcher = launcher.chart { execute = function(entry)
  if entry.id == "caffeine" then fixture:send("TOGGLE_CAFFEINE"); return end
  if entry.id == "lock" then error("Preview only — no lock was requested", 0) end
  error("Preview only — no command was executed", 0)
end } }:actor { id = "shell" }

local scheme_actor = appearance.chart(appearance.services):actor { id = "appearance" }

local audio = volume.chart {
  -- A callback invoke: it stays active, and its cleanup has nothing to close.
  follow = function(_, send)
    send { type = "OUTPUT", output = { available = true, identity = "preview", description = "Preview speakers",
      volume = 0.42, muted = false } }
    return function() end
  end,
  adjust = function() end,
}:actor { id = "volume" }

local function scheme() return scheme_actor:context().scheme end

local function launcher_props()
  return {
    launcher = ui:child("launcher"), shell = ui, scheme = scheme(), current = launcher_props,
    entries = applications:context().entries, catalog_phase = "ready",
    caffeinated = fixture:context().caffeinated,
  }
end

local function workspace_content()
  return bar.content {
    workspaces = desks, time = time, scheme = scheme(),
    open_launcher = ui:event("TOGGLE_LAUNCHER"), volume = audio,
    power = { percentage = 67, icon = "battery-good-charging-symbolic", charging = true, low = false },
    connectivity = network.snapshot({ { Name = "wlan0", Type = "wlan", OperationalState = "routable" } },
      { wlan0 = { name = "Preview Wi-Fi", level = 0, rssi = -48 } }),
  }
end

return ouro.app {
  id = "dev.ouro.shell.preview",
  run = function()
    for _, actor in ipairs({ fixture, desks, applications, scheme_actor, audio, ui }) do actor:start() end
    ui:send("TOGGLE_LAUNCHER")
    local panel = ouro.layer_surface {
      id = "panel", namespace = "ouroshell-preview", layer = "top",
      width = 0, height = bar.height, anchors = { "top", "left", "right" },
      exclusive_zone = bar.height, keyboard_interactivity = "none", content = workspace_content,
    }
    return { send = ui, windows = function()
      local windows = { panel }
      if ui:matches("launcher") then
        windows[#windows + 1] = ouro.layer_surface {
          id = "launcher", namespace = "ouroshell-preview-launcher", layer = "overlay",
          width = 0, height = 0, anchors = { "top", "bottom", "left", "right" },
          background = overlay.background(), background_effect = "blur", keyboard_interactivity = "exclusive",
          send = ui, content = function(width, height)
            if not ui:child("launcher") then return nil end
            return launcher.content(launcher_props(), height, width)
          end,
        }
      end
      return windows
    end }
  end,
}
