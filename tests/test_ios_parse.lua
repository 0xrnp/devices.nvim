local h = require("helpers")
local eq = h.eq

local fixtures = require("fixtures.ios")
local ios = require("devices.backend.ios")

--- Reduce devices to what a test cares about.
local function brief(devices, fields)
  return vim.tbl_map(function(d)
    local row = {}
    for _, field in ipairs(fields) do
      row[#row + 1] = d[field] or false
    end
    return row
  end, devices)
end

local T = {}

-- simctl ------------------------------------------------------------------------------------

T["simctl: reads iOS simulators, in runtime then listed order"] = function()
  local devices, e = ios.parse_simctl(fixtures.simctl())
  eq(e, nil)
  eq(brief(devices, { "name", "os_version", "state" }), {
    { "Old Style Available", "16.4", "shutdown" },
    { "iPhone 15", "17.5", "shutdown" },
    { "iPhone 16 Pro", "18.2", "shutdown" },
    { "iPhone 16", "18.2", "booted" },
    { "iPad Pro 13-inch (M4)", "18.2", "shutting_down" },
    { "iPhone 16 Plus", "18.2", "booting" },
    { "Brand New", "18.2", "unknown" },
    { "iPhone 17", "18.2", "shutdown" },
  })
end

T["simctl: every device has the fixed fields"] = function()
  local devices = ios.parse_simctl(fixtures.simctl())
  for _, d in ipairs(devices) do
    eq(d.platform, "ios")
    eq(d.kind, "simulator")
    eq(d.source, "simctl")
    eq(d.transport, "local")
  end
  eq(devices[3].id, fixtures.udid.shutdown)
end

T["simctl: skips unavailable runtimes, other platforms and damaged entries"] = function()
  local names = vim.tbl_map(function(d)
    return d.name
  end, ios.parse_simctl(fixtures.simctl()))
  for _, excluded in ipairs({
    "Orphan",
    "Old Style Unavailable",
    "No udid",
    "Apple Watch",
    "Apple TV",
    "Apple Vision Pro",
  }) do
    eq(vim.tbl_contains(names, excluded), false)
  end
end

T["simctl: an empty list is not an error"] = function()
  local devices, e = ios.parse_simctl('{"devices":{}}')
  eq(devices, {})
  eq(e, nil)
end

T["simctl: before Xcode 10.1, runtimes were keyed by name"] = function()
  local devices, e = ios.parse_simctl(vim.json.encode({
    devices = {
      ["iOS 12.1"] = {
        { udid = "OLD-1", name = "iPhone XS", state = "Shutdown", availability = "(available)" },
        { udid = "OLD-2", name = "iPhone 6", state = "Shutdown", availability = "(unavailable, runtime missing)" },
      },
      ["watchOS 5.1"] = { { udid = "W-1", name = "Watch", state = "Shutdown", availability = "(available)" } },
    },
  }))
  eq(e, nil)
  eq(brief(devices, { "id", "os_version" }), { { "OLD-1", "12.1" } })
end

-- runtimes ----------------------------------------------------------------------------------

T["runtimes: available iOS ones, newest first, iPhones before iPads"] = function()
  local runtimes = ios.parse_runtimes(vim.json.encode({
    runtimes = {
      {
        identifier = "com.apple.CoreSimulator.SimRuntime.iOS-17-5",
        name = "iOS 17.5",
        version = "17.5",
        platform = "iOS",
        isAvailable = true,
        supportedDeviceTypes = {
          { identifier = "pad", name = "iPad Air", productFamily = "iPad" },
          { identifier = "phone", name = "iPhone 15", productFamily = "iPhone" },
          { identifier = "watch", name = "Apple Watch", productFamily = "Apple Watch" },
        },
      },
      {
        identifier = "com.apple.CoreSimulator.SimRuntime.iOS-18-2",
        name = "iOS 18.2",
        version = "18.2",
        platform = "iOS",
        isAvailable = true,
      },
      {
        identifier = "com.apple.CoreSimulator.SimRuntime.tvOS-18-2",
        name = "tvOS 18.2",
        version = "18.2",
        platform = "tvOS",
        isAvailable = true,
      },
      {
        identifier = "com.apple.CoreSimulator.SimRuntime.iOS-16-4",
        name = "iOS 16.4",
        version = "16.4",
        platform = "iOS",
        isAvailable = false,
      },
    },
  }))
  eq(
    vim.tbl_map(function(r)
      return r.name
    end, runtimes),
    { "iOS 18.2", "iOS 17.5" }
  )
  eq(runtimes[2].device_types, { { id = "phone", name = "iPhone 15" }, { id = "pad", name = "iPad Air" } })
  eq(runtimes[1].device_types, {})
end

T["runtimes: older simctl, with no platform field and the old availability text"] = function()
  local runtimes = ios.parse_runtimes(vim.json.encode({
    runtimes = {
      {
        identifier = "com.apple.CoreSimulator.SimRuntime.iOS-12-1",
        name = "iOS 12.1",
        version = "12.1",
        availability = "(available)",
      },
      {
        identifier = "com.apple.CoreSimulator.SimRuntime.watchOS-5-1",
        name = "watchOS 5.1",
        version = "5.1",
        availability = "(available)",
      },
    },
  }))
  eq(#runtimes, 1)
  eq(runtimes[1].id, "com.apple.CoreSimulator.SimRuntime.iOS-12-1")
end

T["simctl: unreadable output is a parse error, never a throw"] = function()
  for _, bad in ipairs({ "", "not json", "[]", "{}", '{"devices": 5}', '{"devices": null}', "null", "{" }) do
    local devices, e = ios.parse_simctl(bad)
    eq(devices, nil)
    eq(e.code, "parse_failed")
  end
end

-- devicectl ---------------------------------------------------------------------------------

T["devicectl: reads physical iPhones and iPads"] = function()
  local devices, e = ios.parse_devicectl(fixtures.devicectl("new"))
  eq(e, nil)
  eq(brief(devices, { "name", "os_version", "state", "transport" }), {
    { "Test iPhone", "18.2", "connected", "usb" },
    { "Test iPad", "17.6", "connected", "wifi" },
    { "Offline iPhone", "18.2", "disconnected", false },
    { "Untrusted iPhone", "18.2", "unauthorized", "usb" },
    { "No Dev Mode iPhone", "18.2", "connected", "usb" },
  })
  eq(devices[1].id, fixtures.phys.usb)
  eq(devices[1].kind, "physical")
  eq(devices[1].source, "devicectl")
end

T["devicectl: warns when Developer Mode is off, only for a reachable device"] = function()
  local devices = ios.parse_devicectl(fixtures.devicectl("new"))
  eq(devices[5].detail ~= nil and devices[5].detail:find("Developer Mode", 1, true) ~= nil, true)
  eq(devices[1].detail, nil)
end

T["devicectl: no Developer Mode note for a device that cannot be reached"] = function()
  local json = vim.json.encode({
    result = {
      devices = {
        {
          properties = {
            hardware = { udid = "U-1", deviceType = "iPhone", reality = "physical" },
            state = { name = "Away", developerModeStatus = "disabled" },
            connection = { state = "unavailable", pairingState = "paired" },
          },
        },
      },
    },
  })
  local devices = ios.parse_devicectl(json)
  eq(devices[1].state, "disconnected")
  eq(devices[1].detail, nil)
end

T["devicectl: the old layout gives the same result as the new one"] = function()
  local new = ios.parse_devicectl(fixtures.devicectl("new"))
  eq(ios.parse_devicectl(fixtures.devicectl("old")), new)
  eq(ios.parse_devicectl(fixtures.devicectl("both")), new)
end

T["devicectl: the new layout wins when both disagree"] = function()
  local json = vim.json.encode({
    result = {
      devices = {
        {
          properties = {
            hardware = { udid = "U-1", deviceType = "iPhone", reality = "physical" },
            state = { name = "New Name" },
            connection = { state = "connected", transportType = "wired", pairingState = "paired" },
          },
          hardwareProperties = { udid = "U-OLD", deviceType = "iPhone", reality = "physical" },
          deviceProperties = { name = "Old Name" },
          connectionProperties = { tunnelState = "unavailable", pairingState = "paired" },
        },
      },
    },
  })
  local devices = ios.parse_devicectl(json)
  eq(devices[1].id, "U-1")
  eq(devices[1].name, "New Name")
  eq(devices[1].state, "connected")
end

T["devicectl: without a link state, a transport means reachable"] = function()
  local function parse(connection)
    return ios.parse_devicectl(vim.json.encode({
      result = {
        devices = {
          {
            hardwareProperties = { udid = "U-1", deviceType = "iPhone", reality = "physical" },
            deviceProperties = { name = "Phone" },
            connectionProperties = connection,
          },
        },
      },
    }))
  end
  eq(parse({ transportType = "wired", pairingState = "paired" })[1].state, "connected")
  eq(parse({ pairingState = "paired" })[1].state, "disconnected")
end

T["devicectl: unreadable output is a parse error, never a throw"] = function()
  for _, bad in ipairs({ "", "nope", "[]", "{}", '{"result": 3}', '{"result": {}}', '{"result": {"devices": "x"}}' }) do
    local devices, e = ios.parse_devicectl(bad)
    eq(devices, nil)
    eq(e.code, "parse_failed")
  end
end

T["devicectl: no devices is not an error"] = function()
  local devices, e = ios.parse_devicectl('{"result":{"devices":[]}}')
  eq(devices, {})
  eq(e, nil)
end

return T
