local h = require("helpers")
local eq = h.eq

local fake_android = require("fake_android")
local logs = require("devices.logs")

local T = {}

-- Lines recorded from a real emulator (API 36) and simulator (iOS 27.2).
local ANDROID = {
  "--------- beginning of main",
  "11-13 20:49:44.298   917  1126 D ControlsListingControllerImpl: Subscribing callback, service count: 0",
  "11-13 20:49:44.301   917   917 W PageIndicator: Total number of pages invalid: 0. Assuming 1 page.",
  "11-13 20:49:45.210   673  1000 E RoleControllerServiceImpl: Default/fallback role holder package doesn't qualify",
  "11-13 20:49:46.000   600   620 I ActivityManager: Start proc 4242:com.example.app/u0a123 for next-top-activity",
  "11-13 20:49:46.100  4242  4242 I flutter : hello from release",
  "11-13 20:49:46.200  5151  5151 I flutter : another app",
  "11-13 20:49:46.300   600   620 I ActivityManager: Start proc 5252:com.example.app.debug/u0a124 for activity",
  "11-13 20:49:46.400  5252  5252 I flutter : the debug variant",
  "11-13 20:49:47.000  4242  4250 F libc    : Fatal signal 11 (SIGSEGV), code 1",
}

local IOS = {
  "Timestamp               Ty Process[PID:TID]",
  "2026-11-13 20:56:36.411 Df log[30348:6e9c9] (LoggingSupport) Sending stream request to diagnosticd",
  "2026-11-13 20:56:36.414 Db SpringBoard[30002:6e788] [com.apple.x:y] debug detail",
  "2026-11-13 20:56:36.500 E  Runner[30500:6e800] something failed",
  "2026-11-13 20:56:36.600 F  Runner[30500:6e800] a fault",
}

T["android lines: level and pid from threadtime, nothing from separators"] = function()
  local parsed = vim.tbl_map(logs.parse_android, ANDROID)
  eq(parsed[1].level, nil)
  eq(parsed[2].level, logs.rank.debug)
  eq(parsed[2].pid, "917")
  eq(parsed[3].level, logs.rank.warning)
  eq(parsed[4].level, logs.rank.error)
  eq(parsed[10].level, logs.rank.fatal)
  eq(parsed[6].pid, "4242")
end

T["ios lines: level and pid from the compact style"] = function()
  local parsed = vim.tbl_map(logs.parse_ios, IOS)
  eq(parsed[1].level, nil)
  eq(parsed[2].level, logs.rank.info)
  eq(parsed[2].pid, "30348")
  eq(parsed[3].level, logs.rank.debug)
  eq(parsed[4].level, logs.rank.error)
  eq(parsed[5].level, logs.rank.fatal)
end

