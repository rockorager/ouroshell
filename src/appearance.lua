local ouro = require("ouro")
local scheme = ouro.signal("light")
local M = {}

function M.colors()
  return ouro.tokens[scheme()], ouro.tokens.palette[scheme()]
end

-- Custom color props are explicit overrides, so they must follow settings too.
-- Subscribe before reading; retain the last palette while reconnecting.
function M.connect()
  if not ouro.xdg.runtime_dir then return end
  ouro.spawn(function()
    local address = "unix:" .. ouro.xdg.runtime_dir .. "/ouro/settings.mcp.sock"
    local uri = "ouro://settings/appearance/color_scheme"
    local retry = 250
    while true do
      pcall(function()
        ouro.mcp.subscribe(address, uri, function(notification)
          if notification.error then error(notification.error.message) end
          if not notification.method then error("appearance subscription ended") end
          local reply = ouro.mcp.request(address, "resources/read", { uri = uri })
          if reply.error then error(reply.error.message) end
          local selection = ouro.json.decode(reply.result.contents[1].text)
          local value = selection.exists and selection.value or "default"
          assert(value == "light" or value == "dark" or value == "default", "invalid color scheme")
          scheme:set(value == "dark" and "dark" or "light")
          retry = 250
        end)
      end)
      ouro.sleep(retry)
      retry = math.min(retry * 2, 10000)
    end
  end)
end

return M
