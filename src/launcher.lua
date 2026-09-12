local ouro = require("ouro")

local M = {}

local colors = {
  selected = "#293B70",
  foreground = "#F1F3F5", muted = "#A7ABB2", error = "#FF9592",
  transparent = "#00000000", hover = "#2B2E33",
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
    query = ouro.signal(""), selected = ouro.signal(1),
    phase = ouro.signal(services.phase or "loading"),
    message = ouro.signal(nil), launching = ouro.signal(false),
  }

  function state.results() return M.search(state.entries(), state.query()) end
  function state.change(value)
    state.query:set(value)
    state.selected:set(1)
    state.message:set(nil)
  end
  function state.move(delta)
    local count = #state.results()
    if count == 0 then state.selected:set(1); return end
    state.selected:set(((state.selected() - 1 + delta) % count) + 1)
  end
  function state.launch(entry)
    entry = entry or state.results()[state.selected()]
    if not entry or state.launching() then return end
    state.launching:set(true)
    state.message:set(nil)
    ouro.spawn(function()
      local ok, failure = pcall(function()
        local argv = M.launch_argv(entry, services.prepare_launch or ouro.xdg.applications.prepare_launch)
        local runtime = assert(ouro.xdg.runtime_dir, "XDG_RUNTIME_DIR is unavailable")
        local reply = (services.call or ouro.mcp.call)("unix:" .. runtime .. "/ouro.mcp.sock", "run", { argv = argv })
        if reply.error then error(reply.error.message) end
        if reply.result and reply.result.isError then
          local detail = reply.result.structuredContent and reply.result.structuredContent.error
          error(detail and detail.message or "Ouro rejected the launch")
        end
      end)
      state.launching:set(false)
      if ok then services.dismiss() else state.message:set("Could not launch: " .. tostring(failure)) end
    end)
  end
  function state.command(command)
    if command == "next" then state.move(1)
    elseif command == "previous" then state.move(-1)
    elseif command == "submit" then state.launch()
    elseif command == "cancel" then services.dismiss() end
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

local function status(state, results)
  local message = state.message()
  if message then return message, colors.error end
  if state.phase() == "loading" then return "Loading applications…", colors.muted end
  if #results == 0 then return "No matching applications", colors.muted end
  if state.launching() then return "Asking Ouro to launch…", colors.muted end
  return "↑↓ select   Enter launch   Esc close", colors.muted
end

function M.content(state)
  local results, selected = state.results(), state.selected()
  local rows = {}
  local first = math.max(1, selected - 6)
  for index = first, math.min(#results, first + 6) do
    local entry = results[index]
    local icon = entry.icon
    if not icon or icon == ouro.json.null then icon = "application-x-executable" end
    rows[#rows + 1] = ouro.box {
      key = "application-" .. entry.id, height = 44, padding = 6,
      children = { ouro.row { key = "row", gap = 12, cross_alignment = "center", children = {
        ouro.xdg.icon {
          key = "icon", name = icon, theme = "hicolor", width = 28, height = 28, alt = entry.name,
        },
        ouro.button {
          key = "launch", label = entry.name, height = 32, padding_x = 8,
          background = index == selected and colors.selected or colors.transparent,
          foreground = colors.foreground, hover = colors.hover,
          on_press = function() state.launch(entry) end,
        },
      } } },
    }
  end
  local text, foreground = status(state, results)
  return ouro.box {
    key = "scrim", width = "fill", height = "fill", alignment = "center",
    children = {
      ouro.box {
        key = "palette", width = 620, surface = "card", padding = 16,
        children = {
          ouro.column { key = "content", gap = 10, cross_alignment = "stretch", children = {
            ouro.text { key = "heading", text = "Search applications", size = 14, foreground = colors.muted },
            ouro.text_input {
              key = "search", text = state.query(), autofocus = true, height = 44,
              on_change = state.change, on_command = state.command,
            },
            ouro.column { key = "results", gap = 3, cross_alignment = "stretch", children = rows },
            ouro.text { key = "status", text = text, size = 12, foreground = foreground, max_lines = 2 },
          } },
        },
      },
    },
  }
end

return M
