local ouro = require("ouro")
local appearance = require("appearance")
local config = require("config")
local overlay = require("overlay")
local f = ouro.tokens.foundation
local machine = ouro.machine
local notifications = require("notifications")
local M = {}

local function icon(key, name, color, size)
  return ouro.xdg.icon { key = key, name = name, theme = config.icon_theme, tint = color,
    width = size or f.spacing_4, height = size or f.spacing_4 }
end

local function icon_button(key, label, name, binding, scheme)
  local theme = appearance.colors(scheme)
  return ouro.button { key = key, label = label,
    background = ouro.tokens.palette.transparent, foreground = theme.muted_foreground,
    hover = theme.accent_hover, send = binding,
    children = { icon("icon", name, theme.muted_foreground) } }
end

local function notification_image(image)
  local props = { key = "notification-image", width = f.spacing_5, height = f.spacing_5,
    fit = "contain", alt = "Notification image" }
  if image.bytes then
    props.bytes = image.bytes
    return ouro.image(props)
  end
  props.name, props.theme = image.name, config.icon_theme
  return ouro.xdg.icon(props)
end

local function notification_surface(item, key, surface, radius, content, activate, interaction, scheme)
  local theme, palette = appearance.colors(scheme)
  local props = { key = key, radius = radius, on_interaction_change = interaction,
    border_width = f.border_width_default, border = item.urgent and palette.amber.step_7 or theme.border,
    children = { ouro.box { key = "inset", width = "fill", padding = f.spacing_3, children = { content } } },
  }
  if item.default_action and not item.expired then
    props.label, props.height, props.padding_x = "Open " .. item.app, "auto", 0
    -- Without an explicit foreground, the title and symbolic icons inherit
    -- the solid button's white label color.
    props.background, props.foreground = theme[surface], theme.foreground
    props.hover, props.pressed, props.focus = props.background, props.background, theme.ring
    props.on_press = function() activate("default") end
    return ouro.button(props)
  end
  props.width, props.surface = "fill", surface
  return ouro.box(props)
end

