package.path = "src/?.lua;" .. package.path
local task, callback, delay, fail_read, offline
local selection = { exists = true, value = "dark" }
local ouro = {
  tokens = { light = {}, dark = {}, palette = { light = {}, dark = {} } },
  xdg = { runtime_dir = "/isolated" }, json = { decode = function(value) return value end },
  signal = function(value)
    return setmetatable({ set = function(_, next_value) value = next_value end }, { __call = function() return value end })
  end,
  spawn = function(fn) task = coroutine.create(fn) end,
  sleep = function(ms) delay = ms; coroutine.yield() end,
  mcp = {
    subscribe = function(address, uri, fn)
      assert(address == "unix:/isolated/ouro/settings.mcp.sock")
      assert(uri == "ouro://settings/appearance/color_scheme")
      if offline then error("offline") end
      callback = fn
      fn({ method = "notifications/subscriptions/acknowledged" })
      coroutine.yield()
      error("disconnected")
    end,
    request = function(_, method, params)
      assert(callback and method == "resources/read" and params.uri == "ouro://settings/appearance/color_scheme")
      if fail_read then return { error = { message = "read failed" } } end
      return { result = { contents = { { text = selection } } } }
    end,
  },
}
package.loaded.ouro = ouro
local appearance = require("appearance")
assert(appearance.colors() == ouro.tokens.light, "startup fallback must match Ourokit")
appearance.connect()
assert(coroutine.resume(task))
assert(appearance.colors() == ouro.tokens.dark, "acknowledgment must fetch the initial value")
for _, value in ipairs({ "light", "dark", "default" }) do
  selection.value = value
  callback({ method = "notifications/resources/updated" })
  local colors, palette = appearance.colors()
  local expected = value == "dark" and "dark" or "light"
  assert(colors == ouro.tokens[expected] and palette == ouro.tokens.palette[expected])
end
selection = { exists = false }
callback({ method = "notifications/resources/updated" })
assert(appearance.colors() == ouro.tokens.light)
selection = { exists = true, value = "dark" }
callback({ method = "notifications/resources/updated" })
fail_read = true
assert(not pcall(callback, { method = "notifications/resources/updated" }))
assert(appearance.colors() == ouro.tokens.dark, "failed read must retain the last palette")
offline = true
assert(coroutine.resume(task))
assert(delay == 250)
for _, expected in ipairs({ 500, 1000, 2000, 4000, 8000, 10000, 10000 }) do
  assert(coroutine.resume(task))
  assert(delay == expected and appearance.colors() == ouro.tokens.dark)
end
offline, fail_read = false, false
selection.value = "light"
assert(coroutine.resume(task))
assert(appearance.colors() == ouro.tokens.light, "reconnect must fetch current settings")
assert(coroutine.resume(task))
assert(delay == 250, "successful read must reset retry delay")
print("PASS: appearance initial read, live palettes, defaults, failures, and reconnection")
