local ouro = require("ouro")
local appearance = require("appearance")
local config = require("config")
local f = ouro.tokens.foundation
local M = {}

local function percentage(snapshot)
  return math.floor(snapshot.volume * 100 + 0.5)
end

function M.new(output)
  local state = { output = output, shown = ouro.signal(false), error = ouro.signal(nil) }
  local previous, remaining, running = nil, 0, false

  function state.dismiss()
    remaining = 0
    state.shown:set(false)
  end

  function state.show()
    remaining = 15
    state.shown:set(true)
    if running then return end
    running = true
    -- One bounded timer, even under key repeat. This never polls the audio
    -- backend; its stream supplies confirmed volume and mute changes.
    ouro.spawn_app(function()
      while remaining > 0 do
        ouro.sleep(100)
        remaining = remaining - 1
      end
      running = false
      state.shown:set(false)
    end)
  end

  function state.observe(current)
    state.error:set(current.error)
    if not current.available or not previous or not previous.available
      or current.identity ~= previous.identity then
      -- Initial connection, reconnect and device replacement are not volume
      -- adjustments. Never flash a startup OSD or keep an old device's popup.
      state.dismiss()
    elseif percentage(current) ~= percentage(previous) or current.muted ~= previous.muted then
      state.show()
    end
    previous = current
  end

  function state.adjust(delta)
    local ok, failure = output:adjust_volume(delta)
    state.error:set(failure)
    if ok then state.show() end -- Also show at the 0%/100% limits.
    return ok, failure
  end

  return state
end

function M.connect()
  local output = assert(ouro.audio.default_output())
  local state = M.new(output)
  ouro.spawn(function()
    while true do
      local current = output:next()
      if not current then state.dismiss(); return end
      state.observe(current)
    end
  end)
  return state
end

local function description(snapshot)
  local text, icon = "Audio unavailable", "audio-volume-muted-symbolic"
  if snapshot.available then
    local value = percentage(snapshot)
    text = snapshot.muted and ("Muted (" .. value .. "%)") or ("Volume: " .. value .. "%")
    if not snapshot.muted then
      icon = "audio-volume-" .. (value == 0 and "muted" or value <= 33 and "low"
        or value <= 66 and "medium" or "high") .. "-symbolic"
    end
  end
  return text, icon
end

local function icon(key, name, color, alt)
  return ouro.xdg.icon { key = key, name = name, theme = config.icon_theme,
    width = f.spacing_4, height = f.spacing_4, tint = color, alt = alt or "" }
end

function M.popup(state)
  local snapshot = state.output()
  local theme, palette = appearance.colors()
  local failure = state.error() or snapshot.error
  local name = snapshot.description or snapshot.name or "Audio output"
  local value = snapshot.available and not snapshot.muted and math.min(100, percentage(snapshot)) or 0
  return ouro.box { key = "volume-card", width = "fill", height = "fill",
    surface = "sidebar", radius = f.radius_4, padding = f.spacing_3,
    border_width = f.border_width_default, border = theme.border,
    children = {
      ouro.column { key = "layout", gap = f.spacing_2, cross_alignment = "stretch", children = {
        ouro.text { key = "device", text = failure or name, max_lines = 1, size = f.typography_2,
          weight = "medium", foreground = failure and palette.red.step_11 or theme.muted_foreground },
        ouro.row { key = "controls", gap = f.spacing_2, cross_alignment = "center", children = {
          icon("quiet", "audio-volume-muted-symbolic", theme.muted_foreground),
          ouro.box { key = "level", label = "Volume level, " .. value .. "%", flex = 1,
            height = f.spacing_4, alignment = "center", children = {
              ouro.box { key = "track", width = "fill", height = 6, radius = 3,
                background = theme.switch_track, semantic = false, children = {
                  ouro.row { key = "rail", gap = 0, children = {
                    ouro.box { key = "fill", width = 0, height = 6, radius = 3,
                      flex = value > 0 and value or nil, background = theme.primary, semantic = false },
                    ouro.box { key = "remaining", width = 0, height = 6,
                      flex = value < 100 and 100 - value or nil, semantic = false },
                  } },
                } },
            } },
          icon("loud", "audio-volume-high-symbolic", theme.muted_foreground),
        } },
      } },
    },
  }
end

local indicator = ouro.stateful(function(props)
  -- Interaction is per mounted bar, so hovering one output does not pin the
  -- popups on every other output. Key-change feedback is shared.
  local active = ouro.signal(false)
  return function(next_props)
    props = next_props or props
    local state = props.state
    local snapshot = state.output()
    local theme = appearance.colors()
    local text, name = description(snapshot)
    return ouro.popover { key = "volume", width = 320, height = 72, side = "bottom", gap = 16,
      interactive = false, open = snapshot.available and (state.shown() or active()),
      on_interaction_change = function(value) active:set(value) end,
      on_close = function()
        active:set(false)
        state.dismiss()
      end,
      content = function() return M.popup(state) end,
      children = { icon("icon", name,
        snapshot.available and theme.sidebar_foreground or theme.muted_foreground, text) },
    }
  end
end)

function M.content(state)
  -- Replacing the default device must also retire hover on the old one.
  return indicator { key = "volume-" .. tostring(state.output().identity), state = state }
end

return M
