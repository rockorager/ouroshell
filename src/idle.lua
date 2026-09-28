local ouro = require("ouro")
local support = require("dbus_support")
local config = require("config")
local lock = require("lock")
local M = {}
local service = "org.freedesktop.login1"
local path = "/org/freedesktop/login1"
local manager = service .. ".Manager"
local session_interface = service .. ".Session"

function M.connect(services)
  local state = { caffeinated = ouro.signal(false), status = ouro.signal(nil) }
  local connection
  local timers, outputs = {}, {}
  local revision = 0
  local sleeping, blanked, power_due, suspend_due = false, false, false, false
  local restart_timers

  local function report(message) state.status:set(message) end
  local function call(bus, target, interface, member, signature, args)
    return support.need(bus:call { destination = service, path = target, interface = interface,
      member = member, signature = signature, args = args, timeout_ms = 5000 })
  end
  local function inhibit(record, what, why, mode)
    local reply = call(record.bus, path, manager, "Inhibit", "ssss", { what, "Ouroshell", why, mode })
    assert(reply.signature == "h" and reply.args[1], "Invalid logind inhibitor reply")
    local fd = reply.args[1]
    if connection ~= record then fd:close(); error("Logind disconnected during the inhibitor request") end
    return fd
  end
  local function close_fd(record, key)
    if record and record[key] then record[key]:close(); record[key] = nil end
  end
  local function display_power(off)
    blanked = off
    for name, output in pairs(outputs) do
      if output.handle then
        local ok = pcall(function() output.handle:set(not off) end)
        if not ok then report("Display power control failed for " .. name) end
      end
    end
  end
  local function hint(locked)
    local record = connection
    if not record or not record.session then return end
    ouro.spawn_app(function()
      -- LockedHint is advisory. Never use it as lock acknowledgement.
      pcall(call, record.bus, record.session, session_interface, "SetLockedHint", "b", { locked })
    end)
  end
  local function apply_due()
    if not state.locker.secured() then return end
    if sleeping then close_fd(connection, "delay"); return end
    if state.caffeinated() then return end
    if power_due then display_power(true) end
    if suspend_due then
      suspend_due = false
      local record, version = connection, revision
      ouro.spawn_app(function()
        if sleeping or state.caffeinated() or revision ~= version or not state.locker.secured() then return end
        if not record or connection ~= record then report("Idle suspend is unavailable; logind is disconnected."); return end
        local ok, failure = pcall(call, record.bus, path, manager, "Suspend", "b", { false })
        if not ok then report("Idle suspend failed: " .. tostring(failure)) end
      end)
    end
  end

  state.locker = lock.new {
    dismiss = services.dismiss,
    locked = function() hint(true); apply_due() end,
    unlocked = function()
      hint(false)
      display_power(false)
      restart_timers()
      -- Suspend may have arrived after authentication queued unlock. Do not
      -- release its delay inhibitor until this replacement lock is acknowledged.
      if sleeping then state.locker.request() end
    end,
    failure = function(message) power_due = false; suspend_due = false; report(message) end,
  }
  function state.lock()
    display_power(false)
    state.locker.request()
  end

  restart_timers = function()
    revision = revision + 1
    local version = revision
    for _, timer in ipairs(timers) do timer:close() end
    timers = {}
    power_due, suspend_due = false, false
    if sleeping or state.caffeinated() then return end
    for _, stage in ipairs({ { "lock", config.idle.lock_ms }, { "power", config.idle.power_ms },
      { "suspend", config.idle.suspend_ms } }) do
      -- Every caller is already app-scoped, including launcher actions.
      -- Ordinary spawn also permits staging native timers during reload.
      ouro.spawn(function()
        if revision ~= version then return end
        local ok, failure = pcall(function()
          local timer <close> = ouro.session.idle(stage[2])
          timers[#timers + 1] = timer
          while revision == version do
            local event = timer:next()
            if revision ~= version then return end
            if event == "idled" then
              if stage[1] == "power" then power_due = true
              elseif stage[1] == "suspend" then suspend_due = true end
              state.locker.request()
              apply_due()
            elseif event == "resumed" then
              if stage[1] == "power" then power_due = false; display_power(false)
              elseif stage[1] == "suspend" then suspend_due = false end
            else
              error("Idle notifications unavailable")
            end
          end
        end)
        if not ok and revision == version then report(tostring(failure)) end
      end)
    end
  end
  -- app.run evaluates reload candidates too. Tasks may run during evaluation;
  -- their native idle effects remain staged until commit.
  ouro.spawn(restart_timers)

  -- Full native output snapshots, independent of workspaces or UI builds.
  ouro.spawn(function()
    local stream <close> = ouro.session.outputs()
    while true do
      local names = stream:next()
      if not names then report("Output discovery is unavailable."); return end
      local present = {}
      for _, name in ipairs(names) do present[name] = true end
      for name, output in pairs(outputs) do
        if not present[name] then
          outputs[name] = nil
          if output.handle then output.handle:close() end
        end
      end
      for _, name in ipairs(names) do
        if not outputs[name] then
          local output = {}
          outputs[name] = output
          ouro.spawn(function()
            local retry = 1000
            while outputs[name] == output do
              local ok = pcall(function()
                local power <close> = ouro.session.power(name)
                output.handle = power
                local first = true
                while outputs[name] == output do
                  local event = power:next()
                  if outputs[name] ~= output then return end
                  if event ~= "on" and event ~= "off" then error("Power control unavailable") end
                  if first then power:set(not blanked); first = false end
                  retry = 1000
                end
              end)
              output.handle = nil
              if outputs[name] ~= output then return end
              if not ok then report("Display power control unavailable for " .. name) end
              ouro.sleep(retry)
              retry = math.min(retry * 2, 30000)
            end
          end)
        end
      end
    end
  end)

  function state.toggle()
    if state.caffeinated() then
      close_fd(connection, "caffeine")
      state.caffeinated:set(false)
    else
      local record = assert(connection, "Idle control is unavailable; logind is not connected")
      record.caffeine = inhibit(record, "idle", "Caffeinated from the launcher", "block")
      state.caffeinated:set(true)
      display_power(false)
    end
    state.status:set(nil)
    restart_timers()
  end

  local function prepare(value)
    if sleeping == value then return end
    sleeping = value
    state.locker.prepare_for_sleep(value)
    restart_timers()
    if value then
      state.locker.request()
      apply_due()
    else
      display_power(false)
    end
  end

  support.supervise { bus = "system", session = function(bus, healthy)
    -- One ordered stream covers sleep and this session's explicit Lock signal.
    local events <close> = support.need(bus:subscribe {
      sender = service, close_on_owner_change = true,
    })
    local record = { bus = bus }
    connection = record
    record.delay = inhibit(record, "sleep", "Lock the session before sleep", "delay")
    record.session = call(bus, path, manager, "GetSession", "s", { "auto" }).args[1]
    local properties = call(bus, record.session, "org.freedesktop.DBus.Properties", "GetAll", "s", { session_interface })
    local username = support.properties(properties.args[1]).Name
    assert(type(username) == "string" and username ~= "", "Logind returned no session account")
    state.locker.set_identity(username)
    local preparing = call(bus, path, "org.freedesktop.DBus.Properties", "Get", "ss", { manager, "PreparingForSleep" }).args[1]
    assert(preparing.signature == "b", "Invalid logind sleep state")
    prepare(preparing.value)
    apply_due()
    healthy()
    while true do
      local message = support.need(events:next())
      if message.path == path and message.interface == manager and message.member == "PrepareForSleep"
        and message.signature == "b" then
        prepare(message.args[1])
        if message.args[1] == false and not record.delay then
          record.delay = inhibit(record, "sleep", "Lock the session before sleep", "delay")
        end
      elseif message.path == record.session and message.interface == session_interface and message.member == "Lock" then
        state.lock()
      end
      -- Session.Unlock and LockedHint are never authorization to unlock.
    end
  end, down = function()
    close_fd(connection, "delay")
    close_fd(connection, "caffeine")
    connection = nil
    if state.caffeinated() then state.caffeinated:set(false); restart_timers() end
    report("Logind is disconnected; lock-before-suspend and idle suspend are unavailable.")
  end }
  return state
end

return M
