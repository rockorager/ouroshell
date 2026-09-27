package.path = "src/?.lua;tests/?.lua;" .. package.path
-- A non-default value detects literals instead of references to the catalog.
local ouro = require("fake_ouro").install { tokens = {
  foundation = {
    typography_2 = 14, typography_3 = 23, typography_7 = 28, line_height_2 = 20,
    spacing_1 = 4, spacing_2 = 8, spacing_3 = 15, spacing_4 = 19,
    spacing_5 = 24, spacing_6 = 32, spacing_8 = 48, radius_2 = 5,
    border_width_default = 1, border_width_strong = 2,
  },
  dark = setmetatable({ background = "#012345FF" }, { __index = function(_, key) return "token:" .. key end }),
  palette = { transparent = "#00000000", dark = {
    indigo = { step_6 = "token:indigo6" }, red = { step_11 = "token:red11" },
  } },
} }
local scheme = "dark"
package.loaded.appearance = {
  colors = function() return ouro.tokens[scheme], ouro.tokens.palette[scheme] end,
  connect = function() end,
}
local bar = require("bar")

local function workspace_items(tree)
  return tree.children[1].children[2].children[1].children
end

local activated
local state = { available = true, workspaces = {
  { id = "ten", name = "10", can_activate = true, activate = function() activated = "ten" end },
  { id = "hidden", name = "0", hidden = true },
  { id = "named", name = "chat", can_activate = false },
  { id = "two-b", name = "2:mail", can_activate = true, urgent = true },
  { id = "two-a", name = "2:code", can_activate = true, active = true },
  { id = "one", name = "1", can_activate = true },
} }
local tree = bar.content { workspaces = state, time = "Thu Sep 10  04:32 PM" }
local items = workspace_items(tree)
assert(#items == 5)
for index, name in ipairs({ "1", "2:code", "2:mail", "10", "chat" }) do
  assert(items[index].label == name)
  for _, property in ipairs({ "height", "padding_x", "padding_y", "radius", "font_size" }) do
    assert(items[index][property] == nil, "workspace buttons must inherit default " .. property)
  end
end
assert(state.workspaces[1].name == "10", "sorting mutated the protocol snapshot")
assert(items[4].key == "workspace-id:1:ten")
items[4].on_press()
assert(activated == "ten", "click activated the wrong workspace")
assert(items[2].on_press == nil, "active workspace should not reactivate")
assert(not items[5].enabled and items[5].on_press == nil)
assert(tree.surface == "sidebar" and tree.background == nil, "bar must use the existing sidebar surface")
assert(items[2].background == ouro.tokens.dark.accent_selected and items[2].hover == ouro.tokens.palette.dark.indigo.step_6,
  "active workspace must use the blue selection tokens")
assert(items[1].background == ouro.tokens.palette.transparent and items[1].hover == ouro.tokens.dark.sidebar_accent)
assert(items[2].foreground == ouro.tokens.dark.sidebar_foreground and items[1].foreground == ouro.tokens.dark.muted_foreground)
assert(items[3].foreground == ouro.tokens.palette.dark.red.step_11)
assert(items[2].children == nil,
  "workspace selection must be a rounded button, not a custom underline")
local menu = tree.children[1].children[1]
for _, property in ipairs({ "height", "padding_x", "padding_y", "radius", "font_size" }) do
  assert(menu[property] == nil, "menu button must inherit default " .. property)
end
assert(tree.padding == ouro.tokens.foundation.spacing_1, "bar must inset controls from both desktop edges")
assert(#tree.children[1].children == 3, "bar padding must replace the trailing spacer")
assert(tree.children[1].gap == ouro.tokens.foundation.spacing_1)
assert(tree.children[1].gap == tree.children[1].children[2].children[1].gap,
  "menu-to-workspace gap must match workspace-to-workspace gap")
assert(menu.children[1].size == nil, "menu mark must inherit default text size")
assert(items[2].disabled == items[2].background,
  "active workspace must keep its fill even when activation is unavailable")
assert(items[3].foreground ~= items[1].foreground)
assert(tree.children[1].children[3].children[1].text == "Thu Sep 10  04:32 PM")
assert(tree.children[1].children[3].children[1].size == 23, "clock must use typography_3")
assert(tree.children[1].children[2].axis == "horizontal")

ouro.tokens.light = setmetatable({}, { __index = function(_, key) return "light:" .. key end })
ouro.tokens.palette.light = { indigo = { step_6 = "light:indigo6" }, red = { step_11 = "light:red11" } }
scheme = "light"
local light_tree = bar.content { workspaces = state, time = "time" }
local light_items = workspace_items(light_tree)
assert(light_items[2].background == "light:accent_selected" and light_items[2].hover == "light:indigo6")
assert(light_items[1].foreground == "light:muted_foreground" and light_items[3].foreground == "light:red11")
assert(light_tree.children[1].children[1].foreground == "light:muted_foreground")
assert(light_items[2].key == items[2].key, "retheming must retain workspace identity")
scheme = "dark"

assert(workspace_items(bar.content { workspaces = { available = false, workspaces = state.workspaces }, time = "time" })[1].text
  == "Workspaces unavailable")
assert(workspace_items(bar.content { workspaces = { available = true, workspaces = { state.workspaces[2] } }, time = "time" })[1].text
  == "No workspaces")

local repeated = { available = true, workspaces = {
  { id = "3", name = "1", can_activate = true, activate = function() activated = "first" end },
  { id = "3", name = "1", can_activate = true, activate = function() activated = "second" end },
  { name = "1", can_activate = false },
} }
local duplicates = workspace_items(bar.content { workspaces = repeated, time = "time" })
assert(#duplicates == 3)
assert(duplicates[1].key ~= duplicates[2].key and duplicates[1].key ~= duplicates[3].key
  and duplicates[2].key ~= duplicates[3].key, "duplicate or missing IDs collided")
duplicates[1].on_press()
assert(activated == "first")
duplicates[2].on_press()
assert(activated == "second", "duplicate IDs must retain separate activation targets")
repeated.workspaces[1].hidden = true
assert(workspace_items(bar.content { workspaces = repeated, time = "time" })[1].key == duplicates[2].key,
  "hiding a workspace changed its sibling's key")

repeated.workspaces[1].hidden = false
repeated.workspaces[1].outputs = { "DP-1" }
repeated.workspaces[2].outputs = { "eDP-1" }
repeated.workspaces[3].outputs = { "DP-1", "eDP-1" }
local dp = workspace_items(bar.content { workspaces = repeated, time = "time", output = "DP-1" })
local edp = workspace_items(bar.content { workspaces = repeated, time = "time", output = "eDP-1" })
assert(#dp == 2 and #edp == 2, "each output must include only its members")
dp[1].on_press()
assert(activated == "first")
edp[1].on_press()
assert(activated == "second", "same-name workspaces must activate on their own output")
assert(workspace_items(bar.content { workspaces = repeated, time = "time", output = "absent" })[1].text == "No workspaces")
repeated.workspaces[2].outputs = { "DP-1" }
assert(#workspace_items(bar.content { workspaces = repeated, time = "time", output = "DP-1" }) == 3)
assert(#workspace_items(bar.content { workspaces = repeated, time = "time", output = "eDP-1" }) == 1,
  "moving groups must remove the workspace from its old output")

ouro.xdg = { runtime_dir = "/run/user/42", icon = ouro.xdg.icon, applications = {
  list = function() return {} end,
  prepare_launch = function() return {} end,
} }
local opened = false
for _, quiet in ipairs({ false, true }) do
  local controls = bar.content { workspaces = state, time = "test clock",
    open_notifications = function() opened = true end, quiet = quiet }.children[1].children[3].children
  assert(#controls == 2 and controls[1].key == "notifications" and controls[2].key == "clock",
    "bell must be immediately left of the rightmost clock")
  assert(controls[2].text == "test clock")
  assert(controls[1].padding_x == ouro.tokens.foundation.spacing_2,
    "bell hover and click area must include horizontal padding")
  assert(controls[1].foreground == ouro.tokens.dark.sidebar_foreground)
  assert(controls[1].children[1].tint == ouro.tokens.dark.sidebar_foreground,
    "bell must match the normal status icon foreground")
  assert(controls[1].children[1].theme == "Adwaita")
  assert(controls[1].children[1].name == (quiet and "notifications-disabled-symbolic"
    or "preferences-system-notifications-symbolic"))
  controls[1].on_press()
end
assert(opened, "bell must invoke the notification toggle")
ouro.mcp = { call = function() return { result = {} } end }
ouro.spawn = function(fn) assert(coroutine.resume(coroutine.create(fn))) end
ouro.shell = { workspaces = { connect = function() return function() return state end end } }
local power, connectivity, time = nil, nil, "minute 1"
require("battery").connect = function() return function() return power end end
require("network").connect = function() return function() return connectivity end end
require("notifications").connect = function() end
require("clock").connect = function() return function() return time end end
local app = dofile("src/application.lua")
assert(app.theme == nil, "shell must inherit the host theme")
local running = app.run()
local windows = running.windows()
local panel = windows[1]
assert(panel.height == 40 and panel.exclusive_zone == 40)
assert(panel.outputs == "all" and panel.output == nil)
assert(workspace_items(panel.content("DP-1"))[1].text == "No workspaces",
  "application did not pass the native output name to the bar")
assert(panel.content().children[1].children[3].children[2].text == "minute 1")
time = "minute 2"
assert(panel.content().children[1].children[3].children[2].text == "minute 2", "panel must follow the clock")
power = { percentage = 12, icon = "battery-caution-symbolic", low = true }
local status = panel.content().children[1].children[3]
assert(#status.children == 3 and status.children[1].key == "battery" and status.children[3].key == "clock")
assert(status.children[1].children[2].text == "12%" and status.gap == ouro.tokens.foundation.spacing_2,
  "status gap must leave room for padding inside the bell button")
connectivity = { icon = "network-wireless-signal-good-symbolic", label = "Wi-Fi" }
status = panel.content().children[1].children[3]
assert(#status.children == 4 and status.children[1].key == "network" and status.children[2].key == "battery")
assert(#status.children[1].children == 1 and status.children[4].key == "clock")
assert(status.children[3].key == "notifications", "bell must be immediately left of the clock")
assert(status.children[1].children[1].name == connectivity.icon)
connectivity = nil
power = nil
assert(#panel.content().children[1].children[3].children == 2, "missing battery left an empty indicator")
local bell = panel.content().children[1].children[3].children[1]
assert(bell.key == "notifications" and bell.children[1].name == "preferences-system-notifications-symbolic")
bell.on_press()
assert(running.windows()[2].id == "notifications")
assert(app.actions["launcher.toggle"].inputSchema.type == "object")
panel.content().children[1].children[1].on_press()
assert(#running.windows() == 2 and running.windows()[2].id == "launcher")
app.actions["notifications.toggle"].handler()
assert(#running.windows() == 2 and running.windows()[2].id == "notifications")
app.actions["launcher.toggle"].handler()
app.actions["launcher.toggle"].handler()
assert(#running.windows() == 1)
print("PASS: workspace ordering, visibility, activation, states, status indicators, and overlays")
