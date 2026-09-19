local ouro = require("ouro")
local appearance = require("appearance")
local f = ouro.tokens.foundation
local M = {}

function M.new()
  local state = { items = ouro.signal({}), quiet = ouro.signal(false), collapsed = ouro.signal({}) }
  local next_id = 0
  function state.add(item, replaces)
    if not replaces then next_id = next_id + 1 end
    local copy = {}
    for key, value in pairs(item) do copy[key] = value end
    copy.id = replaces or next_id
    local items = { copy }
    for _, previous in ipairs(state.items()) do
      if previous.id ~= copy.id then items[#items + 1] = previous end
    end
    state.items:set(items)
    return copy
  end
  function state.dismiss(id)
    local items = {}
    for _, item in ipairs(state.items()) do
      if item.id ~= id then items[#items + 1] = item end
    end
    state.items:set(items)
  end
  function state.clear() state.items:set({}) end
  function state.toggle_group(app)
    local collapsed = {}
    for key, value in pairs(state.collapsed()) do collapsed[key] = value end
    collapsed[app] = not collapsed[app]
    state.collapsed:set(collapsed)
  end
  function state.groups()
    local groups, by_app = {}, {}
    for _, item in ipairs(state.items()) do
      local group = by_app[item.app]
      if not group then
        group = { app = item.app, items = {} }
        by_app[item.app] = group
        groups[#groups + 1] = group
      end
      group.items[#group.items + 1] = item
    end
    return groups
  end
  return state
end

local function icon(key, name, color, size)
  return ouro.xdg.icon { key = key, name = name, theme = "Adwaita", tint = color,
    width = size or f.spacing_4, height = size or f.spacing_4 }
end

local function icon_button(key, label, name, callback)
  local theme = appearance.colors()
  return ouro.button { key = key, label = label,
    background = ouro.tokens.palette.transparent, foreground = theme.muted_foreground,
    hover = theme.accent_hover, on_press = callback,
    children = { icon("icon", name, theme.muted_foreground) } }
end

local function notification_image(image)
  local props = { key = "notification-image", width = f.spacing_5, height = f.spacing_5,
    fit = "contain", alt = "Notification image" }
  if image.bytes then
    props.bytes = image.bytes
    return ouro.image(props)
  end
  props.name, props.theme = image.name, "Adwaita"
  return ouro.xdg.icon(props)
end

local function notification_surface(item, key, surface, radius, content, activate, interaction)
  local theme, palette = appearance.colors()
  local props = { key = key, radius = radius, on_interaction_change = interaction,
    border_width = f.border_width_default, border = item.urgent and palette.amber.step_7 or theme.border,
    children = { ouro.box { key = "inset", width = "fill", padding = f.spacing_3, children = { content } } },
  }
  if item.default_action then
    props.label, props.height, props.padding_x = "Open " .. item.app, "auto", 0
    props.background = theme[surface]
    props.hover, props.pressed, props.focus = props.background, props.background, theme.ring
    props.on_press = function() activate("default") end
    return ouro.button(props)
  end
  props.width, props.surface = "fill", surface
  return ouro.box(props)
end

local function card(item, dismiss, activate, actions, interaction)
  local theme = appearance.colors()
  local heading = {}
  if item.image then heading[#heading + 1] = notification_image(item.image) end
  heading[#heading + 1] = ouro.text { key = "title", text = item.title, size = f.typography_3, max_lines = 2, flex = 1 }
  heading[#heading + 1] = icon_button("dismiss", "Dismiss " .. item.title, "window-close-symbolic", dismiss)
  local children = {
    ouro.row { key = "heading", gap = f.spacing_2, cross_alignment = "center", children = heading },
  }
  if item.body ~= "" then
    children[#children + 1] = ouro.text { key = "body", text = item.body, size = f.typography_2,
      foreground = theme.muted_foreground, max_lines = 5 }
  end
  if actions then children[#children + 1] = actions end
  return notification_surface(item, "notification-" .. item.id, "card", f.radius_4,
    ouro.column { key = "content", gap = f.spacing_2, cross_alignment = "stretch", children = children }, activate, interaction)
end

function M.content(state, callbacks)
  local theme = appearance.colors()
  local rows = {}
  for _, group in ipairs(state.groups()) do
    rows[#rows + 1] = { key = "app-" .. group.app, group = group, collapsed = state.collapsed()[group.app] }
    if not state.collapsed()[group.app] then
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
          background = ouro.tokens.palette.transparent, hover = theme.accent_hover,
          on_press = function() state.toggle_group(group.app) end,
          children = { ouro.row { key = "heading", gap = f.spacing_2, cross_alignment = "center", children = heading } },
        }
      elseif row.item then
        local item = row.item
        content = M.card(item, function() state.dismiss(item.id) end,
          function(key) callbacks.activate(item, key) end)
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
            ouro.text { key = "subtitle", text = "This session · " .. #state.items() .. " notifications",
              foreground = theme.muted_foreground, size = f.typography_2 },
          } },
          icon_button("close", "Close notification center", "window-close-symbolic", callbacks.close),
        } },
        ouro.box { key = "quiet", surface = "card", padding = f.spacing_3, radius = f.radius_4, children = {
          ouro.row { key = "row", gap = f.spacing_3, cross_alignment = "center", children = {
            icon("quiet-icon", "notifications-disabled-symbolic", theme.muted_foreground),
            ouro.column { key = "description", gap = f.spacing_1, flex = 1, children = {
              ouro.text { key = "label", text = "Do Not Disturb", size = f.typography_2 },
              ouro.text { key = "detail", text = state.quiet() and "Popups paused. History stays here." or "Allow notification popups",
                foreground = theme.muted_foreground, size = f.typography_1, max_lines = 2 },
            } },
            ouro.switch { key = "toggle", label = "Do Not Disturb", checked = state.quiet(),
              on_change = function(value) state.quiet:set(value) end },
          } },
        } },
        history,
  }
  layout[#layout + 1] = ouro.row { key = "footer", cross_alignment = "center", children = {
          ouro.text { key = "note", text = callbacks.sample and "Preview · sample notifications" or "History kept for this session", size = f.typography_1,
            foreground = theme.muted_foreground, flex = 1 },
          ouro.button { key = "clear", label = "Clear all", enabled = #state.items() > 0, on_press = callbacks.clear },
  } }
  if callbacks.sample then
    layout[#layout + 1] = ouro.row { key = "preview-controls", gap = f.spacing_2, children = {
          ouro.button { key = "sample", label = "Try a popup", on_press = callbacks.sample },
          ouro.button { key = "reset", label = "Reset preview", on_press = callbacks.reset },
    } }
  end
  layout[#layout + 1] = ouro.box { key = "feedback-space", height = f.spacing_6, children = {
          ouro.text { key = "feedback", text = callbacks.message(), foreground = theme.muted_foreground,
            size = f.typography_1, max_lines = 2 },
  } }
  return ouro.box { key = "notification-center", width = "fill", height = "fill", surface = "sidebar",
    border_width = f.border_width_default, radius = f.radius_5, padding = f.spacing_4, children = {
      ouro.column { key = "layout", gap = f.spacing_4, cross_alignment = "stretch", children = layout },
    } }
end

local function popup(item, callbacks, actions, interaction)
  local theme = appearance.colors()
  local heading = {}
  if item.image then heading[#heading + 1] = notification_image(item.image) end
  heading[#heading + 1] = ouro.text { key = "name", text = item.app, size = f.typography_2,
    foreground = theme.muted_foreground, flex = 1, max_lines = 1 }
  heading[#heading + 1] = ouro.button { key = "dismiss", label = "Dismiss " .. item.title,
    width = f.spacing_5, height = f.spacing_5, padding_x = 0,
    background = ouro.tokens.palette.transparent, hover = theme.accent_hover, on_press = callbacks.dismiss,
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
  if actions then children[#children + 1] = actions end
  return notification_surface(item, "popup", "sidebar", f.radius_5,
    ouro.column { key = "layout", gap = f.spacing_2, cross_alignment = "stretch", children = children }, callbacks.activate, interaction)
end

local notification = ouro.component(function(props)
  local active, menu, invoking = ouro.signal(false), ouro.signal(nil), ouro.signal(nil)
  local function close_menu(open)
    if menu() == open then menu:set(nil) end
    if open and open.handle then open.handle:close() end
  end
  return function()
    local item, theme, activate = props.item, appearance.colors(), props.activate
    local open = menu()
    if open and open.item ~= item then
      -- Close queues on_close at a task safe point. Do not write a signal
      -- while reconciling a same-ID replacement's new props.
      if open.handle then open.handle:close() end
      open = nil
    end
    local actions = {}
    for index, action in ipairs(item.actions or (item.action and { { key = "action", label = item.action } } or {})) do
      if action.key ~= "default" then
        actions[#actions + 1] = { key = item.action and "action" or "action-" .. index, action = action }
      end
    end
    local controls
    if #actions > 0 then
      local children = { ouro.box { key = "spacer", flex = 1 } }
      if active() or open or invoking() == item then
        local function action_button(entry)
          local theme = appearance.colors()
          return ouro.button { key = entry.key, label = entry.action.label, height = f.spacing_6,
            background = ouro.tokens.palette.transparent, foreground = theme.foreground, hover = theme.accent_hover,
            border_width = f.border_width_default, border = ouro.tokens.palette.transparent, focus = theme.ring,
            on_press = function()
              if props.item ~= item or invoking() == item then return end
              -- Activation-token acquisition yields. Keep this callback's
              -- originating control mounted even if the native popup closes.
              local open = menu()
              invoking:set(item)
              activate(entry.action.key)
              invoking:set(nil)
              close_menu(open)
            end }
        end
        if #actions == 1 then
          children[#children + 1] = action_button(actions[1])
        else
          local trigger = ouro.box { key = "trigger", height = f.spacing_6, padding = f.spacing_1, children = {
            ouro.row { key = "label", gap = f.spacing_1, cross_alignment = "center", children = {
              ouro.text { key = "text", text = "Options", size = f.typography_2 },
              icon("disclosure", open and "pan-up-symbolic" or "pan-down-symbolic", theme.muted_foreground),
            } },
          } }
          children[#children + 1] = ouro.button { key = "options", label = open and "Close notification options" or "Notification options",
            height = f.spacing_6 + 2 * f.border_width_default, padding_x = 0, background = ouro.tokens.palette.transparent,
            hover = ouro.tokens.palette.transparent, pressed = ouro.tokens.palette.transparent,
            border_width = f.border_width_default, border = ouro.tokens.palette.transparent, focus = theme.ring,
            on_press = function()
              if invoking() == item then return end
              if menu() and menu().item == item then close_menu(menu()); return end
              local opened = { item = item }
              menu:set(opened)
              -- Open before yielding: Ourokit captures this button's bounds
              -- and input serial, not the notification's enclosing surface.
              opened.handle = ouro.popup {
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
                on_close = function() if menu() == opened then menu:set(nil) end end,
              }
              if not opened.handle then close_menu(opened) end
            end,
            children = { trigger },
          }
        end
      end
      -- Reserve the trigger's height so revealing it never shifts the message.
      controls = ouro.box { key = "actions", min_height = f.spacing_6 + 2 * f.border_width_default, width = "fill",
        children = { ouro.row { key = "controls", cross_alignment = "start", children = children } } }
    end
    local interaction = #actions > 0 and function(value) active:set(value) end or nil
    if props.popup then
      return popup(item, props, controls, interaction)
    end
    return card(item, props.dismiss, props.activate, controls, interaction)
  end
end)

function M.card(item, dismiss, activate)
  return notification { key = "notification-" .. item.id, item = item, dismiss = dismiss, activate = activate }
end

function M.popup(item, callbacks)
  return notification { key = "popup-" .. item.id, item = item, popup = true,
    dismiss = callbacks.dismiss, activate = callbacks.activate }
end

return M
