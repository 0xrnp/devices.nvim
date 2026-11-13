local h = require("helpers")
local eq, await = h.eq, h.await

local process = require("devices.process")

local T = {}

T["run: captures stdout, stderr and exit code"] = function()
  local res = await(function(cb)
    process.run({ "sh", "-c", "printf out; printf err >&2; exit 0" }, nil, cb)
  end)
  eq(res.code, 0)
  eq(res.stdout, "out")
  eq(res.stderr, "err")
  eq(res.timed_out, false)
  eq(res.missing, false)
end

T["run: reports a non-zero exit"] = function()
  local res = await(function(cb)
    process.run({ "sh", "-c", "echo boom >&2; exit 7" }, nil, cb)
  end)
  eq(res.code, 7)
  eq(res.stderr, "boom\n")
  eq(res.timed_out, false)
end

T["run: reports a missing executable without throwing"] = function()
  local res = await(function(cb)
    process.run({ "devices-nvim-no-such-tool" }, nil, cb)
  end)
  eq(res.missing, true)
  eq(res.code, -1)
  eq(res.stderr, "devices-nvim-no-such-tool: command not found")
end

T["run: reports a missing absolute path without throwing"] = function()
  local res = await(function(cb)
    process.run({ "/no/such/dir/tool" }, nil, cb)
  end)
  eq(res.missing, true)
end

T["run: kills a hung process at the timeout"] = function()
  local started = vim.uv.hrtime()
  local res = await(function(cb)
    process.run({ "sleep", "30" }, { timeout = 300 }, cb)
  end)
  local elapsed_ms = (vim.uv.hrtime() - started) / 1e6
  eq(res.timed_out, true)
  eq(elapsed_ms < 5000, true)
end

T["run: a timeout also stops children that hold the output open"] = function()
  local pidfile = h.tree({}) .. "/child.pid"
  local started = vim.uv.hrtime()
  local res = await(function(cb)
    -- The shell waits on a child that inherited stdout, as wrapper scripts do.
    -- The timeout leaves the shell time to start its child even on a busy machine.
    process.run({ "sh", "-c", 'sleep 30 & echo $! > "$1"; wait', "sh", pidfile }, { timeout = 2000 }, cb)
  end, 20000)
  local elapsed_ms = (vim.uv.hrtime() - started) / 1e6
  eq(res.timed_out, true)
  eq(res.code, 124)
  -- Without stopping the child, the result would only arrive when `sleep 30` ends.
  eq(elapsed_ms < 15000, true)

  local child = tonumber(vim.fn.readfile(pidfile)[1])
  assert(child, "the shell did not record its child")
  local alive = vim.uv.kill(child, 0) == 0
  if alive then
    vim.uv.kill(child, "sigkill")
  end
  eq(alive, false)
end

T["run: a process that ignores SIGTERM is killed anyway"] = function()
  local started = vim.uv.hrtime()
  local res = await(function(cb)
    -- An ignored signal stays ignored across exec, so `sleep` ignores SIGTERM too.
    process.run({ "sh", "-c", 'trap "" TERM; sleep 30' }, { timeout = 300 }, cb)
  end, 15000)
  local elapsed_ms = (vim.uv.hrtime() - started) / 1e6
  eq(res.timed_out, true)
  eq(elapsed_ms < 10000, true)
end

T["run: a normal exit is never reported as a timeout"] = function()
  for _ = 1, 20 do
    local res = await(function(cb)
      process.run({ "true" }, { timeout = 1 }, cb)
    end)
    -- With a 1 ms timeout either outcome can happen, but a timeout must come with code 124 and
    -- a normal exit with code 0. Never a mix.
    eq(res.timed_out == (res.code == 124), true)
    eq(res.code == 0 or res.code == 124, true)
  end
end

T["run: quitting Neovim stops commands that are still running"] = function()
  local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
  local pidfile = h.tree({}) .. "/cmd.pid"
  local out = vim
    .system({ vim.v.progpath, "--headless", "-l", root .. "/tests/fixtures/run_and_quit.lua", root, pidfile })
    :wait(15000)
  eq(out.code, 0)

  local pid = tonumber((vim.fn.readfile(pidfile)[1] or ""))
  assert(pid, "the command never started")
  local gone = vim.wait(3000, function()
    return vim.uv.kill(pid, 0) ~= 0
  end, 20)
  if not gone then
    vim.uv.kill(-pid, "sigkill")
  end
  eq(gone, true)
end

--- Keep the main thread busy without running the event loop, as a slow plugin or a loaded
--- machine does.
local function block(ms)
  local start = vim.uv.hrtime()
  while (vim.uv.hrtime() - start) / 1e6 < ms do
  end
end

T["run: the timeout counts from the call, even after Neovim was busy"] = function()
  block(1500)
  local res = await(function(cb)
    process.run({ "sleep", "0.5" }, { timeout = 1000 }, cb)
  end)
  eq(res.timed_out, false)
  eq(res.code, 0)
