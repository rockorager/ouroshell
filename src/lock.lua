local ouro = require("ouro")
local config = require("config")
local appearance = require("appearance")
local f = ouro.tokens.foundation
local M = {}

-- Native ownership and its sole reader live at application scope. No password
-- ever enters this module: auth_input submits its native buffer directly to PAM.
function M.new(services)
  local state = {
    phase = ouro.signal("unlocked"), username = ouro.signal(nil),
    message = ouro.signal(nil), prompt = ouro.signal(nil),
    authenticating = ouro.signal(false),
  }
  local owner, conversation
  local requested, sleeping = false, false
  local attempt = 0

  function state.secured() return state.phase() == "locked" end
  function state.visible() return state.phase() ~= "unlocked" end

  function state.cancel_auth()
    attempt = attempt + 1
    if conversation then conversation:cancel(); conversation = nil end
    state.prompt:set(nil)
    state.authenticating:set(false)
  end

  function state.authenticate()
    if not state.secured() or sleeping or state.authenticating() then return end
    local username = state.username()
    if not username then
      state.message:set("Session identity is unavailable. Try again when logind reconnects.")
      return
    end
    state.cancel_auth()
    local serial, lock = attempt, owner
    state.authenticating:set(true)
    state.message:set("Authenticating…")
    ouro.spawn_app(function()
      -- A queued task may have been canceled before it started.
      if serial ~= attempt or sleeping or owner ~= lock then return end
      local ok = pcall(function()
        local auth, failure = ouro.auth.start(config.pam_service, username)
        if not auth then error(failure) end
        local session <close> = auth
        conversation = auth
        while serial == attempt and owner == lock and not sleeping do
          local event = session:next()
          if serial ~= attempt or owner ~= lock or sleeping then return end
          if not event then error("Authentication conversation closed") end
          if event.type == "prompt" then
            state.prompt:set({ conversation = auth, id = event.id, text = event.text })
            state.message:set("Enter your credentials to unlock.")
          elseif event.type == "info" or event.type == "error" then
            state.message:set(event.text)
          elseif event.type == "result" then
            state.prompt:set(nil)
            conversation = nil
            state.authenticating:set(false)
            if event.success == true and state.secured() then
              -- Authentication success on this exact live ownership is the
              -- only path to unlock. Submission, cancellation and errors are not.
              state.phase:set("unlocking")
              lock:unlock()
              state.message:set("Unlocking…")
            else
              state.message:set("Authentication failed. Try again.")
            end
            return
          end
        end
      end)
      if not ok and serial == attempt and owner == lock then
        state.cancel_auth()
        if state.phase() == "unlocking" then
          state.phase:set("failed")
          state.message:set("Unlock failed. End this graphical session from a trusted VT or SSH session.")
        else
          state.message:set("Authentication is unavailable. Try again.")
        end
      end
    end)
  end

  function state.set_identity(username)
    if state.username() == username then return end
    state.cancel_auth()
    state.username:set(username)
    if state.secured() and not sleeping then state.authenticate() end
  end

  function state.prepare_for_sleep(value)
    sleeping = value
    state.cancel_auth()
    if value then state.message:set("Preparing for sleep…")
    elseif state.secured() then state.authenticate() end
  end

  function state.request()
    if requested or state.visible() then return end
    requested = true
    ouro.spawn_app(function()
      local acknowledged = false
      local ok, failure = pcall(function()
        owner = ouro.session.lock()
        state.phase:set("locking")
        state.message:set("Securing session…")
        services.dismiss()
        while true do
          local event = owner:next()
          if event == "locked" then
            acknowledged = true
            state.phase:set("locked")
            services.locked()
            if not sleeping then state.authenticate() end
          elseif event == "unlocked" then
            state.cancel_auth()
            owner:close()
            owner = nil
            state.phase:set("unlocked")
            state.message:set(nil)
            requested = false
            services.unlocked()
            return
          elseif event == "finished" and not acknowledged then
            owner:close()
            owner = nil
            state.phase:set("unlocked")
            requested = false
            services.failure("The compositor refused the session lock.")
            return
          else
            error("Session lock ownership failed")
          end
        end
      end)
      if not ok then
        state.cancel_auth()
        -- After a lock request, failure is not evidence of an unlocked
        -- desktop. Retain the declaration/owner; never acquire a replacement.
        if owner then
          state.phase:set("failed")
          state.message:set("Lock control was lost. End this graphical session from a trusted VT or SSH session.")
        else
          requested = false
          state.phase:set("unlocked")
        end
        services.failure("Session locking failed: " .. tostring(failure))
      end
    end)
  end

  return state
