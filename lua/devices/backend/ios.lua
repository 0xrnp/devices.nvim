--- iOS simulators (simctl) and physical devices (devicectl). macOS and Xcode only.
local async = require("devices.async")
local Device = require("devices.device")
local err = require("devices.error")
local process = require("devices.process")

local M = {}

local LIST_TIMEOUT_MS = 30000
local ACTION_TIMEOUT_MS = 60000
local SIMULATOR_APP = "com.apple.iphonesimulator"
local DEVICEHUB_APP = "com.apple.dt.Devices"
-- The first boot of a new simulator has taken minutes, so waiting for it needs a long limit.
local BOOT_WAIT_TIMEOUT_MS = 600000

local NOT_INSTALLED = { hint = "Install Xcode from the App Store.", guide = "ios" }

local DECODE = { luanil = { object = true, array = true } }

--- The first value found at any of the dotted paths.
---@param tbl table
---@param ... string
---@return any
local function pick(tbl, ...)
  for _, path in ipairs({ ... }) do
    local value = tbl
    for key in path:gmatch("[^.]+") do
      if type(value) ~= "table" then
        value = nil
        break
      end
      value = value[key]
    end
    if value ~= nil then
      return value
    end
  end
end

---@param value any
---@return boolean
local function non_empty_string(value)
  return type(value) == "string" and value ~= ""
end

-- Parsing -------------------------------------------------------------------------------------

local SIMCTL_STATES = {
  Booted = "booted",
  Booting = "booting",
  Shutdown = "shutdown",
  ["Shutting Down"] = "shutting_down",
}

--- Modern simctl has `isAvailable`. Older versions have an `availability` string.
---@param entry table
---@return boolean
local function simctl_available(entry)
  if entry.isAvailable ~= nil then
    return entry.isAvailable == true
  end
  return entry.availability == nil or entry.availability == "(available)"
end

--- Read `simctl list devices --json`. Only iOS simulators are returned. Unavailable ones (a
--- runtime that is no longer installed) and other platforms are skipped.
---@param text string
---@return devices.Device[]? devices
---@return devices.Error? error
function M.parse_simctl(text)
  local ok, data = pcall(vim.json.decode, text, DECODE)
  if not ok or type(data) ~= "table" or type(data.devices) ~= "table" then
    return nil, err.new("parse_failed", "Could not read the simulator list from simctl")
  end

  local runtimes = vim.tbl_keys(data.devices)
  table.sort(runtimes)

  local devices = {}
  for _, runtime in ipairs(runtimes) do
    -- "...SimRuntime.iOS-18-2", and variants such as "...iOS-18-2-iPhone17-4". Before Xcode 10.1
    -- the keys were names such as "iOS 12.1".
    local platform, major, minor = runtime:match("SimRuntime%.(%a+)%-(%d+)%-(%d+)")
    if not platform then
      platform, major, minor = runtime:match("^(%a+) (%d+)%.(%d+)")
    end
    local entries = data.devices[runtime]
    if platform == "iOS" and type(entries) == "table" then
      for _, entry in ipairs(entries) do
        if
          type(entry) == "table"
          and non_empty_string(entry.udid)
          and non_empty_string(entry.name)
          and simctl_available(entry)
        then
          devices[#devices + 1] = Device.new({
            id = entry.udid,
            name = entry.name,
            platform = "ios",
            kind = "simulator",
            state = SIMCTL_STATES[entry.state] or "unknown",
            os_version = major .. "." .. minor,
            transport = "local",
            source = "simctl",
          })
        end
      end
    end
  end
  return devices
end

local TRANSPORTS = { wired = "usb", localNetwork = "wifi" }

--- Xcode 27 reports versions as { stringValue = "27.0", components = {...} }; older Xcode as
--- "27.0".
---@param value any
---@return string?
local function version_string(value)
  if type(value) == "table" then
    value = value.stringValue
  end
  return non_empty_string(value) and value or nil
end

