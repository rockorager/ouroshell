-- The shell's overlays and the bar, against real charts.
local o = require("ouro")
local machine = o.machine
local bar = require("bar")
local launcher = require("launcher")
local shell = require("shell")
local workspaces_chart = require("workspaces")

local function start()
  return shell.chart { launcher = launcher.chart { execute = function() end } }
    :start { scheduler = machine.manual_scheduler() }
end

local function notified(ui, id, fields)
  fields = fields or {}
  ui:send { type = "NOTIFIED", id = id, replaced = fields.replaced or false, quiet = fields.quiet or false }
end

return {
  ["overlays are exclusive and a popup never covers the launcher or center"] = function()
    local ui = start()
    notified(ui, 1)
    assert(ui:matches("popup") and ui:context().popup == 1)
    notified(ui, 2, { quiet = true })
    assert(ui:context().popup == 1, "Do Not Disturb keeps history but shows no new popup")
    ui:send("TOGGLE_LAUNCHER")
    assert(ui:matches("launcher") and ui:child("launcher") and ui:context().popup == nil)
    notified(ui, 3)
    assert(ui:matches("launcher"), "a notification never replaces the launcher")
    ui:send("TOGGLE_CENTER")
    assert(ui:matches("center") and ui:child("launcher") == nil, "the center replaces the launcher")
    notified(ui, 4)
    assert(ui:matches("center"))
    ui:send("ACTIVATED")
    assert(ui:matches("none"))
    ui:send("TOGGLE_LAUNCHER")
    ui:send("ACTIVATED")
    assert(ui:matches("launcher"), "activating a notification keeps the launcher")
    ui:send("DISMISS")
    assert(ui:matches("none"), "locking dismisses any overlay")
  end,

  ["each launcher opening starts fresh"] = function()
    local ui = start()
    ui:send("TOGGLE_LAUNCHER")
    ui:child("launcher"):send { type = "QUERY", value = "files" }
    ui:send("TOGGLE_LAUNCHER")
    assert(ui:matches("none") and ui:child("launcher") == nil)
    ui:send("TOGGLE_LAUNCHER")
    assert(ui:child("launcher"):context().query == "", "reopening resets the query")
    ui:child("launcher"):send("BACK")
    assert(ui:matches("none"), "the launcher finishing closes it")
    ui:send("TOGGLE_LAUNCHER")
    ui:deliver({ type = "surface.close_requested.launcher", id = "launcher" }, "surface")
    assert(ui:matches("none"), "a compositor close request closes the launcher")
    ui:deliver({ type = "surface.closed.launcher", id = "launcher" }, "surface")
  end,

  ["unread counts what arrived while the center was closed"] = function()
    local ui = start()
    local items = { { id = 1 }, { id = 2 }, { id = 3 } }
    notified(ui, 1); notified(ui, 2); notified(ui, 1, { replaced = true })
    assert(shell.unread(ui, items) == 2)
    assert(shell.unread(ui, { { id = 2 } }) == 1, "removed notifications stop counting")
    ui:send("TOGGLE_CENTER")
    assert(shell.unread(ui, items) == 0, "opening the center clears the count")
    notified(ui, 3)
    assert(shell.unread(ui, items) == 0, "notifications seen in the open center are read")
    ui:send("TOGGLE_CENTER")
    ui:send { type = "TOGGLE_GROUP", app = "Mail" }
    assert(ui:context().collapsed.Mail)
    ui:send { type = "TOGGLE_GROUP", app = "Mail" }
    assert(ui:context().collapsed.Mail == nil)
  end,

  ["the bar sorts this output's workspaces and sends the shell's events"] = function(t)
    local ui = start()
    local activated
    local clock = machine.manual_scheduler()
    local workspaces = workspaces_chart.chart {
      watch = function() error("a real service ran in a test") end,
      activate = function(handle) activated = handle end,
    }:start { scheduler = clock }
    local function desk(id, name, fields)
      local workspace = { id = id, handle = "h-" .. id, name = name, can_activate = true, outputs = { "DP-1" } }
      for key, value in pairs(fields or {}) do workspace[key] = value end
      return workspace
    end
    clock.emit("watch", { type = "WORKSPACES", snapshot = { available = true, workspaces = {
      desk("ten", "10"), desk("hidden", "0", { hidden = true }), desk("named", "chat", { can_activate = false }),
      desk("two-b", "2:mail", { urgent = true }), desk("two-a", "2:code", { active = true }),
      desk("one", "1"), desk("other", "3", { outputs = { "HDMI-A-1" } }),
    } } })
    local caffeinated = true
    t:mount(function()
      return bar.content { workspaces = workspaces, output = "DP-1", time = "Thu Sep 10  04:32 PM", scheme = "light",
        open_launcher = ui:event("TOGGLE_LAUNCHER"), open_notifications = ui:event("TOGGLE_CENTER"),
        unread = 3, quiet = false, caffeinated = caffeinated, decaffeinate = ui:event("DISMISS") }
    end, { width = 1280, height = 40, padding = 0 })
    local base = "panel-background/panel-content"
    local labels = {}
    for _, key in ipairs({ "one", "two-a", "two-b", "ten", "named" }) do
      labels[#labels + 1] = t:node(base .. "/workspace-scroll/workspaces/workspace-id:" .. key).label
    end
    assert(table.concat(labels, ",") == "1,2:code,2:mail,10,chat")
    assert(not pcall(t.node, t, base .. "/workspace-scroll/workspaces/workspace-id:other"), "other outputs' workspaces are hidden")
    assert(not t:node(base .. "/workspace-scroll/workspaces/workspace-id:named").enabled)
    t:click(base .. "/workspace-scroll/workspaces/workspace-id:ten")
    assert(activated == "h-ten", "activation goes by the watch snapshot's handle")
    assert(t:node(base .. "/status/notifications").label == "Open notifications, 3 unread")
    assert(t:node(base .. "/status/clock").label == "Thu Sep 10  04:32 PM")
    t:click(base .. "/launcher")
    assert(ui:matches("launcher"))
    t:click(base .. "/status/notifications")
    assert(ui:matches("center"))
  end,
}
