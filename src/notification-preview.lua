local ouro = require("ouro")
local center = require("notification_center")
local appearance = require("appearance")
local overlay = require("overlay")
local state = center.new()
local popup = ouro.signal(nil)
local message = ouro.signal("Nothing here changes your real notifications.")
local expires = 0

-- Fixtures use the daemon's item shape: one action list per notification.
local function action(label) return { { key = "preview", label = label } } end

local function reset()
  state.clear()
  state.collapsed:set({ Files = true, CI = true })
  state.add { app = "CI", image = { name = "utilities-terminal-symbolic" }, title = "Build failed",
    body = "ouro / main — 2 tests need attention.", actions = action("View logs"), urgent = true }
  state.add { app = "Files", image = { name = "folder-symbolic" }, title = "Upload complete",
    body = "design-assets.zip is ready to share.", actions = action("Open folder") }
  state.add { app = "Messages", image = { name = "user-available-symbolic" }, title = "Taylor",
    body = "Pushed the latest changes. Take a look when you have a minute.", actions = {} }
  state.add { app = "Messages", image = { name = "user-available-symbolic" }, title = "Alex",
    body = "Coffee after the build?", actions = action("Open") }
  message:set("Nothing here changes your real notifications.")
end

local function activate(item, key)
  for _, entry in ipairs(item.actions) do
    if entry.key == key then
      popup:set(nil)
      message:set("Preview: “" .. entry.label .. "” from " .. item.app .. ". No app was opened.")
    end
  end
end

local function sample()
  local item = state.add { app = "Messages", image = { name = "user-available-symbolic" }, title = "Alex",
    body = "Found a table by the window. See you in five?", actions = action("Open") }
  if state.quiet() then
    message:set("Do Not Disturb: saved to history without a popup.")
    return
  end
  expires = ouro.time() + 6
  popup:set(item)
end

return ouro.app {
  id = "dev.ouro.notifications.preview",
  actions = {},
  run = function()
    appearance.connect()
    reset()
    -- Preview-only clock, owned by the app rather than the disappearing button.
    -- The real daemon's expiration tasks will belong to its D-Bus service scope.
    ouro.spawn(function()
      while true do
        ouro.sleep(250)
        if popup() and ouro.time() >= expires then
          popup:set(nil)
          message:set("The popup expired; its notification is still in history.")
        end
      end
    end)
    return { windows = function()
      if popup() then
        local item = popup()
        return { ouro.layer_surface {
          id = "popup", namespace = "ouroshell-notification-preview-popup", layer = "overlay",
          width = 420, height = 160, anchors = { "top", "right" },
          margins = { top = 56, right = 16 }, exclusive_zone = -1, keyboard_interactivity = "none",
          background = ouro.tokens.palette.transparent,
          content = function() return center.popup(item, {
            dismiss = function() state.remove(item.id); popup:set(nil) end,
            activate = function(key) activate(item, key) end,
          }) end,
        } }
      end
      -- Leave the shell bar's 40px uncovered, as the shell's center does.
      return { ouro.layer_surface {
        id = "center", namespace = "ouroshell-notification-preview", layer = "overlay",
        width = 0, height = 0, anchors = { "top", "bottom", "left", "right" },
        margins = { top = 40 }, exclusive_zone = 0,
        background = overlay.background(), background_effect = "blur",
        keyboard_interactivity = "on_demand",
        content = function(width, height) return center.overlay(center.content(state, {
          close = function() ouro.exit(0) end, sample = sample, reset = reset,
          clear = function() state.clear(); message:set("Preview history cleared.") end,
          dismiss = state.remove, activate = activate, message = message,
        }), width, height) end,
      } }
    end }
  end,
}