--- Read `devicectl list devices --json-output`. Xcode 27 moved the fields under `properties`
--- and deprecated the old `hardwareProperties`, `deviceProperties` and `connectionProperties`.
--- Both layouts are read, the new one first. Only physical iPhones and iPads are returned.
---@param text string
---@return devices.Device[]? devices
---@return devices.Error? error
function M.parse_devicectl(text)
  local ok, data = pcall(vim.json.decode, text, DECODE)
  if not ok or type(data) ~= "table" or type(data.result) ~= "table" or type(data.result.devices) ~= "table" then
    return nil, err.new("parse_failed", "Could not read the device list from devicectl")
  end

  local devices = {}
  for _, entry in ipairs(data.result.devices) do
    if type(entry) == "table" then
      local udid = pick(entry, "properties.hardware.udid", "hardwareProperties.udid")
      local name = pick(
        entry,
        "properties.state.name",
        "deviceProperties.name",
        "properties.hardware.marketingName",
        "hardwareProperties.marketingName"
      )
      local reality = pick(entry, "properties.hardware.reality", "hardwareProperties.reality")
      local device_type = pick(entry, "properties.hardware.deviceType", "hardwareProperties.deviceType")

      if
        non_empty_string(udid)
        and non_empty_string(name)
        and reality == "physical"
        and (device_type == "iPhone" or device_type == "iPad")
      then
        local transport = pick(entry, "properties.connection.transportType", "connectionProperties.transportType")
        local link = pick(entry, "properties.connection.state", "connectionProperties.tunnelState")
        local pairing = pick(entry, "properties.connection.pairingState", "connectionProperties.pairingState")
        local developer_mode =
          pick(entry, "properties.state.developerModeStatus", "deviceProperties.developerModeStatus")

        -- "unavailable" means the device cannot be reached. Without a link state, a transport does.
        local reachable
        if link ~= nil then
          reachable = link ~= "unavailable"
        else
          reachable = transport ~= nil
        end

        local state = "disconnected"
        if reachable then
          -- An unpaired device is attached but has not been trusted yet.
          state = pairing == "paired" and "connected" or "unauthorized"
        end

        local detail
        if reachable and developer_mode == "disabled" then
          detail = "Developer Mode is off. Turn it on in Settings > Privacy & Security > Developer Mode."
        end

        devices[#devices + 1] = Device.new({
          id = udid,
          name = name,
          platform = "ios",
          kind = "physical",
          state = state,
          os_version = version_string(
            pick(entry, "properties.software.osVersionNumber", "deviceProperties.osVersionNumber")
          ),
          transport = reachable and TRANSPORTS[transport] or nil,
          detail = detail,
          source = "devicectl",
        })
      end
    end
  end
  return devices
end

-- Listing -------------------------------------------------------------------------------------

---@param opts? { timeout?: integer }
---@param cb fun(devices: devices.Device[]?, error: devices.Error?)
function M.list_simulators(opts, cb)
  opts = opts or {}
  local argv = { "xcrun", "simctl", "list", "devices", "--json" }
  process.run(argv, { timeout = opts.timeout or LIST_TIMEOUT_MS }, function(res)
    local failure = err.from_process(res, argv, NOT_INSTALLED)
    if failure then
      return cb(nil, failure)
    end
    local devices, parse_error = M.parse_simctl(res.stdout)
    cb(devices, parse_error)
  end)
end

---@param opts? { timeout?: integer }
---@param cb fun(devices: devices.Device[]?, error: devices.Error?)
function M.list_physical(opts, cb)
  opts = opts or {}
  -- devicectl only writes JSON to a file. It holds device names and ids, so it is read and
  -- deleted at once. tempname() is inside a directory only this user can open.
  local out = vim.fn.tempname() .. ".json"
  local argv = { "xcrun", "devicectl", "list", "devices", "--json-output", out }
  process.run(argv, { timeout = opts.timeout or LIST_TIMEOUT_MS }, function(res)
    local failure = err.from_process(res, argv, NOT_INSTALLED)
    local lines = {}
    if not failure then
      local read_ok, content = pcall(vim.fn.readfile, out)
      lines = read_ok and content or {}
    end
    vim.fn.delete(out)

    if failure then
      return cb(nil, failure)
    end
    local devices, parse_error = M.parse_devicectl(table.concat(lines, "\n"))
    cb(devices, parse_error)
  end)
end

