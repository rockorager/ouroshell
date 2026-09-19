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

local function notification_surface(item, key, surface, radius, content, activate)
  local theme, palette = appearance.colors()
  local props = { key = key, radius = radius,
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

function M.card(item, dismiss, activate)
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
  if item.action then
    children[#children + 1] = ouro.row { key = "actions", children = {
      ouro.button { key = "action", label = item.action, on_press = activate },
    } }
  end
  for index, action in ipairs(item.actions or {}) do
    if action.key ~= "default" then children[#children + 1] = ouro.row { key = "action-row-" .. index, children = {
      ouro.button { key = "action-" .. index, label = action.label,
        on_press = function() activate(action.key) end },
    } } end
  end
  return notification_surface(item, "notification-" .. item.id, "card", f.radius_4,
    ouro.column { key = "content", gap = f.spacing_2, cross_alignment = "stretch", children = children }, activate)
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

function M.popup(item, callbacks)
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
  local actions = item.actions or (item.action and { { key = "action", label = item.action } } or {})
  for index, action in ipairs(actions) do
    if action.key ~= "default" then children[#children + 1] = ouro.row { key = "action-row-" .. index, children = {
      ouro.button { key = item.action and "action" or "action-" .. index, label = action.label,
        background = ouro.tokens.palette.transparent, foreground = theme.foreground, hover = theme.accent_hover,
        on_press = function() callbacks.activate(action.key) end },
    } } end
  end
  return notification_surface(item, "popup", "sidebar", f.radius_5,
    ouro.column { key = "layout", gap = f.spacing_2, cross_alignment = "stretch", children = children }, callbacks.activate)
end

return M
