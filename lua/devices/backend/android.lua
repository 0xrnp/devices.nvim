--- Android emulators (emulator, avdmanager) and devices (adb), on macOS and Linux.
local async = require("devices.async")
local Device = require("devices.device")
local env = require("devices.env")
local err = require("devices.error")
local process = require("devices.process")

local M = {}

local LIST_TIMEOUT_MS = 20000
local QUERY_TIMEOUT_MS = 5000
local ACTION_TIMEOUT_MS = 60000
-- avdmanager starts a JVM and may read the whole SDK, so it gets longer.
local AVDMANAGER_TIMEOUT_MS = 120000
local BOOT_WAIT_TIMEOUT_MS = 300000
local BOOT_POLL_MS = 2000
-- How long a new emulator must stay up to count as started. Bad AVDs and missing system images
-- make it exit within a second or two.
local LAUNCH_GRACE_MS = 3000

local GUIDE = { guide = "android" }

---@class devices.AndroidOptions: devices.EnvOptions
---@field avd_home? string Where AVDs live. Default: the emulator's own lookup order.

-- Android versions by API level, for display only.
local RELEASES = {
  [21] = "5.0",
  [22] = "5.1",
  [23] = "6",
  [24] = "7.0",
  [25] = "7.1",
  [26] = "8.0",
  [27] = "8.1",
  [28] = "9",
  [29] = "10",
  [30] = "11",
  [31] = "12",
  [32] = "12L",
  [33] = "13",
  [34] = "14",
  [35] = "15",
  [36] = "16",
}

--- "16" for API 36, "API 99" for one this table does not know yet.
---@param api string|integer|nil
---@return string?
function M.release_for_api(api)
  local level = tonumber(api)
  if not level then
    return nil
  end
  return RELEASES[level] or ("API " .. level)
end

-- Tools ---------------------------------------------------------------------------------------

local INSTALL_HINT = {
  emulator = 'Install it with: sdkmanager "emulator", or in Android Studio > SDK Manager > SDK Tools.',
  adb = 'Install it with: sdkmanager "platform-tools", or in Android Studio > SDK Manager > SDK Tools.',
  avdmanager = 'Install the command-line tools: sdkmanager "cmdline-tools;latest", or in Android Studio > SDK Manager > SDK Tools.',
}

--- The path of an SDK tool, or an error saying how to install it.
---@param name "emulator"|"adb"|"avdmanager"
---@param opts? devices.AndroidOptions
---@return string? path
---@return devices.Error? error
function M.tool(name, opts)
  local found = env.find_android_tool(name, opts)
  if found then
    return found.path
  end
  return nil, err.new("tool_missing", name .. " was not found", { hint = INSTALL_HINT[name], guide = "android" })
end

---@param cb function
---@param ... any
local function later(cb, ...)
  local args = vim.F.pack_len(...)
  vim.schedule(function()
    cb(vim.F.unpack_len(args))
  end)
end

-- Parsing -------------------------------------------------------------------------------------

