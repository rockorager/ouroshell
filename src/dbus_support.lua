local ouro = require("ouro")
local M = {}

-- Returns `value`, or raises the D-Bus error table that came with it.
function M.need(value, failure)
  if value then return value end
  local text = failure and ((failure.name and failure.name .. ": " or "") .. (failure.message or ""))
  error(text or "D-Bus request failed", 2)
end

-- D-Bus dictionaries are ordered {key, variant} pairs, not Lua maps.
function M.variants(dictionary)
  local values = {}
  for _, pair in ipairs(dictionary) do values[pair[1]] = pair[2] end
  return values
end

function M.properties(dictionary)
  local values = {}
  for _, pair in ipairs(dictionary) do values[pair[1]] = pair[2].value end
  return values
end

-- Runs `session(bus, healthy)` on a fresh connection for the life of the
-- shell. A session ends by returning or raising, for example when a
-- close_on_owner_change stream closes or the bus drops. Each end calls
-- `down(failure)`, then reconnects after an exponential backoff that
-- `healthy()` resets once the session is serving again.
function M.supervise(options)
  local initial, limit = options.retry or 1000, options.max_retry or 30000
  ouro.spawn(function()
    local retry = initial
    while true do
      local _, failure = pcall(function()
        local bus <close> = M.need(ouro.dbus.connect(options.bus))
        options.session(bus, function() retry = initial end)
      end)
      if options.down then options.down(failure) end
      ouro.sleep(retry)
      retry = math.min(retry * 2, limit)
    end
  end)
end

return M
