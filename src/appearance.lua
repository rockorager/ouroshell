local ouro = require("ouro")
local support = require("dbus_support")
local machine = ouro.machine
local M = {}
local service = "org.freedesktop.portal.Desktop"
local path = "/org/freedesktop/portal/desktop"
local interface = "org.freedesktop.portal.Settings"
local namespace = "org.freedesktop.appearance"

-- Semantic tokens and palette for "light" or "dark".
function M.colors(scheme)
  scheme = scheme == "dark" and "dark" or "light"
  return ouro.tokens[scheme], ouro.tokens.palette[scheme]
end

-- A Settings-portal color-scheme value: dark (1) is dark; light (2), no
-- preference (0), missing and malformed values are light, matching Ourokit.
function M.scheme_of(value)
  return value and value.signature == "u" and value.value == 1 and "dark" or "light"
end

-- Headless: the effective scheme follows the portal; losing the portal or
-- the bus falls back to light until the session reconnects.
--   services.portal(_, send): serves one portal session (sends SCHEME, CONNECTED)
function M.chart(services)
  return machine.create {
    id = "appearance", initial = "portal",
    context = { scheme = "light", retry = support.retry },
    events = { SCHEME = { value = "string" }, CONNECTED = {} },
    actors = { portal = services.portal },
    delays = support.delays("retry"),
    actions = { fallback = machine.assign { scheme = "light" } },
    states = {
      portal = support.reconnecting { src = "portal", retry = "retry", down = "fallback",
        online = { on = {
          SCHEME = machine.set("scheme", "string"),
          CONNECTED = { actions = support.reset("retry") },
        } } },
    },
  }
end

-- Explicit color tokens must follow the same Settings portal as Ourokit.
-- Portal owner changes are followed within one connection, without polling;
-- an owner change or a newer signal supersedes an in-flight read.
function M.portal(_, send)
  local bus <close> = support.connect("session")
  local owners <close> = support.need(bus:subscribe {
    sender = "org.freedesktop.DBus", path = "/org/freedesktop/DBus",
    interface = "org.freedesktop.DBus", member = "NameOwnerChanged",
  })
  local changes <close> = support.need(bus:subscribe {
    sender = service, path = path, interface = interface, member = "SettingChanged",
  })
  send("CONNECTED")
  local owner, revision = nil, 0
  local function update(value) send { type = "SCHEME", value = M.scheme_of(value) } end
  local function refresh()
    revision = revision + 1
    local reading = revision
    local reply, failure
    repeat
      reply, failure = bus:call {
        destination = service, path = path, interface = interface,
        member = "ReadAll", signature = "as", args = { { namespace } }, timeout_ms = 5000,
      }
      -- A slow portal, for example one still starting at login, is asked
      -- again; any other failure falls back to light below.
    until reply or not failure or failure.kind ~= "timeout" or revision ~= reading
    if revision ~= reading then return end
    local value
    if reply and reply.signature == "a{sa{sv}}" and (owner == nil or reply.sender == owner) then
      owner = reply.sender
      for _, section in ipairs(reply.args[1]) do
        if section[1] == namespace then
          for _, setting in ipairs(section[2]) do
            if setting[1] == "color-scheme" then value = setting[2] end
          end
        end
      end
    end
    update(value)
  end
  -- These tasks belong to the invoke: leaving the state cancels them.
  ouro.spawn(function()
    while true do
      local message = changes:next()
      if not message then bus:close(); return end
      if message.signature == "ssv" and (owner == nil or message.sender == owner)
        and message.args[1] == namespace and message.args[2] == "color-scheme" then
        revision = revision + 1
        update(message.args[3])
      end
    end
  end)
  ouro.spawn(refresh) -- Both matches are registered before the initial read.
  while true do
    local message = support.need(owners:next())
    if message.signature == "sss" and message.args[1] == service then
      owner = message.args[3]
      revision = revision + 1
      update(nil)
      if owner ~= "" then ouro.spawn(refresh) end
    end
  end
end

M.services = { portal = M.portal }

return M
