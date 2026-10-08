local ouro = require("ouro")
local machine = ouro.machine
local assign, unset = machine.assign, machine.unset
local M = {}

-- The shell's presentation state. The launcher, the notification center and
-- a notification popup are mutually exclusive overlays: `overlay` names the
-- one showing. The launcher's own state is a child chart spawned on each
-- opening and stopped on closing. Context keeps which notifications arrived
-- since the center was last opened (`unseen`) and which app groups the
-- center has collapsed. A notification never replaces the launcher or the
-- open center; it stays in history instead.
--   launcher: the launcher chart
function M.chart(options)
  local spawn_launcher = machine.spawn(options.launcher, { id = "launcher" })
  local see = assign { unseen = {} }
  return machine.create {
    id = "shell", initial = "none",
    context = { unseen = {}, collapsed = {} },
    events = {
      TOGGLE_LAUNCHER = {}, TOGGLE_CENTER = {}, CLOSE_CENTER = {}, DISMISS = {}, ACTIVATED = {},
      NOTIFIED = { id = "integer", replaced = "boolean", quiet = "boolean" },
      TOGGLE_GROUP = { app = "string" },
    },
    guards = {
      popup = function(_, e) return not e.quiet end,
      fresh = function(_, e) return not e.replaced end,
    },
    actions = {
      unseen = assign { unseen = function(c, e)
        if e.replaced then return c.unseen end
        local unseen = machine.plain(c.unseen)
        unseen[e.id] = true
        return unseen
      end },
      popup = assign { popup = function(_, e) return e.id end },
      toggle_group = assign { collapsed = function(c, e)
        local collapsed = machine.plain(c.collapsed)
        collapsed[e.app] = not collapsed[e.app] or nil
        return collapsed
      end },
      forget_popup = assign { popup = unset },
    },
    on = {
      TOGGLE_GROUP = { actions = "toggle_group" },
      -- Bound surfaces report back; the overlays handle what matters to them.
      ["surface.*"] = {},
    },
    states = {
      none = { on = {
        TOGGLE_LAUNCHER = "launcher",
        TOGGLE_CENTER = { target = "center", actions = see },
        NOTIFIED = { { guard = "popup", target = "popup", actions = { "unseen", "popup" } }, { actions = "unseen" } },
      } },
      launcher = { entry = spawn_launcher, exit = machine.stop("launcher"),
        on = {
          TOGGLE_LAUNCHER = "none", DISMISS = "none",
          TOGGLE_CENTER = { target = "center", actions = see },
          NOTIFIED = { actions = "unseen" },
          -- Success or Escape finished the launcher.
          ["done.actor.launcher"] = "none",
          ["surface.close_requested.launcher"] = "none",
          ["surface.failed.launcher"] = "none",
        } },
      center = { on = {
        TOGGLE_CENTER = "none", CLOSE_CENTER = "none", DISMISS = "none", ACTIVATED = "none",
        TOGGLE_LAUNCHER = "launcher",
        ["surface.close_requested.notifications"] = "none",
        ["surface.failed.notifications"] = "none",
      } },
      popup = { exit = "forget_popup",
        on = {
          TOGGLE_LAUNCHER = "launcher",
          TOGGLE_CENTER = { target = "center", actions = see },
          DISMISS = "none", ACTIVATED = "none",
          NOTIFIED = { { guard = "popup", actions = { "unseen", "popup" } }, { actions = "unseen" } },
        } },
    },
  }
end

-- Notifications that arrived since the center was last opened and are
-- still in history.
function M.unread(shell, items)
  local count, unseen = 0, shell:context().unseen
  for _, item in ipairs(items) do
    if unseen[item.id] then count = count + 1 end
  end
  return count
end

return M
