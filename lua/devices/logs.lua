--- Log streams from devices: what each device offers, how to read its lines, and a session that
--- runs the stream and filters it to one app. No UI here; see devices.view for the buffer.
local android = require("devices.backend.android")
local err = require("devices.error")
local ios = require("devices.backend.ios")
local process = require("devices.process")

local M = {}

-- Levels -------------------------------------------------------------------------------------

M.levels = { "verbose", "debug", "info", "warning", "error", "fatal" }
M.rank = { verbose = 1, debug = 2, info = 3, warning = 4, error = 5, fatal = 6 }

local ANDROID_RANK = { V = 1, D = 2, I = 3, W = 4, E = 5, F = 6, A = 6 }
-- os_log types in `log stream --style compact`: Db debug, I info, Df default, E error, F fault.
-- "A" lines are activities.
local IOS_RANK = { Db = 2, I = 3, Df = 3, A = 3, E = 5, F = 6 }

---@class devices.LogLine
---@field text string
---@field level integer? 1 (verbose) to 6 (fatal), nil when the line has no header.
---@field pid string?

--- Read an Android `logcat -v threadtime` line: "11-13 20:49:44.298   917  1126 D Tag: msg".
---@param line string
---@return devices.LogLine
function M.parse_android(line)
  local pid, level = line:match("^%d%d%-%d%d%s+%d%d:%d%d:%d%d%.%d+%s+(%d+)%s+%d+%s+([VDIWEFA])%s")
  return { text = line, level = level and ANDROID_RANK[level], pid = pid }
end