end

function M.content(state, time)
  local theme = appearance.colors()
  local prompt = state.prompt()
  local date, clock = time:match("^(.-)  (.+)$")
  local titles = { locked = "Session locked", locking = "Securing session", unlocking = "Unlocking…",
    failed = "Session recovery required" }
  local children = {
    ouro.text { key = "title", text = titles[state.phase()] or "Session locked",
      size = f.typography_5, alignment = "center", foreground = theme.foreground },
    ouro.text { key = "account", text = state.username() or "Local session", size = f.typography_3,
      alignment = "center", foreground = theme.muted_foreground },
  }
  if prompt then
    local function current() return state.prompt() == prompt end
    local function submitted()
      if not current() then return end
      state.prompt:set(nil)
      state.message:set("Authenticating…")
    end
    children[#children + 1] = ouro.text { key = "prompt", text = prompt.text, size = f.typography_3,
      foreground = theme.foreground, max_lines = 3 }
    children[#children + 1] = ouro.auth_input {
      key = "credentials", conversation = prompt.conversation, prompt_id = prompt.id,
      autofocus = true, width = "fill", on_submit = submitted,
      on_cancel = function()
        if not current() then return end
        state.cancel_auth()
        state.message:set("Authentication canceled. Try again.")
      end,
      on_error = function()
        if current() then
          state.cancel_auth()
          state.message:set("Authentication is unavailable. Try again.")
        end
      end,
    }
    children[#children + 1] = ouro.button { key = "unlock", label = "Unlock",
      variant = "solid", tone = "accent", height = 44,
      on_press = function()
        if not current() then return end
        local accepted = prompt.conversation:submit(prompt.id)
        if accepted then submitted() end
      end }
  elseif state.secured() and not state.authenticating() then
    children[#children + 1] = ouro.button { key = "retry", label = "Try again", on_press = state.authenticate }
  end
  children[#children + 1] = ouro.text { key = "status", text = state.message() or "",
    size = f.typography_2, alignment = "center", foreground = theme.muted_foreground, max_lines = 4 }
  return ouro.box { key = "lock-screen", width = "fill", height = "fill", padding = f.spacing_5,
    background = theme.background, alignment = "center", children = {
      ouro.column { key = "center", width = 400, gap = f.spacing_6, cross_alignment = "stretch", children = {
        ouro.column { key = "time", gap = f.spacing_2, cross_alignment = "stretch", children = {
          ouro.text { key = "clock", text = clock or time, size = f.typography_9,
            alignment = "center", foreground = theme.foreground },
          ouro.text { key = "date", text = date or "", size = f.typography_3,
            alignment = "center", foreground = theme.muted_foreground },
        } },
        ouro.box { key = "card", width = "fill", padding = f.spacing_5, radius = f.radius_6,
          background = theme.card, border = theme.border, border_width = f.border_width_default,
          children = { ouro.column { key = "form", gap = f.spacing_4, cross_alignment = "stretch", children = children } } },
      } },
    } }
end

function M.window(state, time)
  if not state.visible() then return nil end
  local theme = appearance.colors()
  return ouro.lock_surface { id = "lock", outputs = "all", background = theme.background,
    content = function() return M.content(state, time()) end }
end

return M
