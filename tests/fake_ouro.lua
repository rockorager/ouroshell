-- Shared stand-in for Ourokit's Lua API, installed as the `ouro` module.
-- Widgets return their props tagged with `kind`, signals are getter/setter
-- cells, and components render once per call. Tests override the runtime
-- behavior they exercise (tasks, time, D-Bus, tokens) through `overrides`.
local M = {}

function M.signal(value)
  return setmetatable({ set = function(_, next_value) value = next_value end }, { __call = function() return value end })
end

local widgets = { "app", "layer_surface", "box", "row", "column", "stack", "scroll", "virtual_list",
  "text", "text_input", "button", "switch", "image" }

function M.install(overrides)
  local ouro = {
    json = { null = {} }, xdg = { runtime_dir = "/run/user/42", applications = {} },
    dbus = {}, mcp = {}, shell = {},
    tokens = {
      foundation = setmetatable({}, { __index = function() return 16 end }),
      palette = { transparent = "#00000000" },
    },
    signal = M.signal,
    component = function(initialize) return function(props) return initialize(props)() end end,
    spawn = function() error("test did not expect ouro.spawn") end,
    sleep = function() error("test did not expect ouro.sleep") end,
    time = function() return 0 end,
    date = function() return "time" end,
  }
  for _, kind in ipairs(widgets) do
    ouro[kind] = function(props) props.kind = kind; return props end
  end
  ouro.xdg.icon = function(props) props.kind = "icon"; return props end
  for key, value in pairs(overrides or {}) do ouro[key] = value end
  package.loaded.ouro = ouro
  return ouro
end

return M