--- List simulators and physical devices together. A source that fails does not hide the other:
--- `cb` always gets the devices that were found, plus the errors of the sources that failed.
---@param opts? { simulators?: boolean, physical?: boolean, timeout?: integer, env?: devices.IosEnv }
---@param cb fun(devices: devices.Device[], errors: devices.Error[])
function M.list(opts, cb)
  opts = opts or {}
  local env = opts.env
  if env and not env.supported then
    return vim.schedule(function()
      cb({}, {})
    end)
  end

  local tasks = {}
  local function add(wanted, source)
    if wanted then
      tasks[#tasks + 1] = function(done)
        source(opts, function(devices, failure)
          done({ devices = devices or {}, error = failure })
        end)
      end
    end
  end
  add(opts.simulators ~= false and (not env or env.simctl), M.list_simulators)
  add(opts.physical ~= false and (not env or env.devicectl), M.list_physical)

  async.all(tasks, function(results)
    local devices, errors, seen = {}, {}, {}
    for _, result in ipairs(results) do
      vim.list_extend(devices, result.devices)
      local failure = result.error
      -- Without Xcode both lookups fail the same way: say it once.
      local key = failure and (failure.code .. "\0" .. failure.message .. "\0" .. (failure.hint or ""))
      if failure and not seen[key] then
        seen[key] = true
        errors[#errors + 1] = failure
      end
    end
    cb(Device.dedupe(devices), errors)
  end)
end

-- Actions -------------------------------------------------------------------------------------

---@class devices.IosAction
---@field verb string For messages: "boot", "shut down", "erase".
---@field already table<string, boolean> Simulator states in which the goal is already met.
---@field hint string? Advice when the state is wrong.

---@type table<string, devices.IosAction>
local ACTIONS = {
  boot = { verb = "boot", already = { Booted = true, Booting = true } },
  shutdown = { verb = "shut down", already = { Shutdown = true, ["Shutting Down"] = true } },
  erase = { verb = "erase", already = {}, hint = "Shut it down first." },
}

--- Turn a failed simctl action into a typed error. simctl exits 148 for an unknown device and
--- 149 for a wrong state ("Unable to boot device in current state: Booted").
---@param res devices.ProcessResult
---@param argv string[]
---@param action devices.IosAction
---@return devices.Error? error nil when the action succeeded or its goal was already met
local function action_error(res, argv, action)
  local failure = err.from_process(res, argv, NOT_INSTALLED)
  if not failure or failure.code ~= "command_failed" then
    return failure
  end

  local text = res.stderr .. "\n" .. res.stdout
  if text:find("Invalid device", 1, true) then
    return err.new("not_found", "That simulator no longer exists", {
      hint = "Refresh the device list.",
      cmd = argv,
      exit_code = res.code,
      stderr = res.stderr,
    })
  end

  local state = vim.trim(text:match("in current state:[ \t]*([^\r\n]*)") or "")
  -- A message with no state name is reported as the plain command failure below.
  if state ~= "" then
    if action.already[state] then
      return nil
    end
    return err.new("invalid_state", ("Cannot %s: the simulator is %s"):format(action.verb, state:lower()), {
      hint = action.hint,
      cmd = argv,
      exit_code = res.code,
      stderr = res.stderr,
    })
  end
  return failure
end

---@param device devices.Device
---@param action devices.IosAction
---@return devices.Error?
local function check_simulator(device, action)
  if device.platform ~= "ios" or device.kind ~= "simulator" then
    return err.new("unsupported", ("Cannot %s %s: it is not an iOS simulator"):format(action.verb, device.name), {
      hint = "Only iOS simulators can be booted, shut down or erased.",
    })
  end
end

---@param device devices.Device
---@param action devices.IosAction
---@param argv string[]
---@param cb fun(error: devices.Error?)
local function run_action(device, action, argv, cb)
  local invalid = check_simulator(device, action)
  if invalid then
    return vim.schedule(function()
      cb(invalid)
    end)
  end
  process.run(argv, { timeout = ACTION_TIMEOUT_MS }, function(res)
    cb(action_error(res, argv, action))
  end)
end

--- Wait until the simulator has finished booting.
---@param device devices.Device
---@param opts? { timeout?: integer }
---@param cb fun(error: devices.Error?)
function M.wait_booted(device, opts, cb)
  opts = opts or {}
  local argv = { "xcrun", "simctl", "bootstatus", device.id }
  process.run(argv, { timeout = opts.timeout or BOOT_WAIT_TIMEOUT_MS }, function(res)
    local failure = action_error(res, argv, ACTIONS.boot)
    if failure and failure.code == "timeout" then
      failure.hint = "It is still booting. The first boot of a new simulator can take several minutes."
    end
    cb(failure)
  end)
end

--- Boot a simulator. Booting one that is already booted succeeds.
--- By default this returns as soon as the boot has started and opens Simulator.app (DeviceHub in
--- Xcode 27).
---@param device devices.Device
---@param opts? { wait?: boolean, open_app?: boolean, wait_timeout?: integer }
---@param cb fun(error: devices.Error?)
function M.boot(device, opts, cb)
  opts = opts or {}
  run_action(device, ACTIONS.boot, { "xcrun", "simctl", "boot", device.id }, function(failure)
    if failure then
      return cb(failure)
    end

    local function after_open()
      if opts.wait then
        M.wait_booted(device, { timeout = opts.wait_timeout }, cb)
      else
        cb(nil)
      end
    end

    if opts.open_app == false then
      return after_open()
    end
    -- Xcode 26 and earlier ship Simulator.app, told which device to show by a launch argument.
    -- Xcode 27 replaced it with DeviceHub, which opens a device from the same URL Xcode itself
    -- sends (IDEKit's IDEDevicesApp.show). The app inside the selected Xcode comes first, so a
    -- Mac with several Xcodes opens the matching one. Then any installed copy, by bundle id.
    local id = device.id:gsub("[^%w%-%.]", function(c)
      return ("%%%02X"):format(c:byte())
    end)
    local url = "devices://device/open?id=" .. id
    local candidates = {}
    local function try(i, last_error, last_res, last_argv)
      local argv = candidates[i]
      if not argv then
        return cb(
          err.new("command_failed", "The simulator booted, but neither Simulator nor DeviceHub could be opened", {
            hint = last_error.message
              .. ". Open Xcode once to finish installing it, or set ios.open_simulator_app = false.",
            cmd = last_argv,
            exit_code = last_res.code,
            stderr = last_res.stderr,
          })
        )
      end
      process.run(argv, { timeout = ACTION_TIMEOUT_MS }, function(res)
        local open_error = err.from_process(res, argv)
        if open_error then
          return try(i + 1, open_error, res, argv)
        end
        after_open()
      end)
    end
    process.run({ "xcode-select", "-p" }, { timeout = 10000 }, function(selected)
      local developer = selected.code == 0 and vim.trim(selected.stdout or "") or ""
      if developer ~= "" then
        -- .../Xcode.app/Contents/Developer: Simulator.app is under it, DeviceHub.app next to it.
        local simulator = developer .. "/Applications/Simulator.app"
        local devicehub = vim.fn.fnamemodify(developer, ":h") .. "/Applications/DeviceHub.app"
        if vim.uv.fs_stat(simulator) then
          candidates[#candidates + 1] = { "open", "-a", simulator, "--args", "-CurrentDeviceUDID", device.id }
        end
        if vim.uv.fs_stat(devicehub) then
          candidates[#candidates + 1] = { "open", "-a", devicehub, url }
        end
      end
      vim.list_extend(candidates, {
        { "open", "-b", SIMULATOR_APP, "--args", "-CurrentDeviceUDID", device.id },
        { "open", "-b", DEVICEHUB_APP, url },
      })
      try(1)
    end)
  end)
end

--- Shut a simulator down. Shutting down one that is already off succeeds.
---@param device devices.Device
---@param cb fun(error: devices.Error?)
function M.shutdown(device, cb)
  run_action(device, ACTIONS.shutdown, { "xcrun", "simctl", "shutdown", device.id }, cb)
end

-- The apps that show simulators, by process name. Both keep a window open for a simulator after
-- it shuts down.
local SIMULATOR_APPS = {
  { process = "Simulator", bundle = SIMULATOR_APP },
  { process = "DeviceHub", bundle = DEVICEHUB_APP },
}

--- Quit Simulator.app and DeviceHub once no simulator is running. An app that is not running is
--- left alone, and so are both while any simulator still runs, because quitting DeviceHub stops
--- its simulators by default.
---@param cb fun(error: devices.Error?)
function M.quit_simulator_apps(cb)
  local function quit(i)
    local app = SIMULATOR_APPS[i]
    if not app then
      return cb(nil)
    end
    process.run({ "pgrep", "-x", app.process }, { timeout = 10000 }, function(found)
      if found.missing or found.code ~= 0 then
        return quit(i + 1)
      end
      -- Listed again right before quitting: a simulator may have been booted meanwhile.
      M.list_simulators(nil, function(devices, list_error)
        if list_error then
          return cb(list_error)
        end
        for _, d in ipairs(devices or {}) do
          if d.state ~= "shutdown" then
            return cb(nil)
          end
        end
        local argv = { "osascript", "-e", ('tell application id "%s" to quit'):format(app.bundle) }
        process.run(argv, { timeout = ACTION_TIMEOUT_MS }, function(res)
          local failure = err.from_process(res, argv)
          if failure then
            failure.message = "The simulator shut down, but "
              .. app.process
              .. " could not be quit: "
              .. failure.message
            failure.hint = "Allow Neovim's terminal to control "
              .. app.process
              .. " in System Settings > Privacy & Security > Automation, or set ios.quit_simulator_app = false."
            return cb(failure)
          end
          quit(i + 1)
        end)
      end)
    end)
  end
  quit(1)
end

--- Erase a simulator's content and settings. It must be shut down.
---@param device devices.Device
---@param cb fun(error: devices.Error?)
function M.erase(device, cb)
  run_action(device, ACTIONS.erase, { "xcrun", "simctl", "erase", device.id }, cb)
end

-- Creating and deleting -----------------------------------------------------------------------

---@class devices.IosRuntime
---@field id string "com.apple.CoreSimulator.SimRuntime.iOS-18-2"
---@field name string "iOS 18.2"
---@field version string
---@field device_types { id: string, name: string }[] iPhones first, then iPads.

--- iPhone and iPad device types from simctl's JSON, iPhones first, in simctl's order otherwise.
--- Older simctl has no productFamily, so the name decides.
---@param list any
---@return { id: string, name: string }[]
local function phone_and_tablet_types(list)
  local types = {}
  for _, t in ipairs(type(list) == "table" and list or {}) do
    if type(t) == "table" and non_empty_string(t.identifier) and non_empty_string(t.name) then
      local family = t.productFamily or t.name:match("^(iPhone)") or t.name:match("^(iPad)")
      if family == "iPhone" or family == "iPad" then
        types[#types + 1] = { id = t.identifier, name = t.name, family = family }
      end
    end
  end
  local ordered = {}
  for _, family in ipairs({ "iPhone", "iPad" }) do
    for _, t in ipairs(types) do
      if t.family == family then
        ordered[#ordered + 1] = { id = t.id, name = t.name }
      end
    end
  end
  return ordered
end

--- Read `simctl list runtimes --json`: available iOS runtimes, newest first, with the device
--- types each one supports. Before Xcode 13 the list has no `platform` or
--- `supportedDeviceTypes`; then the platform comes from the id and device_types stays empty.
---@param text string
---@return devices.IosRuntime[]? runtimes
---@return devices.Error? error
function M.parse_runtimes(text)
  local ok, data = pcall(vim.json.decode, text, DECODE)
  if not ok or type(data) ~= "table" or type(data.runtimes) ~= "table" then
    return nil, err.new("parse_failed", "Could not read the runtime list from simctl")
  end
  local runtimes = {}
  for _, r in ipairs(data.runtimes) do
    if
      type(r) == "table"
      and non_empty_string(r.identifier)
      and non_empty_string(r.name)
      and (r.platform == "iOS" or (r.platform == nil and r.identifier:find("SimRuntime.iOS-", 1, true)))
      and simctl_available(r)
    then
      runtimes[#runtimes + 1] = {
        id = r.identifier,
        name = r.name,
        version = tostring(r.version or ""),
        device_types = phone_and_tablet_types(r.supportedDeviceTypes),
      }
    end
  end
  table.sort(runtimes, function(a, b)
    local va, vb = vim.version.parse(a.version), vim.version.parse(b.version)
    if va and vb and va ~= vb then
      return va > vb
    end
    -- Plain runtimes before special builds of the same version.
    if #a.id ~= #b.id then
      return #a.id < #b.id
    end
    return a.id < b.id
  end)
  return runtimes
end

---@param cb fun(runtimes: devices.IosRuntime[]?, error: devices.Error?)
function M.runtimes(cb)
  local argv = { "xcrun", "simctl", "list", "runtimes", "--json" }
  process.run(argv, { timeout = LIST_TIMEOUT_MS }, function(res)
    local failure = err.from_process(res, argv, NOT_INSTALLED)
    if failure then
      return cb(nil, failure)
    end
    local runtimes, parse_error = M.parse_runtimes(res.stdout)
    if not runtimes then
      return cb(nil, parse_error)
    end
    local missing = vim.tbl_filter(function(r)
      return #r.device_types == 0
    end, runtimes)
    if #missing == 0 then
      return cb(runtimes)
    end
    -- Older simctl does not say which device types a runtime supports: offer every iPhone and
    -- iPad, and let simctl refuse a combination that does not work.
    local types_argv = { "xcrun", "simctl", "list", "devicetypes", "--json" }
    process.run(types_argv, { timeout = LIST_TIMEOUT_MS }, function(types_res)
      local decoded_ok, data = pcall(vim.json.decode, types_res.stdout or "", DECODE)
      if types_res.code == 0 and decoded_ok and type(data) == "table" then
        local types = phone_and_tablet_types(data.devicetypes)
        for _, r in ipairs(missing) do
          r.device_types = types
        end
      end
      cb(runtimes)
    end)
  end)
end

--- Create a simulator and return its UDID.
---@param spec { name: string, device_type: string, runtime: string }
---@param cb fun(udid: string?, error: devices.Error?)
function M.create(spec, cb)
  if not non_empty_string(spec.name) or spec.name:find("[\r\n]") then
    return vim.schedule(function()
      cb(nil, err.new("invalid_state", "The simulator needs a name"))
    end)
  end
  local argv = { "xcrun", "simctl", "create", spec.name, spec.device_type, spec.runtime }
  process.run(argv, { timeout = ACTION_TIMEOUT_MS }, function(res)
    local failure = err.from_process(res, argv, NOT_INSTALLED)
    if failure then
      return cb(nil, failure)
    end
    local udid = vim.trim(res.stdout)
    if not udid:match("^%x+%-%x+%-%x+%-%x+%-%x+$") then
      return cb(nil, err.new("parse_failed", "simctl did not print the new simulator's id", { cmd = argv }))
    end
    cb(udid)
  end)
end

--- Delete a simulator. A booted one is shut down by simctl first.
---@param device devices.Device
---@param cb fun(error: devices.Error?)
function M.delete(device, cb)
  run_action(device, { verb = "delete", already = {} }, { "xcrun", "simctl", "delete", device.id }, cb)
end

-- Apps ----------------------------------------------------------------------------------------

--- The executable name of an installed app ("Runner" for most Flutter apps), which is the
--- process name its logs carry.
---@param device devices.Device a booted simulator
---@param bundle_id string
---@param cb fun(name: string?, error: devices.Error?)
function M.app_executable(device, bundle_id, cb)
  local argv = { "xcrun", "simctl", "get_app_container", device.id, bundle_id, "app" }
  process.run(argv, { timeout = ACTION_TIMEOUT_MS }, function(res)
    local failure = err.from_process(res, argv, NOT_INSTALLED)
    if failure then
      failure.hint = "Is " .. bundle_id .. " installed on " .. device.name .. ", and is it booted?"
      return cb(nil, failure)
    end
    local plist = vim.trim(res.stdout) .. "/Info.plist"
    local read = { "plutil", "-extract", "CFBundleExecutable", "raw", "-o", "-", plist }
    process.run(read, { timeout = ACTION_TIMEOUT_MS }, function(out)
      local name = vim.trim(out.stdout)
      if out.code ~= 0 or name == "" then
        return cb(nil, err.new("parse_failed", "Could not read the app's executable name", { cmd = read }))
      end
      cb(name)
    end)
  end)
end

return M
