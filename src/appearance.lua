local ouro = require("ouro")
local support = require("dbus_support")
local scheme = ouro.signal("light")
local M = {}
local service = "org.freedesktop.portal.Desktop"
local path = "/org/freedesktop/portal/desktop"
local interface = "org.freedesktop.portal.Settings"
local namespace = "org.freedesktop.appearance"

function M.colors()
  return ouro.tokens[scheme()], ouro.tokens.palette[scheme()]
end

local function update(value)
  scheme:set(value and value.signature == "u" and value.value == 1 and "dark" or "light")
end

-- Explicit color tokens must follow the same Settings portal as Ourokit.
-- Portal owner changes are followed within one connection, without polling;
-- losing the bus itself falls back to light and reconnects.
function M.connect()
  local revision = 0
  support.supervise { bus = "session", session = function(bus, healthy)
    local owners <close> = support.need(bus:subscribe {
      sender = "org.freedesktop.DBus", path = "/org/freedesktop/DBus",
      interface = "org.freedesktop.DBus", member = "NameOwnerChanged",
    })
    local changes <close> = support.need(bus:subscribe {
      sender = service, path = path, interface = interface, member = "SettingChanged",
    })
    healthy()
    local owner = nil
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
      -- A newer signal or owner supersedes an in-flight snapshot.
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
  end, down = function()
    revision = revision + 1 -- Retire reads from the lost connection.
    update(nil)
  end }
end

return M
