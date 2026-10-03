local ouro = require("ouro")
local bar = require("bar")
local launcher = require("launcher")
local appearance = require("appearance")
local battery = require("battery")
local catalog = require("catalog")
local clock = require("clock")
local idle = require("idle")
local lock = require("lock")
local network = require("network")
local notifications = require("notifications")
local volume = require("volume")

-- These must outlive builds: windows() reads them reactively and never yields.
-- The launcher, notification center and notification popup are mutually
-- exclusive, so one overlay signal names whichever is showing.
local overlay = ouro.signal(nil)
local applications = catalog.new()
local notices = notifications.new { overlay = overlay, applications = applications.entries }
local launcher_state
local audio

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

local function adjust_volume(delta)
  assert(audio, "Audio is not ready")
  local ok, failure = audio.adjust(delta)
  assert(ok, failure)
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
    ["volume.up"] = {
      description = "Raise the default output volume by five percentage points and show its level.",
      inputSchema = { type = "object", properties = {}, additionalProperties = false },
      outputSchema = { type = "object", properties = {}, additionalProperties = false },
      handler = function() return adjust_volume(0.05) end,
    },
    ["volume.down"] = {
      description = "Lower the default output volume by five percentage points and show its level.",
      inputSchema = { type = "object", properties = {}, additionalProperties = false },
      outputSchema = { type = "object", properties = {}, additionalProperties = false },
      handler = function() return adjust_volume(-0.05) end,
    },
  },
  run = function()
    appearance.connect()
    notifications.connect(notices)
    local power = battery.connect()
    local connectivity = network.connect()
    audio = volume.connect()
    local workspaces = ouro.shell.workspaces.connect()
    local time = clock.connect()
    local session = idle.connect { dismiss = function() overlay:set(nil) end }
    launcher_state = launcher.new { catalog = applications, dismiss = dismiss_launcher, idle = session }
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
            audio = audio,
            open_notifications = toggle_notifications, quiet = notices.store.quiet(),
            unread = notices.store.unread(), caffeinated = session.caffeinated(),
            decaffeinate = function()
              -- Idle timers belong to the application, not this button's scope.
              ouro.spawn_app(function() if session.caffeinated() then session.toggle() end end)
            end,
          }
        end,
    }
    return { windows = function()
      local lock_window = lock.window(session.locker, time)
      if lock_window then return { lock_window } end
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
