local ouro = require("ouro")

local M = { height = 40 }

-- Radix gray/blue/red roles for the shell's dark workspace controls.
local colors = {
  foreground = "#EDEEF0",
  muted = "#B0B4BA",
  hover = "#2B2D31",
  accent = "#8ABCF0",
  background = "#19212A",
  urgent = "#FF9592",
  transparent = "#00000000",
}

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

function M.content(state, time, output, toggle_launcher)
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
    items[#items + 1] = ouro.button {
      key = "workspace-" .. item.key,
      label = workspace.name,
      enabled = workspace.can_activate,
      height = 40,
      padding_x = 10,
      radius = 0,
      font_size = ouro.tokens.foundation.typography_3,
      background = colors.transparent,
      foreground = foreground,
      hover = colors.hover,
      disabled = colors.transparent,
      disabled_foreground = foreground,
      on_press = workspace.can_activate and not workspace.active and workspace.activate or nil,
      children = { ouro.column { key = "workspace", gap = 0, children = {
        ouro.box { key = "label", height = 38, alignment = "center", children = {
          ouro.text { key = "name", text = workspace.name, size = ouro.tokens.foundation.typography_3,
            foreground = foreground, max_lines = 1 },
        } },
        ouro.box { key = "indicator", width = "fill", height = 2,
          background = workspace.active and colors.accent or colors.transparent },
      } } },
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

  return ouro.box {
    key = "panel-background",
    width = "fill",
    height = "fill",
    background = colors.background,
    alignment = "center",
    children = {
      ouro.row {
        key = "panel-content",
        gap = 12,
        cross_alignment = "center",
        children = {
          ouro.button { key = "launcher", label = "Open launcher", height = 40, padding_x = 16, radius = 0,
            background = colors.transparent, foreground = colors.muted, hover = colors.hover,
            on_press = toggle_launcher, children = {
              ouro.text { key = "mark", text = "●", size = 17, foreground = colors.muted },
            } },
          ouro.scroll {
            key = "workspace-scroll",
            axis = "horizontal",
            flex = 1,
            children = {
              ouro.row { key = "workspaces", gap = 4, children = items },
            },
          },
          ouro.text { key = "clock", text = time, size = ouro.tokens.foundation.typography_3, max_lines = 1 },
          ouro.box { key = "end-padding", width = 4 },
        },
      },
    },
  }
end

return M
