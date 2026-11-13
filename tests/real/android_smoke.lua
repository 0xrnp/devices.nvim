-- Opt-in check of the Android backend and logs against the real SDK.
--
--   nvim -l tests/real/android_smoke.lua [AVD name]
--
-- Boots an AVD with -read-only (your AVD and its saved state are not changed) and without a
-- window, follows the Settings app's log across a restart, then shuts it down again.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
vim.opt.runtimepath:prepend(root)

local android = require("devices.backend.android")
local logs = require("devices.logs")

local failures = 0
local function check(name, ok, detail)
  io.stdout:write(ok and "  ok    " or "  FAIL  ", name, ok and "" or ("   " .. tostring(detail)), "\n")
  if not ok then
    failures = failures + 1
  end
end

local function await(start, timeout)
  local done, a, b = false, nil, nil
  start(function(x, y)
    done, a, b = true, x, y
  end)
  assert(
    vim.wait(timeout or 120000, function()
      return done
    end, 50),
    "timed out"
  )
  return a, b
end

local function find(name)
  local devices = await(function(cb)
    android.list({}, cb)
  end)
  for _, d in ipairs(devices) do
    if d.id == name then
      return d
    end
  end
end

io.stdout:write("list\n")
local devices, errors = await(function(cb)
  android.list({}, cb)
end)
check("no errors", #errors == 0, vim.inspect(errors))
local emulator = android.tool("emulator")
local names = android.parse_avd_names(vim.system({ emulator, "-list-avds" }, { text = true }):wait().stdout)
local avds = vim.tbl_filter(function(d)
  return d.source == "emulator"
end, devices)
check(("every AVD is listed (%d)"):format(#names), #avds == #names, #avds)

local name = _G.arg[1] or names[1]
if not name then
  io.stdout:write("no AVD to boot\n")
  os.exit(failures == 0 and 0 or 1)
end
local device = find(name)
if device.state ~= "shutdown" then
  io.stdout:write("  skip  " .. name .. " is already running; not touching it\n")
  os.exit(failures == 0 and 0 or 1)
end

io.stdout:write("lifecycle and logs on " .. name .. " (read-only, no window)\n")
local adb = android.tool("adb")
local ok, problem = pcall(function()
  local started = vim.uv.hrtime()
  local e = await(function(cb)
    android.boot(device, {
      headless = true,
      args = { "-read-only", "-no-audio", "-no-boot-anim" },
      wait = true,
      wait_timeout = 240000,
    }, cb)
  end, 260000)
  check("boot and wait", e == nil, vim.inspect(e))
  io.stdout:write(("  info  booted in %.0f s\n"):format((vim.uv.hrtime() - started) / 1e9))
  local running = find(name)
  check("listed as booted, with its serial", running.state == "booted" and running.serial ~= nil, vim.inspect(running))

  e = await(function(cb)
    android.boot(running, {}, cb)
  end)
  check("booting it again is a success", e == nil, vim.inspect(e))
  e = await(function(cb)
    android.boot(running, { wipe = true }, cb)
  end)
  check("wiping it while running is refused", e and e.code == "invalid_state", vim.inspect(e))

  -- Follow the Settings app across a restart.
  local package = "com.android.settings"
  local pids, lines, ended = {}, 0, false
  local session = logs.start({ device = running, mode = "logcat", app = package, tail = 0 }, {
    on_lines = function(list)
      for _, line in ipairs(list) do
        lines = lines + 1
        if line.pid then
          pids[line.pid] = true
        end
      end
    end,
    on_exit = function()
      ended = true
    end,
  })
  local function shell(...)
    vim.system({ adb, "-s", running.serial, "shell", ... }):wait(30000)
  end
  shell("am", "start", "-W", "-n", package .. "/.Settings")
  vim.wait(4000)
  shell("am", "force-stop", package)
  shell("am", "start", "-W", "-n", package .. "/.Settings")
  vim.wait(4000)
  session.stop()
  vim.wait(5000, function()
    return ended
  end)
  local app_pids = 0
  for pid in pairs(pids) do
    -- system_server reports the start; the app's own pids are the others.
    local out = vim
      .system({ adb, "-s", running.serial, "shell", "ps", "-o", "NAME", "-p", pid }, { text = true })
      :wait(10000)
    if (out.stdout or ""):find(package, 1, true) then
      app_pids = app_pids + 1
    end
  end
  io.stdout:write(("  info  %d lines from %d pids\n"):format(lines, vim.tbl_count(pids)))
  check("the log has the app's lines", lines > 0, lines)
  check("the stream stops when asked", ended, ended)
  check("lines came from more than one pid (it followed the restart)", vim.tbl_count(pids) >= 2, vim.inspect(pids))
  io.stdout:write(("  info  %d of those pids still belong to the app (the first run was stopped)\n"):format(app_pids))

  e = await(function(cb)
    android.shutdown(running, {}, cb)
  end)
  check("shutdown", e == nil, vim.inspect(e))
  local gone = vim.wait(30000, function()
    return find(name).state == "shutdown"
  end, 1000)
  check("listed as shut down", gone, find(name).state)
end)
if not ok then
  check("ran without a Lua error", false, problem)
end

-- Never leave it running.
local now = find(name)
if now and now.serial then
  vim.system({ adb, "-s", now.serial, "emu", "kill" }):wait(30000)
end

io.stdout:write(("\n%s\n"):format(failures == 0 and "all checks passed" or (failures .. " check(s) failed")))
os.exit(failures == 0 and 0 or 1)