--- Read an iOS `log stream --style compact` line:
--- "2026-11-13 20:56:36.411 Df Runner[30348:6e9c9] message".
---@param line string
---@return devices.LogLine
function M.parse_ios(line)
  local kind, pid = line:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d%.%d+%s+(%a+)%s+[^%[]+%[(%d+)")
  return { text = line, level = kind and IOS_RANK[kind], pid = pid }
end

--- Plain output (an app's console): errors are only recognisable by their text.
---@param line string
---@return devices.LogLine
function M.parse_plain(line)
  return { text = line }
end

-- Following an Android app --------------------------------------------------------------------

---@class devices.AppFilter
---@field add_pids fun(pids: string[])
---@field accept fun(line: devices.LogLine): boolean

--- Keep the lines of one app, across restarts. An app gets a new pid each time it starts, so
--- pids are learned from ActivityManager's "Start proc <pid>:<package>/..." line (instant) and
--- from polling `pidof` (catches an app that was already running). Lines that mention the
--- package, such as a crash report from the system, are kept too.
---@param package string
---@return devices.AppFilter
function M.android_app_filter(package)
  local pids = {}
  local start_pattern = "Start proc (%d+):" .. vim.pesc(package) .. "[/:%s]"
  return {
    add_pids = function(list)
      for _, pid in ipairs(list) do
        pids[pid] = true
      end
    end,
    accept = function(line)
      local started = line.text:match(start_pattern)
      if started then
        pids[started] = true
        return true
      end
      if line.pid and pids[line.pid] then
        return true
      end
      return line.text:find(package, 1, true) ~= nil
    end,
  }
end

-- What a device offers --------------------------------------------------------------------------

---@alias devices.LogMode "logcat"|"system"|"console"

---@class devices.LogModeInfo
---@field id devices.LogMode
---@field label string
---@field app "optional"|"required"

--- The log streams a device can give right now. Empty when it is not running.
---@param device devices.Device
---@return devices.LogModeInfo[]
function M.modes(device)
  local ready = device.state == "booted" or device.state == "connected"
  if not ready then
    return {}
  end
  if device.platform == "android" then
    return { { id = "logcat", label = "logcat (optionally only one app)", app = "optional" } }
  end
  if device.kind == "simulator" then
    return {
      { id = "system", label = "System log (optionally only one app)", app = "optional" },
      { id = "console", label = "Launch an app and show its output (print, NSLog)", app = "required" },
    }
  end
  return {
    { id = "console", label = "Launch an app and show its output (print, NSLog)", app = "required" },
    { id = "system", label = "Device system log (needs idevicesyslog)", app = "optional" },
  }
end

-- Sessions ----------------------------------------------------------------------------------

---@class devices.LogSpec
---@field device devices.Device
---@field mode devices.LogMode
---@field app string? Android package or iOS bundle id.
---@field tail integer? Android: how many earlier lines to show first. Default 1000.
---@field android devices.AndroidOptions?
---@field detach boolean? false keeps the stream in Neovim's process group, for the terminal command.

---@class devices.LogHandlers
---@field on_lines fun(lines: devices.LogLine[])
---@field on_exit fun(error: devices.Error?, res: table?) error is nil when the stream was stopped.
---@field on_status? fun(message: string)

---@class devices.LogSession
---@field stop fun()
---@field argv string[]? The command, once it started.

---@param device devices.Device
---@param mode devices.LogMode
---@return devices.Error?
local function check_mode(device, mode)
  for _, m in ipairs(M.modes(device)) do
    if m.id == mode then
      return nil
    end
  end
  if device.state ~= "booted" and device.state ~= "connected" then
    return err.new("invalid_state", device.name .. " is not running", { hint = "Boot or connect it first." })
  end
  return err.new("unsupported", ("%s has no %s log"):format(device.name, mode))
end

--- Whether `id` looks like an Android package or an iOS bundle id. adb joins `shell` arguments
--- into one command line for the device's shell, so anything else is refused before it gets there.
---@param id string
---@return boolean
function M.valid_app_id(id)
  return id:match("^[%w_][%w._%-]*$") ~= nil
end

-- An iOS process name goes into a log predicate, so only plain names are allowed.
---@param name string
---@return boolean
local function safe_process_name(name)
  return name:match("^[%w][%w._%- ]*$") ~= nil
end

local PIDOF_POLL_MS = 2000

--- Start streaming. Returns at once; problems arrive through `on_exit`.
---@param spec devices.LogSpec
---@param handlers devices.LogHandlers
---@return devices.LogSession
function M.start(spec, handlers)
  local device = spec.device
  local session = { stopped = false }
  local stream, poll_timer
  local finished = false

  local function finish(failure, res)
    if poll_timer and not poll_timer:is_closing() then
      poll_timer:close()
    end
    if finished then
      return
    end
    finished = true
    handlers.on_exit(failure, res)
  end

  function session.stop()
    if session.stopped then
      return
    end
    session.stopped = true
    if poll_timer and not poll_timer:is_closing() then
      poll_timer:close()
    end
    if stream then
      stream.stop()
    else
      -- Stopped while still looking something up: nothing will run, so end here.
      vim.schedule(function()
        finish(nil)
      end)
    end
  end

  ---@param argv string[]
  ---@param parse fun(line: string): devices.LogLine
  ---@param filter devices.AppFilter?
  local function run(argv, parse, filter)
    if session.stopped then
      return
    end
    session.argv = argv
    -- Error output is shown like any other line, and its end also explains a failure.
    local recent_errors = {}
    stream = process.stream(argv, { detach = spec.detach }, function(lines, source)
      if source == "stderr" then
        vim.list_extend(recent_errors, lines)
        if #recent_errors > 20 then
          recent_errors = vim.list_slice(recent_errors, #recent_errors - 19)
        end
      end
      local out = {}
      for _, text in ipairs(lines) do
        local line = parse(text)
        if not filter or filter.accept(line) then
          out[#out + 1] = line
        end
      end
      if #out > 0 then
        handlers.on_lines(out)
      end
    end, function(res)
      if res.stopped then
        return finish(nil, res)
      end
      local with_errors = vim.tbl_extend("force", res, { stderr = table.concat(recent_errors, "\n") })
      local failure = err.from_process(with_errors, argv, { guide = device.platform })
      if not failure then
        failure = err.new("command_failed", "The log stream ended", { cmd = argv })
      end
      finish(failure, res)
    end)
  end

  local function fail(failure)
    vim.schedule(function()
      if not session.stopped then
        finish(failure)
      end
    end)
  end

  local invalid = check_mode(device, spec.mode)
  if invalid then
    fail(invalid)
    return session
  end
  if spec.mode == "console" and not spec.app then
    fail(err.new("invalid_state", "Launching an app needs its bundle id"))
    return session
  end
  if spec.app and not M.valid_app_id(spec.app) then
    fail(err.new("invalid_state", "That does not look like an app id: " .. spec.app, {
      hint = "Use a package name or bundle id, such as com.example.app.",
    }))
    return session
  end

  -- Android ----------------------------------------------------------------------------------
  if device.platform == "android" then
    local adb, missing = android.tool("adb", spec.android)
    if not adb then
      fail(missing)
      return session
    end
    local serial = device.serial or device.id
    local argv = { adb, "-s", serial, "logcat", "-v", "threadtime", "-T", tostring(spec.tail or 1000) }
    if not spec.app then
      run(argv, M.parse_android)
      return session
    end

    local filter = M.android_app_filter(spec.app)
    ---@param done? fun()
    local function poll(done)
      process.run({ adb, "-s", serial, "shell", "pidof", spec.app }, { timeout = 5000 }, function(res)
        if res.code == 0 then
          filter.add_pids(vim.split(vim.trim(res.stdout), "%s+", { trimempty = true }))
        end
        if done then
          done()
        end
      end)
    end
    -- Ask first, so the earlier lines of an app that is already running are not dropped for
    -- arriving before its pid is known.
    poll(function()
      if session.stopped then
        return
      end
      run(argv, M.parse_android, filter)
      poll_timer = assert(vim.uv.new_timer())
      vim.uv.update_time()
      poll_timer:start(PIDOF_POLL_MS, PIDOF_POLL_MS, vim.schedule_wrap(poll))
    end)
    return session
  end

  -- iOS --------------------------------------------------------------------------------------
  if spec.mode == "console" then
    local argv
    if device.kind == "simulator" then
      -- A PTY keeps the app's stdout line-buffered, so print() output arrives at once.
      argv = { "xcrun", "simctl", "launch", "--console-pty", "--terminate-running-process", device.id, spec.app }
    else
      argv = {
        "xcrun",
        "devicectl",
        "device",
        "process",
        "launch",
        "--device",
        device.id,
        "--console",
        "--terminate-existing",
        spec.app,
      }
    end
    if handlers.on_status then
      handlers.on_status("Launching " .. spec.app .. ". Its output appears below.")
    end
    run(argv, M.parse_plain)
    return session
  end

  if device.kind == "physical" then
    if vim.fn.executable("idevicesyslog") == 0 then
      fail(err.new("tool_missing", "idevicesyslog was not found", {
        hint = "Install libimobiledevice (brew install libimobiledevice) for the live system log. "
          .. "For your own app, the app console needs nothing extra. "
          .. "To save past logs instead: sudo log collect --device-udid "
          .. device.id
          .. " --last 10m",
        guide = "ios",
      }))
      return session
    end
    run({ "idevicesyslog", "-u", device.id }, M.parse_plain)
    return session
  end

  -- Simulator system log. Without an app it is very busy, so debug messages only come with one.
  local base = { "xcrun", "simctl", "spawn", device.id, "log", "stream", "--style", "compact" }
  if not spec.app then
    run(base, M.parse_ios)
    return session
  end
  ios.app_executable(device, spec.app, function(name, failure)
    if session.stopped then
      return
    end
    if failure then
      return finish(failure)
    end
    if not safe_process_name(name) then
      return finish(err.new("unsupported", "Unusual app executable name: " .. name))
    end
    if handlers.on_status then
      handlers.on_status(("Showing process %q (%s), including debug messages"):format(name, spec.app))
    end
    run(vim.list_extend(base, { "--level", "debug", "--predicate", ('process == "%s"'):format(name) }), M.parse_ios)
  end)
  return session
end

return M
