local ouro = require("ouro")
local machine = ouro.machine
local M = {}

-- Headless desktop-entry catalog, loaded once. The launcher lists it and the
-- notification daemon resolves application icons from it.
--   services.list(): the installed entries (ouro.xdg.applications.list)
-- A fixed catalog for fixtures and previews: M.chart { entries = {...} }.
function M.chart(services)
  return machine.create {
    id = "catalog", initial = services.entries and "ready" or "loading",
    context = { entries = services.entries or {} },
    actors = { list = services.list or function() return services.entries end },
    states = {
      loading = { invoke = { src = "list",
        on_done = { target = "ready", actions = machine.assign { entries = function(_, e) return e.output end } },
        on_error = { target = "failed", actions = machine.assign { error = function(_, e) return tostring(e.error) end } } } },
      ready = {},
      failed = {},
    },
  }
end

M.services = { list = function() return ouro.xdg.applications.list() end }

return M
