local h = require("helpers")
local eq = h.eq

local Device = require("devices.device")
local fake_xcode = require("fake_xcode")
local fixtures = require("fixtures.ios")
local ios = require("devices.backend.ios")

local function new_fake()
  return fake_xcode.new({ simctl_json = fixtures.simctl(), devicectl_json = fixtures.devicectl("both") })
end

local function simulator(udid, name)
  return Device.new({
    id = udid,
    name = name or "Test Sim",
    platform = "ios",
    kind = "simulator",
    state = "shutdown",
    source = "simctl",
  })
end

--- Run `ios.list` and return its devices and errors.
local function list(opts)
  local result = h.await(function(cb)
    ios.list(opts, function(devices, errors)
      cb({ devices = devices, errors = errors })
    end)
  end)
  return result.devices, result.errors
end

--- Run an action that reports `cb(error)` and return the error.
local function act(start)
  local result = h.await(function(cb)
    start(function(e)
      cb({ error = e })
    end)
  end)
  return result.error
end

--- The calls whose first argument is `first`.
local function calls_of(fake, first)
  return vim.tbl_filter(function(call)
    return call[1] == first
  end, fake.calls())
end

local T = {}

-- list --------------------------------------------------------------------------------------

T["list: simulators and physical devices together"] = function()
  local fake = new_fake()
  h.with_env(fake.env(), function()
    local devices, errors = list()
    eq(errors, {})
    eq(#devices, 8 + 5)
    eq(#vim.tbl_filter(function(d)
      return d.kind == "physical"
    end, devices), 5)
  end)
end

T["list: sorts well when the caller sorts"] = function()
  local fake = new_fake()
  h.with_env(fake.env(), function()
    local devices = Device.sort((list()))
    -- The three connected physical devices first, by name, then the one booted simulator.
    eq({ devices[1].name, devices[2].name, devices[3].name }, { "No Dev Mode iPhone", "Test iPad", "Test iPhone" })
    eq(devices[4].name, "iPhone 16")
    eq(devices[4].state, "booted")
  end)
end

T["list: another OS lists nothing and runs nothing"] = function()
  local fake = new_fake()
  h.with_env(fake.env(), function()
    local devices, errors = list({ env = { supported = false, simctl = false, devicectl = false, problems = {} } })
    eq(devices, {})
    eq(errors, {})
    eq(fake.calls(), {})
  end)
end