--- AVD names from `emulator -list-avds`. Newer emulators also print log lines such as
--- "INFO    | Storing crashdata in: ..." on stdout, and AVD names cannot contain spaces.
---@param text string
---@return string[]
function M.parse_avd_names(text)
  local names = {}
  for line in text:gmatch("[^\r\n]+") do
    line = vim.trim(line)
    if line:match("^[%w][%w._%-]*$") then
      names[#names + 1] = line
    end
  end
  return names
end

---@class devices.AdbEntry
---@field serial string
---@field state string The raw adb state: "device", "offline", "unauthorized", "no permissions", ...
---@field props table<string, string> "model", "device", "product", "transport_id", "usb".
---@field note string? The text adb printed after the state, for "no permissions".

--- Read `adb devices -l`.
---@param text string
---@return devices.AdbEntry[]
function M.parse_adb_devices(text)
  local entries = {}
  for line in text:gmatch("[^\r\n]+") do
    -- Skip the header, the "* daemon started" notices and blank lines.
    if not line:match("^List of devices") and not line:match("^%*") and vim.trim(line) ~= "" then
      local serial, rest = line:match("^(%S+)%s+(.+)$")
      if serial then
        local state, after
        if rest:match("^no permissions") then
          -- "no permissions (missing udev rules? user is in the plugdev group); see [...]"
          state = "no permissions"
          after = rest:match("^no permissions%s*(.*)$")
        else
          state, after = rest:match("^(%S+)%s*(.*)$")
        end
        local props = {}
        for key, value in (after or ""):gmatch("(%w[%w_]*):(%S+)") do
          props[key] = value
        end
        entries[#entries + 1] = {
          serial = serial,
          state = state,
          props = props,
          note = state == "no permissions" and vim.trim((after or ""):gsub("%s*%w[%w_]*:%S+", "")) or nil,
        }
      end
    end
  end
  return entries
end

--- A Wi-Fi device is "host:port", or an mDNS name such as "adb-XYZ._adb-tls-connect._tcp".
---@param serial string
---@return boolean
function M.is_wifi_serial(serial)
  return serial:match("^[%w.%-]+:%d+$") ~= nil or serial:find("._adb-tls-connect.", 1, true) ~= nil
end

---@param serial string
---@return boolean
function M.is_emulator_serial(serial)
  return serial:match("^emulator%-%d+$") ~= nil
end

--- Read an `key=value` ini file, as AVDs use.
---@param path string
---@return table<string, string>?
local function read_ini(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end
  local values = {}
  for _, line in ipairs(lines) do
    local key, value = line:match("^%s*([^#=][^=]-)%s*=%s*(.-)%s*$")
    -- An empty value counts as unset, so callers fall back to their defaults.
    if key and value ~= "" then
      values[key] = value
    end
  end
  return values
end

--- Where AVDs live, in the emulator's own lookup order.
---@param opts? devices.AndroidOptions
---@return string
function M.avd_home(opts)
  opts = opts or {}
  if opts.avd_home then
    return opts.avd_home
  end
  if vim.env.ANDROID_AVD_HOME and vim.env.ANDROID_AVD_HOME ~= "" then
    return vim.env.ANDROID_AVD_HOME
  end
  if vim.env.ANDROID_USER_HOME and vim.env.ANDROID_USER_HOME ~= "" then
    return vim.env.ANDROID_USER_HOME .. "/avd"
  end
  if vim.env.ANDROID_SDK_HOME and vim.env.ANDROID_SDK_HOME ~= "" then
    return vim.env.ANDROID_SDK_HOME .. "/.android/avd"
  end
  return (vim.uv.os_homedir() or "") .. "/.android/avd"
end

---@class devices.AvdInfo
---@field display_name string?
---@field api string?
---@field device_type string?
---@field abi string?
---@field tag string?

--- What an AVD's config says about it. Best effort: nil fields when the files are missing.
---@param name string
---@param opts? devices.AndroidOptions
---@return devices.AvdInfo
function M.avd_info(name, opts)
  local home = M.avd_home(opts)
  local pointer = read_ini(home .. "/" .. name .. ".ini") or {}
  local dir = pointer.path
  if not dir or vim.uv.fs_stat(dir) == nil then
    dir = home .. "/" .. name .. ".avd"
  end
  local config = read_ini(dir .. "/config.ini") or {}
  local target = pointer.target or config.target or ""
  local api = target:match("android%-(%d+)") or (config["image.sysdir.1"] or ""):match("android%-(%d+)")
  return {
    display_name = config["avd.ini.displayname"],
    api = api,
    device_type = config["hw.device.name"],
    abi = config["abi.type"],
    tag = config["tag.id"],
  }
end

-- Listing -------------------------------------------------------------------------------------

---@param argv string[]
---@param timeout integer
---@param cb fun(res: devices.ProcessResult)
local function run(argv, timeout, cb)
  process.run(argv, { timeout = timeout }, cb)
end

---@param opts devices.AndroidOptions
---@param cb fun(names: string[]?, error: devices.Error?)
function M.list_avd_names(opts, cb)
  local emulator, missing = M.tool("emulator", opts)
  if not emulator then
    return later(cb, nil, missing)
  end
  local argv = { emulator, "-list-avds" }
  run(argv, LIST_TIMEOUT_MS, function(res)
    local failure = err.from_process(res, argv, GUIDE)
    if failure then
      return cb(nil, failure)
    end
    cb(M.parse_avd_names(res.stdout))
  end)
end

---@param opts devices.AndroidOptions
---@param cb fun(entries: devices.AdbEntry[]?, error: devices.Error?)
function M.list_adb(opts, cb)
  local adb, missing = M.tool("adb", opts)
  if not adb then
    return later(cb, nil, missing)
  end
  local argv = { adb, "devices", "-l" }
  run(argv, LIST_TIMEOUT_MS, function(res)
    local failure = err.from_process(res, argv, GUIDE)
    if failure then
      return cb(nil, failure)
    end
    cb(M.parse_adb_devices(res.stdout))
  end)
end

--- Run `adb -s <serial> <args...>` and return trimmed stdout, or nil on any failure.
---@param adb string
---@param serial string
---@param args string[]
---@param cb fun(out: string?)
local function adb_query(adb, serial, args, cb)
  local argv = vim.list_extend({ adb, "-s", serial }, args)
  run(argv, QUERY_TIMEOUT_MS, function(res)
    if res.code ~= 0 then
      return cb(nil)
    end
    cb(vim.trim(res.stdout))
  end)
end

local ADB_STATES = {
  device = "connected",
  offline = "offline",
  unauthorized = "unauthorized",
  authorizing = "unauthorized",
  ["no permissions"] = "unauthorized",
}

--- Combine AVDs and adb entries into devices. `facts` maps a serial to what was asked of it:
--- `avd` (the AVD a running emulator was started from), `booted`, and `release`.
---@param names string[]
---@param entries devices.AdbEntry[]
---@param facts table<string, { avd?: string, booted?: boolean, release?: string }>
---@param opts? devices.AndroidOptions
---@return devices.Device[]
function M.combine(names, entries, facts, opts)
  local running_by_avd = {}
  local devices = {}

  for _, entry in ipairs(entries) do
    local fact = facts[entry.serial] or {}
    if M.is_emulator_serial(entry.serial) and fact.avd and vim.tbl_contains(names, fact.avd) then
      running_by_avd[fact.avd] = { entry = entry, fact = fact }
    elseif M.is_emulator_serial(entry.serial) then
      -- Running, but its AVD is unknown (an old emulator, or one adb could not ask).
      devices[#devices + 1] = Device.new({
        id = entry.serial,
        name = fact.avd or entry.serial,
        platform = "android",
        kind = "emulator",
        state = entry.state == "device" and (fact.booted == false and "booting" or "booted")
          or (ADB_STATES[entry.state] or "unknown"),
        os_version = fact.release,
        serial = entry.serial,
        transport = "local",
        source = "adb",
      })
    else
      local state = ADB_STATES[entry.state] or "unknown"
      local detail
      if entry.state == "unauthorized" then
        detail = "Unlock the phone and accept the USB debugging prompt."
      elseif entry.state == "no permissions" then
        detail = "No permission to use this USB device. On Linux, add udev rules for Android devices and re-plug it."
      elseif entry.state == "offline" then
        detail = "adb lost the connection. Re-plug the cable, or run: adb kill-server"
      end
      devices[#devices + 1] = Device.new({
        id = entry.serial,
        name = entry.props.model and (entry.props.model:gsub("_", " ")) or entry.serial,
        platform = "android",
        kind = "physical",
        state = state,
        os_version = fact.release,
        model = entry.props.model,
        serial = entry.serial,
        transport = M.is_wifi_serial(entry.serial) and "wifi" or "usb",
        detail = detail,
        source = "adb",
      })
    end
  end

  for _, name in ipairs(names) do
    local info = M.avd_info(name, opts)
    local running = running_by_avd[name]
    local state = "shutdown"
    if running then
      if running.entry.state == "device" then
        state = running.fact.booted == false and "booting" or "booted"
      else
        state = ADB_STATES[running.entry.state] or "unknown"
      end
    end
    devices[#devices + 1] = Device.new({
      id = name,
      name = info.display_name or (name:gsub("_", " ")),
      platform = "android",
      kind = "emulator",
      state = state,
      os_version = M.release_for_api(info.api),
      model = info.device_type,
      serial = running and running.entry.serial or nil,
      transport = "local",
      source = "emulator",
    })
  end
  return devices
