local h = require("helpers")
local eq = h.eq

local fake_android = require("fake_android")

local ROOT = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

--- A PATH with only what bin/devices itself uses, so no real Xcode or SDK is found. (On a Mac,
--- /usr/bin has xcrun, and its first run can take long enough to make a test flaky.)
local function launcher_path()
  local dir = h.tree({ ["bin/"] = "" }) .. "/bin"
  for _, tool in ipairs({ "dirname", "readlink" }) do
    vim.uv.fs_symlink(vim.fn.exepath(tool), dir .. "/" .. tool)
  end
  return dir
end

--- Start bin/devices with exactly `environment`, nothing inherited. `env -i` instead of
--- vim.system's clear_env, which on Neovim 0.10 starts the process with no environment at all.
---@param environment table<string, string>
---@param args string[]
---@param opts table vim.system options
local function launch(environment, args, opts)
  local argv = { "/usr/bin/env", "-i" }
  for key, value in pairs(environment) do
    argv[#argv + 1] = key .. "=" .. value
  end
  argv[#argv + 1] = ROOT .. "/bin/devices"
  return vim.system(vim.list_extend(argv, args), opts)
end

--- Run bin/devices with the fake SDK and nothing else on PATH (no Xcode, no real Android SDK).
local function cli(fake, args)
  local environment = {
    PATH = launcher_path(),
    HOME = fake.root,
    ANDROID_HOME = fake.root .. "/sdk",
    ANDROID_AVD_HOME = fake.root .. "/avd",
    FAKE_STATE = fake.state,
    DEVICES_NVIM = vim.v.progpath,
  }
  return launch(environment, args, { text = true }):wait(30000)
end

local T = {}

T["cli: help, and wrong usage exits 2"] = function()
  local fake = fake_android.new()
  local help = cli(fake, { "help" })
  eq(help.code, 0)
  eq(help.stdout:find("Usage: devices", 1, true) ~= nil, true)
  eq(cli(fake, {}).code, 2)
  local unknown = cli(fake, { "launch" })
  eq(unknown.code, 2)
  eq(unknown.stderr:find("Unknown command: launch", 1, true) ~= nil, true)
end

T["cli: list as a table and as JSON"] = function()
  local fake = fake_android.new({
    avds = { "Pixel_9a" },
    configs = { Pixel_9a = { ["avd.ini.displayname"] = "Pixel 9a" } },
  })
  local res = cli(fake, { "list" })
  eq(res.code, 0)
  local rows = vim.split(vim.trim(res.stdout), "\n")
  eq(rows[1]:match("^STATE%s+PLATFORM%s+KIND%s+OS%s+NAME%s+ID$") ~= nil, true)
  local avd_rows = vim.tbl_filter(function(row)
    return row:match("^shutdown%s+android%s+emulator%s+16%s+Pixel 9a%s+Pixel_9a$") ~= nil
  end, rows)
  eq(#avd_rows, 1)

  local json = cli(fake, { "list", "--json" })
  local list = vim.json.decode(json.stdout)
  local android = vim.tbl_filter(function(d)
    return d.platform == "android"
  end, list)
  eq(#android, 1)
  eq(android[1].id, "Pixel_9a")
end

T["cli: an unknown device is an error, and delete needs --yes"] = function()
  local fake = fake_android.new({ avds = { "Pixel_9a" } })
  local missing = cli(fake, { "boot", "Galaxy" })
  eq(missing.code, 1)
  eq(missing.stderr:find('No device matches "Galaxy"', 1, true) ~= nil, true)
  local unconfirmed = cli(fake, { "delete", "Pixel_9a" })
  eq(unconfirmed.code, 2)
  eq(unconfirmed.stderr:find("--yes", 1, true) ~= nil, true)
  eq(fake.read("avds"), { "Pixel_9a" })
  -- Erasing needs it too, either way it is asked for, and nothing starts without it.
  for _, args in ipairs({ { "erase", "Pixel_9a" }, { "boot", "Pixel_9a", "--wipe" } }) do
    local res = cli(fake, args)
    eq(res.code, 2)
    eq(res.stderr:find("--yes", 1, true) ~= nil, true)
  end
  eq(fake.read("emulator.pid"), {})
end

T["cli: id prints what flutter -d and adb -s want"] = function()
  local fake = fake_android.new({ avds = { "Pixel_9a" }, adb_devices = { "emulator-5554\tdevice transport_id:1" } })
  fake.write("avd_emulator-5554", { "Pixel_9a" })
  fake.write("booted_emulator-5554", { "1" })
  local res = cli(fake, { "id", "Pixel_9a" })
  eq(res.code, 0)
  eq(vim.trim(res.stdout), "emulator-5554")
end

T["cli: logs streams to stdout and ends with the stream"] = function()
  local fake = fake_android.new({ adb_devices = { "R5CT1\tdevice model:Pixel_8 transport_id:2" } })
  fake.write("logcat", { "11-13 20:49:46.100  4242  4242 I flutter : hello" })
  -- The fake logcat ends at once when told to, so the command finishes.
  local res = launch({
    PATH = launcher_path(),
    HOME = fake.root,
    ANDROID_HOME = fake.root .. "/sdk",
    FAKE_STATE = fake.state,
    FAKE_LOGCAT_EXIT = "0",
    DEVICES_NVIM = vim.v.progpath,
  }, { "logs", "R5CT1" }, { text = true }):wait(30000)
  eq(res.stdout, "11-13 20:49:46.100  4242  4242 I flutter : hello\n")
  eq(res.code, 1)
  eq(res.stderr:find("log stream ended", 1, true) ~= nil, true)
end

T["cli: Ctrl-C in the terminal ends the command and the log stream"] = function()
  local fake = fake_android.new({ adb_devices = { "R5CT1\tdevice model:Pixel_8 transport_id:2" } })
  fake.write("logcat", { "11-13 20:49:46.100  4242  4242 I flutter : hello" })
  local out = {}
  local proc = launch({
    PATH = launcher_path(),
    HOME = fake.root,
    ANDROID_HOME = fake.root .. "/sdk",
    FAKE_STATE = fake.state,
    DEVICES_NVIM = vim.v.progpath,
  }, { "logs", "R5CT1" }, {
    -- Its own group stands in for the terminal's foreground group.
    detach = true,
    stdout = function(_, data)
      if data then
        out[#out + 1] = data
      end
    end,
  })
  assert(
    vim.wait(15000, function()
      return table.concat(out):find("hello", 1, true) ~= nil
    end, 20),
    "no output"
  )
  local logcat = tonumber(fake.read("logcat.pid")[1] or "")
  assert(logcat, "the fake logcat did not start")
  -- The fake prints before it execs sleep. Interrupting in between would test the shell, not the CLI.
  assert(
    vim.wait(5000, function()
      local ps = vim.system({ "ps", "-o", "comm=", "-p", tostring(logcat) }):wait()
      return vim.trim(ps.stdout or ""):match("sleep$") ~= nil
    end, 50),
    "the fake logcat never reached sleep"
  )
  -- What a terminal does on Ctrl-C: SIGINT to every process in the foreground group.
  vim.uv.kill(-proc.pid, "sigint")
  local res = proc:wait(10000)
  -- Neovim 0.12 exits with a code; 0.10 does not handle SIGINT and is killed by it, which
  -- vim.system reports as code 0 with the signal set. Either way a shell sees an interrupt.
  eq(res.code ~= 0 or res.signal ~= 0, true)
  local gone = vim.wait(5000, function()
    return vim.uv.kill(logcat, 0) ~= 0
  end, 20)
  if not gone then
    vim.uv.kill(logcat, "sigkill")
  end
  eq(gone, true)
end

return T
