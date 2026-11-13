-- Opt-in check of the iOS backend against the real tools. macOS and Xcode only.
--
--   nvim -l tests/real/ios_smoke.lua
--
-- It lists your simulators and physical devices, then runs the whole lifecycle on a throwaway
-- simulator that it creates and always deletes. Your own simulators are never changed.
-- Device names and ids are not printed.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
vim.opt.runtimepath:prepend(root)

local ios = require("devices.backend.ios")

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
    end, 20),
    "timed out"
  )
  return a, b
end

local function run(argv)
  return vim.system(argv, { text = true }):wait(60000)
end

-- 1. list ----------------------------------------------------------------------------------------

io.stdout:write("list\n")
local devices, errors = await(function(cb)
  ios.list({}, cb)
end)
check("no errors", #errors == 0, vim.inspect(errors))

-- An independent count: iOS devices in the plain-text listing, which has a "-- iOS x.y --" heading
-- per runtime.
local expected, in_ios = 0, false
for line in run({ "xcrun", "simctl", "list", "devices", "available" }).stdout:gmatch("[^\r\n]+") do
  if line:match("^%-%- ") then
    in_ios = line:match("^%-%- iOS ") ~= nil
  elseif in_ios and line:match("%(%x+%-%x+%-%x+%-%x+%-%x+%)") then
    expected = expected + 1
  end
end
local simulators, physical = {}, {}
for _, d in ipairs(devices) do
  table.insert(d.kind == "simulator" and simulators or physical, d)
end
check(("simulators match simctl's own listing (%d)"):format(expected), #simulators == expected, #simulators)

local by_state = {}
for _, d in ipairs(physical) do
  by_state[d.state] = (by_state[d.state] or 0) + 1
end
io.stdout:write(("  info  %d physical device(s): %s\n"):format(#physical, vim.inspect(by_state):gsub("%s+", " ")))

-- 2. lifecycle and logs on a throwaway simulator ---------------------------------------------------

io.stdout:write("lifecycle and logs on a throwaway simulator\n")
local logs = require("devices.logs")

local runtimes, runtime_error = await(function(cb)
  ios.runtimes(cb)
end)
check("runtimes are readable", runtime_error == nil and #runtimes > 0, vim.inspect(runtime_error))
local runtime = runtimes and runtimes[1]
local device_type = runtime and runtime.device_types[1]
if not device_type then
  check("an iOS runtime with a device type exists", false, "nothing to create a simulator from")
else
  io.stdout:write("  info  using " .. runtime.name .. "\n")
  local udid, create_error = await(function(cb)
    ios.create({ name = "devices-nvim-smoke", device_type = device_type.id, runtime = runtime.id }, cb)
  end)
  check("created a throwaway simulator", create_error == nil and udid ~= nil, vim.inspect(create_error))

  local sim = {
    id = udid or "none",
    name = "devices-nvim-smoke",
    platform = "ios",
    kind = "simulator",
    state = "shutdown",
    source = "simctl",
  }
  local function state()
    local all = await(function(cb)
      ios.list({ physical = false }, cb)
    end)
    for _, d in ipairs(all) do
      if d.id == udid then
        return d.state
      end
    end
  end

  local ok, problem = pcall(function()
    assert(udid, "no simulator was created, so there is nothing to run the lifecycle on")
    check("it shows up in the list, shut down", state() == "shutdown", state())

    local e = await(function(cb)
      ios.boot(sim, { open_app = false, wait = true }, cb)
    end, 600000)
    check("boot and wait", e == nil, vim.inspect(e))
    check("it is booted", state() == "booted", state())

    e = await(function(cb)
      ios.boot(sim, { open_app = false }, cb)
    end)
    check("booting it again succeeds", e == nil, vim.inspect(e))

    e = await(function(cb)
      ios.erase(sim, cb)
    end)
    check(
      "erase while booted is invalid_state",
      e and e.code == "invalid_state" and e.hint == "Shut it down first.",
      vim.inspect(e)
    )

    -- Logs: the system log of one app, and an app's own console.
    local booted = vim.tbl_extend("force", sim, { state = "booted" })
    local name = await(function(cb)
      ios.app_executable(booted, "com.apple.Preferences", cb)
    end)
    io.stdout:write("  info  Settings runs as process " .. tostring(name) .. "\n")
    check("the app's process name is found", type(name) == "string" and name ~= "", name)

    local got, other, ended, status = 0, 0, false, nil
    local session = logs.start({ device = booted, mode = "system", app = "com.apple.Preferences" }, {
      on_lines = function(list)
        for _, line in ipairs(list) do
          if line.text:find(" " .. name .. "[", 1, true) then
            got = got + 1
          elseif line.level then
            other = other + 1
          end
        end
      end,
      on_status = function(message)
        status = message
      end,
      on_exit = function()
        ended = true
      end,
    })
    vim.wait(2000)
    run({ "xcrun", "simctl", "launch", udid, "com.apple.Preferences" })
    vim.wait(5000, function()
      return got > 0
    end, 100)
    session.stop()
    vim.wait(5000, function()
      return ended
    end)
    io.stdout:write(("  info  %d lines from the app, %d from other processes\n"):format(got, other))
    check("the system log shows the app's lines", got > 0, got)
    check("and only the app's lines", other == 0, other)
    check("it says what it shows", status and status:find(name, 1, true) ~= nil, status)
    check("the stream stops when asked", ended, ended)

    local console, console_ended = {}, false
    local launched = logs.start({ device = booted, mode = "console", app = "com.apple.Preferences" }, {
      on_lines = function(list)
        for _, line in ipairs(list) do
          console[#console + 1] = line.text
        end
      end,
      on_exit = function()
        console_ended = true
      end,
    })
    vim.wait(15000, function()
      return #console > 0
    end, 100)
    launched.stop()
    vim.wait(5000, function()
      return console_ended
    end)
    io.stdout:write(("  info  %d console lines\n"):format(#console))
    -- The app's own stdout and stderr, live. (simctl's "<bundle>: <pid>" line is buffered by
    -- simctl and only appears when it exits normally.)
    check("the console shows the app's own output", #console > 0, #console)
    check("and stops when asked", console_ended, console_ended)

    e = await(function(cb)
      ios.shutdown(sim, cb)
    end)
    check("shutdown", e == nil, vim.inspect(e))
    check("it is shut down", state() == "shutdown", state())

    e = await(function(cb)
      ios.shutdown(sim, cb)
    end)
    check("shutting down again succeeds", e == nil, vim.inspect(e))

    e = await(function(cb)
      ios.erase(sim, cb)
    end)
    check("erase when shut down", e == nil, vim.inspect(e))

    e = await(function(cb)
      ios.boot({
        id = "00000000-0000-0000-0000-000000000000",
        name = "ghost",
        platform = "ios",
        kind = "simulator",
        state = "shutdown",
        source = "simctl",
      }, { open_app = false }, cb)
    end)
    check("an unknown simulator is not_found", e and e.code == "not_found", vim.inspect(e))
  end)
  if not ok then
    check("lifecycle ran without a Lua error", false, problem)
  end

  -- Always clean up, whatever happened above.
  if udid then
    run({ "xcrun", "simctl", "shutdown", udid })
    local e = await(function(cb)
      ios.delete(sim, cb)
    end)
    check("deleted the throwaway simulator", e == nil, vim.inspect(e))
    if e then
      run({ "xcrun", "simctl", "delete", udid })
    end
  end
end

io.stdout:write(("\n%s\n"):format(failures == 0 and "all checks passed" or (failures .. " check(s) failed")))
os.exit(failures == 0 and 0 or 1)
