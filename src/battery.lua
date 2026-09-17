local ouro = require("ouro")
local appearance = require("appearance")
local f = ouro.tokens.foundation
local M = {}
local service = "org.freedesktop.UPower"
local device_interface = service .. ".Device"

function M.snapshot(properties)
  local values = {}
  -- D-Bus dictionaries are ordered key/variant pairs, not Lua maps.
  for _, pair in ipairs(properties) do values[pair[1]] = pair[2].value end
  local percentage = values.Percentage
  if not values.IsPresent or (values.Type ~= 2 and values.Type ~= 3)
    or type(percentage) ~= "number" or percentage ~= percentage or percentage < 0 or percentage > 100 then
    return nil
  end
  return {
    percentage = math.floor(percentage + 0.5),
    icon = values.IconName ~= "" and values.IconName or "battery-missing-symbolic",
    charging = values.State == 1 or values.State == 5,
    low = (values.WarningLevel or 0) >= 3,
  }
end

function M.connect()
  local state = ouro.signal(nil)
  ouro.spawn(function()
    local retry = 1000
    while true do
      pcall(function()
        local connection, failure = ouro.dbus.connect("system")
        assert(connection, failure and failure.message)
        local bus <close> = connection
        local owner_stream, owner_error = bus:subscribe {
          sender = "org.freedesktop.DBus", path = "/org/freedesktop/DBus",
          interface = "org.freedesktop.DBus", member = "NameOwnerChanged",
        }
        assert(owner_stream, owner_error and owner_error.message)
        local owners <close> = owner_stream
        ouro.spawn(function()
          while true do
            local message = owners:next()
            if not message then bus:close(); return end
            if message.args[1] == service and message.args[2] ~= "" then
              bus:close() -- Wake the property listener and reconnect to the new owner.
              return
            end
          end
        end)
        local reply, err = bus:call {
          destination = service, path = "/org/freedesktop/UPower", interface = service,
          member = "GetDisplayDevice", signature = "", args = {}, timeout_ms = 5000,
        }
        assert(reply, err and err.message)
        local path = reply.args[1]
        local stream, stream_error = bus:subscribe {
          sender = service, path = path, interface = "org.freedesktop.DBus.Properties", member = "PropertiesChanged",
        }
        assert(stream, stream_error and stream_error.message)
        local changes <close> = stream
        local function refresh()
          local current, read_error = bus:call {
            destination = service, path = path, interface = "org.freedesktop.DBus.Properties",
            member = "GetAll", signature = "s", args = { device_interface }, timeout_ms = 5000,
          }
          assert(current, read_error and read_error.message)
          state:set(M.snapshot(current.args[1]))
          retry = 1000
        end
        refresh() -- Match registration precedes the snapshot so no update is lost.
        while true do
          local message, next_error = changes:next()
          assert(message, next_error and next_error.message)
          if message.args[1] == device_interface then refresh() end
        end
      end)
      state:set(nil)
      ouro.sleep(retry)
      retry = math.min(retry * 2, 30000)
    end
  end)
  return state
end

function M.content(state)
  if not state then return nil end
  local theme, palette = appearance.colors()
  local color = state.low and palette.red.step_11 or theme.sidebar_foreground
  return ouro.row { key = "battery", gap = f.spacing_1, cross_alignment = "center", children = {
    ouro.xdg.icon { key = "icon", name = state.icon, theme = "Adwaita",
      width = f.spacing_4, height = f.spacing_4, tint = color,
      alt = state.charging and "Battery charging" or "Battery" },
    ouro.text { key = "percentage", text = state.percentage .. "%", foreground = color, size = f.typography_3, max_lines = 1 },
  } }
end

return M
