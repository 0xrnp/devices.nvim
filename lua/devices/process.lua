--- Every external command goes through here. Commands are argv lists (never a shell string),
--- always have a timeout, and report failure in the result instead of throwing.
local M = {}

local DEFAULT_TIMEOUT_MS = 30000
local DEFAULT_GRACE_MS = 3000
local LOG_TAIL_BYTES = 4096
-- After SIGTERM on timeout, how long a process group gets before SIGKILL.
local KILL_AFTER_MS = 2000

---@class devices.ProcessResult
---@field code integer Exit code. -1 when the process could not be started.
---@field signal integer Terminating signal, 0 when none.
---@field stdout string
---@field stderr string
---@field timed_out boolean The timeout elapsed and the process was killed.
---@field missing boolean The executable was not found.

---@param fields table
---@return devices.ProcessResult
local function result(fields)
  return vim.tbl_extend("force", {
    code = -1,
    signal = 0,
    stdout = "",
    stderr = "",
    timed_out = false,
    missing = false,
  }, fields)
end

---@param argv any
---@param cb any
---@param name string
local function check_args(argv, cb, name)
  assert(type(argv) == "table" and #argv > 0, name .. ": argv must be a non-empty list")
  assert(type(cb) == "function", name .. ": a callback is required")
end

-- Commands still running, so they can be stopped when Neovim exits. The value says whether the
-- pid leads its own process group (then the whole group is stopped) or not.
local running = {} ---@type table<integer, { group: boolean }>
local exit_hook = false

---@param pid integer
---@param signal string
---@param group? boolean Default true.
local function kill_group(pid, signal, group)
  -- A negative pid signals the whole group: the command and every child it started.
  pcall(vim.uv.kill, group == false and pid or -pid, signal)
end

local function stop_running_on_exit()
  if exit_hook then
    return
  end
  exit_hook = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("devices.process", { clear = true }),
    callback = function()
      for pid, info in pairs(running) do
        kill_group(pid, "sigterm", info.group)
      end
    end,
  })
end

--- Run a command and call `cb` once with the result, always from the main loop.
---
--- The command runs in its own process group, and a timeout stops the whole group. Wrapper
--- tools (sdkmanager, flutter, xcrun) start children that hold the output pipes, so killing only
--- the command would leave them running and delay the result until they finish on their own.
---@param argv string[]
---@param opts? { timeout?: integer, env?: table<string, string>, cwd?: string, stdin?: string }
---@param cb fun(res: devices.ProcessResult)
function M.run(argv, opts, cb)
  check_args(argv, cb, "devices.process.run")
  opts = opts or {}

  if vim.fn.executable(argv[1]) == 0 then
    vim.schedule(function()
      cb(result({ missing = true, stderr = argv[1] .. ": command not found" }))
    end)
    return
  end

  local timer = assert(vim.uv.new_timer())
  local timed_out, pid = false, nil

  local started, obj = pcall(vim.system, argv, {
    text = true,
    detach = true,
    env = opts.env,
    cwd = opts.cwd,
    stdin = opts.stdin,
  }, function(out)
    -- Stop it here, not in the scheduled callback, so a timer that is due cannot fire in between
    -- and call a normal exit a timeout.
    timer:stop()
    vim.schedule(function()
      if not timer:is_closing() then
        timer:close()
      end
      if pid then
        running[pid] = nil
      end
      cb(result({
        -- 124, as vim.system and timeout(1) report a timeout.
        code = timed_out and 124 or out.code,
        signal = out.signal or 0,
        stdout = out.stdout or "",
        stderr = out.stderr or "",
        timed_out = timed_out,
      }))
    end)
  end)

  if not started then
    timer:close()
    local message = tostring(obj)
    vim.schedule(function()
      cb(result({ missing = message:find("ENOENT", 1, true) ~= nil, stderr = message }))
    end)
    return
  end

  pid = obj.pid
  running[pid] = { group = true }
  stop_running_on_exit()
  -- Timers count from the loop's cached clock, which is stale after Neovim was busy. Without
  -- this, a timeout started then fires early and kills a healthy command.
  vim.uv.update_time()
  timer:start(opts.timeout or DEFAULT_TIMEOUT_MS, KILL_AFTER_MS, function()
    if not running[pid] then
      return
    end
    -- First tick: ask politely. Every later tick: force it.
    kill_group(pid, timed_out and "sigkill" or "sigterm")
    timed_out = true
  end)
end

--- Split a byte stream into lines. Returns a handler for vim.system's stdout/stderr callback.
--- A trailing partial line is kept until the next chunk, or until the stream ends.
---@param emit fun(lines: string[])
---@return fun(err: string?, data: string?)
local function line_splitter(emit)
  local rest = ""
  return function(_, data)
    if data == nil then
      if rest ~= "" then
        local last = rest:gsub("\r$", "")
        rest = ""
        emit({ last })
      end
      return
    end
    local lines = vim.split(rest .. data, "\n", { plain = true })
    rest = table.remove(lines)
    if #lines > 0 then
      for i, line in ipairs(lines) do
        lines[i] = line:gsub("\r$", "")
      end
      emit(lines)
    end
  end
end

---@class devices.Stream
---@field stop fun() Stop the command and everything it started. Safe to call more than once.
---@field is_running fun(): boolean

