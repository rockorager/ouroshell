local ouro = require("ouro")
local appearance = require("appearance")
local config = require("config")
local overlay = require("overlay")
local f = ouro.tokens.foundation
local machine = ouro.machine

local M = {}
-- Result rows accommodate two text lines; the frame surrounds the 560x620
-- content area.
local row_height, palette_height = 56, 620
local search_height = f.spacing_8
local frame_padding = f.spacing_4

M.background = overlay.background

-- These are shell-owned actions, never commands supplied by search text.
local lock = {
  id = "lock", name = "Lock screen", kind = "system", icon = "system-lock-screen-symbolic",
  keywords = { "lock" },
}
local session = {
  id = "session", name = "Session", kind = "system", icon = "system-shutdown-symbolic",
  description = "Log out, restart, or shut down", submenu = true,
}
local session_actions = {
  { id = "logout", name = "Log out…", verb = "Log out", kind = "system", tool = "exit",
    icon = "system-log-out-symbolic", description = "End this desktop session", keywords = { "logout", "sign out" } },
  { id = "restart", name = "Restart…", verb = "Restart", kind = "system", argv = { "systemctl", "reboot" },
    icon = "system-reboot-symbolic", description = "Restart the computer", keywords = { "reboot" } },
  { id = "shutdown", name = "Shut down…", verb = "Shut down", kind = "system", argv = { "systemctl", "poweroff" },
    icon = "system-shutdown-symbolic", description = "Turn off the computer", keywords = { "shutdown", "power off" } },
}

local function normalized(value)
  return (type(value) == "string" and value or ""):lower():gsub("[%p%s]+", " "):match("^%s*(.-)%s*$")
end

