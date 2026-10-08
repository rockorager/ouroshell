local ouro = require("ouro")
local machine = ouro.machine
local assign, unset = machine.assign, machine.unset
local appearance = require("appearance")
local center = require("notification_center")
local notifications = require("notifications")
local overlay = require("overlay")

-- An interactive fixture of the notification center. It never owns
-- org.freedesktop.Notifications or changes the live daemon.
local hint = "Nothing here changes your real notifications."

-- Fixtures use the daemon's item shape: one action list per notification.
local function action(label) return { { key = "preview", label = label } } end
local fixtures = {
  { app = "CI", image = { name = "utilities-terminal-symbolic" }, title = "Build failed",
    body = "ouro / main — 2 tests need attention.", actions = action("View logs"), urgent = true },
  { app = "Files", image = { name = "folder-symbolic" }, title = "Upload complete",
    body = "design-assets.zip is ready to share.", actions = action("Open folder") },
  { app = "Messages", image = { name = "user-available-symbolic" }, title = "Taylor",
    body = "Pushed the latest changes. Take a look when you have a minute.", actions = {} },
  { app = "Messages", image = { name = "user-available-symbolic" }, title = "Alex",
    body = "Coffee after the build?", actions = action("Open") },
}
local sample = { app = "Messages", image = { name = "user-available-symbolic" }, title = "Alex",
  body = "Found a table by the window. See you in five?", actions = action("Open") }

-- Adds copies of `added` (oldest first) to the front of `items`, newest first.
local function add(c, items, added)
  local next_id, serial, result = c.next_id, c.serial, {}
  for _, fields in ipairs(added) do
    next_id, serial = next_id + 1, serial + 1
    local item = {}
    for key, value in pairs(fields) do item[key] = value end
    item.id, item.revision = next_id, serial
    table.insert(result, 1, item)
  end
  for _, item in ipairs(items) do result[#result + 1] = item end
  return { items = result, next_id = next_id, serial = serial }
end

local preview = machine.create {
  id = "notification-preview", initial = "center",
  context = function()
    local fields = add({ next_id = 0, serial = 0 }, {}, fixtures)
    fields.quiet, fields.message, fields.collapsed = false, hint, { Files = true, CI = true }
    return fields
  end,
  events = {
    SAMPLE = {}, RESET = {}, CLEAR = {}, CLOSE = {},
    DISMISS = { id = "integer" }, QUIET = { value = "boolean" }, TOGGLE_GROUP = { app = "string" },
    ACTIVATE = { id = "integer", key = "string" }, HOLD = { id = "integer", active = "boolean" },
  },
  actors = { exit = function() ouro.exit(0) end },
  guards = {
    quiet = function(c) return c.quiet end,
    popup = function(c, e) return c.popup == e.id end,
  },
  actions = {
    reset = assign(function(c)
      local fields = add(c, {}, fixtures)
      fields.collapsed, fields.message = { Files = true, CI = true }, hint
      return fields
    end),
    sample = assign(function(c) return add(c, c.items, { sample }) end),
    show = assign { popup = function(c) return c.next_id end },
    hide = assign { popup = unset },
    held_back = assign { message = "Do Not Disturb: saved to history without a popup." },
    expired = assign { message = "The popup expired; its notification is still in history." },
    dismiss = assign { items = function(c, e)
      local items = {}
      for _, item in ipairs(c.items) do if item.id ~= e.id then items[#items + 1] = item end end
      return items
    end },
    clear = assign { items = {}, message = "Preview history cleared." },
    activated = assign { message = function(c, e)
      local item = notifications.get(c.items, e.id)
      for _, entry in ipairs(item and item.actions or {}) do
        if entry.key == e.key then return "Preview: “" .. entry.label .. "” from " .. item.app .. ". No app was opened." end
      end
      return c.message
    end },
    toggle_group = assign { collapsed = function(c, e)
      local collapsed = machine.plain(c.collapsed)
      collapsed[e.app] = not collapsed[e.app] or nil
      return collapsed
    end },
  },
  on = {
    RESET = { target = ".center", actions = "reset" },
    CLEAR = { target = ".center", actions = "clear" },
    DISMISS = { actions = "dismiss" },
    QUIET = machine.set("quiet", "boolean"),
    TOGGLE_GROUP = { actions = "toggle_group" },
    ACTIVATE = { target = ".center", actions = "activated" },
    CLOSE = ".exiting",
    HOLD = {},
    ["surface.*"] = {},
  },
  states = {
    center = { on = {
      SAMPLE = { { guard = "quiet", actions = { "sample", "held_back" } }, { target = "popup", actions = { "sample", "show" } } },
    } },
    -- Briefly replaces the panel; history keeps the notification.
    popup = { exit = "hide",
      after = { [6000] = { target = "center", actions = "expired" } },
      on = { DISMISS = { { target = "center", guard = "popup", actions = "dismiss" }, { actions = "dismiss" } } } },
    exiting = { invoke = { src = "exit" } },
  },
}:actor { id = "notification-preview" }

local scheme_actor = appearance.chart(appearance.services):actor { id = "appearance" }

local function activate(item, key) preview:send { type = "ACTIVATE", id = item.id, key = key } end

return ouro.app {
  id = "dev.ouro.notifications.preview",
  actions = {},
  run = function()
    scheme_actor:start()
    preview:start()
    return { send = preview, windows = function()
      local scheme = scheme_actor:context().scheme
      if preview:matches("popup") then
        local item = notifications.get(preview:context().items, preview:context().popup)
        if not item then return {} end
        return { ouro.layer_surface {
          id = "popup", namespace = "ouroshell-notification-preview-popup", layer = "overlay",
          width = 420, height = 160, anchors = { "top", "right" },
          margins = { top = 56, right = 16 }, exclusive_zone = -1, keyboard_interactivity = "none",
          background = ouro.tokens.palette.transparent, send = preview,
          content = function() return center.popup(item, { notices = preview, activate = activate, scheme = scheme }) end,
        } }
      end
      -- Leave the shell bar's 40px uncovered, as the shell's center does.
      return { ouro.layer_surface {
        id = "center", namespace = "ouroshell-notification-preview", layer = "overlay",
        width = 0, height = 0, anchors = { "top", "bottom", "left", "right" },
        margins = { top = 40 }, exclusive_zone = 0,
        background = overlay.background(), background_effect = "blur",
        keyboard_interactivity = "on_demand", send = preview,
        content = function(width, height) return center.overlay(center.content {
          notices = preview, ui = preview, close = preview:event("CLOSE"),
          sample = preview:event("SAMPLE"), reset = preview:event("RESET"),
          activate = activate, scheme = scheme_actor:context().scheme,
        }, width, height) end,
      } }
    end }
  end,
}
