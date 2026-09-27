local ouro = require("ouro")
local M = {}

-- The installed desktop-entry catalog. The launcher lists it and the
-- notification daemon resolves application icons from it.
function M.new(list)
  local catalog = { entries = ouro.signal({}), phase = ouro.signal("loading"), error = ouro.signal(nil) }
  function catalog.load()
    ouro.spawn(function()
      local ok, entries = pcall(list or ouro.xdg.applications.list)
      if ok then
        catalog.entries:set(entries)
        catalog.phase:set("ready")
      else
        catalog.error:set(tostring(entries))
        catalog.phase:set("error")
      end
    end)
  end
  return catalog
end

-- A preloaded catalog for fixtures and previews.
function M.fixed(entries)
  local catalog = M.new(function() return entries end)
  catalog.entries:set(entries)
  catalog.phase:set("ready")
  return catalog
end

return M