T["app filter: follows the app by the pid ActivityManager reports, not a similar package"] = function()
  local filter = logs.android_app_filter("com.example.app")
  local kept = {}
  for i, text in ipairs(ANDROID) do
    if filter.accept(logs.parse_android(text)) then
      kept[#kept + 1] = i
    end
  end
  -- 5: its start line. 6: its output. 8: the .debug variant's start line mentions the package
  -- name, so it is kept, but its pid is not learned: 9 is dropped. 10: its crash.
  eq(kept, { 5, 6, 8, 10 })
end

T["app filter: pids from pidof count too, for an app that was already running"] = function()
  local filter = logs.android_app_filter("com.example.app")
  local line = logs.parse_android("11-13 20:49:46.200  5151  5151 I flutter : already running")
  eq(filter.accept(line), false)
  filter.add_pids({ "5151" })
  eq(filter.accept(line), true)
end

T["app filter: a package name with pattern characters is matched literally"] = function()
  local filter = logs.android_app_filter("com.a-b.c")
  eq(
    filter.accept(
      logs.parse_android("11-13 20:49:46.000   600   620 I ActivityManager: Start proc 77:com.a-b.c/u0a1 for x")
    ),
    true
  )
  eq(filter.accept(logs.parse_android("11-13 20:49:46.100    77    77 I tag : mine")), true)
  eq(
    filter.accept(
      logs.parse_android("11-13 20:49:46.000   600   620 I ActivityManager: Start proc 88:comXa-bYc/u0a2 for x")
    ),
    false
  )
end

local function device(fields)
  return vim.tbl_extend("force", { id = "D", name = "Dev", source = "x" }, fields)
end

T["modes: what each device offers, and nothing when it is not running"] = function()
  local function ids(d)
    return vim.tbl_map(function(m)
      return m.id
    end, logs.modes(d))
  end
  eq(ids(device({ platform = "android", kind = "emulator", state = "booted" })), { "logcat" })
  eq(ids(device({ platform = "android", kind = "physical", state = "connected" })), { "logcat" })
  eq(ids(device({ platform = "ios", kind = "simulator", state = "booted" })), { "system", "console" })
  eq(ids(device({ platform = "ios", kind = "physical", state = "connected" })), { "console", "system" })
  eq(ids(device({ platform = "android", kind = "emulator", state = "shutdown" })), {})
  eq(ids(device({ platform = "ios", kind = "physical", state = "unauthorized" })), {})
end

--- Start a session and collect until it ends or `until_fn` is true.
local function run_session(spec, until_fn)
  local got, exit, done = {}, nil, false
  local session = logs.start(spec, {
    on_lines = function(lines)
      for _, l in ipairs(lines) do
        got[#got + 1] = l.text
      end
    end,
    on_exit = function(failure)
      exit, done = failure, true
    end,
  })
  vim.wait(10000, function()
    return done or (until_fn and until_fn(got))
  end, 10)
  if not done then
    session.stop()
    assert(
      vim.wait(5000, function()
        return done
      end, 10),
      "stop did not end the session"
    )
  end
  return got, exit, session
end

local function emulator(serial)
  return device({ platform = "android", kind = "emulator", state = "booted", serial = serial, source = "emulator" })
end

T["session: android logcat streams through adb, filtered to the app"] = function()
  local fake = fake_android.new({ adb_devices = { "emulator-5554\tdevice transport_id:1" } })
  fake.write("logcat", ANDROID)
  fake.write("pidof", { "" })
  h.with_env(fake.env(), function()
    local got, exit, session = run_session(
      { device = emulator("emulator-5554"), mode = "logcat", app = "com.example.app", tail = 50, android = fake.opts() },
      function(lines)
        return #lines >= 4
      end
    )
    eq(exit, nil)
    eq(#got, 4)
    eq(session.argv[#session.argv - 1], "-T")
    eq(session.argv[#session.argv], "50")
    local pidof = vim.tbl_filter(function(c)
      return c[4] == "shell" and c[5] == "pidof"
    end, fake.calls())
    eq(pidof[1][6], "com.example.app")
  end)
end

T["session: an app that was already running keeps its earlier lines"] = function()
  local fake = fake_android.new({ adb_devices = { "emulator-5554\tdevice transport_id:1" } })
  -- No "Start proc" line: the app started before the log was opened. Only pidof knows it.
  fake.write("logcat", {
    "11-13 20:49:46.200  5151  5151 I flutter : from before",
    "11-13 20:49:46.300  6000  6000 I other   : not the app",
    "11-13 20:49:46.400  5151  5151 I flutter : still running",
  })
  fake.write("pidof", { "5151" })
  h.with_env(fake.env(), function()
    local got = run_session(
      { device = emulator("emulator-5554"), mode = "logcat", app = "com.example.app", android = fake.opts() },
      function(lines)
        return #lines >= 2
      end
    )
    eq(got, {
      "11-13 20:49:46.200  5151  5151 I flutter : from before",
      "11-13 20:49:46.400  5151  5151 I flutter : still running",
    })
    -- pidof was asked before logcat started.
    local order = vim.tbl_map(
      function(c)
        return c[4] .. " " .. c[5]
      end,
      vim.tbl_filter(function(c)
        return c[1] == "adb"
      end, fake.calls())
    )
    eq(order[1], "shell pidof")
    eq(order[2], "logcat -v")
  end)
end

T["session: an app id that is not one is refused before anything runs on the device"] = function()
  local fake = fake_android.new({ adb_devices = { "emulator-5554\tdevice transport_id:1" } })
  h.with_env(fake.env(), function()
    local _, exit = run_session({
      device = emulator("emulator-5554"),
      mode = "logcat",
      app = "x;pm uninstall com.example.app",
      android = fake.opts(),
    })
    eq(exit.code, "invalid_state")
    eq(fake.calls(), {})
  end)
end

T["session: stopped while still looking up the app, it still ends once"] = function()
  local fake = fake_android.new({ adb_devices = { "emulator-5554\tdevice transport_id:1" } })
  fake.write("pidof", { "5151" })
  h.with_env(fake.env(), function()
    local ends = {}
    local session = logs.start(
      { device = emulator("emulator-5554"), mode = "logcat", app = "com.example.app", android = fake.opts() },
      {
        on_lines = function() end,
        on_exit = function(failure)
          ends[#ends + 1] = failure or "stopped"
        end,
      }
    )
    session.stop()
    vim.wait(1000)
    eq(ends, { "stopped" })
    -- logcat never started.
    local logcat = vim.tbl_filter(function(c)
      return c[4] == "logcat"
    end, fake.calls())
    eq(logcat, {})
  end)
end

T["session: a stream that ends by itself is reported as an error"] = function()
  local fake = fake_android.new({ adb_devices = { "emulator-5554\tdevice transport_id:1" } })
  fake.write("logcat", { "11-13 20:49:44.298   917  1126 D A: last words" })
  h.with_env(fake.env({ FAKE_LOGCAT_EXIT = "1" }), function()
    local got, exit = run_session({ device = emulator("emulator-5554"), mode = "logcat", android = fake.opts() })
    eq(got, { "11-13 20:49:44.298   917  1126 D A: last words" })
    eq(exit.code, "command_failed")
  end)
end

T["session: refuses a stopped device, a mode it lacks, and a console without an app"] = function()
  local stopped = device({ platform = "android", kind = "emulator", state = "shutdown", source = "emulator" })
  local _, e1 = run_session({ device = stopped, mode = "logcat" })
  eq(e1.code, "invalid_state")
  local sim = device({ platform = "ios", kind = "simulator", state = "booted" })
  local _, e2 = run_session({ device = sim, mode = "logcat" })
  eq(e2.code, "unsupported")
  local _, e3 = run_session({ device = sim, mode = "console" })
  eq(e3.code, "invalid_state")
end

T["session: a missing idevicesyslog explains the alternatives"] = function()
  h.with_env(h.isolated(), function()
    local phone = device({ platform = "ios", kind = "physical", state = "connected" })
    local _, e = run_session({ device = phone, mode = "system" })
    eq(e.code, "tool_missing")
    eq(e.hint:find("libimobiledevice", 1, true) ~= nil, true)
    eq(e.hint:find("log collect", 1, true) ~= nil, true)
  end)
end

T["session: the iOS console launches the app with the right tool"] = function()
  local bin = h.tree({
    ["bin/xcrun"] = '#!/bin/sh\nprintf "%s\\n" "$@" > "$CALL_LOG"\necho "com.example.app: 123"\necho "hello"\n',
  })
  local call_log = bin .. "/call.log"
  h.with_env(h.isolated({ PATH = bin .. "/bin", CALL_LOG = call_log }), function()
    local sim = device({ platform = "ios", kind = "simulator", state = "booted", id = "SIM-1" })
    local got = run_session({ device = sim, mode = "console", app = "com.example.app" })
    eq(got, { "com.example.app: 123", "hello" })
    eq(vim.fn.readfile(call_log), {
      "simctl",
      "launch",
      "--console-pty",
      "--terminate-running-process",
      "SIM-1",
      "com.example.app",
    })
    local phone = device({ platform = "ios", kind = "physical", state = "connected", id = "PHONE-1" })
    run_session({ device = phone, mode = "console", app = "com.example.app" })
    eq(vim.fn.readfile(call_log), {
      "devicectl",
      "device",
      "process",
      "launch",
      "--device",
      "PHONE-1",
      "--console",
      "--terminate-existing",
      "com.example.app",
    })
  end)
end

return T
