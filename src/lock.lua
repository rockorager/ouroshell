local ouro = require("ouro")
local appearance = require("appearance")
local f = ouro.tokens.foundation
local M = {}

-- The lock screen's phase, from the session chart.
function M.phase(session)
  if session:matches("lock.held.locking") then return "locking"
  elseif session:matches("lock.held.secured") then return "locked"
  elseif session:matches("lock.held.unlocking") then return "unlocking"
  elseif session:matches("lock.held.failed") then return "failed" end
  return "unlocked"
end

-- No password ever enters Lua: the masked text_input sends its text
-- directly to PAM, and the chart only hears the outcome.
function M.content(session, time, scheme)
  local theme = appearance.colors(scheme)
  local c = session:context()
  local prompt = c.prompt
  local date, clock = time:match("^(.-)  (.+)$")
  local titles = { locked = "Session locked", locking = "Securing session", unlocking = "Unlocking…",
    failed = "Session recovery required" }
  local children = {
    ouro.text { key = "title", text = titles[M.phase(session)] or "Session locked",
      size = f.typography_5, alignment = "center", foreground = theme.foreground },
    ouro.text { key = "account", text = c.username or "Local session", size = f.typography_3,
      alignment = "center", foreground = theme.muted_foreground },
  }
  if prompt then
    -- PAM's prompt ("Password:") becomes the field's hint while it is empty.
    local hint = tostring(prompt.text or ""):gsub("[%s:]+$", "")
    -- Bound to the conversation, the field is masked and Enter sends its text
    -- natively to PAM. The commands only exist while authenticating.
    children[#children + 1] = ouro.text_input {
      key = "credentials", conversation = prompt.conversation, prompt_id = prompt.id,
      placeholder = hint ~= "" and hint or "Password", autofocus = true, width = "fill",
      on_command = {
        submit = session:event("SUBMITTED"),
        -- Escape clears the field and starts over; it never needs a mouse.
        cancel = session:event("CANCEL_AUTH"),
        stale = session:event("STALE"),
      },
    }
  elseif session:matches("lock.held.secured") and not session:matches("lock.held.secured.authenticating") then
    -- Mounting requests focus, so Enter or Space retries without a pointer.
    children[#children + 1] = ouro.button { key = "retry", label = "Try again", focus_request = 1,
      send = session:event("RETRY") }
  end
  children[#children + 1] = ouro.text { key = "status", text = c.message or "",
    size = f.typography_2, alignment = "center", foreground = theme.muted_foreground, max_lines = 4 }
  return ouro.box { key = "lock-screen", width = "fill", height = "fill", padding = f.spacing_5,
    background = theme.background, alignment = "center", children = {
      -- Rows and columns have no width; the Box sets the card width.
      ouro.box { key = "center", width = 400, children = {
        ouro.column { key = "stack", gap = f.spacing_6, cross_alignment = "stretch", children = {
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
      } },
    } }
end

-- The lock surface exists while the session is not unlocked, and reports
-- to the session chart (send = session). read.time() and read.scheme() are
-- read by the content, so the clock and theme update without redeclaring it.
function M.window(session, read)
  -- Lock surfaces belong to an acquired lock: show them once lock() returned.
  if session:matches("lock.unlocked") or session:context().owner == nil then return nil end
  local theme = appearance.colors(read.scheme())
  return ouro.lock_surface { id = "lock", outputs = "all", background = theme.background, send = session,
    content = function() return M.content(session, read.time(), read.scheme()) end }
end

return M
