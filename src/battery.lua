local ouro = require("ouro")
local appearance = require("appearance")
local config = require("config")
local support = require("dbus_support")
local f = ouro.tokens.foundation
local machine = ouro.machine
local M = {}
local service = "org.freedesktop.UPower"
local device_interface = service .. ".Device"

function M.snapshot(properties)
  local values = support.properties(properties)
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

-- Headless UPower display-device state: `power` is a snapshot from
-- M.snapshot, or nil while absent or disconnected.
--   services.upower(_, send): serves one UPower session (sends POWER)
function M.chart(services)
  return machine.create {
    id = "battery", initial = "upower",
    context = { retry = support.retry },
    events = { POWER = { power = "table?" } },
    actors = { upower = services.upower },
    delays = support.delays("retry"),
    actions = {
      store = machine.assign(function(_, e) return { power = e.power or machine.unset, retry = support.retry } end),
      lost = machine.assign { power = machine.unset },
    },
    states = {
      upower = support.reconnecting { src = "upower", retry = "retry", down = "lost",
        online = { on = { POWER = { actions = "store" } } } },
    },
  }
end

-- One UPower session over `connect(bus)` (support.connect, or a fake in
-- tests). A UPower restart closes the stream, ending the session.
function M.make_services(connect)
  local services = {}
  function services.upower(_, send)
    local bus <close> = connect("system")
    local path = support.need(bus:call {
      destination = service, path = "/org/freedesktop/UPower", interface = service,
      member = "GetDisplayDevice", signature = "", args = {}, timeout_ms = 5000,
    }).args[1]
    local changes <close> = support.need(bus:subscribe {
      sender = service, path = path, interface = "org.freedesktop.DBus.Properties",
      member = "PropertiesChanged", close_on_owner_change = true,
    })
    local function refresh()
      local current = support.need(bus:call {
        destination = service, path = path, interface = "org.freedesktop.DBus.Properties",
        member = "GetAll", signature = "s", args = { device_interface }, timeout_ms = 5000,
      })
      send { type = "POWER", power = M.snapshot(current.args[1]) }
    end
    refresh() -- Match registration precedes the snapshot so no update is lost.
    while true do
      local message = support.need(changes:next())
      if message.signature == "sa{sv}as" and message.args[1] == device_interface then refresh() end
    end
  end
  return services
end

M.services = M.make_services(support.connect)

function M.content(state, scheme)
  if not state then return nil end
  local theme, palette = appearance.colors(scheme)
  local color = state.low and palette.red.step_11 or theme.sidebar_foreground
  return ouro.row { key = "battery", gap = f.spacing_1, cross_alignment = "center", children = {
    ouro.xdg.icon { key = "icon", name = state.icon, theme = config.icon_theme,
      width = f.spacing_4, height = f.spacing_4, tint = color,
      alt = state.charging and "Battery charging" or "Battery" },
    ouro.text { key = "percentage", text = state.percentage .. "%", foreground = color, size = f.typography_3, max_lines = 1 },
  } }
end

return M
