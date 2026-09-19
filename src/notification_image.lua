local ouro = require("ouro")
local M = {}

local function from_path(value)
  if value == "" or #value > 4096 or value:find("\0", 1, true) then return end
  if value:sub(1, 7) == "file://" then
    value = value:sub(8)
    if value:sub(1, 10) == "localhost/" then value = value:sub(10) end
    if value:sub(1, 1) ~= "/" or value:find("[?#]") then return end
    if value:gsub("%%[%x][%x]", ""):find("%%") then return end
    value = value:gsub("%%([%x][%x])", function(hex) return string.char(tonumber(hex, 16)) end)
    if value:find("\0", 1, true) then return end
  end
  if value:sub(1, 1) == "/" then
    local bytes = ouro.images.load { path = value }
    if bytes then return { bytes = bytes } end
  elseif not value:find("[/:]") then
    return { name = value }
  end
end

local function from_data(hint)
  if not hint or hint.signature ~= "(iiibiiay)" then return end
  local data = hint.value
  local bytes = ouro.images.load {
    width = data[1], height = data[2], rowstride = data[3], has_alpha = data[4],
    bits_per_sample = data[5], channels = data[6], data = data[7],
  }
  if bytes then return { bytes = bytes } end
end

-- Import before replying to Notify: senders can delete their temporary image
-- as soon as the notification closes. History owns the resulting thumbnail.
function M.load(hints, app_icon)
  local values = {}
  for _, pair in ipairs(hints) do values[pair[1]] = pair[2] end
  for _, key in ipairs({ "image-data", "image_data" }) do
    local image = from_data(values[key])
    if image then return image end
  end
  for _, key in ipairs({ "image-path", "image_path" }) do
    local hint = values[key]
    if hint and hint.signature == "s" then
      local image = from_path(hint.value)
      if image then return image end
    end
  end
  return from_path(app_icon or "") or from_data(values.icon_data)
end

return M
