package.path = "src/?.lua;" .. package.path
local tasks, exited, now = {}, nil, 100
local building, deferred = false, {}
local ouro = { tokens = {
  foundation = setmetatable({}, { __index = function() return 16.0 end }),
  palette = { transparent = "transparent" },
}, xdg = {} }
ouro.signal = function(value)
  return setmetatable({ set = function(_, next_value)
    assert(not building, "signals cannot be written during a build transaction")
    value = next_value
  end }, { __call = function() return value end })
end
ouro.component = function(initialize)
  local mounts = {}
  return function(props)
    local mount = mounts[props.key]
    if not mount then
      local render = initialize(props)
      mount = { props = props, render = function()
        building = true
        local result = render()
        building = false
        local callbacks = deferred
        deferred = {}
        for _, callback in ipairs(callbacks) do callback() end
        return result
      end }
      mounts[props.key] = mount
    else
      for key in pairs(mount.props) do mount.props[key] = nil end
      for key, value in pairs(props) do mount.props[key] = value end
    end
    local result = mount.render()
    result._render = mount.render
    return result
  end
end
for _, name in ipairs({ "app", "layer_surface", "row", "column", "box", "scroll", "virtual_list", "text", "button", "switch", "image" }) do
  ouro[name] = function(props) return props end
end
ouro.xdg.icon = function(props) return props end
ouro.spawn = function(fn) tasks[#tasks + 1] = coroutine.create(fn) end
ouro.sleep = function(ms) assert(ms == 250); coroutine.yield() end
ouro.time = function() return now end
ouro.exit = function(code) exited = code end
local native_menu, fail_popup
ouro.popup = function(props)
  assert(math.type(props.width) == "integer" and math.type(props.height) == "integer", "native popup dimensions must be integers")
  if fail_popup then return nil, { name = "Unavailable" } end
  local handle = { content = props.content, width = props.width, height = props.height }
  function handle:close()
    if self.closed then return end
    self.closed = true
    if building then deferred[#deferred + 1] = props.on_close else props.on_close() end
  end
  native_menu = handle
  return handle
end
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
  if tree._render then tree = tree._render() end
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
assert(not find(popup, "action-2"), "actions must not be mounted before hover or focus")
popup.on_interaction_change(true)
find(popup, "action-2").on_press()
assert(activated == "reply")
popup.on_interaction_change(false)
assert(not find(popup, "action-2"), "leaving the notification must hide its action")
find(popup, "dismiss").on_press()
assert(dismissed and activated == "reply", "dismiss must not invoke the default action")
local card = center.card(popup_item, function() dismissed = true end, function(key) activated = key end)
assert(card.height == "auto" and card.background == "card" and card.hover == card.background and card.pressed == card.background)
assert(card.focus == "focus" and not find(card, "open"))
card.on_press()
assert(activated == "default")
assert(not find(card, "action-2"))
card.on_interaction_change(true)
find(card, "action-2").on_press()
assert(activated == "reply")
card.on_interaction_change(false)

for _, render in ipairs({
  function(item) return center.popup(item, { activate = function(key) activated = key end }) end,
  function(item) return center.card(item, nil, function(key) activated = key end) end,
}) do
  local item = { id = 99, app = "Chrome", title = "Two actions", body = "", actions = {
    { key = "reply", label = "Reply" }, { key = "default", label = "Open" }, { key = "settings", label = "Settings" },
  } }
  local tree = render(item)
  assert(not find(tree, "options") and not find(tree, "action-1"))
  tree.on_interaction_change(true)
  assert(find(tree, "options") and not find(tree, "menu") and not find(tree, "action-3"))
  local trigger_height = find(tree, "options").height
  local slot_height = find(tree, "actions").min_height
  find(tree, "options").on_press()
  assert(not find(tree, "menu") and not find(tree, "action-3"), "menu must not be inside the card")
  assert(find(native_menu.content(), "action-1") and not find(native_menu.content(), "action-2"), "default must not be in the menu")
  assert(find(native_menu.content(), "items").gap == 0, "menu row spacing must match its fixed native allocation")
  assert(find(tree, "options").height == trigger_height and find(tree, "actions").min_height == slot_height,
    "opening Options must not change the trigger or action slot size")
  find(tree, "options").on_press()
  assert(native_menu.closed, "the trigger must toggle closed")
  find(tree, "options").on_press()
  native_menu:close() -- Compositor outside-click / toolkit Escape callback.
  assert(find(tree, "options").label == "Notification options", "native dismissal must reset the trigger")
  find(tree, "options").on_press()
  find(native_menu.content(), "action-3").on_press()
  assert(activated == "settings" and native_menu.closed, "Settings must remain an ordinary action")
  find(tree, "options").on_press()
  tree.on_interaction_change(false)
  assert(find(tree, "options") and not native_menu.closed, "crossing into the native popup must keep its origin mounted")
  tree.on_interaction_change(true)
  local stale_action = find(native_menu.content(), "action-1").on_press
  local replacement = { id = item.id, app = item.app, title = "Replacement", body = "", actions = item.actions }
  tree = render(replacement)
  assert(native_menu.closed, "replacement must close the old item's native popup")
  activated = nil
  stale_action()
  assert(activated == nil, "a replaced menu callback must not invoke its old action")
  fail_popup = true
  find(tree, "options").on_press()
  assert(find(tree, "options").label == "Notification options", "failed native open must reset state")
  fail_popup = false
  tree.on_interaction_change(false)
end
local pending = center.popup({ id = 101, app = "Chrome", title = "Pending action", body = "", actions = {
  { key = "reply", label = "Reply" }, { key = "settings", label = "Settings" },
} }, { activate = function(key) coroutine.yield(); activated = key end })
pending.on_interaction_change(true)
find(pending, "options").on_press()
local invocation = coroutine.create(find(native_menu.content(), "action-2").on_press)
assert(coroutine.resume(invocation))
pending.on_interaction_change(false)
native_menu:close()
assert(find(pending, "options"), "native dismissal during token acquisition must retain the originating callback scope")
assert(coroutine.resume(invocation) and activated == "settings")
assert(not find(pending, "options"), "completed activation must release the pending reveal")
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
find(view(), "notification-4").children[1].on_interaction_change(true)
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
