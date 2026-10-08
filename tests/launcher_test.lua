-- The launcher: search and launch policy (plain functions), its chart, and
-- the view mounted against real actors with fake services.
local o = require("ouro")
local machine = o.machine
local launcher = require("launcher")
local shell = require("shell")

local entries = {
  { id = "code.desktop", name = "Visual Code", generic_name = "Editor", keywords = { "development" }, exec = "code", visible = true },
  { id = "calc.desktop", name = "Calculator", exec = "calc", visible = true },
  { id = "files.desktop", name = "Files", exec = "files", visible = true },
  { id = "mail.desktop", name = "Mail", exec = "mail", visible = true },
  { id = "hidden.desktop", name = "Hidden Code", exec = "hidden", visible = false },
  { id = "dbus.desktop", name = "No Exec", exec = o.json.null, visible = true },
}

local function ids(rows)
  local result = {}
  for index, row in ipairs(rows) do result[index] = row.id end
  return table.concat(result, ",")
end

local function results(c, fields)
  fields = fields or {}
  return launcher.results({ query = c.query or "", scope = c.scope or "all", page = c.page },
    { entries = entries, caffeinated = fields.caffeinated, scheme = fields.scheme or "light" })
end

local function start(execute)
  local requests = {}
  local chart = launcher.chart { execute = function(entry)
    requests[#requests + 1] = entry.id
    if execute then return execute(entry) end
  end }
  local clock = machine.manual_scheduler()
  return chart:start { scheduler = clock }, clock, requests
end

local function row(id)
  for _, view in ipairs({ { scope = "apps" }, { scope = "system" }, { page = "session" } }) do
    for _, entry in ipairs(results(view)) do
      if entry.id == id then return entry end
    end
  end
end

return {
  ["search ranks names, generic names and keywords; launches are argv"] = function()
    assert(launcher.search(entries, "code")[1].id == "code.desktop")
    assert(launcher.search(entries, "editor")[1].id == "code.desktop")
    assert(launcher.search(entries, "development")[1].id == "code.desktop")
    assert(#launcher.search(entries, "") == 4 and launcher.search(entries, "")[1].name == "Calculator",
      "hidden and Exec-less entries are not presented")
    local plain = launcher.launch_argv(entries[1], function(...)
      assert(select("#", ...) == 1, "native options must be omitted, not nil")
      return { argv = { "code", "a b" }, cwd = o.json.null }
    end)
    assert(table.concat(plain, "|") == "code|a b")
    local terminal = launcher.launch_argv({ terminal = true }, function(_, options)
      assert(options.terminal_argv[1] == "monstar" and options.terminal_argv[2] == "-e")
      return { argv = { "monstar", "-e", "htop" }, cwd = "/tmp/a b" }
    end)
    assert(table.concat(terminal, "|") == "env|--chdir=/tmp/a b|--|monstar|-e|htop")
  end,

  ["rows combine applications and fixed system actions"] = function()
    assert(ids(results {}) == "calc.desktop,files.desktop,mail.desktop,lock,session,caffeine,color-scheme",
      "home shows three applications")
    assert(ids(results { scope = "apps" }) == "calc.desktop,files.desktop,mail.desktop,code.desktop")
    assert(ids(results { scope = "system" }) == "lock,session,caffeine,color-scheme")
    assert(ids(results { query = "reboot" }) == "restart" and row("restart").verb == "Restart")
    assert(ids(results { page = "session" }) == "logout,restart,shutdown")
    local theme = results({ query = "dark mode" })[1]
    assert(theme.name == "Switch to dark theme" and table.concat(theme.argv, " ") == "prefer set color-scheme dark")
    theme = results({ query = "theme" }, { scheme = "dark" })[1]
    assert(theme.name == "Switch to light theme" and theme.argv[4] == "light")
    assert(results({ query = "idle" }, { caffeinated = true })[1].name == "Decaffeinate")
  end,

  ["scopes, pages and Back; Escape at the top closes"] = function()
    local actor = start()
    actor:send { type = "SCOPE", value = "apps" }
    assert(actor:context().scope == "apps" and actor:context().focus == 1, "mouse actions hand focus back to search")
    actor:send { type = "QUERY", value = "ca" }
    actor:send { type = "MOVE", delta = 1, count = 3 }
    actor:send { type = "MOVE", delta = 3, count = 3 }
    assert(actor:context().selected == 2)
    actor:send { type = "QUERY", value = "" }
    assert(actor:context().selected == 1, "a new query resets the selection")
    actor:send { type = "ACTIVATE", entry = row("session") }
    assert(actor:context().page == "session" and actor:matches("browsing"))
    actor:send("BACK")
    assert(actor:context().page == nil and actor:matches("browsing"))
    actor:send("BACK")
    assert(actor:matches("dismissed") and actor:status() == "done")
  end,

  ["destructive actions confirm with Cancel selected"] = function()
    local actor, clock, requests = start()
    actor:send { type = "ACTIVATE", entry = row("shutdown") }
    assert(actor:matches("confirming") and actor:context().selected == 1 and actor:context().confirming.verb == "Shut down")
    assert(not actor:can { type = "ACTIVATE", entry = row("lock") }, "rows are inert while confirming")
    actor:send("BACK")
    assert(actor:matches("browsing") and actor:context().confirming == nil and #requests == 0)
    actor:send { type = "ACTIVATE", entry = row("shutdown") }
    actor:send { type = "MOVE", delta = 1, count = 2 }
    actor:send("CONFIRM")
    assert(actor:matches("executing") and actor:context().target.id == "shutdown")
    clock.run_tasks()
    assert(requests[1] == "shutdown" and actor:matches("dismissed"))
  end,

  ["a failed request stays visible and keeps the confirmation"] = function()
    local actor, clock = start(function() error("Ouro rejected the request", 0) end)
    actor:send { type = "ACTIVATE", entry = row("restart") }
    actor:send("CONFIRM")
    assert(not actor:can("CONFIRM"), "one request at a time")
    clock.run_tasks()
    assert(actor:matches("confirming") and actor:context().message == "Request failed: Ouro rejected the request")
    actor:send("BACK")
    actor:send { type = "ACTIVATE", entry = row("calc.desktop") }
    clock.run_tasks()
    assert(actor:matches("browsing") and actor:context().message:find("rejected", 1, true))
    actor:send { type = "QUERY", value = "x" }
    assert(actor:context().message == nil, "typing clears the error")
  end,

  ["requests go to Ouro's run tool as fixed argv"] = function()
    local calls = {}
    local execute = launcher.execute {
      session = function() error("not used") end, address = "unix:/run/user/1000/ouro.mcp.sock",
      prepare_launch = function(entry) return { argv = { entry.exec }, cwd = "/work dir" } end,
      call = function(address, tool, arguments)
        calls[#calls + 1] = { address = address, tool = tool, arguments = arguments }
        if #calls == 3 then
          return { result = { isError = true, structuredContent = { error = { message = "Denied" } } } }
        end
        return { result = {} }
      end,
    }
    execute(entries[2])
    assert(calls[1].address == "unix:/run/user/1000/ouro.mcp.sock" and calls[1].tool == "run")
    assert(table.concat(calls[1].arguments.argv, "|") == "env|--chdir=/work dir|--|calc")
    execute(row("logout"))
    assert(calls[2].tool == "exit" and next(calls[2].arguments) == nil)
    local ok, failure = pcall(execute, row("restart"))
    assert(not ok and failure == "Denied" and table.concat(calls[3].arguments.argv, " ") == "systemctl reboot")
  end,

  ["the view lists rows, sends events and closes the shell when done"] = function(t)
    local ui = shell.chart { launcher = launcher.chart { execute = function() end } }
      :start { scheduler = machine.manual_scheduler() }
    ui:send("TOGGLE_LAUNCHER")
    local function props()
      return { launcher = ui:child("launcher"), shell = ui, scheme = "light", entries = entries,
        catalog_phase = "ready", caffeinated = false, current = props }
    end
    t:mount(function() return ui:child("launcher") and launcher.content(props(), 760, 1280) end, { width = 1280, height = 760, padding = 0 })
    local base = "launcher/position/palette/content"
    local function result(key) return base .. "/results/" .. key .. "/row/" .. key end
    assert(t:node(result("application-calc.desktop")).label == "Calculator")
    t:click(base .. "/scopes/tabs/scope-system/button")
    assert(ui:child("launcher"):context().scope == "system")
    t:click(result("system-session"))
    assert(ui:child("launcher"):context().page == "session")
    assert(t:node(base .. "/scopes/tabs/back").label == "← Back")
    t:click(result("system-shutdown"))
    assert(ui:child("launcher"):matches("confirming"))
    t:key("enter")
    assert(ui:child("launcher"):matches("browsing"), "Enter on the default choice cancels")
    t:click(base .. "/scopes/tabs/back")
    assert(ui:child("launcher"):context().page == nil)
    t:key("escape")
    assert(ui:matches("none") and ui:child("launcher") == nil, "Back at the top closes the launcher")
  end,
}
