package.path = "src/?.lua;" .. package.path

local tasks = {}
local ouro = { json = { null = {} }, xdg = { runtime_dir = "/run/user/42", applications = {} }, mcp = {} }
for _, kind in ipairs({ "box", "row", "column", "text", "button", "text_input", "icon", "layer_surface", "app" }) do
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
state.command("next"); assert(state.selected() == 2)
state.command("next"); assert(state.selected() == 1)
state.change("code"); assert(state.selected() == 1 and #state.results() == 1)
state.command("previous"); assert(state.selected() == 1)
state.command("submit"); assert(#tasks == 1); tasks[1]()
assert(call[1] == "unix:/run/user/42/ouro.mcp.sock" and call[2] == "run")
assert(call[3].argv[1] == "code" and dismissed)
dismissed = false; state.command("cancel"); assert(dismissed)

local tree = launcher.content(state)
local palette = tree.children[1].children[1]
assert(palette.children[2].autofocus and palette.children[2].on_command == state.command)
assert(palette.children[3].children[1].children[1].children[2].background ~= "#00000000")
assert(#launcher.search({ {id="x", name="Other", generic_name=ouro.json.null, exec="x"} }, "absent") == 0)
local many = {}
for index = 1, 10 do many[index] = {id=tostring(index), name=string.format("App %02d", index), exec="app"} end
state.entries:set(many); state.change(""); state.selected:set(9)
local rows = launcher.content(state).children[1].children[1].children[3].children
assert(#rows == 7 and rows[7].key == "application-9")
assert(rows[7].children[1].children[2].background ~= "#00000000")

ouro.date = function() return "12:00" end
ouro.time = function() return 0 end
ouro.shell = { workspaces = { connect = function() return function() return {available=false} end end } }
local app = dofile("src/application.lua")
local windows = app.run().windows
assert(#windows() == 1 and windows()[1].id == "panel")
app.actions["launcher.toggle"].handler()
assert(#windows() == 2 and windows()[2].id == "launcher")
assert(windows()[2].keyboard_interactivity == "exclusive")
app.actions["launcher.toggle"].handler()
assert(#windows() == 1 and windows()[1].id == "panel")
print("PASS: launcher search, selection, commands, argv policy, MCP call, and widget states")
