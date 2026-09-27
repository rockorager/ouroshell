local ouro = require("ouro")
local bar = require("bar")
local launcher = require("launcher")
local appearance = require("appearance")
local battery = require("battery")
local catalog = require("catalog")
local clock = require("clock")
local network = require("network")
local notifications = require("notifications")

-- These must outlive builds: windows() reads them reactively and never yields.
-- The launcher, notification center and notification popup are mutually
-- exclusive, so one overlay signal names whichever is showing.
local overlay = ouro.signal(nil)
local applications = catalog.new()
local notices = notifications.new { overlay = overlay, applications = applications.entries }
local launcher_state

local function launcher_open()
  local current = overlay()
  return current ~= nil and current.kind == "launcher"
end
local function dismiss_launcher()
  if launcher_open() then overlay:set(nil) end
end
local function toggle_launcher()
  if launcher_open() then
    overlay:set(nil)
  elseif launcher_state then
    launcher_state.open()
    overlay:set({ kind = "launcher" })
  end
  return {}
end

local function toggle_notifications()
  notices.toggle()
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
    ["notifications.toggle"] = {
      description = "Show or dismiss the notification center.",
      inputSchema = { type = "object", properties = {}, additionalProperties = false },
      outputSchema = { type = "object", properties = {}, additionalProperties = false },
      handler = toggle_notifications,
    },
  },
  run = function()
    appearance.connect()
    notifications.connect(notices)
    local power = battery.connect()
    local connectivity = network.connect()
    local workspaces = ouro.shell.workspaces.connect()
    local time = clock.connect()
    launcher_state = launcher.new { catalog = applications, dismiss = dismiss_launcher }
    applications.load()

    local panel = ouro.layer_surface {
        id = "panel",
        namespace = "ouroshell-panel",
        outputs = "all",
        layer = "top",
        width = 0,
        height = bar.height,
        anchors = { "top", "left", "right" },
        exclusive_zone = bar.height,
        keyboard_interactivity = "none",
        content = function(output)
          return bar.content {
            workspaces = workspaces(), time = time(), output = output,
            open_launcher = toggle_launcher, power = power(), connectivity = connectivity(),
            open_notifications = toggle_notifications, quiet = notices.store.quiet(),
          }
        end,
    }
    return { windows = function()
      local windows = { panel }
      if launcher_open() then
        windows[#windows + 1] = ouro.layer_surface {
          id = "launcher", namespace = "ouroshell-launcher", layer = "overlay",
          width = 0, height = 0, anchors = { "top", "bottom", "left", "right" }, exclusive_zone = 0,
          background = launcher.background(), background_effect = "blur",
          keyboard_interactivity = "exclusive",
          content = function(width, height) return launcher.content(launcher_state, height, width) end,
        }
      else
        local notification_window = notifications.window(notices)
        if notification_window then windows[#windows + 1] = notification_window end
      end
      return windows
    end }
  end,
}