--- Run a long-lived command (a log stream) and hand its output over line by line.
--- `on_lines` and `on_exit` are called from the main loop, in order, and `on_exit` exactly once.
--- After `stop()`, no more lines are delivered and `on_exit` gets `stopped = true`.
---
--- By default the command gets its own process group, so Ctrl-C in Neovim does not end it and
--- stop() ends everything it started. `detach = false` keeps it in Neovim's group instead,
--- which a terminal command wants: Ctrl-C then reaches the stream directly.
---@param argv string[]
---@param opts? { env?: table<string, string>, cwd?: string, detach?: boolean }
---@param on_lines fun(lines: string[], source: "stdout"|"stderr")
---@param on_exit fun(res: devices.ProcessResult|{ stopped: boolean })
---@return devices.Stream
function M.stream(argv, opts, on_lines, on_exit)
  check_args(argv, on_exit, "devices.process.stream")
  assert(type(on_lines) == "function", "devices.process.stream: on_lines is required")
  opts = opts or {}

  local stopped, finished, pid = false, false, nil
  local handle = {
    stop = function() end,
    is_running = function()
      return not finished
    end,
  }

  local function finish(fields)
    vim.schedule(function()
      finished = true
      on_exit(vim.tbl_extend("force", result(fields), { stopped = stopped }))
    end)
  end

  if vim.fn.executable(argv[1]) == 0 then
    finish({ missing = true, stderr = argv[1] .. ": command not found" })
    return handle
  end

  local function deliver(source)
    return line_splitter(function(lines)
      vim.schedule(function()
        if not stopped then
          on_lines(lines, source)
        end
      end)
    end)
  end

  local group = opts.detach ~= false
  local started, obj = pcall(vim.system, argv, {
    detach = group,
    env = opts.env,
    cwd = opts.cwd,
    stdout = deliver("stdout"),
    stderr = deliver("stderr"),
  }, function(out)
    if pid then
      running[pid] = nil
    end
    finish({ code = out.code, signal = out.signal or 0 })
  end)

  if not started then
    local message = tostring(obj)
    finish({ missing = message:find("ENOENT", 1, true) ~= nil, stderr = message })
    return handle
  end

  pid = obj.pid
  running[pid] = { group = group }
  stop_running_on_exit()

  handle.stop = function()
    if stopped or finished then
      stopped = true
      return
    end
    stopped = true
    kill_group(pid, "sigterm", group)
    vim.uv.update_time()
    vim.defer_fn(function()
      if running[pid] then
        kill_group(pid, "sigkill", group)
      end
    end, KILL_AFTER_MS)
  end
  return handle
end

---@class devices.DetachedResult
---@field started boolean The process was spawned.
---@field pid integer?
---@field exited boolean It had already exited when the grace period ended.
---@field code integer? Exit code, when it exited.
---@field missing boolean The executable was not found.
---@field log string? Path of the file that received stdout and stderr.
---@field log_tail string The end of the log, for error messages.
---@field error string? Why it could not be started.

---@param path string
---@return string
local function read_tail(path)
  local file = io.open(path, "rb")
  if not file then
    return ""
  end
  local size = file:seek("end") or 0
  file:seek("set", math.max(0, size - LOG_TAIL_BYTES))
  local data = file:read("*a") or ""
  file:close()
  return data
end

---@param overrides table<string, string>
---@return string[]
local function merged_env(overrides)
  local env = vim.fn.environ()
  for key, value in pairs(overrides) do
    env[key] = value
  end
  local list = {}
  for key, value in pairs(env) do
    list[#list + 1] = key .. "=" .. value
  end
  return list
end

--- Start a long-running process that must outlive Neovim (an emulator). Its output goes to a
--- log file. After `grace_ms`, `cb` reports whether it is still running, so a launch that dies
--- at once (bad AVD name, missing library) is an error instead of a silent success.
---@param argv string[]
---@param opts? { log?: string, grace_ms?: integer, env?: table<string, string>, cwd?: string }
---@param cb fun(res: devices.DetachedResult)
function M.spawn_detached(argv, opts, cb)
  check_args(argv, cb, "devices.process.spawn_detached")
  opts = opts or {}

  local function fail(fields)
    vim.schedule(function()
      cb(vim.tbl_extend("force", { started = false, exited = false, missing = false, log_tail = "" }, fields))
    end)
  end

  if vim.fn.executable(argv[1]) == 0 then
    return fail({ missing = true, error = argv[1] .. ": command not found" })
  end

  local uv = vim.uv
  local log = opts.log or (vim.fn.tempname() .. ".log")
  local fd, open_err = uv.fs_open(log, "w", 420)
  if not fd then
    return fail({ error = "cannot open log file " .. log .. ": " .. tostring(open_err) })
  end

  local state = { exited = false, code = nil }
  local handle, pid_or_err
  handle, pid_or_err = uv.spawn(argv[1], {
    args = vim.list_slice(argv, 2),
    stdio = { nil, fd, fd },
    detached = true,
    cwd = opts.cwd,
    env = opts.env and merged_env(opts.env) or nil,
  }, function(code)
    state.exited = true
    state.code = code
    if handle and not handle:is_closing() then
      handle:close()
    end
  end)
  -- The child holds its own copy of the descriptor.
  uv.fs_close(fd)

  if not handle then
    return fail({ error = tostring(pid_or_err), missing = tostring(pid_or_err):find("ENOENT", 1, true) ~= nil })
  end
  -- Do not keep Neovim alive for it, or kill it when Neovim exits.
  handle:unref()

  local timer = assert(uv.new_timer())
  -- See run(): a stale loop clock would end the grace period early.
  uv.update_time()
  timer:start(opts.grace_ms or DEFAULT_GRACE_MS, 0, function()
    timer:stop()
    timer:close()
    vim.schedule(function()
      cb({
        started = true,
        pid = pid_or_err,
        exited = state.exited,
        code = state.code,
        missing = false,
        log = log,
        log_tail = read_tail(log),
      })
    end)
  end)
end

return M
