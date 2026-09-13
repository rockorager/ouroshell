package.path = "src/?.lua;" .. package.path

local tasks = {}
local ouro = { json = { null = {} }, xdg = { runtime_dir = "/run/user/42", applications = {} }, mcp = {} }
for _, kind in ipairs({ "box", "row", "column", "scroll", "stack", "image", "text", "button", "text_input", "icon", "layer_surface", "app" }) do
  ouro[kind] = function(props) props.kind = kind; return props end
end
ouro.xdg.icon = ouro.icon
ouro.signal = function(value)
  return setmetatable({ set = function(_, next_value) value = next_value end }, { __call = function() return value end })
end
ouro.spawn = function(fn) tasks[#tasks + 1] = fn end
package.loaded.ouro = ouro

local launcher = require("launcher")
local entries = {
  { id = "code.desktop", name = "Visual Code", generic_name = "Editor", keywords = { "development" }, exec = "code", visible = true },
  { id = "calc.desktop", name = "Calculator", exec = "calc", visible = true },
  { id = "hidden.desktop", name = "Hidden Code", exec = "hidden", visible = false },
  { id = "dbus.desktop", name = "No Exec", exec = ouro.json.null, visible = true },
}
assert(launcher.search(entries, "code")[1].id == "code.desktop")
assert(launcher.search(entries, "editor")[1].id == "code.desktop")
assert(#launcher.search(entries, "") == 2 and launcher.search(entries, "")[1].name == "Calculator")

local plain = launcher.launch_argv(entries[1], function(...)
  assert(select("#", ...) == 1) -- Native options must be omitted, not nil.
  return { argv = { "code", "a b" }, cwd = ouro.json.null }
end)
assert(table.concat(plain, "|") == "code|a b")
local terminal = launcher.launch_argv({ terminal = true }, function(_, options)
  assert(options.terminal_argv[1] == "monstar" and options.terminal_argv[2] == "-e")
  return { argv = { "monstar", "-e", "htop" }, cwd = "/tmp/a b" }
end)
assert(table.concat(terminal, "|") == "env|--chdir=/tmp/a b|--|monstar|-e|htop")

local dismissed, call
local state = launcher.new {
  entries = entries, phase = "ready", dismiss = function() dismissed = true end,
  prepare_launch = function(entry) return { argv = { entry.exec }, cwd = ouro.json.null } end,
  call = function(address, tool, arguments)
    call = { address, tool, arguments }; return { result = { isError = false } }
  end,
}
state.choose_scope("apps")
state.command("next"); assert(state.selected() == 2)
state.command("next"); assert(state.selected() == 1)
state.change("code"); assert(state.selected() == 1 and #state.results() == 1)
state.command("previous"); assert(state.selected() == 1)
state.command("submit"); assert(#tasks == 1); tasks[1]()
assert(call[1] == "unix:/run/user/42/ouro.mcp.sock" and call[2] == "run")
assert(call[3].argv[1] == "code" and dismissed)
dismissed = false; state.command("cancel"); assert(dismissed)

local function find(tree, key)
  if tree.key == key then return tree end
  for _, child in ipairs(tree.children or {}) do
    local found = find(child, key)
    if found then return found end
  end
end
local tree = launcher.content(state)
assert(tree.kind == "stack" and tree.children[1].key == "vignette")
assert(find(tree, "vignette").width == "fill" and find(tree, "vignette").height == "fill")
assert(find(tree, "position").width == "fill" and find(tree, "position").height == "fill")
assert(find(tree, "palette").background == nil and find(tree, "palette").surface == nil)
assert(find(tree, "results-scroll").flex == 1)
local input = find(tree, "search-" .. state.input_generation())
assert(input.autofocus and type(input.on_command) == "function")
input.on_command("next"); assert(state.selected() == 1)
assert(input.placeholder == "Search apps and commands…" and input.label == "Search apps and commands")
assert(find(tree, "application-code.desktop").background ~= "#00000000")
assert(#launcher.search({ {id="x", name="Other", generic_name=ouro.json.null, exec="x"} }, "absent") == 0)
local many = {}
for index = 1, 10 do many[index] = {id=tostring(index), name=string.format("App %02d", index), exec="app"} end
state.entries:set(many); state.change("")
for _ = 1, 8 do state.command("next") end
assert(state.selected() == 9 and state.first() == 3)
local rows = find(launcher.content(state), "results").children
assert(#rows == 8 and rows[8].key == "application-9")
assert(rows[8].background ~= "#00000000")
state.command("previous")
assert(state.selected() == 8 and state.first() == 3)
for _ = 1, 5 do state.command("previous") end
assert(state.selected() == 3 and state.first() == 3)
state.command("previous")
assert(state.selected() == 2 and state.first() == 2)
state.change(""); state.command("previous")
assert(state.selected() == 10 and state.first() == 4)
state.command("next")
assert(state.selected() == 1 and state.first() == 1)
state.command("previous"); state.change("App 02")
assert(state.selected() == 1 and state.first() == 1 and #state.results() == 1)
state.change("missing"); state.command("previous")
assert(state.selected() == 1 and state.first() == 1 and #state.results() == 0)

state.change("App")
local short_input = find(launcher.content(state, 440), "search-" .. state.input_generation())
for _ = 1, 8 do short_input.on_command("next") end
assert(state.selected() == 9 and state.first() == 7)
local short_rows = find(launcher.content(state, 440), "results").children
assert(#short_rows == 4 and short_rows[4].key == "application-9", "short output hid the selection")

-- Empty All is compact; Apps keeps every application; system search is explicit.
state.open()
assert(#state.results() == 5 and state.results()[4].id == "lock" and state.results()[5].id == "session")
state.choose_scope("apps"); assert(#state.results() == 10)
state.change("reboot"); assert(#state.results() == 0)
state.choose_scope("system"); assert(#state.results() == 2)
state.command("next"); state.command("submit")
assert(state.page() == "session" and #state.results() == 3)
state.command("cancel"); assert(state.page() == nil and state.scope() == "system")

-- Merely finding or opening a destructive action must never submit it.
local before = #tasks
state.change("reboot")
assert(#state.results() == 1 and state.results()[1].id == "restart")
state.command("submit")
assert(state.confirming().id == "restart" and state.selected() == 1 and #tasks == before)
tree = launcher.content(state)
assert(find(tree, "cancel").background ~= "#00000000")
assert(find(tree, "search-" .. state.input_generation()).read_only)
state.command("submit") -- Enter defaults to Cancel.
assert(not state.confirming() and #tasks == before)
state.command("submit"); state.command("next"); state.command("submit")
assert(#tasks == before + 1)
state.command("submit"); assert(#tasks == before + 1, "duplicate activation while request is pending")
tasks[#tasks]()
assert(call[2] == "run" and table.concat(call[3].argv, "|") == "systemctl|reboot")

for _, case in ipairs({ { "shutdown", "run", "systemctl|poweroff" }, { "logout", "exit" } }) do
  state.open(); state.change(case[1]); state.command("submit")
  assert(state.confirming() and #tasks == before + 1)
  state.command("next"); state.command("submit"); tasks[#tasks]()
  before = #tasks - 1
  assert(call[2] == case[2])
  if case[3] then assert(table.concat(call[3].argv, "|") == case[3]) else assert(next(call[3]) == nil) end
end
state.open(); state.change("lock"); state.command("submit"); tasks[#tasks]()
assert(table.concat(call[3].argv, "|") == "loginctl|lock-session|auto")
state.open(); state.change("restart"); state.command("submit"); state.open()
assert(not state.confirming() and state.query() == "" and state.scope() == "all")

-- An app catalog failure cannot remove the shell's system actions.
local failed = launcher.new { dismiss = function() end, list = function() error("offline") end,
  call = function() return { result = { isError = true, structuredContent = { error = { message = "denied" } } } } end }
failed.load(); tasks[#tasks]()
assert(failed.phase() == "error" and #failed.results() == 2)
failed.change("lock"); failed.command("submit"); tasks[#tasks]()
assert(not failed.launching() and failed.message():find("denied", 1, true))

ouro.date = function() return "12:00" end
ouro.time = function() return 0 end
ouro.shell = { workspaces = { connect = function() return function() return {available=false} end end } }
local app = dofile("src/application.lua")
local windows = app.run().windows
assert(#windows() == 1 and windows()[1].id == "panel")
app.actions["launcher.toggle"].handler()
assert(#windows() == 2 and windows()[2].id == "launcher")
assert(windows()[2].keyboard_interactivity == "exclusive")
assert(windows()[2].width == 0 and windows()[2].height == 0 and #windows()[2].anchors == 4)
assert(windows()[2].exclusive_zone == 0 and windows()[2].background_effect == "blur")
assert(windows()[2].background == launcher.background)
app.actions["launcher.toggle"].handler()
assert(#windows() == 1 and windows()[1].id == "panel")
print("PASS: launcher search, scope navigation, safe confirmations, fixed argv, failure states, and full-screen composition")
