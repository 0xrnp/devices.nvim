--- The one shape every backend (simctl, devicectl, emulator, adb) reports devices in.
local M = {}

M.platforms = { ios = true, android = true }
M.kinds = { simulator = true, emulator = true, physical = true }

--- Virtual devices are "booted" or "shutdown". Physical devices are "connected" or
--- "disconnected". "offline" and "unauthorized" are adb states for a device that is attached
--- but not usable. "unknown" is for anything a tool reports that we do not recognise.
M.states = {
  booted = true,
  booting = true,
  shutdown = true,
  shutting_down = true,
  connected = true,
  disconnected = true,
  offline = true,
  unauthorized = true,
  unknown = true,
}

---@alias devices.Platform "ios"|"android"
---@alias devices.Kind "simulator"|"emulator"|"physical"
---@alias devices.State "booted"|"booting"|"shutdown"|"shutting_down"|"connected"|"disconnected"|"offline"|"unauthorized"|"unknown"

---@class devices.Device
---@field id string The identifier the platform tool uses: UDID, AVD name, or adb serial.
---@field name string
---@field platform devices.Platform
---@field kind devices.Kind
---@field state devices.State
---@field os_version string?
---@field model string?
---@field transport "usb"|"wifi"|"local"? How a physical device is reached.
---@field serial string? The adb serial of a running emulator, which links an AVD to its instance.
---@field source string Which tool reported it: "simctl", "devicectl", "emulator" or "adb".
---@field detail string? Something the user should know, such as "Developer Mode is off".

--- Build a device. Backends call this with values they have already parsed, so an invalid
--- field is a bug in the backend and raises.
---@param fields table
---@return devices.Device
function M.new(fields)
  assert(type(fields.id) == "string" and fields.id ~= "", "device.id must be a non-empty string")
  assert(type(fields.name) == "string" and fields.name ~= "", "device.name must be a non-empty string")
  assert(M.platforms[fields.platform], "device.platform is invalid: " .. tostring(fields.platform))
  assert(M.kinds[fields.kind], "device.kind is invalid: " .. tostring(fields.kind))
  assert(type(fields.source) == "string" and fields.source ~= "", "device.source must be a non-empty string")
  local state = fields.state or "unknown"
  assert(M.states[state], "device.state is invalid: " .. tostring(state))
  for _, field in ipairs({ "os_version", "model", "serial", "detail" }) do
    local value = fields[field]
    assert(value == nil or type(value) == "string", ("device.%s must be a string or nil"):format(field))
  end
  return vim.tbl_extend("force", fields, { state = state })
end

--- A unique key across platforms and kinds.
---@param device devices.Device
---@return string
function M.key(device)
  return device.platform .. ":" .. device.kind .. ":" .. device.id
end

--- Whether the device can be run on right now.
---@param device devices.Device
---@return boolean
function M.is_ready(device)
  return device.state == "booted" or device.state == "connected"
end

--- Ready devices first, then physical before virtual, then iOS before Android, then by name.
---@param list devices.Device[]
---@return devices.Device[]
function M.sort(list)
  local sorted = vim.list_slice(list)
  table.sort(sorted, function(a, b)
    local ready_a, ready_b = M.is_ready(a), M.is_ready(b)
    if ready_a ~= ready_b then
      return ready_a
    end
    local physical_a, physical_b = a.kind == "physical", b.kind == "physical"
    if physical_a ~= physical_b then
      return physical_a
    end
    if a.platform ~= b.platform then
      return a.platform == "ios"
    end
    local name_a, name_b = a.name:lower(), b.name:lower()
    if name_a ~= name_b then
      return name_a < name_b
    end
    return a.id < b.id
  end)
  return sorted
end

--- Drop duplicates, which happen when two tools report the same device. The first one wins,
--- and fields it lacks are filled in from the later ones.
---@param list devices.Device[]
---@return devices.Device[]
function M.dedupe(list)
  local by_key, result = {}, {}
  for _, device in ipairs(list) do
    local key = M.key(device)
    local existing = by_key[key]
    if existing then
      for field, value in pairs(device) do
        if existing[field] == nil then
          existing[field] = value
        end
      end
    else
      local copy = vim.deepcopy(device)
      by_key[key] = copy
      result[#result + 1] = copy
    end
  end
  return result
end

---@param device devices.Device
---@return string
function M.label(device)
  local parts = { device.name }
  if device.os_version then
    parts[#parts + 1] = (device.platform == "ios" and "iOS " or "Android ") .. device.os_version
  end
  parts[#parts + 1] = device.kind
  if device.transport and device.transport ~= "local" then
    parts[#parts + 1] = device.transport
  end
  parts[#parts + 1] = (device.state:gsub("_", " "))
  return table.concat(parts, "  ·  ")
end

return M
