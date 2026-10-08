local ouro = require("ouro")
local machine = ouro.machine
local M = { retry = 1000, max_retry = 30000 }

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

-- Opens a bus connection that closes with the calling task (an invoke).
function M.connect(bus)
  return M.need(ouro.dbus.connect(bus))
end

-- Resets the backoff stored in context[key] once a session is serving.
function M.reset(key)
  return machine.assign { [key] = M.retry }
end

-- Named `delays` for charts using M.reconnecting: each backoff waits
-- context[key] on the logical clock.
function M.delays(...)
  local delays = {}
  for _, key in ipairs({ ... }) do delays[key] = function(c) return c[key] end end
  return delays
end

-- A compound state that keeps a D-Bus session running for as long as it is
-- active. `online` invokes `options.src`, an `fn(input, send)` service that
-- serves until its connection ends; it reports with the chart's own events.
-- When it returns or raises, `offline` runs `options.down` and waits out an
-- exponential backoff: the named delay `options.retry` (declare it with
-- M.delays) reads context[options.retry], then the session reconnects. Use
-- M.reset(options.retry) on the event that shows the session is healthy.
-- Leaving the state cancels both.
--   options.online: extra fields of the online state (on, states, initial...)
--   options.max: the longest backoff (30 s by default)
function M.reconnecting(options)
  local key, limit = options.retry, options.max or M.max_retry
  local online = options.online or {}
  online.invoke = { id = options.src, src = options.src, input = options.input,
    on_done = "offline", on_error = { target = "offline", actions = options.failed } }
  return {
    initial = "online",
    states = {
      online = online,
      offline = {
        entry = options.down,
        after = { [key] = { target = "online",
          actions = machine.assign { [key] = function(c) return math.min(c[key] * 2, limit) end } } },
      },
    },
  }
end

return M
