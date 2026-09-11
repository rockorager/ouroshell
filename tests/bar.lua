package.path = "src/?.lua;" .. package.path
local ouro = {}
for _, kind in ipairs({ "box", "row", "scroll", "text", "button", "app", "layer_surface" }) do
  ouro[kind] = function(props) props.kind = kind; return props end
end
package.loaded.ouro = ouro
local bar = require("bar")

local function workspace_items(tree)
  return tree.children[1].children[1].children[1].children
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
local tree = bar.content(state, "Thu Sep 10  04:32 PM")
local items = workspace_items(tree)
assert(#items == 5)
for index, name in ipairs({ "1", "2:code", "2:mail", "10", "chat" }) do
  assert(items[index].label == name)
end
assert(state.workspaces[1].name == "10", "sorting mutated the protocol snapshot")
assert(items[4].key == "workspace-id:1:ten")
items[4].on_press()
assert(activated == "ten", "click activated the wrong workspace")
assert(items[2].on_press == nil, "active workspace should not reactivate")
assert(not items[5].enabled and items[5].on_press == nil)
assert(items[2].background ~= items[1].background)
assert(items[3].foreground ~= items[1].foreground)
assert(tree.children[1].children[2].text == "Thu Sep 10  04:32 PM")
assert(tree.children[1].children[1].axis == "horizontal")

assert(workspace_items(bar.content({ available = false, workspaces = state.workspaces }, "time"))[1].text
  == "Workspaces unavailable")
assert(workspace_items(bar.content({ available = true, workspaces = { state.workspaces[2] } }, "time"))[1].text
  == "No workspaces")

local repeated = { available = true, workspaces = {
  { id = "3", name = "1", can_activate = true, activate = function() activated = "first" end },
  { id = "3", name = "1", can_activate = true, activate = function() activated = "second" end },
  { name = "1", can_activate = false },
} }
local duplicates = workspace_items(bar.content(repeated, "time"))
assert(#duplicates == 3)
assert(duplicates[1].key ~= duplicates[2].key and duplicates[1].key ~= duplicates[3].key
  and duplicates[2].key ~= duplicates[3].key, "duplicate or missing IDs collided")
duplicates[1].on_press()
assert(activated == "first")
duplicates[2].on_press()
assert(activated == "second", "duplicate IDs must retain separate activation targets")
repeated.workspaces[1].hidden = true
assert(workspace_items(bar.content(repeated, "time"))[1].key == duplicates[2].key,
  "hiding a workspace changed its sibling's key")

repeated.workspaces[1].hidden = false
repeated.workspaces[1].outputs = { "DP-1" }
repeated.workspaces[2].outputs = { "eDP-1" }
repeated.workspaces[3].outputs = { "DP-1", "eDP-1" }
local dp = workspace_items(bar.content(repeated, "time", "DP-1"))
local edp = workspace_items(bar.content(repeated, "time", "eDP-1"))
assert(#dp == 2 and #edp == 2, "each output must include only its members")
dp[1].on_press()
assert(activated == "first")
edp[1].on_press()
assert(activated == "second", "same-name workspaces must activate on their own output")
assert(workspace_items(bar.content(repeated, "time", "absent"))[1].text == "No workspaces")
repeated.workspaces[2].outputs = { "DP-1" }
assert(#workspace_items(bar.content(repeated, "time", "DP-1")) == 3)
assert(#workspace_items(bar.content(repeated, "time", "eDP-1")) == 1,
  "moving groups must remove the workspace from its old output")

local now, spawned, delay = 119, nil, nil
ouro.time = function() return now end
ouro.date = function(format)
  assert(format == "%a %b %d  %I:%M %p")
  return "minute " .. math.floor(now / 60)
end
ouro.signal = function(value)
  return setmetatable({ set = function(_, next_value) value = next_value end }, {
    __call = function() return value end,
  })
end
ouro.spawn = function(fn) assert(spawned == nil); spawned = coroutine.create(fn) end
ouro.sleep = function(ms) delay = ms; coroutine.yield() end
ouro.shell = { workspaces = { connect = function() return function() return state end end } }
local app = dofile("src/application.lua")
local panel = app.run().windows[1]
assert(panel.height == 40 and panel.exclusive_zone == 40)
assert(panel.outputs == "all" and panel.output == nil)
assert(workspace_items(panel.content("DP-1"))[1].text == "No workspaces",
  "application did not pass the native output name to the bar")
assert(panel.content().children[1].children[2].text == "minute 1")
assert(coroutine.resume(spawned))
assert(delay == 1000, "clock did not align with the next minute")
now = 120
assert(coroutine.resume(spawned))
assert(delay == 60000)
assert(panel.content().children[1].children[2].text == "minute 2")
print("PASS: workspace ordering, visibility, activation, states, and minute-aligned clock")
