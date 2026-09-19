package.path = "src/?.lua;" .. package.path
local tasks, signals, methods = {}, {}, nil
local ouro = { tokens = { foundation = {} } }
ouro.signal = function(value)
  return setmetatable({ set = function(_, next_value) value = next_value end }, { __call = function() return value end })
end
ouro.spawn = function(fn)
  local task = coroutine.create(fn)
  local ok, delay = coroutine.resume(task)
  assert(ok, delay)
  tasks[#tasks + 1] = { task = task, delay = delay }
end
ouro.sleep = coroutine.yield
ouro.activation_token = function() return nil end
package.loaded.ouro = ouro
package.loaded.appearance = {}
local service = require("notifications")
local bus = {
  export = function(_, definition) methods = definition.methods; return {} end,
  emit = function(_, signal) signals[#signals + 1] = signal; return true end,
}
local state = service.new()
service.export(bus, state)
local function notify(replaces, timeout, hints, actions, title)
  return methods.Notify.handler { sender = ":1.42", args = { "Files", replaces or 0, "", title or "Download ready", "Body",
    actions or {}, hints or {}, timeout or -1 } }
end
local function resume(index) assert(coroutine.resume(tasks[index].task)) end
local function closed(id, reason)
  local signal = signals[#signals]
  assert(signal.member == "NotificationClosed" and signal.args[1] == id and signal.args[2] == reason)
end
assert(methods.GetCapabilities.handler()[1][1] == "body")
assert(methods.GetServerInformation.handler()[1] == "Ouroshell")
local id = notify()[1]
assert(id == 1 and tasks[1].delay == 6000)
local old = state.items()[1]
assert(notify(id, 3000)[1] == id and #state.items() == 1)
resume(1)
assert(state.popup() and #signals == 0, "old timeout expired its replacement")
resume(2)
closed(id, 1)
assert(state.popup() == nil and #state.items() == 1 and #state.items()[1].actions == 0)
state.dismiss(id)
assert(#signals == 1 and #state.items() == 0, "archived dismissal sent duplicate closure")
assert(notify(id, 0)[1] == 2, "closed IDs cannot be reused")
assert(#tasks == 2, "timeout zero must not expire")
state.dismiss(2)
closed(2, 2)
id = notify(nil, 0)[1]
assert(methods.CloseNotification.handler { args = { id } })
closed(id, 3)
local result, err = methods.CloseNotification.handler { args = { id } }
assert(result == nil and err.name:find("InvalidArgs"))

id = notify(nil, 0, nil, { "default", "Open", "archive", "Archive" })[1]
local item = state.items()[1]
state.activate(item, "missing")
local count = #signals
state.activate(item, "archive")
assert(signals[count + 1].member == "ActionInvoked" and signals[count + 1].args[2] == "archive")
closed(id, 2)
state.activate(item, "default")
assert(#signals == count + 2, "stale action sent a signal")
id = notify(nil, 0, nil, { "default", "Open" })[1]
ouro.activation_token = function() return "click-token" end
count = #signals
state.activate(state.items()[1], "default")
assert(signals[count + 1].member == "ActivationToken" and signals[count + 1].args[2] == "click-token")
assert(signals[count + 2].member == "ActionInvoked" and signals[count + 2].args[2] == "default")
assert(signals[count + 1].destination == ":1.42" and signals[count + 2].destination == ":1.42")
id = notify(nil, 0, nil, { "default", "Open" })[1]
ouro.activation_token = function() notify(id, 0); return "obsolete-token" end
count = #signals
state.activate(state.items()[1], "default")
assert(#signals == count, "replacement during token acquisition invoked stale action")
state.dismiss(id)
ouro.activation_token = function() return nil end
id = notify(nil, 0, { { "resident", { signature = "b", value = true } } }, { "open", "Open" })[1]
state.activate(state.items()[1], "open")
assert(state.items()[1].id == id and signals[#signals].member == "ActionInvoked")
notify(id, 1, { { "transient", { signature = "b", value = true } } })
resume(#tasks)
assert(#state.items() == 0)
closed(id, 1)

state.quiet:set(true)
id = notify(nil, 1)[1]
assert(state.popup() == nil and #state.items() == 1)
resume(#tasks)
closed(id, 1)
state.quiet:set(false)
assert(state.popup() == nil, "leaving DND resurrected a suppressed popup")
notify(nil, 1, { { "urgency", { signature = "y", value = 2 } } })
assert(state.items()[1].urgent and #tasks == 4, "critical notification must not autoexpire")
state.clear()
assert(#state.items() == 0)

ouro.images = { load = function(options)
  if options.path == "/tmp/site.png" then return "retained-image-bytes" end
end }
id = notify(nil, 1, { { "image-path", { signature = "s", value = "/tmp/site.png" } } })[1]
assert(state.popup().image.bytes == "retained-image-bytes")
resume(#tasks)
assert(state.popup() == nil and state.items()[1].image.bytes == "retained-image-bytes",
  "expiry must retain the notification image with history")
id = notify(nil, 0, { { "image-path", { signature = "s", value = "/tmp/site.png" } } })[1]
notify(id, 0)
assert(state.items()[1].image == nil, "replacement without an image must clear the old image")
state.clear()

result, err = notify(nil, -2)
assert(result == nil and err.name:find("InvalidArgs"))
assert(not notify(nil, 0, nil, { "odd" }))
assert(not notify(nil, 0, nil, { "a", "A", "a", "Duplicate" }))
assert(not notify(nil, 0, nil, {}, string.rep("x", 8193)))
notify(nil, 0, nil, {}, string.rep("é", 100))
assert(utf8.len(state.items()[1].title) == 65 and state.items()[1].title:sub(-3) == "…")
state.clear()
for index = 1, 101 do notify(nil, 0, nil, {}, "Item " .. index) end
assert(#state.items() == 100 and state.items()[100].title == "Item 2")
assert(signals[#signals].args[2] == 4)
assert(#state.groups()[1].items == 100, "group history must not be sliced into pages")
state.clear()
assert(#state.groups() == 0)
for _ = 1, 64 do assert(notify(nil, 9000)) end
result, err = notify(nil, 9000)
assert(result == nil and err.name:find("LimitsExceeded") and #state.items() == 64)
state.disconnect()
count = #signals
resume(#tasks)
assert(#signals == count and #state.items()[1].actions == 0, "disconnect left active timers/actions")
local icons = service.new(function() return {
  { id = "slack.desktop", name = "Slack", icon = "slack" },
  { id = "hidden.desktop", name = "Hidden", icon = "hidden-icon", hidden = true },
  { id = "empty.desktop", name = "Empty", icon = {} },
} end)
service.export(bus, icons)
local function notify_icon(app, supplied, desktop_entry, hints)
  hints = hints or {}
  if desktop_entry then hints[#hints + 1] = { "desktop-entry", { signature = "s", value = desktop_entry } } end
  assert(methods.Notify.handler { sender = ":1.42", args = { app, 0, supplied, "Title", "Body", {}, hints, 0 } })
  local image = icons.items()[1].image
  return image and (image.name or image.bytes)
end
assert(notify_icon("Different display name", "folder-symbolic", "slack") == "folder-symbolic",
  "desktop-entry must not override an explicit app_icon")
assert(notify_icon("Slack", "file:///tmp/site.png", "slack") == "retained-image-bytes")
assert(notify_icon("Slack", "folder-symbolic", "slack",
  { { "image-path", { signature = "s", value = "/tmp/site.png" } } }) == "retained-image-bytes",
  "image-path must precede both app_icon and desktop-entry")
assert(notify_icon("Different display name", "", "slack.desktop") == "slack")
assert(notify_icon("sLaCk", "", nil) == "slack", "app name should fall back to the installed catalog")
assert(notify_icon("Unknown", "mail-unread-symbolic", nil) == "mail-unread-symbolic")
assert(notify_icon("Unknown", "", "missing") == nil, "missing metadata must not manufacture a bell icon")
assert(notify_icon("Hidden", "", "hidden") == nil)
assert(notify_icon("Empty", "", "empty") == nil)
assert(notify_icon("Unknown", "/tmp/untrusted.png", nil) == nil, "unloadable files must not produce an image")
print("PASS: notification IDs, replacement timers, closure reasons, actions, hints, DND, UTF-8, history and limits")