end

T["spawn_detached: the grace period counts from the call, even after Neovim was busy"] = function()
  block(1500)
  local res = await(function(cb)
    process.spawn_detached({ "sh", "-c", "sleep 0.3; exit 4" }, { grace_ms = 1000 }, cb)
  end)
  eq(res.exited, true)
  eq(res.code, 4)
end

T["run: never passes arguments through a shell"] = function()
  local nasty = "a b; echo pwned $HOME `id` $(id) 'quoted' \"double\""
  local res = await(function(cb)
    process.run({ "printf", "%s", nasty }, nil, cb)
  end)
  eq(res.stdout, nasty)
end

T["run: calls back outside a fast event"] = function()
  local in_fast
  await(function(cb)
    process.run({ "true" }, nil, function(res)
      in_fast = vim.in_fast_event()
      cb(res)
    end)
  end)
  eq(in_fast, false)
end

T["run: calls back exactly once"] = function()
  local _, calls = await(function(cb)
    process.run({ "true" }, nil, cb)
  end)
  eq(calls, 1)
  local _, missing_calls = await(function(cb)
    process.run({ "devices-nvim-no-such-tool" }, nil, cb)
  end)
  eq(missing_calls, 1)
end

T["run: captures large output completely"] = function()
  local res = await(function(cb)
    process.run({ "sh", "-c", "head -c 2000000 /dev/zero | tr '\\0' 'x'" }, nil, cb)
  end)
  eq(res.code, 0)
  eq(#res.stdout, 2000000)
end

T["run: passes env and stdin"] = function()
  local res = await(function(cb)
    process.run(
      { "sh", "-c", 'printf "%s|" "$DEVICES_TEST"; cat' },
      { env = { DEVICES_TEST = "set" }, stdin = "piped" },
      cb
    )
  end)
  eq(res.stdout, "set|piped")
end

T["run: honours cwd"] = function()
  local dir = assert(vim.uv.fs_realpath(vim.fn.stdpath("run")))
  local res = await(function(cb)
    process.run({ "pwd", "-P" }, { cwd = dir }, cb)
  end)
  eq(vim.trim(res.stdout), dir)
end

T["run: rejects bad arguments as a programming error"] = function()
  h.expect_error(function()
    process.run({}, nil, function() end)
  end)
  h.expect_error(function()
    process.run({ "true" }, nil, nil)
  end)
end

T["spawn_detached: reports a missing executable"] = function()
  local res = await(function(cb)
    process.spawn_detached({ "devices-nvim-no-such-tool" }, nil, cb)
  end)
  eq(res.started, false)
  eq(res.missing, true)
end

T["spawn_detached: surfaces a launch that dies at once, with its output"] = function()
  local res = await(function(cb)
    process.spawn_detached({ "sh", "-c", "echo launch failed >&2; exit 3" }, { grace_ms = 3000 }, cb)
  end)
  eq(res.started, true)
  eq(res.exited, true)
  eq(res.code, 3)
  eq(res.log_tail, "launch failed\n")
end

T["spawn_detached: reports a process that keeps running"] = function()
  local res = await(function(cb)
    process.spawn_detached({ "sleep", "30" }, { grace_ms = 300 }, cb)
  end)
  eq(res.started, true)
  eq(res.exited, false)
  eq(type(res.pid), "number")
  vim.uv.kill(res.pid, 15)
end

T["spawn_detached: leads its own process group so a closed terminal cannot kill it"] = function()
  local res = await(function(cb)
    process.spawn_detached({ "sleep", "30" }, { grace_ms = 300 }, cb)
  end)
  local ps = vim.system({ "ps", "-o", "pgid=", "-p", tostring(res.pid) }, { text = true }):wait()
  vim.uv.kill(res.pid, 15)
  -- A process started with setsid is the leader of a new group, so its group id is its own pid.
  eq(tonumber(vim.trim(ps.stdout)), res.pid)
end

T["spawn_detached: passes env to the child"] = function()
  local res = await(function(cb)
    process.spawn_detached(
      { "sh", "-c", 'printf %s "$DEVICES_TEST"' },
      { env = { DEVICES_TEST = "hello" }, grace_ms = 3000 },
      cb
    )
  end)
  eq(res.log_tail, "hello")
end

T["spawn_detached: survives the Neovim that started it"] = function()
  local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
  local out = vim
    .system({ vim.v.progpath, "--headless", "-l", root .. "/tests/fixtures/spawn_and_exit.lua", root }, { text = true })
    :wait(15000)
  eq(out.code, 0)
  local pid = tonumber(out.stdout)
  assert(pid, "fixture did not print a pid: " .. vim.inspect(out))

  -- The parent has exited by now. Signal 0 only checks that the process still exists.
  local alive = vim.uv.kill(pid, 0) == 0
  vim.uv.kill(pid, 15)
  eq(alive, true)
end

return T