local function score(entry, query)
  if query == "" then return 0 end
  local name = normalized(entry.name)
  local generic = normalized(entry.generic_name)
  local id = normalized(entry.id)
  if name == query then return 1000 end
  if name:sub(1, #query) == query then return 800 - #name end
  local at = name:find(query, 1, true)
  if at then return 600 - at end
  if generic:find(query, 1, true) then return 400 end
  if id:find(query, 1, true) then return 300 end
  for _, keyword in ipairs(entry.keywords or {}) do
    if normalized(keyword):find(query, 1, true) then return 200 end
  end
end

function M.search(entries, query)
  query = normalized(query)
  local matches = {}
  for _, entry in ipairs(entries or {}) do
    if entry.visible ~= false and entry.name and type(entry.exec) == "string" then
      local rank = score(entry, query)
      if rank then matches[#matches + 1] = { entry = entry, rank = rank } end
    end
  end
  table.sort(matches, function(a, b)
    if a.rank ~= b.rank then return a.rank > b.rank end
    local an, bn = normalized(a.entry.name), normalized(b.entry.name)
    if an ~= bn then return an < bn end
    return a.entry.id < b.entry.id
  end)
  local result = {}
  for index, match in ipairs(matches) do result[index] = match.entry end
  return result
end

function M.launch_argv(entry, prepare_launch)
  local options = entry.terminal and { terminal_argv = config.terminal_argv } or nil
  local launch = options and prepare_launch(entry, options) or prepare_launch(entry)
  local argv = {}
  if launch.cwd and launch.cwd ~= ouro.json.null then
    argv = { "env", "--chdir=" .. launch.cwd, "--" }
  end
  for _, argument in ipairs(launch.argv) do argv[#argv + 1] = argument end
  return argv
end

local function wrap(index, delta, count)
  if count == 0 then return 1 end
  return ((index - 1 + delta) % count) + 1
end

-- The rows for one launcher view: a plain function of the launcher's
-- context and the other charts it reads.
--   view.entries: the catalog; view.caffeinated, view.scheme: session and appearance
function M.results(c, view)
  local query = normalized(c.query)
  local results = {}
  if not c.page and c.scope ~= "system" then
    results = M.search(view.entries, query)
    -- The home view is a starting point; Apps browses the complete catalog.
    if c.scope == "all" and query == "" then
      while #results > 3 do table.remove(results) end
    end
  end
  if c.page or c.scope ~= "apps" then
    local actions = c.page and { session_actions[1], session_actions[2], session_actions[3] }
      or query == "" and { lock, session }
      or { lock, session_actions[1], session_actions[2], session_actions[3] }
    if not c.page then
      local active = view.caffeinated
      actions[#actions + 1] = {
        id = "caffeine", name = active and "Decaffeinate" or "Caffeinate", kind = "system",
        icon = "alarm-symbolic", active = active,
        description = active and "Resume automatic locking, display sleep, and idle suspend"
          or "Pause automatic locking, display sleep, and idle suspend",
        keywords = { "caffeinate", "decaffeinate", "idle", "keep awake" },
      }
      -- prefer's setter is Varlink-only; its CLI stores the preference and
      -- the Settings portal broadcasts it, which the shell then follows.
      local dark = view.scheme == "dark"
      actions[#actions + 1] = {
        id = "color-scheme", name = dark and "Switch to light theme" or "Switch to dark theme", kind = "system",
        icon = dark and "weather-clear-symbolic" or "weather-clear-night-symbolic",
        keywords = { "theme", "toggle color scheme", "dark mode", "light mode", "appearance" },
        argv = { "prefer", "set", "color-scheme", dark and "light" or "dark" },
      }
    end
    for _, action in ipairs(actions) do
      if score(action, query) then results[#results + 1] = action end
    end
  end
  return results
end

-- The launcher's presentation state, spawned by the shell each time it
-- opens, so reopening resets the query, scope, page and confirmation. The
-- view computes results and hands ACTIVATE the selected row and MOVE the row
-- count; the chart decides what a row means. Destructive session actions
-- confirm first, with Cancel selected. Success or Escape at the top level
-- reaches `dismissed`, which the shell takes as closing.
--   services.execute(entry): performs a row; raises with a message on failure
function M.chart(services)
  local assign, unset = machine.assign, machine.unset
  local refocus = { focus = function(c) return c.focus + 1 end }
  local function refocused(fields)
    fields.focus = refocus.focus
    return assign(fields)
  end
  return machine.create {
    id = "launcher", initial = "browsing",
    context = { query = "", scope = "all", selected = 1, focus = 0 },
    events = {
      QUERY = { value = "string" },
      MOVE = { delta = "integer", count = "integer" },
      SCOPE = { value = "string" },
      ACTIVATE = { entry = "table?" },
      CONFIRM = {}, BACK = {},
    },
    actors = { execute = services.execute },
    guards = {
      submenu = function(_, e) return e.entry ~= nil and e.entry.submenu == true end,
      confirm = function(_, e) return e.entry ~= nil and e.entry.verb ~= nil end,
      entry = function(_, e) return e.entry ~= nil end,
      in_page = function(c) return c.page ~= nil end,
      confirming = function(c) return c.confirming ~= nil end,
    },
    actions = {
      query = assign(function(_, e) return { query = e.value, selected = 1, message = unset } end),
      move = assign { selected = function(c, e) return wrap(c.selected, e.delta, e.count) end },
      scope = refocused { scope = function(_, e) return e.value end, page = unset, query = "", selected = 1, message = unset },
      page = refocused { page = "session", query = "", selected = 1, message = unset },
      leave_page = refocused { page = unset, query = "", selected = 1, message = unset },
      -- Cancel, never the destructive action, is the default.
      ask = refocused { confirming = function(_, e) return e.entry end, selected = 1 },
      cancel = refocused { confirming = unset, selected = 1, message = unset },
      run = assign { target = function(_, e) return e.entry end, message = unset },
      run_confirmed = assign { target = function(c) return c.confirming end, message = unset },
      failed = refocused { message = function(_, e) return "Request failed: " .. tostring(e.error) end },
    },
    on = { QUERY = { actions = "query" } },
    states = {
      browsing = { on = {
        MOVE = { actions = "move" },
        SCOPE = { actions = "scope" },
        ACTIVATE = {
          { guard = "submenu", actions = "page" },
          { guard = "confirm", target = "confirming", actions = "ask" },
          { guard = "entry", target = "executing", actions = "run" },
        },
        BACK = { { guard = "in_page", actions = "leave_page" }, { target = "dismissed" } },
      } },
      confirming = { on = {
        MOVE = { actions = "move" },
        CONFIRM = { target = "executing", actions = "run_confirmed" },
        BACK = { target = "browsing", actions = "cancel" },
      } },
      -- One request at a time; Escape abandons it.
      executing = {
        invoke = { src = "execute", input = function(c) return c.target end,
          on_done = "dismissed",
          on_error = { { target = "confirming", guard = "confirming", actions = "failed" },
                       { target = "browsing", actions = "failed" } } },
        on = { BACK = "dismissed" },
      },
      dismissed = { type = "final" },
    },
  }
end

-- Performs a launcher row. Native session actions go to the session chart
-- (system id "session"); everything else is a fixed request to Ouro's MCP
-- endpoint.
--   options.prepare_launch, options.call, options.address: overrides for fixtures
function M.execute(options)
  options = options or {}
  return function(entry)
    if entry.kind == "system" and entry.id == "lock" then
      machine.system("session"):send("LOCK")
      return
    elseif entry.kind == "system" and entry.id == "caffeine" then
      local session = assert(machine.system("session"), "Idle control is unavailable")
      if entry.active then
        assert(session:send("DECAFFEINATE"), "Caffeine is not active")
        return
      end
      assert(session:send("CAFFEINATE"), "Idle control is unavailable; logind is not connected")
      -- The label changes only once logind granted the inhibitor.
      local snapshot = machine.wait_for(session, function(s)
        return machine.matches(s, "logind.online.caffeine.on.held") or not machine.matches(s, "logind.online.caffeine.on")
      end, { timeout = 10000 })
      if not machine.matches(snapshot, "logind.online.caffeine.on.held") then
        error(snapshot.context.caffeine_error or "Idle control is unavailable; logind is not connected", 0)
      end
      return
    end
    local tool, arguments = "run", nil
    if entry.kind == "system" then
      tool = entry.tool or "run"
      arguments = entry.argv and { argv = entry.argv } or {}
    else
      arguments = { argv = M.launch_argv(entry, options.prepare_launch or ouro.xdg.applications.prepare_launch) }
    end
    local address = options.address
      or "unix:" .. assert(ouro.xdg.runtime_dir, "XDG_RUNTIME_DIR is unavailable") .. "/ouro.mcp.sock"
    local reply = (options.call or ouro.mcp.call)(address, tool, arguments)
    if reply.error then error(reply.error.message, 0) end
    if reply.result and reply.result.isError then
      local detail = reply.result.structuredContent and reply.result.structuredContent.error
      error(detail and detail.message or "Ouro rejected the request", 0)
    end
  end
end

local function icon(key, name, size, tint)
  return ouro.xdg.icon { key = key, name = name, theme = config.icon_theme, width = size, height = size, tint = tint, alt = "" }
end

local function rule(key, colors)
  return ouro.box { key = key, height = f.border_width_default, width = "fill", background = colors.line }
end

local function result_key(entry)
  return (entry.kind == "system" and "system-" or "application-") .. entry.id
end

local function result_row(launcher, entry, index, selected, colors)
  local name = entry.icon
  if not name or name == ouro.json.null then name = "application-x-executable-symbolic" end
  local description = entry.description or entry.generic_name
  if type(description) ~= "string" or description == "" then
    description = entry.kind == "system" and "" or "Application"
  end
  local text = { ouro.text { key = "name", text = entry.name, size = f.typography_3,
    foreground = colors.foreground, max_lines = 1, overflow = "ellipsis" } }
  if description ~= "" then
    text[#text + 1] = ouro.text { key = "description", text = description, size = f.typography_2,
      foreground = colors.muted, max_lines = 1, overflow = "ellipsis" }
  end
  local contents = {
    icon("icon", name, f.spacing_5, entry.kind == "system" and colors.foreground or nil),
    ouro.column { key = "text", gap = f.spacing_1, flex = 1, cross_alignment = "stretch", children = text },
  }
  if entry.submenu then contents[#contents + 1] = icon("disclosure", "go-next-symbolic", f.spacing_4, colors.muted) end
  return ouro.button {
    key = result_key(entry), label = entry.name, height = row_height,
    background = index == selected and colors.selected or colors.transparent,
    border = index == selected and colors.selected_border or colors.transparent, border_width = f.border_width_default,
    foreground = colors.foreground, hover = colors.hover,
    send = launcher:event { type = "ACTIVATE", entry = entry },
    children = { ouro.box { key = "contents", width = "fill", children = {
      ouro.row { key = "row", gap = f.spacing_4, cross_alignment = "center", children = contents },
    } } },
  }
end

local function confirmation(launcher, c, colors)
  local entry = c.confirming
  local children = {
    ouro.text { key = "title", text = entry.verb .. "?", size = f.typography_7, foreground = colors.foreground },
    ouro.text { key = "warning", text = "Save your work before continuing. Unsaved changes may be lost.",
      size = f.typography_3, foreground = colors.muted, max_lines = 3 },
  }
  for index, label in ipairs({ "Cancel", entry.verb }) do
    children[#children + 1] = ouro.button {
      key = index == 1 and "cancel" or "confirm", label = label,
      foreground = index == 1 and colors.foreground or colors.error,
      background = c.selected == index and colors.selected or colors.transparent,
      border = c.selected == index and colors.selected_border or colors.border, border_width = f.border_width_default,
      hover = colors.hover, send = launcher:event(index == 1 and "BACK" or "CONFIRM"),
    }
  end
  return ouro.column { key = "confirmation", gap = f.spacing_4, cross_alignment = "stretch", children = children }
end

local results = machine.selector(function(c, entries, caffeinated, scheme)
  return M.results(c, { entries = entries, caffeinated = caffeinated, scheme = scheme })
end)

-- The search field's commands. Lazy payloads: a key that outruns the
-- rebuild after typing is resolved against the current state at dispatch,
-- not the rows of the last render. props.current() reads the other charts.
local function commands(props)
  local launcher = props.launcher
  local function rows(s)
    local p = props.current()
    return results(s.context, p.entries, p.caffeinated, p.scheme)
  end
  local function move(delta)
    return launcher:event(function(s)
      return { type = "MOVE", delta = delta, count = s.context.confirming and 2 or #rows(s) }
    end)
  end
  return {
    next = move(1),
    previous = move(-1),
    submit = launcher:event(function(s)
      if s.context.confirming then return { type = s.context.selected == 2 and "CONFIRM" or "BACK" } end
      local entry = rows(s)[s.context.selected]
      return entry and { type = "ACTIVATE", entry = entry }
    end),
    cancel = launcher:event("BACK"),
  }
end

-- props.launcher: the launcher actor; props.shell: the shell actor (dismissal)
-- props.current(): these props, read again when a key is dispatched
-- props.entries, props.catalog_phase, props.catalog_error: the catalog
-- props.caffeinated, props.status: the session; props.scheme: the appearance
function M.content(props, height, width)
  height, width = height or 760, width or 1280
  local launcher = props.launcher
  local c = launcher:context()
  local confirming = c.confirming ~= nil
  local theme, palette = appearance.colors(props.scheme)
  local frame_width = math.min(560 + 2 * frame_padding, width - 2 * f.spacing_5)
  local frame_height = math.min(palette_height + 2 * frame_padding, height - 2 * f.spacing_5)
  -- Center the shadow image behind the card, clipped to the viewport.
  local reach, offset = overlay.shadow_reach, overlay.shadow_offset
  local shadow_width = math.min(frame_width + 2 * reach, width)
  local shadow_height = math.min(frame_height + 2 * (reach + offset), height)
  local shadow = overlay.shadow(shadow_width, shadow_height, (shadow_width - frame_width) / 2,
    (shadow_height - frame_height) / 2, frame_width, frame_height, f.radius_6)
  local colors = {
    selected = theme.accent_selected, selected_border = theme.ring,
    foreground = theme.foreground, muted = theme.muted_foreground,
    error = palette.red.step_11, input = theme.surface, input_border = theme.input,
    border = theme.border, accent = theme.primary, hover = theme.accent_hover,
    transparent = ouro.tokens.palette.transparent, line = theme.border,
  }
  local rows = results(c, props.entries, props.caffeinated, props.scheme)
  -- Each virtual row is one result; the first result of a group also
  -- carries its heading, so revealing that row reveals the heading too.
  local headings, previous = {}, nil
  for index, entry in ipairs(rows) do
    local group = entry.kind == "system" and (c.page and "Session" or "System") or "Applications"
    if group ~= previous then headings[index] = group end
    previous = group
  end
  local list
  if confirming then
    list = ouro.scroll { key = "results-scroll", axis = "vertical", flex = 1, children = { confirmation(launcher, c, colors) } }
  elseif #rows == 0 then
    list = ouro.box { key = "results-empty", width = "fill", flex = 1, children = {
      ouro.text { key = "empty", text = "No matches. Try another name or keyword.", size = f.typography_3, foreground = colors.muted },
    } }
  else
    list = ouro.virtual_list { key = "results", flex = 1,
      item_count = #rows, estimated_item_height = row_height + f.spacing_1,
      item_key = function(index) return result_key(rows[index]) end,
      -- Layout reveals the keyboard selection; no row windowing is needed.
      ensure_visible = c.selected,
      render_item = function(index)
        local children = {}
        if headings[index] then
          if index > 1 then children[#children + 1] = rule("rule", colors) end
          children[#children + 1] = ouro.text { key = "heading", text = headings[index],
            size = f.typography_2, foreground = colors.muted }
        end
        children[#children + 1] = result_row(launcher, rows[index], index, c.selected, colors)
        children[#children + 1] = ouro.box { key = "spacing", height = 0 }
        return ouro.column { key = "row", gap = f.spacing_1, cross_alignment = "stretch", children = children }
      end,
    }
  end
  local tabs = {}
  if c.page or confirming then
    tabs[1] = ouro.button { key = "back", label = "← Back",
      background = colors.transparent, foreground = colors.muted, hover = colors.hover, send = launcher:event("BACK") }
  else
    for _, scope in ipairs({ { "all", "All" }, { "apps", "Apps" }, { "system", "System" } }) do
      local active = c.scope == scope[1]
      tabs[#tabs + 1] = ouro.column { key = "scope-" .. scope[1], gap = 0, cross_alignment = "stretch", children = {
        ouro.button { key = "button", label = scope[2],
          background = colors.transparent, foreground = active and colors.foreground or colors.muted, hover = colors.hover,
          send = launcher:event { type = "SCOPE", value = scope[1] } },
        ouro.box { key = "indicator", width = "fill", height = f.border_width_strong, background = active and colors.accent or colors.transparent },
      } }
    end
  end
  local status = c.message or props.status
  if not status and launcher:matches("executing") then status = "Sending request…" end
  if not status and c.scope ~= "system" and not c.page then
    if props.catalog_phase == "loading" then status = "Loading applications…"
    elseif props.catalog_phase == "failed" then
      status = "Applications could not be loaded (" .. tostring(props.catalog_error)
        .. "). System actions are still available."
    end
  end
  return ouro.stack { key = "launcher", children = {
    ouro.box { key = "shadow-position", width = "fill", height = "fill", alignment = "center", children = {
      ouro.image { key = "shadow", bytes = shadow, width = shadow_width, height = shadow_height, fit = "fill", alt = "" },
    } },
    ouro.box { key = "position", width = "fill", height = "fill", padding = f.spacing_5, alignment = "center", children = {
      ouro.box { key = "palette", width = frame_width, height = frame_height,
        on_pointer_down_outside = { propagate = false, handler = props.shell:event("DISMISS") },
        padding = frame_padding - f.border_width_default, radius = f.radius_6,
        background = theme == ouro.tokens.dark and palette.slate.step_3 or theme.card,
        border = palette.slate.step_6, border_width = f.border_width_default, children = {
        ouro.column { key = "content", gap = f.spacing_4, cross_alignment = "stretch", children = {
          ouro.box { key = "search-shell", width = "fill", height = search_height, alignment = "center",
            background = colors.input, border = colors.input_border, border_width = f.border_width_default, radius = f.radius_2, children = {
            ouro.row { key = "search-row", gap = f.spacing_2, cross_alignment = "center", children = {
              ouro.box { key = "search-inset-start", width = f.spacing_1 },
              icon("search-icon", "system-search-symbolic", f.spacing_5, colors.foreground),
              ouro.text_input {
                key = "search", text = confirming and "" or c.query,
                label = "Search apps and commands", placeholder = confirming and "Confirmation" or "Search apps and commands…",
                autofocus = true, focus_request = c.focus, read_only = confirming, flex = 1,
                padding_x = 0, border_width = 0, background = colors.transparent,
                foreground = colors.foreground, send = launcher:event("QUERY"),
                on_command = commands(props),
              },
              ouro.box { key = "search-inset-end", width = f.spacing_1 },
            } },
          } },
          ouro.column { key = "scopes", gap = 0, cross_alignment = "stretch", children = {
            ouro.row { key = "tabs", gap = f.spacing_2, children = tabs }, rule("scope-rule", colors),
          } },
          list,
          ouro.text { key = "status", text = status or ("↑ ↓  Navigate     Enter  " .. (confirming and "Choose" or "Open")
              .. "     Esc  " .. ((c.page or confirming) and "Back" or "Close")),
            size = f.typography_2, foreground = c.message and colors.error or colors.muted, max_lines = 2 },
        } },
      } },
    } },
  } }
end

return M
