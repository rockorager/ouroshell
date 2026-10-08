local ouro = require("ouro")
local machine = ouro.machine
local M = {}

-- Headless desktop-entry catalog. The launcher lists it and the notification
-- daemon resolves application icons from it. It loads at startup; REFRESH
-- (the shell sends one on each launcher opening) rescans in the background.
-- A refresh keeps the cached entries in `ready` while it runs, so the open
-- launcher keeps its results and search until the new scan replaces them.
-- REFRESH during a scan is ignored, so scans never overlap. A failed refresh
-- keeps the last successful entries and records the error; the next success
-- clears it. There is no polling or filesystem watcher.
--   services.list(): the installed entries (ouro.xdg.applications.list)
-- A fixed catalog for fixtures and previews: M.chart { entries = {...} }.
function M.chart(services)
  local assign, unset = machine.assign, machine.unset
  local function scan(target, failure)
    return { src = "list",
      on_done = { target = target, actions = "listed" },
      on_error = { target = failure, actions = "failed" } }
  end
  return machine.create {
    id = "catalog", initial = services.entries and "ready" or "loading",
    context = { entries = services.entries or {} },
    events = { REFRESH = {} },
    actors = { list = services.list or function() return services.entries end },
    actions = {
      listed = assign(function(_, e) return { entries = e.output, error = unset } end),
      failed = assign { error = function(_, e) return tostring(e.error) end },
    },
    states = {
      loading = { invoke = scan("ready", "failed") },
      ready = { initial = "idle", states = {
        idle = { on = { REFRESH = "refreshing" } },
        refreshing = { invoke = scan("idle", "idle") },
      } },
      failed = { on = { REFRESH = "loading" } },
    },
  }
end

M.services = { list = function() return ouro.xdg.applications.list() end }

return M
