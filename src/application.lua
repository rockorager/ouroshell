local ouro = require("ouro")
local machine = ouro.machine
local appearance = require("appearance")
local bar = require("bar")
local battery = require("battery")
local catalog = require("catalog")
local clock = require("clock")
local launcher = require("launcher")
local lock = require("lock")
local network = require("network")
local notification_center = require("notification_center")
local notifications = require("notifications")
local overlay = require("overlay")
local session = require("session")
local shell = require("shell")
local volume = require("volume")
local workspaces = require("workspaces")

-- Every piece of shell state lives in one of these root actors. They are
-- created at load (render-safe, and what source reload carries) and started
-- in run(). Domain charts are headless: they own their D-Bus sessions and
-- native resources through invokes. `shell` holds the overlays. System ids
-- let the charts address each other (machine.system, send_to { system }).
local actors = {}
local function root(name, chart)
  actors[name] = chart:actor { id = name, system_id = name }
end
root("appearance", appearance.chart(appearance.services))
root("clock", clock.chart(clock.services))
root("battery", battery.chart(battery.services))
root("network", network.chart(network.services))
root("volume", volume.chart(volume.services))
root("workspaces", workspaces.chart(workspaces.services))
root("catalog", catalog.chart(catalog.services))
root("shell", shell.chart { launcher = launcher.chart { execute = launcher.execute() } })
root("session", session.chart(session.services))
root("notifications", notifications.chart(notifications.services))

local order = { "appearance", "clock", "battery", "network", "volume", "workspaces", "catalog", "shell", "session",
  "notifications" }

local function running(actor)
  if not actor:started() then return ouro.action_error("NotRunning", {}) end
end

-- MCP actions are chart events; production --mcp exposes only these.
local actions = machine.actions(actors.shell, {
  ["launcher.toggle"] = { event = "TOGGLE_LAUNCHER", description = "Show or dismiss the application launcher." },
  ["notifications.toggle"] = { event = "TOGGLE_CENTER", description = "Show or dismiss the notification center." },
}, { before = running })
for name, action in pairs(machine.actions(actors.volume, {
  ["volume.up"] = { event = "UP",
    description = "Raise the default output volume by five percentage points and show its level." },
  ["volume.down"] = { event = "DOWN",
    description = "Lower the default output volume by five percentage points and show its level." },
}, { before = running })) do actions[name] = action end

local function scheme() return actors.appearance:context().scheme end

-- Notification activation runs in the pressing callback: the activation
-- token needs that press's provenance, which spawned tasks do not inherit.
local function activate(item, key)
  local token = ouro.activation_token()
  if actors.notifications:send { type = "ACTIVATE", id = item.id, revision = item.revision, key = key, token = token } then
    actors.shell:send("ACTIVATED")
  end
end

local function launcher_props()
  local catalog_state = actors.catalog
  return {
    launcher = actors.shell:child("launcher"), shell = actors.shell, scheme = scheme(), current = launcher_props,
    entries = catalog_state:context().entries,
    catalog_phase = catalog_state:matches("loading") and "loading" or catalog_state:matches("failed") and "failed" or "ready",
    catalog_error = catalog_state:context().error,
    caffeinated = session.caffeinated(actors.session), status = actors.session:context().status,
  }
end

local function launcher_content(width, height)
  if not actors.shell:child("launcher") then return nil end
  return launcher.content(launcher_props(), height, width)
end

local function center_content(width, height)
  return notification_center.overlay(notification_center.content {
    notices = actors.notifications, ui = actors.shell, close = actors.shell:event("CLOSE_CENTER"),
    activate = activate, scheme = scheme(),
  }, width, height)
end

local network_snapshot = machine.selector(network.snapshot)
local lock_reads = { time = function() return actors.clock:context().time end, scheme = scheme }

return ouro.app {
  id = "dev.ouro.shell",
  actions = actions,
  run = function()
    for _, name in ipairs(order) do actors[name]:start() end
    -- A reloaded daemon lost its connection and expiry timers.
    if actors.notifications:restored() then actors.notifications:send("RESTORED") end
    local panel = ouro.layer_surface {
      id = "panel", namespace = "ouroshell-panel", outputs = "all", layer = "top",
      width = 0, height = bar.height, anchors = { "top", "left", "right" },
      exclusive_zone = bar.height, keyboard_interactivity = "none", send = actors.shell,
      content = function(output)
        local net = actors.network:context()
        return bar.content {
          workspaces = actors.workspaces, time = actors.clock:context().time, output = output, scheme = scheme(),
          open_launcher = actors.shell:event("TOGGLE_LAUNCHER"),
          open_notifications = actors.shell:event("TOGGLE_CENTER"),
          power = actors.battery:context().power, connectivity = network_snapshot(net.links, net.stations),
          volume = actors.volume, quiet = actors.notifications:context().quiet,
          unread = shell.unread(actors.shell, actors.notifications:context().items),
          caffeinated = session.caffeinated(actors.session), decaffeinate = actors.session:event("DECAFFEINATE"),
        }
      end,
    }
    -- Pure: the windows follow the session and shell charts.
    return { send = actors.shell, windows = function()
      local lock_window = lock.window(actors.session, lock_reads)
      if lock_window then return { lock_window } end
      local windows = { panel }
      if actors.shell:matches("launcher") then
        windows[#windows + 1] = ouro.layer_surface {
          id = "launcher", namespace = "ouroshell-launcher", layer = "overlay",
          width = 0, height = 0, anchors = { "top", "bottom", "left", "right" }, exclusive_zone = 0,
          background = overlay.background(), background_effect = "blur",
          keyboard_interactivity = "exclusive", send = actors.shell, content = launcher_content,
        }
      elseif actors.shell:matches("center") then
        -- Like the launcher, the backdrop covers everything but the bar, and a
        -- press outside the panel closes it.
        windows[#windows + 1] = ouro.layer_surface {
          id = "notifications", namespace = "ouroshell-notifications", layer = "overlay",
          width = 0, height = 0, anchors = { "top", "bottom", "left", "right" }, exclusive_zone = 0,
          background = overlay.background(), background_effect = "blur",
          keyboard_interactivity = "on_demand", send = actors.shell, content = center_content,
        }
      elseif actors.shell:matches("popup") then
        local c = actors.notifications:context()
        local item = not c.quiet and notifications.live(c.items, actors.shell:context().popup)
        if item then
          -- Actions share the header; native menus never enlarge the banner.
          -- Its hover holds expiry, so it reports to the daemon.
          windows[#windows + 1] = ouro.layer_surface {
            id = "notification-popup", namespace = "ouroshell-notification-popup", layer = "overlay",
            width = 420, height = 160, anchors = { "top", "right" },
            margins = { top = 56, right = 16 }, exclusive_zone = -1, keyboard_interactivity = "none",
            background = ouro.tokens.palette.transparent, send = actors.notifications,
            content = function()
              return notification_center.popup(item, { notices = actors.notifications, activate = activate, scheme = scheme() })
            end,
          }
        end
      end
      return windows
    end }
  end,
}
