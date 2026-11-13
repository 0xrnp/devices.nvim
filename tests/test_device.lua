local h = require("helpers")
local eq = h.eq

local Device = require("devices.device")

local function make(fields)
  return Device.new(vim.tbl_extend("force", {
    id = "id-1",
    name = "Phone",
    platform = "ios",
    kind = "simulator",
    state = "shutdown",
    source = "simctl",
  }, fields or {}))
end

local T = {}

T["new: defaults the state to unknown"] = function()
  local d = Device.new({ id = "x", name = "X", platform = "android", kind = "emulator", source = "emulator" })
  eq(d.state, "unknown")
end

T["new: rejects invalid fields"] = function()
  for _, bad in ipairs({
    { id = "" },
    { name = "" },
    { platform = "windows" },
    { kind = "watch" },
    { state = "sleeping" },
    { source = "" },
  }) do
    h.expect_error(function()
      make(bad)
    end)
  end
end

T["key: is unique across platform, kind and id"] = function()
  eq(Device.key(make({ id = "A" })), "ios:simulator:A")
  eq(Device.key(make({ id = "A", platform = "android", kind = "emulator" })), "android:emulator:A")
end

T["is_ready: booted and connected only"] = function()
  eq(Device.is_ready(make({ state = "booted" })), true)
  eq(Device.is_ready(make({ state = "connected", kind = "physical" })), true)
  for _, state in ipairs({
    "shutdown",
    "booting",
    "shutting_down",
    "disconnected",
    "offline",
    "unauthorized",
    "unknown",
  }) do
    eq(Device.is_ready(make({ state = state })), false)
  end
end

T["sort: ready first, then physical, then iOS, then name"] = function()
  local list = {
    make({ id = "1", name = "zeta", platform = "android", kind = "emulator", state = "shutdown" }),
    make({ id = "2", name = "Beta", state = "shutdown" }),
    make({ id = "3", name = "alpha", state = "shutdown" }),
    make({ id = "4", name = "usb phone", kind = "physical", state = "disconnected" }),
    make({ id = "5", name = "booted sim", state = "booted" }),
    make({ id = "6", name = "live phone", kind = "physical", state = "connected" }),
  }
  local order = vim.tbl_map(function(d)
    return d.id
  end, Device.sort(list))
  -- Ready physical, ready virtual, then not ready: physical first, iOS before Android, by name.
  eq(order, { "6", "5", "4", "3", "2", "1" })
end

T["sort: does not change the input and is stable for equal names"] = function()
  local list = { make({ id = "b", name = "Same" }), make({ id = "a", name = "Same" }) }
  local sorted = Device.sort(list)
  eq(list[1].id, "b")
  eq(sorted[1].id, "a")
end

T["dedupe: first wins and gaps are filled from later duplicates"] = function()
  local from_simctl = make({ id = "U1", name = "iPhone", os_version = nil })
  local from_devicectl = make({ id = "U1", name = "ignored", os_version = "27.2", source = "devicectl" })
  local other = make({ id = "U2", name = "Other" })
  local result = Device.dedupe({ from_simctl, from_devicectl, other })
  eq(#result, 2)
  eq(result[1].name, "iPhone")
  eq(result[1].os_version, "27.2")
  eq(result[1].source, "simctl")
  eq(result[2].id, "U2")
  -- The inputs are untouched.
  eq(from_simctl.os_version, nil)
end

T["label: reads well for each kind"] = function()
  eq(
    Device.label(make({ name = "iPhone 16", os_version = "18.2", state = "booted" })),
    "iPhone 16  ·  iOS 18.2  ·  simulator  ·  booted"
  )
  eq(
    Device.label(make({ name = "Pixel", platform = "android", kind = "emulator", state = "shutting_down" })),
    "Pixel  ·  emulator  ·  shutting down"
  )
  eq(
    Device.label(make({ name = "My Phone", kind = "physical", transport = "wifi", state = "connected" })),
    "My Phone  ·  physical  ·  wifi  ·  connected"
  )
  eq(Device.label(make({ name = "Sim", transport = "local", state = "booted" })), "Sim  ·  simulator  ·  booted")
end

return T