local function card(item, dismiss, activate, actions, interaction, scheme)
  local theme = appearance.colors(scheme)
  local heading = {}
  if item.image then heading[#heading + 1] = notification_image(item.image) end
  heading[#heading + 1] = ouro.text { key = "title", text = item.title, size = f.typography_3, max_lines = 2, flex = 1 }
  if actions then heading[#heading + 1] = actions end
  heading[#heading + 1] = icon_button("dismiss", "Dismiss " .. item.title, "window-close-symbolic", dismiss, scheme)
  local children = {
    ouro.row { key = "heading", gap = f.spacing_2, cross_alignment = "center", children = heading },
  }
  if item.body ~= "" then
    children[#children + 1] = ouro.text { key = "body", text = item.body, size = f.typography_2,
      foreground = theme.muted_foreground, max_lines = 5 }
  end
  return notification_surface(item, "notification-" .. item.id, "card", f.radius_4,
    ouro.column { key = "content", gap = f.spacing_2, cross_alignment = "stretch", children = children }, activate, interaction, scheme)
end

-- The center's panel.
--   props.notices: an actor whose context has `items`, `quiet` and `message`,
--     taking DISMISS {id}, CLEAR and QUIET {value}
--   props.ui: an actor whose context has `collapsed`, taking TOGGLE_GROUP {app}
--   props.close: the close binding
--   props.activate(item, key): runs in the pressing callback, which owns the
--     input provenance an activation token needs
--   props.sample, props.reset: preview-only bindings
--   props.scheme: "light" or "dark"
function M.content(props)
  local notices, ui, scheme = props.notices, props.ui, props.scheme
  local c = notices:context()
  local items, collapsed = c.items, ui:context().collapsed
  local theme = appearance.colors(scheme)
  local rows = {}
  for _, group in ipairs(notifications.groups(items)) do
    rows[#rows + 1] = { key = "app-" .. group.app, group = group, collapsed = collapsed[group.app] }
    if not collapsed[group.app] then
      for _, item in ipairs(group.items) do
        rows[#rows + 1] = { key = "notification-" .. item.id, item = item }
      end
    end
  end
  if #rows == 0 then rows[1] = { key = "empty" } end
  local history = ouro.virtual_list { key = "history", flex = 1,
    item_count = #rows, estimated_item_height = 128,
    item_key = function(index) return rows[index].key end,
    render_item = function(index)
      local row = rows[index]
      local content
      if row.group then
        local group = row.group
        local heading = {}
        heading[#heading + 1] = ouro.text { key = "app", text = group.app, size = f.typography_2, flex = 1 }
        heading[#heading + 1] = ouro.text { key = "count", text = tostring(#group.items), size = f.typography_1,
          foreground = theme.muted_foreground }
        heading[#heading + 1] = icon("disclosure", row.collapsed and "pan-end-symbolic" or "pan-down-symbolic", theme.muted_foreground)
        content = ouro.button { key = "group", label = (row.collapsed and "Expand " or "Collapse ") .. group.app,
          background = ouro.tokens.palette.transparent, foreground = theme.foreground, hover = theme.accent_hover,
          send = ui:event { type = "TOGGLE_GROUP", app = group.app },
          children = { ouro.row { key = "heading", gap = f.spacing_2, cross_alignment = "center", children = heading } },
        }
      elseif row.item then
        local item = row.item
        content = M.card(item, { notices = notices, activate = props.activate, scheme = scheme })
      else
        return ouro.box { key = "empty", width = "fill", padding = f.spacing_6, children = {
          ouro.column { key = "message", gap = f.spacing_3, cross_alignment = "center", children = {
            icon("bell", "preferences-system-notifications-symbolic", theme.muted_foreground, f.spacing_6),
            ouro.text { key = "title", text = "All caught up", size = f.typography_4 },
            ouro.text { key = "description", text = "New notifications will appear here.",
              size = f.typography_2, foreground = theme.muted_foreground },
          } },
        } }
      end
      return ouro.column { key = row.key, gap = f.spacing_2, cross_alignment = "stretch", children = {
        content, ouro.box { key = "spacing", height = 0 },
      } }
    end,
  }
  local layout = {
        ouro.row { key = "header", cross_alignment = "center", gap = f.spacing_3, children = {
          ouro.column { key = "heading", flex = 1, gap = f.spacing_1, children = {
            ouro.text { key = "title", text = "Notifications", size = f.typography_5 },
            ouro.text { key = "subtitle", text = "This session · " .. #items .. (#items == 1 and " notification" or " notifications"),
              foreground = theme.muted_foreground, size = f.typography_2 },
          } },
          icon_button("close", "Close notification center", "window-close-symbolic", props.close, scheme),
        } },
        ouro.box { key = "quiet", surface = "card", padding = f.spacing_3, radius = f.radius_4, children = {
          ouro.row { key = "row", gap = f.spacing_3, cross_alignment = "center", children = {
            icon("quiet-icon", "notifications-disabled-symbolic", theme.muted_foreground),
            ouro.column { key = "description", gap = f.spacing_1, flex = 1, children = {
              ouro.text { key = "label", text = "Do Not Disturb", size = f.typography_2 },
              ouro.text { key = "detail", text = c.quiet and "Popups paused. History stays here." or "Allow notification popups",
                foreground = theme.muted_foreground, size = f.typography_1, max_lines = 2 },
            } },
            ouro.switch { key = "toggle", label = "Do Not Disturb", checked = c.quiet, send = notices:event("QUIET") },
          } },
        } },
        history,
  }
  layout[#layout + 1] = ouro.row { key = "footer", cross_alignment = "center", children = {
          ouro.text { key = "note", text = props.sample and "Preview · sample notifications" or "History kept for this session", size = f.typography_1,
            foreground = theme.muted_foreground, flex = 1 },
          ouro.button { key = "clear", label = "Clear all", send = notices:event("CLEAR") },
  } }
  if props.sample then
    layout[#layout + 1] = ouro.row { key = "preview-controls", gap = f.spacing_2, children = {
          ouro.button { key = "sample", label = "Try a popup", send = props.sample },
          ouro.button { key = "reset", label = "Reset preview", send = props.reset },
    } }
  end
  -- The space stays reserved; empty text nodes have no semantic label.
  local feedback = c.message
  layout[#layout + 1] = ouro.box { key = "feedback-space", height = f.spacing_6, children = {
          feedback and feedback ~= "" and ouro.text { key = "feedback", text = feedback,
            foreground = theme.muted_foreground, size = f.typography_1, max_lines = 2 } or nil,
  } }
  return ouro.box { key = "notification-center", width = "fill", height = "fill", surface = "sidebar",
    on_key = { keys = { "Escape" }, states = { "pressed" }, propagate = false, handler = props.close },
    on_pointer_down_outside = { propagate = false, handler = props.close },
    border_width = f.border_width_default, radius = f.radius_5, padding = f.spacing_4, children = {
      ouro.column { key = "layout", gap = f.spacing_4, cross_alignment = "stretch", children = layout },
    } }
end

-- Place the panel from M.content on a full-screen layer, like the launcher:
-- at the right edge with a drop shadow, over the window's blurred backdrop.
function M.overlay(panel, width, height)
  width, height = width or 1280, height or 760
  local margin = f.spacing_4
  local panel_width = math.min(420, width - 2 * margin)
  local panel_height = math.max(0, height - 2 * margin)
  -- The shadow image spans the full height, from the shadow's left reach to
  -- the right edge of the screen.
  local shadow_width = math.min(overlay.shadow_reach + panel_width + margin, width)
  local shadow = overlay.shadow(shadow_width, height, shadow_width - margin - panel_width, margin,
    panel_width, panel_height, f.radius_5)
  return ouro.stack { key = "notification-overlay", children = {
    ouro.box { key = "shadow-position", width = "fill", height = "fill", alignment = "right", children = {
      ouro.image { key = "shadow", bytes = shadow, width = shadow_width, height = height, fit = "fill", alt = "" },
    } },
    ouro.box { key = "position", width = "fill", height = "fill", padding = margin, alignment = "right", children = {
      ouro.box { key = "panel", width = panel_width, height = panel_height, children = { panel } },
    } },
  } }
end

local function popup(item, props, actions, interaction)
  local theme = appearance.colors(props.scheme)
  local heading = {}
  if item.image then heading[#heading + 1] = notification_image(item.image) end
  heading[#heading + 1] = ouro.text { key = "name", text = item.app, size = f.typography_2,
    foreground = theme.muted_foreground, flex = 1, max_lines = 1 }
  if actions then heading[#heading + 1] = actions end
  heading[#heading + 1] = ouro.button { key = "dismiss", label = "Dismiss " .. item.title,
    width = f.spacing_5, height = f.spacing_5, padding_x = 0,
    background = ouro.tokens.palette.transparent, hover = theme.accent_hover,
    send = props.notices:event { type = "DISMISS", id = item.id },
    children = { icon("icon", "window-close-symbolic", theme.muted_foreground) } }
  local message = { ouro.text { key = "title", text = item.title, size = f.typography_3, max_lines = 2 } }
  if item.body ~= "" then message[#message + 1] = ouro.text {
    key = "body", text = item.body, size = f.typography_2, foreground = theme.muted_foreground, max_lines = 2,
  } end
  local content = ouro.column { key = "message", gap = f.spacing_2, cross_alignment = "stretch", children = message }
  local children = {
    ouro.row { key = "app", gap = f.spacing_2, cross_alignment = "center", children = heading },
    content,
  }
  return notification_surface(item, "popup", "sidebar", f.radius_5,
    ouro.column { key = "layout", gap = f.spacing_2, cross_alignment = "stretch", children = children },
    function(key) props.activate(item, key) end, interaction, props.scheme)
end

-- Per-card presentation: hover or focus reveals the actions, an Options menu
-- may be open, and an activation may be acquiring its token.
local card_chart = machine.create {
  id = "notification-card", type = "parallel", order = { "menu", "activation" },
  context = { active = false },
  events = { ACTIVE = { value = "boolean" }, OPENED = { handle = "any", revision = "integer" },
    CLOSED = { handle = "any" }, INVOKE = {}, INVOKED = {} },
  guards = { current = function(c, e) return e.handle == nil or c.menu == e.handle end },
  on = { ACTIVE = machine.set("active", "boolean") },
  states = {
    menu = { initial = "closed", states = {
      closed = { on = { OPENED = { target = "open", actions = machine.assign(function(_, e)
        return { menu = e.handle, menu_revision = e.revision } end) } } },
      open = { exit = machine.assign { menu = machine.unset, menu_revision = machine.unset },
        on = { CLOSED = { target = "closed", guard = "current" } } },
    } },
    activation = { initial = "idle", states = {
      idle = { on = { INVOKE = "invoking" } },
      invoking = { on = { INVOKED = "idle" } },
    } },
  },
}

-- props.item, props.notices, props.activate(item, key), props.scheme;
-- props.popup marks the banner, whose hover holds its expiry.
local notification = machine.component(card_chart, function(self, props)
  local item, theme = props.item, appearance.colors(props.scheme)
  local c = self:context()
  local open = self:matches("menu.open")
  if open and c.menu_revision ~= item.revision then
    -- The notification was replaced or expired under its menu. Closing only
    -- queues on_close at a task safe point; the chart hears CLOSED then.
    c.menu:close()
    open = false
  end
  local invoking = self:matches("activation.invoking")
  local actions = {}
  for index, action in ipairs(not item.expired and item.actions or {}) do
    if action.key ~= "default" then
      actions[#actions + 1] = { key = "action-" .. index, action = action }
    end
  end
  local controls
  if #actions > 0 then
    local children = {}
    if c.active or open or invoking then
      local function action_button(entry)
        return ouro.button { key = entry.key, label = entry.action.label,
          width = #actions == 1 and 112 or nil, height = #actions == 1 and f.spacing_5 or f.spacing_6,
          children = { ouro.text { key = "label", text = entry.action.label, size = f.typography_2, max_lines = 1 } },
          background = ouro.tokens.palette.transparent, foreground = theme.foreground, hover = theme.accent_hover,
          border_width = f.border_width_default, border = ouro.tokens.palette.transparent, focus = theme.ring,
          -- A callback, not a binding: the activation token needs this
          -- press's provenance, which spawned tasks do not inherit.
          on_press = function()
            if props.item ~= item or self:matches("activation.invoking") then return end
            local menu = self:context().menu
            self:send("INVOKE")
            props.activate(item, entry.action.key)
            self:send("INVOKED")
            if menu then menu:close() end
          end }
      end
      if #actions == 1 then
        children[#children + 1] = action_button(actions[1])
      else
        local trigger = ouro.box { key = "trigger", children = {
          ouro.row { key = "label", gap = f.spacing_1, cross_alignment = "center", children = {
            ouro.text { key = "text", text = "Options", size = f.typography_2 },
            icon("disclosure", open and "pan-up-symbolic" or "pan-down-symbolic", theme.muted_foreground),
          } },
        } }
        children[#children + 1] = ouro.button { key = "options", label = open and "Close notification options" or "Notification options",
          width = 112, height = f.spacing_5, padding_x = f.spacing_1, background = ouro.tokens.palette.transparent,
          hover = ouro.tokens.palette.transparent, pressed = ouro.tokens.palette.transparent,
          border_width = f.border_width_default, border = ouro.tokens.palette.transparent, focus = theme.ring,
          -- ouro.popup must run synchronously in the press callback: Ourokit
          -- captures this button's bounds and input serial.
          on_press = function()
            if self:matches("activation.invoking") then return end
            local menu = self:context().menu
            if menu then
              menu:close()
              self:send { type = "CLOSED", handle = menu }
              return
            end
            local handle
            handle = ouro.popup {
              width = 240, height = math.ceil(#actions * f.spacing_6 + 2 * (f.spacing_1 + f.border_width_default)),
              content = function()
                local buttons = {}
                for _, entry in ipairs(actions) do buttons[#buttons + 1] = action_button(entry) end
                return ouro.box { key = "menu", surface = "popover", radius = f.radius_2,
                  width = "fill", height = "fill", padding = f.spacing_1,
                  border_width = f.border_width_default, children = {
                    ouro.column { key = "items", gap = 0, cross_alignment = "stretch", children = buttons },
                  } }
              end,
              on_close = function() self:send { type = "CLOSED", handle = handle } end,
            }
            if handle then self:send { type = "OPENED", handle = handle, revision = item.revision } end
          end,
          children = { trigger },
        }
      end
    end
    -- Reserve horizontal header space, not a footer. Hover and keyboard
    -- reveal must not rewrap the heading or change the card's height.
    controls = ouro.box { key = "actions", width = 112, height = f.spacing_5, children = children }
  end
  if props.popup then
    -- Pointer or focus within a banner holds its expiry.
    return popup(item, props, controls,
      { self:event("ACTIVE"), props.notices:event({ type = "HOLD", id = item.id }, "active") })
  end
  return card(item, props.notices:event { type = "DISMISS", id = item.id },
    function(key) props.activate(item, key) end, controls,
    #actions > 0 and self:event("ACTIVE") or nil, props.scheme)
end)

-- options.notices, options.activate(item, key), options.scheme
function M.card(item, options)
  return notification { key = "notification-" .. item.id, item = item, notices = options.notices,
    activate = options.activate, scheme = options.scheme }
end

function M.popup(item, options)
  return notification { key = "popup-" .. item.id, item = item, popup = true, notices = options.notices,
    activate = options.activate, scheme = options.scheme }
end

return M
