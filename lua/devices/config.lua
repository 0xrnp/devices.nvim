local M = {}

---@class devices.Action
---@field name string Shown in the device's action menu.
---@field run fun(device: devices.Device)
---@field when? fun(device: devices.Device): boolean Only offer it when this returns true.

---@class devices.Config
---@field android devices.AndroidConfig
---@field ios devices.IosConfig
---@field logs devices.LogsConfig
---@field on_boot? fun(device: devices.Device) Called once a device you booted has finished booting.
---@field actions devices.Action[] Your own entries for the action menu, such as "flutter run".

---@class devices.AndroidConfig
---@field sdk? string SDK location. Default: ANDROID_HOME, ANDROID_SDK_ROOT, PATH, usual places.
---@field java_home? string JDK for avdmanager. Default: JAVA_HOME, PATH, Android Studio's JDK.
---@field avd_home? string Where AVDs live. Default: the emulator's own lookup.
---@field emulator_args string[] Extra arguments for every emulator start, such as { "-gpu", "host" }.
---@field headless boolean Start emulators without a window.

---@class devices.IosConfig
---@field open_simulator_app boolean Bring up Simulator.app (DeviceHub in Xcode 27) when a simulator boots.

---@class devices.LogsConfig
---@field tail integer Android: earlier lines to show when a log opens.
---@field max_lines integer Lines kept in a log buffer. Older ones are dropped.
---@field open "split"|"vsplit"|"tab"|"current" Where a log buffer opens.

---@type devices.Config
M.defaults = {
  android = {
    sdk = nil,
    java_home = nil,
    avd_home = nil,
    emulator_args = {},
    headless = false,
  },
  ios = {
    open_simulator_app = true,
  },
  logs = {
    tail = 1000,
    max_lines = 20000,
    open = "split",
  },
  on_boot = nil,
  actions = {},
}

---@type devices.Config
M.options = vim.deepcopy(M.defaults)

---@param value any
---@param name string
---@param kind string
---@param optional? boolean
local function check(value, name, kind, optional)
  if value == nil and optional then
    return
  end
  if type(value) ~= kind then
    error(("devices.nvim: %s must be a %s, got %s"):format(name, kind, type(value)), 3)
  end
end

---@param opts? table
function M.setup(opts)
  opts = opts or {}
  check(opts, "setup()", "table")
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  -- Lists replace the defaults instead of merging by index.
  merged.android.emulator_args = (opts.android or {}).emulator_args or {}
  merged.actions = opts.actions or {}

  check(merged.android, "android", "table")
  check(merged.android.sdk, "android.sdk", "string", true)
  check(merged.android.java_home, "android.java_home", "string", true)
  check(merged.android.avd_home, "android.avd_home", "string", true)
  check(merged.android.emulator_args, "android.emulator_args", "table")
  check(merged.android.headless, "android.headless", "boolean")
  check(merged.ios, "ios", "table")
  check(merged.ios.open_simulator_app, "ios.open_simulator_app", "boolean")
  check(merged.logs, "logs", "table")
  check(merged.logs.tail, "logs.tail", "number")
  check(merged.logs.max_lines, "logs.max_lines", "number")
  if not vim.tbl_contains({ "split", "vsplit", "tab", "current" }, merged.logs.open) then
    error("devices.nvim: logs.open must be one of split, vsplit, tab, current", 2)
  end
  check(merged.on_boot, "on_boot", "function", true)
  check(merged.actions, "actions", "table")
  for i, action in ipairs(merged.actions) do
    check(action, ("actions[%d]"):format(i), "table")
    check(action.name, ("actions[%d].name"):format(i), "string")
    check(action.run, ("actions[%d].run"):format(i), "function")
    check(action.when, ("actions[%d].when"):format(i), "function", true)
  end
  M.options = merged
end

--- Options for the Android backend and environment checks.
---@return devices.AndroidOptions
function M.android()
  local a = M.options.android
  return { android_sdk = a.sdk, java_home = a.java_home, avd_home = a.avd_home }
end

return M
