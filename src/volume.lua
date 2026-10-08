local ouro = require("ouro")
local appearance = require("appearance")
local config = require("config")
local f = ouro.tokens.foundation
local machine = ouro.machine
local M = {}

local function percentage(snapshot)
  return math.floor(snapshot.volume * 100 + 0.5)
end

local function replaced(previous, current)
  return not current.available or not previous or not previous.available or current.identity ~= previous.identity
end

local function adjusted(previous, current)
  return percentage(current) ~= percentage(previous) or current.muted ~= previous.muted
end

-- Headless default-output state. `output` is the latest confirmed snapshot;
-- the feedback region shows the level for about 1.5 s after a confirmed
-- volume or mute change, or a key-driven request (also at the 0%/100%
-- limits). Initial connection, reconnect and device replacement are not
-- adjustments, so they never flash it and retire an old device's popup.
--   services.follow(_, send): owns the output handle (sends CONNECTED, OUTPUT)
--   services.adjust({ handle, delta }): requests a serialized volume step
-- The handle is a transient context field: inspected as a marker, never
-- persisted; a restored actor's follow invoke connects again.
function M.chart(services)
  local assign, unset = machine.assign, machine.unset
  return machine.create {
    id = "volume", type = "parallel", order = { "pipewire", "feedback" },
    context = { output = { available = false } },
    transient = { "handle" },
    events = {
      CONNECTED = { handle = "any" }, OUTPUT = { output = "table" },
      UP = {}, DOWN = {}, DISMISS = {},
    },
    actors = { follow = services.follow, adjust = services.adjust },
    guards = {
      ready = function(c) return c.handle ~= nil end,
      replaced = function(c, e) return e.output ~= nil and replaced(c.output, e.output) end,
      adjusted = function(c, e) return e.output ~= nil and adjusted(c.output, e.output) end,
    },
    actions = {
      connected = assign { handle = function(_, e) return e.handle end },
      observe = assign(function(_, e) return { output = e.output, error = e.output.error or unset } end),
      closed = assign { handle = unset, output = { available = false } },
      failed = assign { error = function(_, e) return tostring(e.error) end },
    },
    states = {
      pipewire = { initial = "following", states = {
        following = {
          invoke = { src = "follow", on_done = "closed", on_error = { target = "closed", actions = "failed" } },
          on = {
            CONNECTED = { actions = "connected" },
            OUTPUT = { actions = "observe" },
            UP = { guard = "ready", actions = machine.spawn("adjust", { input = function(c) return { handle = c.handle, delta = 0.05 } end }) },
            DOWN = { guard = "ready", actions = machine.spawn("adjust", { input = function(c) return { handle = c.handle, delta = -0.05 } end }) },
            ["error.actor.*"] = { actions = "failed" },
            ["done.actor.*"] = {},
          },
        },
        closed = { entry = "closed" },
      } },
      feedback = { initial = "hidden",
        on = {
          OUTPUT = { { guard = "replaced", target = ".hidden" }, { guard = "adjusted", target = ".shown" } },
          UP = { guard = "ready", target = ".shown" },
          DOWN = { guard = "ready", target = ".shown" },
        },
        states = {
          hidden = {},
          shown = { after = { [1500] = "hidden" }, on = { DISMISS = "hidden" } },
        } },
    },
  }
end

M.services = {
  follow = function(_, send)
    local output <close> = assert(ouro.audio.default_output())
    send { type = "CONNECTED", handle = output }
    while true do
      local current = output:next()
      if not current then return end
      send { type = "OUTPUT", output = current }
    end
  end,
  adjust = function(request)
    local ok, failure = request.handle:adjust_volume(request.delta)
    if not ok then error(failure, 0) end
  end,
}

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

function M.popup(volume, scheme)
  local c = volume:context()
  local snapshot = c.output
  local theme, palette = appearance.colors(scheme)
  local failure = c.error
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

-- Hover is per mounted bar, so hovering one output does not pin the popups on
-- every other output. Key-change feedback (the volume chart) is shared.
local indicator = machine.component(machine.create {
  id = "volume-indicator", initial = "idle",
  context = { active = false },
  events = { ACTIVE = { value = "boolean" }, CLOSED = {} },
  states = { idle = { on = {
    ACTIVE = machine.set("active", "boolean"),
    CLOSED = { actions = machine.assign { active = false } },
  } } },
}, function(self, props)
  local volume, scheme = props.volume, props.scheme
  local snapshot = volume:context().output
  local theme = appearance.colors(scheme)
  local text, name = description(snapshot)
  return ouro.popover { key = "volume", width = 320, height = 72, side = "bottom", gap = 16,
    interactive = false,
    open = snapshot.available and (volume:matches("feedback.shown") or self:context().active),
    on_interaction_change = self:event("ACTIVE"),
    -- The popover closed itself (for example at a screen edge): forget both
    -- the hover and the shared feedback.
    on_close = { self:event("CLOSED"), volume:event("DISMISS") },
    content = function() return M.popup(volume, scheme) end,
    children = { icon("icon", name,
      snapshot.available and theme.sidebar_foreground or theme.muted_foreground, text) },
  }
end)

function M.content(volume, scheme)
  -- Replacing the default device must also retire hover on the old one.
  return indicator { key = "volume-" .. tostring(volume:context().output.identity), volume = volume, scheme = scheme }
end

return M
