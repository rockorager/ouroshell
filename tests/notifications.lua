package.path = "src/?.lua;" .. package.path
local tasks, exited, now = {}, nil, 100
local ouro = { tokens = {
  foundation = setmetatable({}, { __index = function() return 16 end }),
  palette = { transparent = "transparent" },
}, xdg = {} }
ouro.signal = function(value)
  return setmetatable({ set = function(_, next_value) value = next_value end }, { __call = function() return value end })
end
for _, name in ipairs({ "app", "layer_surface", "row", "column", "box", "scroll", "virtual_list", "text", "button", "switch", "image" }) do
  ouro[name] = function(props) return props end
end
ouro.xdg.icon = function(props) return props end
ouro.spawn = function(fn) tasks[#tasks + 1] = coroutine.create(fn) end
ouro.sleep = function(ms) assert(ms == 250); coroutine.yield() end
ouro.time = function() return now end
ouro.exit = function(code) exited = code end
package.loaded.ouro = ouro
package.loaded.appearance = { connect = function() end, colors = function()
  return { sidebar = "sidebar", card = "card", ring = "focus", accent_hover = "hover" }, { amber = { step_7 = "amber" } }
end }

local center = require("notification_center")
local state = center.new()
local fixture = { app = "Files", title = "One", body = "Body" }
local first = state.add(fixture)
state.add { app = "Messages", title = "Two" }
local last = state.add { app = "Files", title = "Three" }
assert(fixture.id == nil and first.id ~= last.id)
local groups = state.groups()
assert(#groups == 2 and groups[1].app == "Files" and groups[2].app == "Messages")
assert(groups[1].items[1].title == "Three" and groups[1].items[2].title == "One")
state.toggle_group("Files")
state.toggle_group("Messages")
state.toggle_group("Files")
assert(not state.collapsed().Files and state.collapsed().Messages)
state.dismiss(last.id)
assert(state.groups()[1].app == "Messages", "group order must follow its newest remaining notification")
assert(#state.items() == 2 and state.items()[2].title == "One")
state.quiet:set(true)
state.clear()
assert(#state.items() == 0 and #state.groups() == 0 and state.quiet(), "clearing history must not disable DND")

local function find(tree, key)
  if tree.key == key then return tree end
  for _, child in ipairs(tree.children or {}) do
    local found = find(child, key)
    if found then return found end
  end
  if tree.render_item then
    for index = 1, tree.item_count do
      local found = find(tree.render_item(index), key)
      if found then return found end
    end
  end
end
local activated, dismissed
local popup_item = { id = 42, app = "Slack", image = { name = "slack" }, title = "Alex", body = "A message",
  default_action = true, urgent = true, actions = { { key = "default", label = "Open" }, { key = "reply", label = "Reply" } } }
local popup = center.popup(popup_item, {
  dismiss = function() dismissed = true end, activate = function(key) activated = key end,
})
local function surfaces(tree)
  local count = (tree.surface or (tree.background and tree.background ~= "transparent")) and 1 or 0
  for _, child in ipairs(tree.children or {}) do count = count + surfaces(child) end
  return count
end
assert(surfaces(popup) == 1 and popup.border == "amber", "popup must have one surface and retain urgent styling")
assert(not find(popup, "time") and not find(popup, "notification-42"), "popup must not wrap a history card")
assert(find(popup, "notification-image").name == "slack" and find(popup, "notification-image").tint == nil,
  "app icons must keep their original colors")
assert(find(popup, "body").max_lines == 2)
assert(not find(popup, "action-1"), "default action must not create an extra button")
assert(not find(popup, "open") and popup.height == "auto", "the outer surface must own the default action")
assert(popup.background == "sidebar" and popup.hover == popup.background and popup.pressed == popup.background)
assert(popup.focus == "focus" and popup.border_width > 0, "keyboard focus must remain visible")
popup.on_press()
assert(activated == "default" and not dismissed)
find(popup, "action-2").on_press()
assert(activated == "reply")
find(popup, "dismiss").on_press()
assert(dismissed and activated == "reply", "dismiss must not invoke the default action")
local card = center.card(popup_item, function() dismissed = true end, function(key) activated = key end)
assert(card.height == "auto" and card.background == "card" and card.hover == card.background and card.pressed == card.background)
assert(card.focus == "focus" and not find(card, "open"))
card.on_press()
assert(activated == "default")
find(card, "action-2").on_press()
assert(activated == "reply")
popup_item.image = { bytes = "notification-png" }
popup = center.popup(popup_item, {})
assert(not find(popup, "app-icon") and not find(popup, "illustrated-message"), "must render only one image slot")
assert(find(popup, "notification-image").bytes == "notification-png")
assert(find(popup, "notification-image").fit == "contain" and find(popup, "notification-image").tint == nil)
assert(find(popup, "app").children[1].key == "notification-image", "selected image belongs in the header")
assert(find(center.card(popup_item), "notification-image").bytes == "notification-png")
popup_item.image = { name = "mail-unread" }
assert(find(center.popup(popup_item, {}), "notification-image").name == "mail-unread")
popup_item.image = nil
popup_item.body, popup_item.default_action, popup_item.actions = "", false, {}
popup = center.popup(popup_item, {})
assert(not find(popup, "notification-image") and not find(popup, "body") and not find(popup, "open"))
assert(popup.on_press == nil and popup.surface == "sidebar", "non-actionable notifications must not be click targets")
assert(center.card(popup_item).on_press == nil, "expired history must not be a click target")
assert(find(popup, "app").children[1].key == "name", "no icon must leave no placeholder slot")
local image_history = center.new()
image_history.add { app = "Chrome", title = "First", body = "", image = { bytes = "site-one" } }
image_history.add { app = "Chrome", title = "Second", body = "", image = { bytes = "site-two" } }
local image_rows = find(center.content(image_history, { message = function() return "" end }), "history")
assert(not find(image_rows.render_item(1), "notification-image"), "group must not inherit a notification's image")
assert(find(image_rows.render_item(2), "notification-image").bytes == "site-two")
assert(find(image_rows.render_item(3), "notification-image").bytes == "site-one",
  "each notification must retain its own image within an application group")
local app = dofile("src/notification-preview.lua")
local running = app.run()
assert(coroutine.resume(tasks[1]))
local function window() return running.windows()[1] end
local function view() return window().content() end
assert(window().width == 420 and window().keyboard_interactivity == "on_demand")
assert(find(view(), "subtitle").text == "This session · 4 notifications")
local message_group = find(view(), "app-Messages")
assert(find(view(), "history").item_count == 5, "three headers plus two expanded messages")
find(message_group, "group").on_press()
assert(find(view(), "history").item_count == 3, "collapse must remove message rows, not the header")
find(find(view(), "app-Messages"), "group").on_press()
assert(find(view(), "history").item_count == 5)
find(view(), "action").on_press()
assert(find(view(), "feedback").text:find("No app was opened.", 1, true))
find(view(), "dismiss").on_press()
assert(find(view(), "subtitle").text == "This session · 3 notifications")

assert(find(view(), "toggle").label == "Do Not Disturb" and not find(view(), "toggle").checked)
find(view(), "toggle").on_change(true)
assert(find(view(), "toggle").checked)
find(view(), "toggle").on_change(true)
assert(find(view(), "toggle").checked, "use the requested value rather than inverting state")
find(view(), "sample").on_press()
assert(window().id == "center" and #tasks == 1, "DND must suppress the popup")
assert(find(view(), "subtitle").text == "This session · 4 notifications", "DND still saves history")
find(view(), "toggle").on_change(false)
assert(not find(view(), "toggle").checked)
find(view(), "sample").on_press()
assert(window().id == "popup" and window().keyboard_interactivity == "none")
assert(coroutine.resume(tasks[1]))
find(view(), "dismiss").on_press()
assert(window().id == "center" and find(view(), "subtitle").text == "This session · 4 notifications")
now = 103
find(view(), "sample").on_press()
assert(window().id == "popup")
now = 106
assert(coroutine.resume(tasks[1]))
assert(window().id == "popup", "the old deadline must not dismiss a newer popup")
now = 108
assert(coroutine.resume(tasks[1]))
assert(window().id == "popup", "popup expired before its deadline")
now = 109
assert(coroutine.resume(tasks[1]))
assert(window().id == "center" and find(view(), "subtitle").text == "This session · 5 notifications")
find(view(), "clear").on_press()
assert(find(view(), "empty") and not find(view(), "clear").enabled)
find(view(), "reset").on_press()
assert(find(view(), "subtitle").text == "This session · 4 notifications")
find(view(), "close").on_press()
assert(exited == 0)

local history_state = center.new()
for index = 1, 100 do
  history_state.add { app = index % 2 == 0 and "Files" or "Chat", title = "Item " .. index, body = "Body" }
end
local callbacks = { message = function() return "" end }
local history_tree = center.content(history_state, callbacks)
local history = find(history_tree, "history")
assert(history.item_count == 102 and history.estimated_item_height > 0 and history.item_height == nil,
  "history must virtualize individual variable-height messages, not pages or whole groups")
assert(not find(history_tree, "pages") and not find(history_tree, "older") and not find(history_tree, "newer"))
local keys = {}
for index = 1, history.item_count do
  local key = history.item_key(index)
  assert(not keys[key], "virtual row keys must be unique")
  keys[key] = true
end
assert(history.item_key(1) == "app-Files" and history.item_key(2) == "notification-100")
assert(history.item_key(52) == "app-Chat" and history.item_key(102) == "notification-1",
  "history must include the oldest notification, beyond the old five-item limit")
history_state.add({ app = "Files", title = "Replacement", body = "New body" }, 2)
history = find(center.content(history_state, callbacks), "history")
assert(history.item_count == 102 and history.item_key(2) == "notification-2", "replacement must retain its row key")
history_state.toggle_group("Files")
history = find(center.content(history_state, callbacks), "history")
assert(history.item_count == 52 and find(history.render_item(1), "count").text == "50")
history_state.add { app = "Chat", title = "Newest", body = "Body" }
history = find(center.content(history_state, callbacks), "history")
assert(history.item_key(1) == "app-Chat" and history.item_key(2) == "notification-101")
for index = 3, history.item_count do assert(keys[history.item_key(index)], "prepending changed an existing row key") end
history_state.dismiss(1)
history = find(center.content(history_state, callbacks), "history")
for index = 1, history.item_count do assert(history.item_key(index) ~= "notification-1") end
history_state.clear()
history = find(center.content(history_state, callbacks), "history")
assert(history.item_count == 1 and history.item_key(1) == "empty")
print("PASS: notification preview grouping, actions, dismissal, DND, expiry boundaries, and reset")
