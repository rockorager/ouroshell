local ouro = require("ouro")
local appearance = require("appearance")
local battery = require("battery")
local network = require("network")
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

function M.content(state, time, output, toggle_launcher, power, connectivity)
  local theme, palette = appearance.colors()
  local colors = {
    foreground = theme.sidebar_foreground, muted = theme.muted_foreground,
    hover = theme.sidebar_accent, selected = theme.accent_selected,
    selected_hover = palette.indigo.step_6, urgent = palette.red.step_11,
    transparent = ouro.tokens.palette.transparent,
  }
  local visible = {}
  local occurrences = {}
  if state.available then
    for index, workspace in ipairs(state.workspaces) do
      local key = "index:" .. index
      if workspace.id then
        -- Ouro currently repeats identifiers across output workspace groups.
        local occurrence = (occurrences[workspace.id] or 0) + 1
        occurrences[workspace.id] = occurrence
        key = "id:" .. occurrence .. ":" .. workspace.id
      end
      if not workspace.hidden and belongs_to_output(workspace, output) then
        visible[#visible + 1] = {
          workspace = workspace,
          key = key,
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
  if connectivity then status[#status + 1] = network.content(connectivity) end
  if power then status[#status + 1] = battery.content(power) end
  status[#status + 1] = ouro.text { key = "clock", text = time, size = f.typography_3, max_lines = 1 }

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
            on_press = toggle_launcher, children = {
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
          ouro.row { key = "status", gap = f.spacing_4, cross_alignment = "center", children = status },
        },
      },
    },
  }
end

return M