T["list: only asks the tools the environment says exist"] = function()
  local fake = new_fake()
  h.with_env(fake.env(), function()
    local devices = list({ env = { supported = true, simctl = true, devicectl = false, problems = {} } })
    eq(#devices, 8)
    eq(#calls_of(fake, "devicectl"), 0)
  end)

  local fake2 = new_fake()
  h.with_env(fake2.env(), function()
    local devices = list({ env = { supported = true, simctl = false, devicectl = true, problems = {} } })
    eq(#devices, 5)
    eq(#calls_of(fake2, "simctl"), 0)
  end)
end

T["list: a failing devicectl still returns the simulators"] = function()
  local fake = new_fake()
  h.with_env(fake.env({ FAKE_DEVICECTL_EXIT = "1" }), function()
    local devices, errors = list()
    eq(#devices, 8)
    eq(#errors, 1)
    eq(errors[1].code, "command_failed")
    eq(errors[1].message, "xcrun failed: devicectl: something went wrong")
  end)
end

T["list: a failing simctl still returns the physical devices"] = function()
  local fake = new_fake()
  h.with_env(fake.env({ FAKE_SIMCTL_LIST_FAIL = "1" }), function()
    local devices, errors = list()
    eq(#devices, 5)
    eq(#errors, 1)
    eq(errors[1].message, "xcrun failed: simctl exploded")
  end)
end

T["list: both failing gives no devices and both errors"] = function()
  local fake = new_fake()
  h.with_env(fake.env({ FAKE_SIMCTL_LIST_FAIL = "1", FAKE_DEVICECTL_EXIT = "2" }), function()
    local devices, errors = list()
    eq(devices, {})
    eq(#errors, 2)
  end)
end

T["list: Xcode not installed is a tool_missing error with a hint"] = function()
  h.with_env(h.isolated(), function()
    local devices, errors = list()
    eq(devices, {})
    -- Simulators and physical devices both need xcrun, but the problem is reported once.
    eq(#errors, 1)
    eq(errors[1].code, "tool_missing")
    eq(errors[1].guide, "ios")
    eq(errors[1].hint, "Install Xcode from the App Store.")
  end)
end

T["list: a hung simctl times out and does not hide the rest"] = function()
  local fake = new_fake()
  h.with_env(fake.env({ FAKE_SIMCTL_LIST_SLEEP = "60" }), function()
    local devices, errors = list({ timeout = 2000 })
    eq(#devices, 5)
    eq(#errors, 1)
    eq(errors[1].code, "timeout")
  end)
end

T["list: garbage from simctl is a parse error"] = function()
  local fake = fake_xcode.new({ simctl_json = "this is not json", devicectl_json = fixtures.devicectl("new") })
  h.with_env(fake.env(), function()
    local devices, errors = list()
    eq(#devices, 5)
    eq(errors[1].code, "parse_failed")
  end)
end

T["list: the devicectl output file is deleted after it is read"] = function()
  local fake = new_fake()
  h.with_env(fake.env(), function()
    list({ simulators = false })
    local call = calls_of(fake, "devicectl")[1]
    local path = call[5]
    eq(call[4], "--json-output")
    eq(type(path), "string")
    eq(vim.uv.fs_stat(path), nil)
  end)
end

T["list: the devicectl output file is deleted when devicectl fails too"] = function()
  local fake = new_fake()
  h.with_env(fake.env({ FAKE_DEVICECTL_EXIT = "1" }), function()
    list({ simulators = false })
    eq(vim.uv.fs_stat(calls_of(fake, "devicectl")[1][5]), nil)
  end)
end

-- boot --------------------------------------------------------------------------------------

T["boot: boots a shut down simulator and opens Simulator.app"] = function()
  local fake = new_fake()
  local udid = fixtures.udid.shutdown
  fake.set_state(udid, "Shutdown")
  h.with_env(fake.env(), function()
    eq(
      act(function(cb)
        ios.boot(simulator(udid), nil, cb)
      end),
      nil
    )
    eq(fake.get_state(udid), "Booted")
    eq(fake.calls(), {
      { "simctl", "boot", udid },
      { "-b", "com.apple.iphonesimulator", "--args", "-CurrentDeviceUDID", udid },
    })
  end)
end

T["boot: with Xcode 27, which has DeviceHub instead of Simulator.app, opens the device there"] = function()
  local fake = new_fake()
  fake.set_state("S1", "Shutdown")
  h.with_env(fake.env({ FAKE_OPEN_APPS = "com.apple.dt.Devices" }), function()
    eq(
      act(function(cb)
        ios.boot(simulator("S1"), nil, cb)
      end),
      nil
    )
    eq(fake.calls(), {
      { "simctl", "boot", "S1" },
      { "-b", "com.apple.iphonesimulator", "--args", "-CurrentDeviceUDID", "S1" },
      { "-b", "com.apple.dt.Devices", "devices://device/open?id=S1" },
    })
  end)
end

T["boot: open_app = false does not touch Simulator.app"] = function()
  local fake = new_fake()
  fake.set_state("S1", "Shutdown")
  h.with_env(fake.env(), function()
    eq(
      act(function(cb)
        ios.boot(simulator("S1"), { open_app = false }, cb)
      end),
      nil
    )
    eq(fake.calls(), { { "simctl", "boot", "S1" } })
  end)
end

T["boot: a simulator that is already booted is a success"] = function()
  local fake = new_fake()
  fake.set_state("S1", "Booted")
  h.with_env(fake.env(), function()
    eq(
      act(function(cb)
        ios.boot(simulator("S1"), { open_app = false }, cb)
      end),
      nil
    )
    eq(fake.get_state("S1"), "Booted")
  end)
end

T["boot: an unknown simulator is not_found"] = function()
  local fake = new_fake()
  h.with_env(fake.env(), function()
    local e = act(function(cb)
      ios.boot(simulator("NO-SUCH"), nil, cb)
    end)
    eq(e.code, "not_found")
    eq(e.hint, "Refresh the device list.")
    -- It failed before trying to open the app.
    eq(#calls_of(fake, "-b"), 0)
  end)
end

T["boot: waiting for boot calls bootstatus and returns after it"] = function()
  local fake = new_fake()
  fake.set_state("S1", "Shutdown")
  h.with_env(fake.env(), function()
    eq(
      act(function(cb)
        ios.boot(simulator("S1"), { wait = true, open_app = false }, cb)
      end),
      nil
    )
    eq(fake.calls(), { { "simctl", "boot", "S1" }, { "simctl", "bootstatus", "S1" } })
  end)
end

T["boot: a boot that outlasts the wait limit says so"] = function()
  local fake = new_fake()
  fake.set_state("S1", "Shutdown")
  h.with_env(fake.env({ FAKE_BOOTSTATUS_SLEEP = "5" }), function()
    local e = act(function(cb)
      ios.boot(simulator("S1"), { wait = true, wait_timeout = 400, open_app = false }, cb)
    end)
    eq(e.code, "timeout")
    eq(e.hint:find("first boot", 1, true) ~= nil, true)
    -- The simulator itself did boot.
    eq(fake.get_state("S1"), "Booted")
  end)
end

T["boot: when no simulator app opens, it says so, and the device stays booted"] = function()
  local fake = new_fake()
  fake.set_state("S1", "Shutdown")
  h.with_env(fake.env({ FAKE_OPEN_APPS = "" }), function()
    local e = act(function(cb)
      ios.boot(simulator("S1"), nil, cb)
    end)
    eq(e.code, "command_failed")
    eq(e.message, "The simulator booted, but neither Simulator nor DeviceHub could be opened")
    eq(e.hint:find("ios.open_simulator_app = false", 1, true) ~= nil, true)
    eq(#calls_of(fake, "-b"), 2)
    eq(fake.get_state("S1"), "Booted")
  end)
end

T["boot: ids with spaces and shell characters stay one argument"] = function()
  local fake = new_fake()
  local odd = "weird id; touch pwned `id` $(id) 'q' \"d\""
  fake.set_state(odd, "Shutdown")
  h.with_env(fake.env(), function()
    eq(
      act(function(cb)
        ios.boot(simulator(odd), { open_app = false }, cb)
      end),
      nil
    )
    eq(fake.calls()[1], { "simctl", "boot", odd })
    eq(fake.get_state(odd), "Booted")
  end)
end

--- A fake Xcode.app with the given apps inside, and its Developer folder for xcode-select.
---@param apps { simulator?: boolean, devicehub?: boolean }
---@return string developer
---@return string contents
local function fake_xcode_app(apps)
  local files = { ["Xcode.app/Contents/Developer/"] = "" }
  if apps.simulator then
    files["Xcode.app/Contents/Developer/Applications/Simulator.app/"] = ""
  end
  if apps.devicehub then
    files["Xcode.app/Contents/Applications/DeviceHub.app/"] = ""
  end
  local root = h.tree(files)
  return root .. "/Xcode.app/Contents/Developer", root .. "/Xcode.app/Contents"
end

T["boot: with several Xcodes, opens the app of the selected one"] = function()
  -- Xcode 26 selected: its Simulator.app, even though another Xcode's DeviceHub is installed.
  local fake = new_fake()
  fake.set_state("S1", "Shutdown")
  local developer = fake_xcode_app({ simulator = true })
  h.with_env(fake.env({ FAKE_DEVELOPER_DIR = developer, FAKE_OPEN_APPS = "com.apple.dt.Devices" }), function()
    eq(
      act(function(cb)
        ios.boot(simulator("S1"), nil, cb)
      end),
      nil
    )
    eq(calls_of(fake, "-a"), {
      { "-a", developer .. "/Applications/Simulator.app", "--args", "-CurrentDeviceUDID", "S1" },
    })
    eq(#calls_of(fake, "-b"), 0)
  end)

  -- Xcode 27 selected: its DeviceHub, even though an older Simulator.app is installed.
  fake = new_fake()
  fake.set_state("S1", "Shutdown")
  local developer27, contents27 = fake_xcode_app({ devicehub = true })
  h.with_env(fake.env({ FAKE_DEVELOPER_DIR = developer27, FAKE_OPEN_APPS = "com.apple.iphonesimulator" }), function()
    eq(
      act(function(cb)
        ios.boot(simulator("S1"), nil, cb)
      end),
      nil
    )
    eq(calls_of(fake, "-a"), {
      { "-a", contents27 .. "/Applications/DeviceHub.app", "devices://device/open?id=S1" },
    })
    eq(#calls_of(fake, "-b"), 0)
  end)
end

T["boot: no Xcode selected falls back to any installed simulator app"] = function()
  local fake = new_fake()
  fake.set_state("S1", "Shutdown")
  h.with_env(fake.env({ FAKE_OPEN_APPS = "com.apple.dt.Devices" }), function()
    eq(
      act(function(cb)
        ios.boot(simulator("S1"), nil, cb)
      end),
      nil
    )
    eq(#calls_of(fake, "-a"), 0)
    eq(calls_of(fake, "-b")[2], { "-b", "com.apple.dt.Devices", "devices://device/open?id=S1" })
  end)
end

T["runtimes: older simctl without supported device types offers every iPhone and iPad"] = function()
  local fake = new_fake()
  local dir = h.tree({
    ["runtimes.json"] = vim.json.encode({
      runtimes = {
        { identifier = "com.apple.CoreSimulator.SimRuntime.iOS-12-1", name = "iOS 12.1", version = "12.1" },
      },
    }),
    ["devicetypes.json"] = vim.json.encode({
      devicetypes = {
        { identifier = "t.watch", name = "Apple Watch Series 4 - 44mm" },
        { identifier = "t.pad", name = "iPad Air (3rd generation)" },
        { identifier = "t.phone", name = "iPhone XS" },
      },
    }),
  })
  h.with_env(
    fake.env({ FAKE_RUNTIMES_JSON = dir .. "/runtimes.json", FAKE_DEVICETYPES_JSON = dir .. "/devicetypes.json" }),
    function()
      local runtimes = h.await(function(cb)
        ios.runtimes(function(list, e)
          cb({ list = list, e = e })
        end)
      end)
      eq(runtimes.e, nil)
      eq(runtimes.list[1].device_types, {
        { id = "t.phone", name = "iPhone XS" },
        { id = "t.pad", name = "iPad Air (3rd generation)" },
      })
    end
  )
end

T["boot: an odd id cannot add to the DeviceHub URL"] = function()
  local fake = new_fake()
  local odd = "A B&id=other#x"
  fake.set_state(odd, "Shutdown")
  h.with_env(fake.env({ FAKE_OPEN_APPS = "com.apple.dt.Devices" }), function()
    act(function(cb)
      ios.boot(simulator(odd), nil, cb)
    end)
    local opens = calls_of(fake, "-b")
    eq(opens[#opens][3], "devices://device/open?id=A%20B%26id%3Dother%23x")
  end)
end

T["boot: refuses anything that is not an iOS simulator, and runs nothing"] = function()
  local fake = new_fake()
  h.with_env(fake.env(), function()
    local phone = Device.new({
      id = "P1",
      name = "My Phone",
      platform = "ios",
      kind = "physical",
      state = "connected",
      source = "devicectl",
    })
    local emulator = Device.new({
      id = "Pixel",
      name = "Pixel",
      platform = "android",
      kind = "emulator",
      state = "shutdown",
      source = "emulator",
    })
    for _, device in ipairs({ phone, emulator }) do
      local e = act(function(cb)
        ios.boot(device, nil, cb)
      end)
      eq(e.code, "unsupported")
    end
    eq(fake.calls(), {})
  end)
end

T["boot: without Xcode it is a tool_missing error"] = function()
  h.with_env(h.isolated(), function()
    local e = act(function(cb)
      ios.boot(simulator("S1"), nil, cb)
    end)
    eq(e.code, "tool_missing")
    eq(e.guide, "ios")
  end)
end

-- shutdown ----------------------------------------------------------------------------------

T["shutdown: shuts down a booted simulator"] = function()
  local fake = new_fake()
  fake.set_state("S1", "Booted")
  h.with_env(fake.env(), function()
    eq(
      act(function(cb)
        ios.shutdown(simulator("S1"), cb)
      end),
      nil
    )
    eq(fake.get_state("S1"), "Shutdown")
  end)
end

T["shutdown: a simulator that is already off is a success"] = function()
  local fake = new_fake()
  fake.set_state("S1", "Shutdown")
  h.with_env(fake.env(), function()
    eq(
      act(function(cb)
        ios.shutdown(simulator("S1"), cb)
      end),
      nil
    )
  end)
end

T["shutdown: a simulator that is shutting down is a success"] = function()
  local fake = new_fake()
  fake.set_state("S1", "Shutting Down")
  h.with_env(fake.env(), function()
    eq(
      act(function(cb)
        ios.shutdown(simulator("S1"), cb)
      end),
      nil
    )
  end)
end

T["shutdown: an unknown simulator is not_found"] = function()
  local fake = new_fake()
  h.with_env(fake.env(), function()
    eq(
      act(function(cb)
        ios.shutdown(simulator("NO-SUCH"), cb)
      end).code,
      "not_found"
    )
  end)
end

T["shutdown: refuses a physical device"] = function()
  local fake = new_fake()
  h.with_env(fake.env(), function()
    local phone = Device.new({
      id = "P1",
      name = "My Phone",
      platform = "ios",
      kind = "physical",
      state = "connected",
      source = "devicectl",
    })
    eq(
      act(function(cb)
        ios.shutdown(phone, cb)
      end).code,
      "unsupported"
    )
    eq(fake.calls(), {})
  end)
end

-- erase -------------------------------------------------------------------------------------

T["erase: erases a shut down simulator"] = function()
  local fake = new_fake()
  fake.set_state("S1", "Shutdown")
  h.with_env(fake.env(), function()
    eq(
      act(function(cb)
        ios.erase(simulator("S1"), cb)
      end),
      nil
    )
    eq(fake.calls(), { { "simctl", "erase", "S1" } })
  end)
end

T["erase: a booted simulator is invalid_state with advice"] = function()
  local fake = new_fake()
  fake.set_state("S1", "Booted")
  h.with_env(fake.env(), function()
    local e = act(function(cb)
      ios.erase(simulator("S1"), cb)
    end)
    eq(e.code, "invalid_state")
    eq(e.message, "Cannot erase: the simulator is booted")
    eq(e.hint, "Shut it down first.")
  end)
end

T["erase: a booting simulator is described in lower case"] = function()
  local fake = new_fake()
  fake.set_state("S1", "Booting")
  h.with_env(fake.env(), function()
    local e = act(function(cb)
      ios.erase(simulator("S1"), cb)
    end)
    eq(e.message, "Cannot erase: the simulator is booting")
  end)
end

T["erase: an unknown simulator is not_found"] = function()
  local fake = new_fake()
  h.with_env(fake.env(), function()
    eq(
      act(function(cb)
        ios.erase(simulator("NO-SUCH"), cb)
      end).code,
      "not_found"
    )
  end)
end

return T
