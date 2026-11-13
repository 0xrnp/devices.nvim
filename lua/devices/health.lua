--- :checkhealth devices
local M = {}

local GUIDES = {
  ios = {
    "Install Xcode from the App Store, open it once, and let it install its components.",
    "Select it: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer",
    "Accept the license: sudo xcodebuild -license accept",
    "Simulators need an iOS runtime: Xcode > Settings > Components, or xcodebuild -downloadPlatform iOS",
    "Physical iPhones: connect by cable once, trust this computer, and turn on Developer Mode.",
  },
  android = {
    "Install Android Studio (it brings the SDK, the emulator and a JDK), or the command-line tools.",
    "Set ANDROID_HOME to the SDK (or set android.sdk in setup()) if it is not in the usual place.",
    'Install pieces with sdkmanager: "platform-tools" "emulator" "cmdline-tools;latest", and a system image.',
    "Create an emulator with :Devices create, or in Android Studio's Device Manager.",
    "Physical phones: turn on Developer options and USB debugging, then accept the prompt on the phone.",
    "Linux: add udev rules for your phone (the android-udev-rules package) to use it over USB.",
  },
}

---@param problem devices.Problem
local function report(problem)
  local h = vim.health
  local advice = problem.hint and { problem.hint } or {}
  if problem.severity == "error" then
    h.error(problem.message, advice)
  elseif problem.severity == "warning" then
    h.warn(problem.message, advice)
  else
    h.info(problem.message .. (problem.hint and (" " .. problem.hint) or ""))
  end
end

function M.check()
  local h = vim.health
  local env = require("devices.env")
  local config = require("devices.config")

  h.start("devices.nvim")
  if vim.fn.has("nvim-0.10") == 0 then
    h.error("Neovim 0.10 or newer is needed")
    return
  end
  h.ok(("Neovim %s on %s (%s)"):format(tostring(vim.version()), env.os(), env.arch()))

  local result
  env.detect(config.android(), function(r)
    result = r
  end)
  if not vim.wait(60000, function()
    return result ~= nil
  end, 50) then
    h.error("Checking the tools took longer than a minute")
    return
  end

  h.start("devices.nvim: iOS")
  local ios_env = result.ios
  if not ios_env.supported then
    h.info("iOS simulators and devices need macOS")
  else
    if ios_env.developer_dir then
      h.ok("Xcode: " .. (ios_env.xcode_version or ios_env.developer_dir))
    end
    if ios_env.simctl then
      h.ok("Simulators: simctl found")
    end
    if ios_env.devicectl then
      h.ok("Physical devices: devicectl found")
    end
    for _, problem in ipairs(ios_env.problems) do
      report(problem)
    end
    if vim.fn.executable("idevicesyslog") == 1 then
      h.ok("idevicesyslog found: live system logs from physical iPhones")
    else
      h.info(
        "idevicesyslog is not installed. Optional: it shows a physical iPhone's system log live "
          .. "(brew install libimobiledevice). Your own app's output works without it."
      )
    end
    if not ios_env.simctl then
      h.info("Setup:\n- " .. table.concat(GUIDES.ios, "\n- "))
    end
  end

  h.start("devices.nvim: Android")
  local a = result.android
  if a.sdk then
    h.ok("SDK: " .. a.sdk)
  end
  for _, name in ipairs({ "adb", "emulator", "avdmanager", "sdkmanager" }) do
    local tool = a.tools[name]
    if tool then
      h.ok(("%s: %s%s"):format(name, tool.path, tool.via == "path" and " (from PATH)" or ""))
    end
  end
  if a.java then
    h.ok(("Java %s: %s"):format(a.java.version, a.java.path))
  end
  for _, problem in ipairs(a.problems) do
    report(problem)
  end
  if not a.tools.emulator and not a.tools.adb then
    h.info("Setup:\n- " .. table.concat(GUIDES.android, "\n- "))
  end
end

return M
