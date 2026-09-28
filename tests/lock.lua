package.path = "src/?.lua;tests/?.lua;" .. package.path
local tasks, owners, conversations = {}, {}, {}
local ouro = require("fake_ouro").install {
  spawn_app = function(fn) tasks[#tasks + 1] = coroutine.create(fn) end,
}
ouro.tokens.dark = setmetatable({}, { __index = function(_, key) return key end })
package.loaded.appearance = { colors = function() return ouro.tokens.dark end }
local function resume(task, ...)
  local ok, result = coroutine.resume(task, ...)
  assert(ok, result)
  return result
end
local function resource()
  local value = { next = function() return coroutine.yield() end,
    close = function(self) self.closed = true end }
  return setmetatable(value, { __close = value.close })
end
ouro.session = { lock = function()
  local owner = resource()
  function owner:unlock() self.unlocks = (self.unlocks or 0) + 1 end
  owners[#owners + 1] = owner
  return owner
end }
ouro.auth = { start = function(service, username)
  assert(service == "login" and username == "trusted-user")
  local auth = resource()
  function auth:cancel() self.canceled = true end
  conversations[#conversations + 1] = auth
  return auth
end }
local locked, unlocked, dismissed, errors = 0, 0, 0, {}
local lock = require("lock")
local function create()
  return lock.new {
    dismiss = function() dismissed = dismissed + 1 end,
    locked = function() locked = locked + 1 end,
    unlocked = function() unlocked = unlocked + 1 end,
    failure = function(message) errors[#errors + 1] = message end,
  }
end
local function find(tree, key)
  if tree.key == key then return tree end
  for _, child in ipairs(tree.children or {}) do
    local found = find(child, key)
    if found then return found end
  end
end
local state = create()
assert(lock.window(state, function() return "time" end) == nil)
state.request(); state.request()
assert(#tasks == 1 and #owners == 0, "acquisition must be queued once at app scope")
local reader = tasks[1]
resume(reader)
assert(state.phase() == "locking" and not state.secured() and locked == 0 and dismissed == 1)
local window = lock.window(state, function() return "time" end)
assert(window.kind == "lock_surface" and window.outputs == "all")
assert(#conversations == 0, "PAM must not run before secure lock acknowledgement")
resume(reader, "locked")
assert(state.secured() and locked == 1 and #conversations == 0)
assert(state.message():find("identity", 1, true), "identity must come from logind, not editable input")
state.set_identity("trusted-user")
local auth_reader = tasks[#tasks]
resume(auth_reader)
local auth = conversations[1]
resume(auth_reader, { type = "prompt", id = 7, echo = false, text = "Password:" })
local tree = window.content("DP-2")
local entry = find(tree, "credentials")
assert(entry.kind == "text_input" and entry.conversation == auth and entry.prompt_id == 7)
assert(entry.text == nil and entry.on_change == nil and entry.default_text == nil)
assert(entry.placeholder == "Password" and entry.autofocus)
entry.on_command("submit") -- the native field already sent its text to PAM
assert(not state.prompt() and not owners[1].unlocks,
  "accepting a response for transport must not unlock")
resume(auth_reader, { type = "result", success = false, reason = "Denied" })
assert(state.secured() and auth.closed and not owners[1].unlocks)
assert(find(window.content(), "retry"))

-- Canceling a prompt retires its UI callbacks and rejects a late success.
state.authenticate(); auth_reader = tasks[#tasks]; resume(auth_reader)
resume(auth_reader, { type = "prompt", id = 12, echo = true, text = "Verification:" })
local stale = find(window.content(), "credentials")
assert(stale.kind == "text_input" and stale.conversation, "echo-on PAM prompts must use the masked field too")
stale.on_command("cancel")
assert(conversations[2].canceled and state.secured())
resume(auth_reader, { type = "result", success = true })
assert(not owners[1].unlocks)
state.authenticate(); auth_reader = tasks[#tasks]; resume(auth_reader)
resume(auth_reader, { type = "prompt", id = 15, text = "Password:" })
stale.on_command("submit")
assert(state.prompt().id == 15, "stale callbacks must not clear a new prompt")
state.prepare_for_sleep(true)
resume(auth_reader, { type = "result", success = true })
assert(not owners[1].unlocks and conversations[3].canceled)
state.authenticate()
assert(#conversations == 3, "authentication must remain paused while suspending")
state.prepare_for_sleep(false)
auth_reader = tasks[#tasks]; resume(auth_reader)
resume(auth_reader, { type = "result", success = true })
assert(owners[1].unlocks == 1 and state.phase() == "unlocking" and not state.secured())
assert(unlocked == 0 and state.visible(), "retain lock surfaces until the unlock request is queued")
resume(reader, "unlocked")
assert(unlocked == 1 and not state.visible() and owners[1].closed)

-- Denial before acknowledgement permits retry; a failure after requesting a
-- lock is not proof of an unlocked desktop and must never silently recover.
state.request(); reader = tasks[#tasks]; resume(reader); resume(reader, "finished")
assert(not state.visible() and #errors == 1)
state.request(); reader = tasks[#tasks]; resume(reader); resume(reader, "failed")
assert(state.phase() == "failed" and state.visible())
local count = #tasks
state.request(); state.authenticate()
assert(#tasks == count and not owners[#owners].unlocks)
assert(not find(lock.content(state, "time"), "retry"))

local failed = create()
failed.set_identity("trusted-user")
failed.request(); reader = tasks[#tasks]; resume(reader); resume(reader, "locked")
auth_reader = tasks[#tasks]; resume(auth_reader)
resume(reader, "failed")
resume(auth_reader, { type = "result", success = true })
assert(failed.phase() == "failed" and not owners[#owners].unlocks)
print("PASS: native lock ownership, acknowledgement, credential-free UI, denial, cancellation, stale auth, and fail-closed errors")