end

--- List AVDs, running emulators and connected devices. A tool that is missing or fails does not
--- hide what the other found: `cb` gets the devices plus the errors.
---@param opts? devices.AndroidOptions
---@param cb fun(devices: devices.Device[], errors: devices.Error[])
function M.list(opts, cb)
  opts = opts or {}
  async.all({
    function(done)
      M.list_avd_names(opts, function(names, failure)
        done({ names = names or {}, error = failure })
      end)
    end,
    function(done)
      M.list_adb(opts, function(entries, failure)
        done({ entries = entries or {}, error = failure })
      end)
    end,
  }, function(results)
    local names, entries = results[1].names, results[2].entries
    local errors = {}
    for _, r in ipairs(results) do
      if r.error then
        errors[#errors + 1] = r.error
      end
    end

    -- Ask each usable device what we need: emulators their AVD and boot state, others their
    -- Android version.
    local adb = M.tool("adb", opts)
    local queries = {}
    for _, entry in ipairs(entries) do
      if adb and entry.state == "device" then
        queries[#queries + 1] = function(done)
          local fact = {}
          local asks = {
            function(next)
              adb_query(adb, entry.serial, { "shell", "getprop", "ro.build.version.release" }, function(out)
                fact.release = out ~= "" and out or nil
                next()
              end)
            end,
          }
          if M.is_emulator_serial(entry.serial) then
            asks[#asks + 1] = function(next)
              adb_query(adb, entry.serial, { "emu", "avd", "name" }, function(out)
                -- Prints the name, then "OK".
                local name = out and out:match("^([^\r\n]+)")
                fact.avd = name ~= "OK" and name or nil
                next()
              end)
            end
            asks[#asks + 1] = function(next)
              adb_query(adb, entry.serial, { "shell", "getprop", "sys.boot_completed" }, function(out)
                fact.booted = out == "1"
                next()
              end)
            end
          end
          async.all(asks, function()
            done({ serial = entry.serial, fact = fact })
          end)
        end
      end
    end

    async.all(queries, function(answers)
      local facts = {}
      for _, a in ipairs(answers) do
        facts[a.serial] = a.fact
      end
      cb(Device.dedupe(M.combine(names, entries, facts, opts)), errors)
    end)
  end)
end

-- Emulator actions ----------------------------------------------------------------------------

---@param device devices.Device
---@param verb string
---@return devices.Error?
local function check_avd(device, verb)
  if device.platform ~= "android" or device.kind ~= "emulator" or device.source ~= "emulator" then
    return err.new("unsupported", ("Cannot %s %s: it is not an Android virtual device"):format(verb, device.name))
  end
end

--- The most useful line of an emulator log: the first error, else the last line.
---@param log string
---@return string
local function log_reason(log)
  local last
  for line in log:gmatch("[^\r\n]+") do
    if line:match("ERROR") or line:match("FATAL") or line:match("PANIC") then
      return vim.trim(line)
    end
    if vim.trim(line) ~= "" then
      last = vim.trim(line)
    end
  end
  return last or "no output"
end

---@param name string
---@return string
local function log_path(name)
  local dir = vim.fn.stdpath("log") .. "/devices"
  vim.fn.mkdir(dir, "p")
  return dir .. "/emulator-" .. name:gsub("[^%w._%-]", "_") .. ".log"
end

---@class devices.AndroidBootOptions
---@field cold? boolean Ignore the saved snapshot and boot from scratch.
---@field wipe? boolean Erase all user data first. Implies a cold boot.
---@field headless? boolean No emulator window.
---@field args? string[] Extra emulator arguments.
---@field wait? boolean Call back only once Android has finished booting.
---@field wait_timeout? integer

--- Start an emulator. It keeps running after Neovim exits. Starting one that is already running
--- succeeds, unless a cold boot or wipe was asked for: then it must be shut down first.
---@param device devices.Device
---@param opts? devices.AndroidBootOptions|devices.AndroidOptions
---@param cb fun(error: devices.Error?)
function M.boot(device, opts, cb)
  opts = opts or {}
  local invalid = check_avd(device, "boot")
  if invalid then
    return later(cb, invalid)
  end
  if device.serial and device.state ~= "shutdown" then
    if opts.cold or opts.wipe then
      return later(
        cb,
        err.new(
          "invalid_state",
          ("Cannot %s %s: it is running"):format(opts.wipe and "wipe" or "cold boot", device.name),
          {
            hint = "Shut it down first.",
          }
        )
      )
    end
    return later(cb, nil)
  end

  local emulator, missing = M.tool("emulator", opts)
  if not emulator then
    return later(cb, missing)
  end
  local argv = { emulator, "-avd", device.id }
  if opts.wipe then
    argv[#argv + 1] = "-wipe-data"
  elseif opts.cold then
    argv[#argv + 1] = "-no-snapshot-load"
  end
  if opts.headless then
    argv[#argv + 1] = "-no-window"
  end
  vim.list_extend(argv, opts.args or {})

  process.spawn_detached(argv, { log = log_path(device.id), grace_ms = opts.grace_ms or LAUNCH_GRACE_MS }, function(res)
    if not res.started then
      return cb(err.new(res.missing and "tool_missing" or "command_failed", "The emulator could not be started", {
        hint = res.error,
        cmd = argv,
      }))
    end
    if res.exited then
      return cb(err.new("command_failed", "The emulator stopped right after starting: " .. log_reason(res.log_tail), {
        hint = "Full log: " .. res.log,
        cmd = argv,
        exit_code = res.code,
        stderr = res.log_tail,
      }))
    end
    if opts.wait then
      return M.wait_booted(device, { timeout = opts.wait_timeout, android = opts }, cb)
    end
    cb(nil)
  end)
end

--- Wait until the emulator started from this AVD has finished booting.
---@param device devices.Device
---@param opts? { timeout?: integer, android?: devices.AndroidOptions }
---@param cb fun(error: devices.Error?)
function M.wait_booted(device, opts, cb)
  opts = opts or {}
  local deadline = vim.uv.hrtime() + (opts.timeout or BOOT_WAIT_TIMEOUT_MS) * 1e6
  local function poll()
    M.list(opts.android, function(devices)
      for _, d in ipairs(devices) do
        if d.source == "emulator" and d.id == device.id and d.state == "booted" then
          return cb(nil)
        end
      end
      if vim.uv.hrtime() >= deadline then
        return cb(err.new("timeout", device.name .. " did not finish booting in time", {
          hint = "It may still be booting. The first boot after a wipe can take several minutes.",
        }))
      end
      vim.defer_fn(poll, BOOT_POLL_MS)
    end)
  end
  poll()
end

--- Shut a running emulator down. One that is not running succeeds at once.
---@param device devices.Device
---@param opts? devices.AndroidOptions
---@param cb fun(error: devices.Error?)
function M.shutdown(device, opts, cb)
  if device.platform ~= "android" or device.kind ~= "emulator" then
    return later(cb, err.new("unsupported", ("Cannot shut down %s: it is not an emulator"):format(device.name)))
  end
  if not device.serial or device.state == "shutdown" then
    return later(cb, nil)
  end
  local adb, missing = M.tool("adb", opts)
  if not adb then
    return later(cb, missing)
  end
  local argv = { adb, "-s", device.serial, "emu", "kill" }
  run(argv, ACTION_TIMEOUT_MS, function(res)
    local failure = err.from_process(res, argv, GUIDE)
    if failure and (res.stderr .. res.stdout):find("not found", 1, true) then
      -- It stopped on its own between listing and now.
      return cb(nil)
    end
    cb(failure)
  end)
end

-- AVD management ------------------------------------------------------------------------------

---@class devices.SystemImage
---@field id string The sdkmanager package: "system-images;android-36;google_apis_playstore;arm64-v8a".
---@field api string
---@field tag string
---@field abi string
---@field label string

--- ABIs this machine can run without translation, best first.
---@param arch string
---@return string[]
local function native_abis(arch)
  if arch == "arm64" then
    return { "arm64-v8a" }
  end
  return { "x86_64", "x86" }
end

--- Installed system images that run natively on this machine, newest first.
---@param opts? devices.AndroidOptions|{ arch?: string }
---@return devices.SystemImage[]
function M.system_images(opts)
  opts = opts or {}
  local sdk = env.android_sdk(opts)
  if not sdk then
    return {}
  end
  local abis = native_abis(opts.arch or env.arch())
  local images = {}
  for _, path in ipairs(vim.fn.glob(sdk .. "/system-images/*/*/*", false, true)) do
    local platform, tag, abi = path:match("system%-images/([^/]+)/([^/]+)/([^/]+)$")
    if platform and vim.tbl_contains(abis, abi) and vim.uv.fs_stat(path .. "/system.img") ~= nil then
      local api = platform:match("^android%-(.+)$") or platform
      images[#images + 1] = {
        id = table.concat({ "system-images", platform, tag, abi }, ";"),
        api = api,
        tag = tag,
        abi = abi,
        label = ("Android %s (API %s) · %s · %s"):format(M.release_for_api(api:match("^%d+")) or api, api, tag, abi),
      }
    end
  end
  table.sort(images, function(a, b)
    local na, nb = tonumber(a.api:match("^%d+")) or 0, tonumber(b.api:match("^%d+")) or 0
    if na ~= nb then
      return na > nb
    end
    return a.id < b.id
  end)
  return images
end

--- avdmanager needs Java. Point it at the JDK we found, so it works without JAVA_HOME set.
---@param opts devices.AndroidOptions
---@param cb fun(environment: table<string, string>?, error: devices.Error?)
local function avdmanager_env(opts, cb)
  env.find_java(opts, function(java)
    if not java then
      return cb(
        nil,
        err.new("tool_missing", "avdmanager needs Java, and none was found", {
          hint = "Install a JDK (17 or newer), or Android Studio, which bundles one.",
          guide = "android",
        })
      )
    end
    if java.home then
      return cb({ JAVA_HOME = java.home })
    end
    cb({})
  end)
end

--- Device profiles avdmanager knows ("pixel_9", "medium_phone", ...).
---@param opts? devices.AndroidOptions
---@param cb fun(ids: string[]?, error: devices.Error?)
function M.device_types(opts, cb)
  opts = opts or {}
  local avdmanager, missing = M.tool("avdmanager", opts)
  if not avdmanager then
    return later(cb, nil, missing)
  end
  avdmanager_env(opts, function(environment, java_error)
    if java_error then
      return cb(nil, java_error)
    end
    local argv = { avdmanager, "list", "device", "-c" }
    process.run(argv, { timeout = AVDMANAGER_TIMEOUT_MS, env = environment }, function(res)
      local failure = err.from_process(res, argv, GUIDE)
      if failure then
        return cb(nil, failure)
      end
      local ids = {}
      for line in res.stdout:gmatch("[^\r\n]+") do
        line = vim.trim(line)
        if line:match("^[%w][%w._%-]*$") then
          ids[#ids + 1] = line
        end
      end
      cb(ids)
    end)
  end)
end

--- Whether a name can be an AVD name.
---@param name string
---@return boolean
function M.valid_avd_name(name)
  return type(name) == "string" and name:match("^[%w][%w._%-]*$") ~= nil
end

--- Create an AVD.
---@param spec { name: string, image: string, device_type?: string }
---@param opts? devices.AndroidOptions
---@param cb fun(error: devices.Error?)
function M.create(spec, opts, cb)
  opts = opts or {}
  if not M.valid_avd_name(spec.name) then
    return later(
      cb,
      err.new("invalid_state", "Invalid name: " .. tostring(spec.name), {
        hint = "Use letters, digits, dots, dashes and underscores, starting with a letter or digit.",
      })
    )
  end
  local avdmanager, missing = M.tool("avdmanager", opts)
  if not avdmanager then
    return later(cb, missing)
  end
  avdmanager_env(opts, function(environment, java_error)
    if java_error then
      return cb(java_error)
    end
    local argv = { avdmanager, "create", "avd", "-n", spec.name, "-k", spec.image }
    if spec.device_type then
      vim.list_extend(argv, { "-d", spec.device_type })
    end
    -- It asks "Do you wish to create a custom hardware profile? [no]".
    process.run(argv, { timeout = AVDMANAGER_TIMEOUT_MS, env = environment, stdin = "no\n" }, function(res)
      local failure = err.from_process(res, argv, GUIDE)
      -- Some versions exit 0 after printing an error.
      if not failure and res.stderr:match("^%s*Error:") then
        failure = err.new("command_failed", "avdmanager failed: " .. vim.trim(res.stderr):match("^[^\r\n]*"), {
          cmd = argv,
          stderr = res.stderr,
        })
      end
      cb(failure)
    end)
  end)
end

--- Delete an AVD. It must not be running.
---@param device devices.Device
---@param opts? devices.AndroidOptions
---@param cb fun(error: devices.Error?)
function M.delete(device, opts, cb)
  opts = opts or {}
  local invalid = check_avd(device, "delete")
  if invalid then
    return later(cb, invalid)
  end
  if device.serial and device.state ~= "shutdown" then
    return later(
      cb,
      err.new("invalid_state", "Cannot delete " .. device.name .. ": it is running", {
        hint = "Shut it down first.",
      })
    )
  end
  local avdmanager, missing = M.tool("avdmanager", opts)
  if not avdmanager then
    return later(cb, missing)
  end
  avdmanager_env(opts, function(environment, java_error)
    if java_error then
      return cb(java_error)
    end
    local argv = { avdmanager, "delete", "avd", "-n", device.id }
    process.run(argv, { timeout = AVDMANAGER_TIMEOUT_MS, env = environment }, function(res)
      cb(err.from_process(res, argv, GUIDE))
    end)
  end)
end

-- Wireless devices ----------------------------------------------------------------------------

--- "192.168.1.5:37123" or "[fe80::1]:5555".
---@param address string
---@return boolean
function M.valid_address(address)
  return type(address) == "string"
    and (address:match("^[%w.%-]+:%d+$") ~= nil or address:match("^%[[%x:]+%]:%d+$") ~= nil)
end

---@param verb string
---@param address string
---@return devices.Error
local function bad_address(verb, address)
  return err.new("invalid_state", ("Cannot %s %s: expected host:port"):format(verb, tostring(address)), {
    hint = "On the phone: Settings > Developer options > Wireless debugging shows the address and port.",
  })
end

--- Pair with a phone using the code from "Pair device with pairing code" (Android 11+).
---@param address string The pairing address, which differs from the connect address.
---@param code string
---@param opts? devices.AndroidOptions
---@param cb fun(error: devices.Error?)
function M.pair(address, code, opts, cb)
  if not M.valid_address(address) then
    return later(cb, bad_address("pair with", address))
  end
  if type(code) ~= "string" or not code:match("^%d%d%d%d%d%d$") then
    return later(cb, err.new("invalid_state", "The pairing code is six digits"))
  end
  local adb, missing = M.tool("adb", opts)
  if not adb then
    return later(cb, missing)
  end
  local argv = { adb, "pair", address, code }
  run(argv, ACTION_TIMEOUT_MS, function(res)
    local failure = err.from_process(res, argv, GUIDE)
    if failure then
      return cb(failure)
    end
    if not res.stdout:find("Successfully paired", 1, true) then
      return cb(err.new("command_failed", "Pairing failed: " .. vim.trim(res.stdout .. res.stderr), {
        hint = "Check the code and address, and keep the pairing dialog open on the phone.",
        cmd = argv,
      }))
    end
    cb(nil)
  end)
end

--- Connect to a phone over Wi-Fi. adb exits 0 even when this fails, so the output decides.
---@param address string
---@param opts? devices.AndroidOptions
---@param cb fun(error: devices.Error?)
function M.connect(address, opts, cb)
  if not M.valid_address(address) then
    return later(cb, bad_address("connect to", address))
  end
  local adb, missing = M.tool("adb", opts)
  if not adb then
    return later(cb, missing)
  end
  local argv = { adb, "connect", address }
  run(argv, ACTION_TIMEOUT_MS, function(res)
    local failure = err.from_process(res, argv, GUIDE)
    if failure then
      return cb(failure)
    end
    local out = res.stdout .. res.stderr
    if out:find("connected to", 1, true) and not out:find("cannot", 1, true) and not out:find("failed", 1, true) then
      return cb(nil)
    end
    cb(err.new("command_failed", "Could not connect: " .. vim.trim(out), {
      hint = "Pair first if this phone was never paired, and make sure both are on the same network.",
      cmd = argv,
    }))
  end)
end

--- Disconnect a Wi-Fi device.
---@param device devices.Device
---@param opts? devices.AndroidOptions
---@param cb fun(error: devices.Error?)
function M.disconnect(device, opts, cb)
  if device.platform ~= "android" or device.transport ~= "wifi" then
    return later(cb, err.new("unsupported", "Only Android devices connected over Wi-Fi can be disconnected"))
  end
  local adb, missing = M.tool("adb", opts)
  if not adb then
    return later(cb, missing)
  end
  local argv = { adb, "disconnect", device.serial or device.id }
  run(argv, ACTION_TIMEOUT_MS, function(res)
    cb(err.from_process(res, argv, GUIDE))
  end)
end

return M
