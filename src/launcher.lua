local ouro = require("ouro")
local appearance = require("appearance")
local f = ouro.tokens.foundation

local M = {}
local visible_rows = 7
-- Layout dimensions shared by rendering and keyboard paging. Result rows
-- accommodate two text lines; the frame surrounds the 560x620 content area.
local row_height, palette_height = 56, 620
local search_height, tab_height = f.spacing_8, f.spacing_6
local frame_padding = f.spacing_4

function M.background()
  -- The opaque card carries contrast; keep the blurred backdrop light-touch
  -- and dark-tinted even when the content uses the light palette.
  return ouro.tokens.dark.background:sub(1, 7) .. "4D"
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
  local options = entry.terminal and { terminal_argv = { "monstar", "-e" } } or nil
  local launch = options and prepare_launch(entry, options) or prepare_launch(entry)
  local argv = {}
  if launch.cwd and launch.cwd ~= ouro.json.null then
    argv = { "env", "--chdir=" .. launch.cwd, "--" }
  end
  for _, argument in ipairs(launch.argv) do argv[#argv + 1] = argument end
  return argv
end

function M.new(services)
  services = services or {}
  local state = {
    entries = ouro.signal(services.entries or {}),
    query = ouro.signal(""), selected = ouro.signal(1), first = ouro.signal(1),
    scope = ouro.signal("all"), page = ouro.signal(nil), confirming = ouro.signal(nil),
    input_generation = ouro.signal(0),
    phase = ouro.signal(services.phase or "loading"),
    message = ouro.signal(nil), launching = ouro.signal(false),
  }

  function state.results()
    local query = normalized(state.query())
    local results = {}
    if not state.page() and state.scope() ~= "system" then
      results = M.search(state.entries(), query)
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
    state.first:set(1)
    state.message:set(nil)
  end
  local function refocus()
    -- Re-mount after a mouse action: autofocus on a retained input is one-shot.
    state.input_generation:set(state.input_generation() + 1)
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
      state.first:set(1)
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
  function state.move(delta, capacity)
    capacity = capacity or visible_rows
    local count = state.confirming() and 2 or #state.results()
    if count == 0 then state.selected:set(1); state.first:set(1); return end
    local selected = ((state.selected() - 1 + delta) % count) + 1
    local first = state.first()
    if selected < first then first = selected
    elseif selected >= first + capacity then first = selected - capacity + 1 end
    state.selected:set(selected)
    state.first:set(math.min(first, math.max(1, count - capacity + 1)))
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
  function state.command(command, capacity)
    if command == "next" then state.move(1, capacity)
    elseif command == "previous" then state.move(-1, capacity)
    elseif command == "submit" then
      if state.confirming() then
        if state.selected() == 2 then state.confirm() else state.back() end
      else state.launch() end
    elseif command == "cancel" then state.back() end
  end
  function state.load()
    ouro.spawn(function()
      local ok, entries = pcall((services.list or ouro.xdg.applications.list))
      if ok then
        state.entries:set(entries)
        state.phase:set("ready")
      else
        state.phase:set("error")
        state.message:set("Applications could not be loaded: " .. tostring(entries))
      end
    end)
  end
  return state
end

local function icon(key, name, size, tint)
  return ouro.xdg.icon { key = key, name = name, theme = "Adwaita", width = size, height = size, tint = tint, alt = "" }
end

local function rule(key, colors)
  return ouro.box { key = key, height = f.border_width_default, width = "fill", background = colors.line }
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
    key = (entry.kind == "system" and "system-" or "application-") .. entry.id,
    label = entry.name, height = row_height,
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
  -- Ourokit has no box-shadow primitive. Rasterize a decorative SVG behind
  -- the card, using the actual viewport so the shadow also follows resizing.
  local shadow = string.format([[<svg xmlns="http://www.w3.org/2000/svg" width="%g" height="%g">
    <defs><filter id="shadow" x="-50%%" y="-50%%" width="200%%" height="200%%">
      <feGaussianBlur stdDeviation="12"/>
    </filter></defs>
    <rect x="%g" y="%g" width="%g" height="%g" rx="%g" fill="black" fill-opacity="0.4" filter="url(#shadow)"/>
  </svg>]], width, height, (width - frame_width) / 2, (height - frame_height) / 2 + f.spacing_2,
    frame_width, frame_height, f.radius_6)
  local colors = {
    selected = theme.accent_selected, selected_border = theme.ring,
    foreground = theme.foreground, muted = theme.muted_foreground,
    error = palette.red.step_11, input = theme.surface, input_border = theme.input,
    border = theme.border, accent = theme.primary, hover = theme.accent_hover,
    transparent = ouro.tokens.palette.transparent, line = theme.border,
  }
  local results = state.results()
  local has_apps, has_system = false, false
  for _, entry in ipairs(results) do
    if entry.kind == "system" then has_system = true else has_apps = true end
  end
  local heading_space = f.line_height_2 + f.spacing_1
  if has_apps and has_system then heading_space = 2 * heading_space + f.border_width_default + f.spacing_1 end
  -- Keep the keyboard-selected row visible on short outputs as well. Content
  -- callbacks receive configured logical dimensions; no layout-time mutation.
  local scopes_height = tab_height + f.border_width_strong + f.border_width_default
  local chrome_height = search_height + scopes_height + 3 * f.spacing_4 + 2 * f.line_height_2
  local available = frame_height - 2 * frame_padding - chrome_height - heading_space
  local capacity = math.max(1, math.min(visible_rows, math.floor((available + f.spacing_1) / (row_height + f.spacing_1))))
  local first = math.max(1, math.min(state.first(), #results - capacity + 1))
  if state.selected() < first then first = state.selected()
  elseif state.selected() >= first + capacity then first = state.selected() - capacity + 1 end
  local rows, group = {}, nil
  for index = first, math.min(#results, first + capacity - 1) do
    local entry = results[index]
    local next_group = entry.kind == "system" and (state.page() and "Session" or "System") or "Applications"
    if next_group ~= group then
      if group then rows[#rows + 1] = rule("rule-" .. next_group, colors) end
      rows[#rows + 1] = ouro.text { key = "heading-" .. next_group, text = next_group, size = f.typography_2, foreground = colors.muted }
      group = next_group
    end
    rows[#rows + 1] = result_row(state, entry, index, colors)
  end
  if #results == 0 then
    rows[1] = ouro.text { key = "empty", text = "No matches. Try another name or keyword.", size = f.typography_3, foreground = colors.muted }
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
    if state.phase() == "loading" then status = "Loading applications…"
    elseif state.phase() == "error" then status = "Applications unavailable. System actions are still available." end
  end
  return ouro.stack { key = "launcher", children = {
    ouro.image { key = "shadow", bytes = shadow, width = "fill", height = "fill", fit = "fill", alt = "" },
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
                key = "search-" .. state.input_generation(), text = state.confirming() and "" or state.query(),
                label = "Search apps and commands", placeholder = state.confirming() and "Confirmation" or "Search apps and commands…",
                autofocus = true, read_only = state.confirming() ~= nil, flex = 1,
                padding_x = 0, border_width = 0, background = colors.transparent,
                foreground = colors.foreground, on_change = state.change,
                on_command = function(command) state.command(command, capacity) end,
              },
              ouro.box { key = "search-inset-end", width = f.spacing_1 },
            } },
          } },
          ouro.column { key = "scopes", gap = 0, cross_alignment = "stretch", children = {
            ouro.row { key = "tabs", gap = f.spacing_2, children = tabs }, rule("scope-rule", colors),
          } },
          ouro.scroll { key = "results-scroll", axis = "vertical", flex = 1, children = {
            state.confirming() and confirmation(state, colors) or ouro.column { key = "results", gap = f.spacing_1, cross_alignment = "stretch", children = rows },
          } },
          ouro.text { key = "status", text = status or ("↑ ↓  Navigate     Enter  " .. (state.confirming() and "Choose" or "Open")
              .. "     Esc  " .. ((state.page() or state.confirming()) and "Back" or "Close")),
            size = f.typography_2, foreground = state.message() and colors.error or colors.muted, max_lines = 2 },
        } },
      } },
    } },
  } }
end

return M
