package.path = "src/?.lua;" .. package.path
local calls = {}
package.loaded.ouro = { images = { load = function(options)
  calls[#calls + 1] = options
  if options.path == "/tmp/site icon.png" then return "path-png" end
  if options.data == "legacy" then return "legacy-png" end
  if options.data == "raw" then
    assert(options.width == 3 and options.height == 2 and options.rowstride == 16)
    assert(options.has_alpha and options.bits_per_sample == 8 and options.channels == 4)
    return "raw-png"
  end
end } }
local image = require("notification_image")
local function hint(key, value, signature)
  return { key, { signature = signature or "s", value = value } }
end
local raw = hint("image-data", { 3, 2, 16, true, 8, 4, "raw" }, "(iiibiiay)")
local path = hint("image-path", "file:///tmp/site%20icon.png")
local legacy = hint("icon_data", { 1, 1, 3, false, 8, 3, "legacy" }, "(iiibiiay)")
assert(image.load({ path, raw }).bytes == "raw-png" and #calls == 1)
assert(image.load({ raw, path }).bytes == "raw-png")
assert(image.load({ hint("image_data", raw[2].value, "(iiibiiay)") }).bytes == "raw-png")
assert(image.load({ hint("image_data", { 1, 1, 3, false, 8, 3, "wrong" }, "(iiibiiay)"), raw }).bytes == "raw-png")
assert(image.load({ hint("image-data", "bad signature"), path }).bytes == "path-png")
assert(image.load({ hint("image-data", { 1, 1, 3, false, 8, 3, "invalid" }, "(iiibiiay)"), path }).bytes == "path-png")
assert(image.load({ hint("image_path", "wrong-name"), path }).bytes == "path-png")
assert(image.load({ path, hint("image_path", "wrong-name") }).bytes == "path-png")
assert(image.load({ hint("image-path", "/missing"), hint("image_path", "/tmp/site icon.png") }).bytes == "path-png")
assert(image.load({ hint("image-path", "file://localhost/tmp/site%20icon.png") }).bytes == "path-png")
assert(image.load({ hint("image_path", "folder-symbolic") }).name == "folder-symbolic")
assert(image.load({ legacy, path, raw }, "browser").bytes == "raw-png")
assert(image.load({ legacy, path }, "browser").bytes == "path-png")
assert(image.load({ legacy }, "browser").name == "browser", "app_icon must precede icon_data")
assert(image.load({ legacy }, "file:///tmp/site%20icon.png").bytes == "path-png")
assert(image.load({}, "/tmp/site icon.png").bytes == "path-png")
assert(image.load({ legacy }, "").bytes == "legacy-png")
assert(image.load({ legacy }, "/missing").bytes == "legacy-png")
assert(image.load({ hint("icon_data", "wrong type") }, "") == nil)
assert(image.load({}) == nil)
for _, bad in ipairs({ "", "https://example.com/a.png", "file://remote/tmp/a.png", "file:///tmp/%00.png",
  "file:///tmp/%zz.png", "file:///tmp/%2.png", "file:///tmp/a.png?query", "file:///tmp/a.png#fragment",
  "relative/a.png", "\0", string.rep("a", 4097) }) do
  local before = #calls
  assert(image.load({ hint("image-path", bad) }) == nil, bad)
  assert(#calls == before, "invalid URI reached native loader")
end
image.load({ hint("image-path", "file:///tmp/100%25.png") })
assert(calls[#calls].path == "/tmp/100%.png", "URI must decode exactly once")
print("PASS: notification image precedence, aliases, raw metadata, local URIs and rejection")
