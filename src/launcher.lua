local ouro = require("ouro")
local appearance = require("appearance")
local config = require("config")
local f = ouro.tokens.foundation

local M = {}
-- Result rows accommodate two text lines; the frame surrounds the 560x620
-- content area.
local row_height, palette_height = 56, 620
local search_height = f.spacing_8
local frame_padding = f.spacing_4
local shadow_blur = 12

function M.background()
  -- The opaque card carries contrast; keep the blurred backdrop light-touch
  -- and dark-tinted even when the content uses the light palette.
  return ouro.color.with_alpha(ouro.tokens.dark.background, 0.3)
end

-- These are shell-owned actions, never commands supplied by search text.
local lock = {
  id = "lock", name = "Lock screen", kind = "system", icon = "system-lock-screen-symbolic",
  argv = { "loginctl", "lock-session", "auto" }, keywords = { "lock" },
}
local session = {
  id = "session", name = "Session…", kind = "system", icon = "system-shutdown-symbolic",
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

-- services.catalog: application catalog from catalog.lua
-- services.dismiss: closes the launcher
-- services.prepare_launch, services.call: optional launch overrides for fixtures
function M.new(services)
  local catalog = services.catalog
  local state = {
    catalog = catalog,
    query = ouro.signal(""), selected = ouro.signal(1),
    scope = ouro.signal("all"), page = ouro.signal(nil), confirming = ouro.signal(nil),
    focus = ouro.signal(0),
    message = ouro.signal(nil), launching = ouro.signal(false),
  }

  function state.results()
    local query = normalized(state.query())
    local results = {}
    if not state.page() and state.scope() ~= "system" then
      results = M.search(catalog.entries(), query)
      -- The home view is a starting point; Apps browses the complete catalog.
      if state.scope() == "all" and query == "" then
        while #results > 3 do table.remove(results) end
      end
    end
    if state.page() or state.scope() ~= "apps" then
      local actions = state.page() and session_actions
        or query == "" and { lock, session }
        or { lock, session_actions[1], session_actions[2], session_actions[3] }
      for _, action in ipairs(actions) do
        if score(action, query) then results[#results + 1] = action end
      end
    end
    return results
  end

  function state.change(value)
    state.query:set(value)
    state.selected:set(1)
    state.message:set(nil)
  end
  local function refocus()
    -- Mouse actions move focus; hand it back to the search field.
    state.focus:set(state.focus() + 1)
  end
  function state.choose_scope(scope)
    state.scope:set(scope)
    state.page:set(nil)
    state.confirming:set(nil)
    state.change("")
    refocus()
  end
  function state.open() state.choose_scope("all") end
  function state.back()
    if state.confirming() then
      state.confirming:set(nil)
      state.selected:set(1)
      state.message:set(nil)
      refocus()
    elseif state.page() then
      state.page:set(nil)
      state.change("")
      refocus()
    else
      services.dismiss()
    end
  end
  function state.move(delta)
    local count = state.confirming() and 2 or #state.results()
    state.selected:set(count == 0 and 1 or ((state.selected() - 1 + delta) % count) + 1)
  end
  local function execute(entry)
    if state.launching() then return end
    state.launching:set(true)
    state.message:set(nil)
    ouro.spawn(function()
      local ok, failure = pcall(function()
        local tool, arguments = "run", nil
        if entry.kind == "system" then
          tool = entry.tool or "run"
          arguments = entry.argv and { argv = entry.argv } or {}
        else
          arguments = { argv = M.launch_argv(entry, services.prepare_launch or ouro.xdg.applications.prepare_launch) }
        end
        local runtime = assert(ouro.xdg.runtime_dir, "XDG_RUNTIME_DIR is unavailable")
        local reply = (services.call or ouro.mcp.call)("unix:" .. runtime .. "/ouro.mcp.sock", tool, arguments)
        if reply.error then error(reply.error.message) end
        if reply.result and reply.result.isError then
          local detail = reply.result.structuredContent and reply.result.structuredContent.error
          error(detail and detail.message or "Ouro rejected the request")
        end
      end)
      state.launching:set(false)
      if ok then services.dismiss() else
        state.message:set("Request failed: " .. tostring(failure))
        refocus()
      end
    end)
  end
  function state.confirm()
    local entry = state.confirming()
    if entry then execute(entry) end
  end
  function state.launch(entry)
    entry = entry or state.results()[state.selected()]
    if not entry or state.launching() then return end
    if entry.submenu then
      state.page:set("session")
      state.change("")
      refocus()
    elseif entry.verb then
      state.confirming:set(entry)
      state.selected:set(1) -- Cancel, never the destructive action, is the default.
      refocus()
    else
      execute(entry)
    end
  end
  function state.command(command)
    if command == "next" then state.move(1)
    elseif command == "previous" then state.move(-1)
    elseif command == "submit" then
      if state.confirming() then
        if state.selected() == 2 then state.confirm() else state.back() end
      else state.launch() end
    elseif command == "cancel" then state.back() end
  end
  return state
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

local function result_row(state, entry, index, colors)
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
    background = index == state.selected() and colors.selected or colors.transparent,
    border = index == state.selected() and colors.selected_border or colors.transparent, border_width = f.border_width_default,
    foreground = colors.foreground, hover = colors.hover,
    on_press = function() state.launch(entry) end,
    children = { ouro.box { key = "contents", width = "fill", children = {
      ouro.row { key = "row", gap = f.spacing_4, cross_alignment = "center", children = contents },
    } } },
  }
end

local function confirmation(state, colors)
  local entry = state.confirming()
  local children = {
    ouro.text { key = "title", text = entry.verb .. "?", size = f.typography_7, foreground = colors.foreground },
    ouro.text { key = "warning", text = "Save your work before continuing. Unsaved changes may be lost.",
      size = f.typography_3, foreground = colors.muted, max_lines = 3 },
  }
  for index, label in ipairs({ "Cancel", entry.verb }) do
    children[#children + 1] = ouro.button {
      key = index == 1 and "cancel" or "confirm", label = label,
      foreground = index == 1 and colors.foreground or colors.error,
      background = state.selected() == index and colors.selected or colors.transparent,
      border = state.selected() == index and colors.selected_border or colors.border, border_width = f.border_width_default,
      hover = colors.hover, on_press = index == 1 and state.back or state.confirm,
    }
  end
  return ouro.column { key = "confirmation", gap = f.spacing_4, cross_alignment = "stretch", children = children }
end

function M.content(state, height, width)
  height, width = height or 760, width or 1280
  local theme, palette = appearance.colors()
  local frame_width = math.min(560 + 2 * frame_padding, width - 2 * f.spacing_5)
  local frame_height = math.min(palette_height + 2 * frame_padding, height - 2 * f.spacing_5)
  -- Ourokit has no box-shadow primitive. Rasterize a decorative SVG centered
  -- behind the card: the card plus its blur reach, clipped to the viewport.
  -- The rectangle sits lower in the image, dropping the shadow by `offset`.
  local reach, offset = 2 * shadow_blur, f.spacing_2
  local shadow_width = math.min(frame_width + 2 * reach, width)
  local shadow_height = math.min(frame_height + 2 * (reach + offset), height)
  local shadow = string.format([[<svg xmlns="http://www.w3.org/2000/svg" width="%g" height="%g">
    <defs><filter id="shadow" x="-50%%" y="-50%%" width="200%%" height="200%%">
      <feGaussianBlur stdDeviation="%g"/>
    </filter></defs>
    <rect x="%g" y="%g" width="%g" height="%g" rx="%g" fill="black" fill-opacity="0.4" filter="url(#shadow)"/>
  </svg>]], shadow_width, shadow_height, shadow_blur, (shadow_width - frame_width) / 2,
    (shadow_height - frame_height) / 2 + offset, frame_width, frame_height, f.radius_6)
  local colors = {
    selected = theme.accent_selected, selected_border = theme.ring,
    foreground = theme.foreground, muted = theme.muted_foreground,
    error = palette.red.step_11, input = theme.surface, input_border = theme.input,
    border = theme.border, accent = theme.primary, hover = theme.accent_hover,
    transparent = ouro.tokens.palette.transparent, line = theme.border,
  }
  local results = state.results()
  -- Each virtual row is one result; the first result of a group also
  -- carries its heading, so revealing that row reveals the heading too.
  local headings, previous = {}, nil
  for index, entry in ipairs(results) do
    local group = entry.kind == "system" and (state.page() and "Session" or "System") or "Applications"
    if group ~= previous then headings[index] = group end
    previous = group
  end
  local list
  if state.confirming() then
    list = ouro.scroll { key = "results-scroll", axis = "vertical", flex = 1, children = { confirmation(state, colors) } }
  elseif #results == 0 then
    list = ouro.box { key = "results-empty", width = "fill", flex = 1, children = {
      ouro.text { key = "empty", text = "No matches. Try another name or keyword.", size = f.typography_3, foreground = colors.muted },
    } }
  else
    list = ouro.virtual_list { key = "results", flex = 1,
      item_count = #results, estimated_item_height = row_height + f.spacing_1,
      item_key = function(index) return result_key(results[index]) end,
      -- Layout reveals the keyboard selection; no row windowing is needed.
      ensure_visible = state.selected(),
      render_item = function(index)
        local children = {}
        if headings[index] then
          if index > 1 then children[#children + 1] = rule("rule", colors) end
          children[#children + 1] = ouro.text { key = "heading", text = headings[index],
            size = f.typography_2, foreground = colors.muted }
        end
        children[#children + 1] = result_row(state, results[index], index, colors)
        children[#children + 1] = ouro.box { key = "spacing", height = 0 }
        return ouro.column { key = "row", gap = f.spacing_1, cross_alignment = "stretch", children = children }
      end,
    }
  end
  local tabs = {}
  if state.page() or state.confirming() then
    tabs[1] = ouro.button { key = "back", label = "← Back",
      background = colors.transparent, foreground = colors.muted, hover = colors.hover, on_press = state.back }
  else
    for _, scope in ipairs({ { "all", "All" }, { "apps", "Apps" }, { "system", "System" } }) do
      local active = state.scope() == scope[1]
      tabs[#tabs + 1] = ouro.column { key = "scope-" .. scope[1], gap = 0, cross_alignment = "stretch", children = {
        ouro.button { key = "button", label = scope[2],
          background = colors.transparent, foreground = active and colors.foreground or colors.muted, hover = colors.hover,
          on_press = function() state.choose_scope(scope[1]) end },
        ouro.box { key = "indicator", width = "fill", height = f.border_width_strong, background = active and colors.accent or colors.transparent },
      } }
    end
  end
  local status = state.message()
  if not status and state.launching() then status = "Sending request…" end
  if not status and state.scope() ~= "system" and not state.page() then
    local phase = state.catalog.phase()
    if phase == "loading" then status = "Loading applications…"
    elseif phase == "error" then
      status = "Applications could not be loaded (" .. tostring(state.catalog.error())
        .. "). System actions are still available."
    end
  end
  return ouro.stack { key = "launcher", children = {
    ouro.box { key = "shadow-position", width = "fill", height = "fill", alignment = "center", children = {
      ouro.image { key = "shadow", bytes = shadow, width = shadow_width, height = shadow_height, fit = "fill", alt = "" },
    } },
    ouro.box { key = "position", width = "fill", height = "fill", padding = f.spacing_5, alignment = "center", children = {
      ouro.box { key = "palette", width = frame_width, height = frame_height,
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
                key = "search", text = state.confirming() and "" or state.query(),
                label = "Search apps and commands", placeholder = state.confirming() and "Confirmation" or "Search apps and commands…",
                autofocus = true, focus_request = state.focus(), read_only = state.confirming() ~= nil, flex = 1,
                padding_x = 0, border_width = 0, background = colors.transparent,
                foreground = colors.foreground, on_change = state.change,
                on_command = state.command,
              },
              ouro.box { key = "search-inset-end", width = f.spacing_1 },
            } },
          } },
          ouro.column { key = "scopes", gap = 0, cross_alignment = "stretch", children = {
            ouro.row { key = "tabs", gap = f.spacing_2, children = tabs }, rule("scope-rule", colors),
          } },
          list,
          ouro.text { key = "status", text = status or ("↑ ↓  Navigate     Enter  " .. (state.confirming() and "Choose" or "Open")
              .. "     Esc  " .. ((state.page() or state.confirming()) and "Back" or "Close")),
            size = f.typography_2, foreground = state.message() and colors.error or colors.muted, max_lines = 2 },
        } },
      } },
    } },
  } }
end

return M
