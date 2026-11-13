--- Fake but realistic tool output. The structures mirror what simctl and devicectl print (including
--- the Xcode 27 `devicectl` layout change), but every name and id here is made up.
local M = {}

local RUNTIME = "com.apple.CoreSimulator.SimRuntime."

local function sim(udid, name, state, extra)
  return vim.tbl_extend("force", {
    udid = udid,
    name = name,
    state = state,
    isAvailable = true,
    deviceTypeIdentifier = "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro",
    dataPath = "/fake/data/" .. udid,
    logPath = "/fake/log/" .. udid,
  }, extra or {})
end

--- Simulator udids used by the fake xcrun.
M.udid = {
  shutdown = "00000000-0000-4000-8000-0000000000A1",
  booted = "00000000-0000-4000-8000-0000000000A2",
}

---@return string json
function M.simctl()
  return vim.json.encode({
    devices = {
      [RUNTIME .. "iOS-18-2"] = {
        sim(M.udid.shutdown, "iPhone 16 Pro", "Shutdown"),
        sim(M.udid.booted, "iPhone 16", "Booted"),
        sim("00000000-0000-4000-8000-0000000000A3", "iPad Pro 13-inch (M4)", "Shutting Down"),
        sim("00000000-0000-4000-8000-0000000000A4", "iPhone 16 Plus", "Booting"),
        sim("00000000-0000-4000-8000-0000000000A5", "Brand New", "Creating"),
      },
      [RUNTIME .. "iOS-17-5"] = {
        sim("00000000-0000-4000-8000-0000000000B1", "iPhone 15", "Shutdown"),
      },
      -- A special runtime build has extra text after the version.
      [RUNTIME .. "iOS-18-2-iPhone17-4"] = {
        sim("00000000-0000-4000-8000-0000000000C1", "iPhone 17", "Shutdown"),
      },
      -- A runtime that is no longer installed. simctl still lists its devices.
      [RUNTIME .. "iOS-18-0"] = {
        sim("00000000-0000-4000-8000-0000000000D1", "Orphan", "Shutdown", {
          isAvailable = false,
          availabilityError = "runtime profile not found using \u{201c}System\u{201d} match policy",
        }),
      },
      -- Older simctl has no isAvailable, only an availability string.
      [RUNTIME .. "iOS-16-4"] = {
        {
          udid = "00000000-0000-4000-8000-0000000000E1",
          name = "Old Style Available",
          state = "Shutdown",
          availability = "(available)",
        },
        {
          udid = "00000000-0000-4000-8000-0000000000E2",
          name = "Old Style Unavailable",
          state = "Shutdown",
          availability = "(unavailable, runtime profile not found)",
        },
        -- Damaged entries are skipped, not fatal.
        { name = "No udid", state = "Shutdown", isAvailable = true },
        { udid = "00000000-0000-4000-8000-0000000000E3", state = "Shutdown", isAvailable = true },
      },
      [RUNTIME .. "watchOS-11-2"] = { sim("00000000-0000-4000-8000-0000000000F1", "Apple Watch", "Shutdown") },
      [RUNTIME .. "tvOS-18-2"] = { sim("00000000-0000-4000-8000-0000000000F2", "Apple TV", "Shutdown") },
      [RUNTIME .. "xrOS-2-2"] = { sim("00000000-0000-4000-8000-0000000000F3", "Apple Vision Pro", "Shutdown") },
    },
  })
end

--- "18.2" as Xcode 27 reports it: { components = { 18, 2, 0, 0, 0 }, stringValue = "18.2", ... }.
---@param version string
---@return table
local function version_object(version)
  local components = {}
  for n in version:gmatch("%d+") do
    components[#components + 1] = tonumber(n)
  end
  local count = #components
  while #components < 5 do
    components[#components + 1] = 0
  end
  return { components = components, originalComponentsCount = count, stringValue = version }
end

--- One entry of `devicectl list devices`, in the Xcode 27 layout (`properties`), the older layout
--- (`hardwareProperties`, ...), or both, which is what Xcode 27 prints.
---@param o table
---@param layout "new"|"old"|"both"
local function ctl_device(o, layout)
  local entry = { identifier = "CORE-" .. o.udid }
  if layout == "new" or layout == "both" then
    entry.properties = {
      hardware = {
        udid = o.udid,
        platform = o.platform or "iOS",
        deviceType = o.device_type or "iPhone",
        reality = o.reality or "physical",
        marketingName = "Marketing Name",
      },
      -- Xcode 27 reports a version object, not a string.
      software = { osVersionNumber = version_object(o.os or "18.2") },
      state = { name = o.name, developerModeStatus = o.developer_mode or "enabled" },
      connection = {
        pairingState = o.pairing or "paired",
        state = o.link or "disconnected",
        transportType = o.transport,
      },
    }
  end
  if layout == "old" or layout == "both" then
    entry.hardwareProperties = {
      udid = o.udid,
      platform = o.platform or "iOS",
      deviceType = o.device_type or "iPhone",
      reality = o.reality or "physical",
      marketingName = "Marketing Name",
    }
    entry.deviceProperties = {
      name = o.name,
      osVersionNumber = o.os or "18.2",
      developerModeStatus = o.developer_mode or "enabled",
    }
    entry.connectionProperties = {
      pairingState = o.pairing or "paired",
      tunnelState = o.link or "disconnected",
      transportType = o.transport,
    }
  end
  return entry
end

--- Physical device udids, by what they are.
M.phys = {
  usb = "00008101-0000000000000001",
  wifi = "00008101-0000000000000002",
  offline = "00008101-0000000000000003",
  untrusted = "00008101-0000000000000004",
  no_dev_mode = "00008101-0000000000000005",
}

---@param layout? "new"|"old"|"both"
---@return string json
function M.devicectl(layout)
  layout = layout or "new"
  local p = M.phys
  local devices = {
    ctl_device({ udid = p.usb, name = "Test iPhone", link = "connected", transport = "wired" }, layout),
    ctl_device({
      udid = p.wifi,
      name = "Test iPad",
      device_type = "iPad",
      os = "17.6",
      link = "disconnected",
      transport = "localNetwork",
    }, layout),
    -- Paired once, not reachable now: no transport, link unavailable.
    ctl_device({ udid = p.offline, name = "Offline iPhone", link = "unavailable" }, layout),
    ctl_device({ udid = p.untrusted, name = "Untrusted iPhone", pairing = "unpaired", transport = "wired" }, layout),
    ctl_device({
      udid = p.no_dev_mode,
      name = "No Dev Mode iPhone",
      developer_mode = "disabled",
      transport = "wired",
    }, layout),
    -- devicectl also lists simulators, other platforms and damaged entries. None of them count.
    ctl_device({ udid = "SIMULATED-1", name = "A Simulator", reality = "simulated", transport = "wired" }, layout),
    ctl_device({
      udid = "WATCH-1",
      name = "A Watch",
      platform = "watchOS",
      device_type = "appleWatch",
      transport = "wired",
    }, layout),
    { identifier = "NO-UDID", properties = { state = { name = "No udid" } } },
  }
  return vim.json.encode({
    info = { jsonVersion = 5, outcome = "success", commandType = "devicectl.list.devices" },
    result = { devices = devices },
  })
end

return M
