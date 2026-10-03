local ouro = require("ouro")
local appearance = require("appearance")
local battery = require("battery")
local config = require("config")
local network = require("network")
local volume = require("volume")
local f = ouro.tokens.foundation

local M = { height = 40 }

local function workspace_less(left, right)
  local a, b = left.workspace.name, right.workspace.name
  local an, bn = tonumber(a:match("^%d+")), tonumber(b:match("^%d+"))
  if an and bn and an ~= bn then return an < bn end
  if an and not bn then return true end
  if bn and not an then return false end
  if a ~= b then return a < b end
  return left.key < right.key
end

local function belongs_to_output(workspace, output)
  if output == nil then return true end -- Unfiltered visual fixtures.
  for _, name in ipairs(workspace.outputs or {}) do
    if name == output then return true end
  end
  return false
end

-- props.workspaces: workspace state from ouro.shell.workspaces
-- props.time: formatted clock text
-- props.output: output name to filter workspaces, or nil for fixtures
-- props.open_launcher, props.open_notifications: optional button handlers
-- props.power, props.connectivity: optional battery and network snapshots
-- props.audio: optional volume state
-- props.quiet: whether Do Not Disturb is on
-- props.unread: notifications that arrived since history was last opened
-- props.caffeinated, props.decaffeinate: idle-inhibitor state and its release
function M.content(props)
  local state, output = props.workspaces, props.output
  local theme, palette = appearance.colors()
  local colors = {
    foreground = theme.sidebar_foreground, muted = theme.muted_foreground,
    hover = theme.sidebar_accent, selected = theme.accent_selected,
    selected_hover = palette.indigo.step_6, urgent = palette.red.step_11, accent = theme.primary,
    transparent = ouro.tokens.palette.transparent,
  }
  local visible = {}
  if state.available then
    for index, workspace in ipairs(state.workspaces) do
      if not workspace.hidden and belongs_to_output(workspace, output) then
        visible[#visible + 1] = {
          workspace = workspace,
          -- ext-workspace-v1 identifiers are unique and immutable when sent.
          key = workspace.id and "id:" .. workspace.id or "index:" .. index,
        }
      end
    end
  end
  table.sort(visible, workspace_less)

  local items = {}
  for _, item in ipairs(visible) do
    local workspace = item.workspace
    local foreground = workspace.urgent and colors.urgent
      or workspace.active and colors.foreground or colors.muted
    local background = workspace.active and colors.selected or colors.transparent
    items[#items + 1] = ouro.button {
      key = "workspace-" .. item.key,
      label = workspace.name,
      enabled = workspace.can_activate,
      background = background,
      foreground = foreground,
      hover = workspace.active and colors.selected_hover or colors.hover,
      disabled = background,
      disabled_foreground = foreground,
      on_press = workspace.can_activate and not workspace.active and workspace.activate or nil,
    }
  end
  if #items == 0 then
    items[1] = ouro.text {
      key = "workspace-status",
      text = state.available and "No workspaces" or "Workspaces unavailable",
      foreground = colors.muted,
      max_lines = 1,
    }
  end

  local status = {}
  if props.caffeinated then
    -- Automatic locking is off; keep that visible and one click from undone.
    local description = "Caffeinated: automatic lock and sleep are paused. Click to resume."
    status[#status + 1] = ouro.tooltip { key = "caffeine", text = description, gap = 16, children = {
      ouro.button { key = "decaffeinate", label = description, padding_x = f.spacing_2,
        background = colors.transparent, foreground = colors.foreground, hover = colors.hover,
        on_press = props.decaffeinate, children = {
          ouro.xdg.icon { key = "icon", name = "alarm-symbolic", theme = config.icon_theme,
            tint = colors.foreground, width = f.spacing_4, height = f.spacing_4, alt = "" },
        } },
    } }
  end
  if props.connectivity then
    -- Match the visible gap contributed by the bell's horizontal padding.
    status[#status + 1] = ouro.box { key = "network-spacing",
      padding_right = (props.audio or props.power) and f.spacing_2 or 0,
      children = { network.content(props.connectivity) },
    }
  end
  if props.audio then
    status[#status + 1] = ouro.box { key = "volume-spacing",
      padding_right = props.power and f.spacing_2 or 0,
      children = { volume.content(props.audio) },
    }
  end
  if props.power then status[#status + 1] = battery.content(props.power) end
  if props.open_notifications then
    local unread = props.unread or 0
    local bell = {
      ouro.xdg.icon { key = "bell", name = props.quiet and "notifications-disabled-symbolic" or "preferences-system-notifications-symbolic",
        theme = config.icon_theme, tint = colors.foreground, width = f.spacing_4, height = f.spacing_4 },
    }
    if unread > 0 then
      bell[2] = ouro.text { key = "unread", text = unread > 99 and "99+" or tostring(unread),
        size = f.typography_2, foreground = colors.accent, max_lines = 1 }
    end
    status[#status + 1] = ouro.button { key = "notifications",
      label = unread > 0 and ("Open notifications, " .. unread .. " unread") or "Open notifications",
      padding_x = f.spacing_2,
      background = colors.transparent, foreground = colors.foreground, hover = colors.hover,
      on_press = props.open_notifications, children = {
        ouro.row { key = "content", gap = f.spacing_1, cross_alignment = "center", children = bell },
      } }
  end
  status[#status + 1] = ouro.text { key = "clock", text = props.time, size = f.typography_3, max_lines = 1 }

  return ouro.box {
    key = "panel-background",
    width = "fill",
    height = "fill",
    surface = "sidebar",
    padding = f.spacing_1,
    alignment = "center",
    children = {
      ouro.row {
        key = "panel-content",
        gap = f.spacing_1,
        cross_alignment = "center",
        children = {
          ouro.button { key = "launcher", label = "Open launcher",
            background = colors.transparent, foreground = colors.muted, hover = colors.hover,
            on_press = props.open_launcher, children = {
              ouro.text { key = "mark", text = "●", foreground = colors.muted },
            } },
          ouro.scroll {
            key = "workspace-scroll",
            axis = "horizontal",
            flex = 1,
            children = {
              ouro.row { key = "workspaces", gap = f.spacing_1, children = items },
            },
          },
          ouro.row { key = "status", gap = f.spacing_2, cross_alignment = "center", children = status },
        },
      },
    },
  }
end

return M
