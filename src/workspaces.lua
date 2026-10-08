local ouro = require("ouro")
local machine = ouro.machine
local M = {}

-- Headless compositor workspaces (ext-workspace-v1). The watch invoke sends
-- each complete snapshot; activation queues a request by opaque handle.
--   services.watch(_, send): sends WORKSPACES { snapshot } for every protocol batch
--   services.activate(handle): requests activation (does not wait)
function M.chart(services)
  return machine.create {
    id = "workspaces", initial = "watching",
    context = { available = false, workspaces = {} },
    events = { WORKSPACES = { snapshot = "table" }, ACTIVATE = { handle = "string" } },
    actors = { watch = services.watch },
    actions = {
      store = machine.assign(function(_, e)
        return { available = e.snapshot.available, workspaces = e.snapshot.workspaces }
      end),
      activate = function(_, e) services.activate(e.handle) end,
      lost = machine.assign { available = false, workspaces = {} },
    },
    states = {
      watching = {
        invoke = { src = "watch", on_done = "lost", on_error = "lost" },
        on = { WORKSPACES = { actions = "store" }, ACTIVATE = { actions = "activate" } },
      },
      -- Without the protocol the bar says so; the clock still works.
      lost = { entry = "lost" },
    },
  }
end

M.services = {
  watch = function(_, send)
    local watcher <close> = ouro.shell.workspaces.watch()
    while true do send { type = "WORKSPACES", snapshot = watcher:next() } end
  end,
  activate = function(handle) ouro.shell.workspaces.activate(handle) end,
}

return M
