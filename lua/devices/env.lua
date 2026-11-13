--- Finds the tools each platform needs and says what is missing and how to fix it. Nothing
--- here throws. A missing or broken tool becomes a `devices.Problem` in the report.
local async = require("devices.async")
local process = require("devices.process")

local M = {}

local TOOL_TIMEOUT_MS = 10000

---@class devices.EnvOptions
---@field android_sdk? string Android SDK location. Wins over PATH and the environment.
---@field java_home? string JDK for avdmanager and sdkmanager.
---@field os? devices.OS Pretend to run on another OS. For tests.
---@field android_sdk_fallbacks? string[] Where to look when nothing else matched. Default: usual install locations.
---@field java_fallbacks? string[] JDK homes to try after PATH. Default: Android Studio's bundled JDK.

---@alias devices.OS "macos"|"linux"|"windows"|"other"

---@class devices.Problem
---@field code string Stable id, for example "xcode_missing".
---@field platform "ios"|"android"
---@field severity "error"|"warning"|"info" error: set up wrongly. warning: unavailable because not installed. info: optional.
---@field message string
---@field hint string?
---@field guide string? Setup guide topic.

---@return devices.OS
function M.os()
  local sysname = vim.uv.os_uname().sysname
  if sysname == "Darwin" then
    return "macos"
  elseif sysname == "Linux" then
    return "linux"
  elseif sysname:find("Windows", 1, true) then
    return "windows"
  end
  return "other"
end

---@param machine string
---@return string
function M.normalize_arch(machine)
  if machine == "arm64" or machine == "aarch64" then
    return "arm64"
  elseif machine == "x86_64" or machine == "amd64" or machine == "AMD64" then
    return "x86_64"
  end
  return machine
end

---@return string
function M.arch()
  return M.normalize_arch(vim.uv.os_uname().machine)
end

---@param path string
---@return boolean
local function is_dir(path)
  local stat = vim.uv.fs_stat(path)
  return stat ~= nil and stat.type == "directory"
end

---@param paths string[]
---@return string?
local function first_executable(paths)
  for _, path in ipairs(paths) do
    if vim.fn.executable(path) == 1 then
      return path
    end
  end
end

-- Android SDK ---------------------------------------------------------------------------------

---@param opts devices.EnvOptions
---@param os devices.OS
---@return { path: string, source: string }[]
local function sdk_candidates(opts, os)
  local list, seen = {}, {}
  local function add(path, source)
    if not path or path == "" then
      return
    end
    path = vim.fs.normalize(path)
    if not seen[path] then
      seen[path] = true
      list[#list + 1] = { path = path, source = source }
    end
  end

  add(opts.android_sdk, "config")
  add(vim.env.ANDROID_HOME, "ANDROID_HOME")
  add(vim.env.ANDROID_SDK_ROOT, "ANDROID_SDK_ROOT")

  if opts.android_sdk_fallbacks then
    for _, path in ipairs(opts.android_sdk_fallbacks) do
      add(path, "default")
    end
  else
    local home = vim.uv.os_homedir() or ""
    if os == "macos" then
      add(home .. "/Library/Android/sdk", "default")
      add("/opt/homebrew/share/android-commandlinetools", "default")
      add("/usr/local/share/android-commandlinetools", "default")
    elseif os == "linux" then
      add(home .. "/Android/Sdk", "default")
      add("/usr/lib/android-sdk", "default")
    end
  end
  return list
end

--- Newer command-line tools directories sort first. `latest` is the newest.
---@param dir string
---@return number
local function cmdline_rank(dir)
  local name = vim.fs.basename(dir)
  if name == "latest" then
    return math.huge
  end
  local major, minor = name:match("^(%d+)%.?(%d*)")
  return (tonumber(major) or 0) + (tonumber(minor) or 0) / 1000
end

---@param sdk string
---@param name string
---@return string[]
local function sdk_tool_paths(sdk, name)
  if name == "emulator" then
    return { sdk .. "/emulator/emulator" }
  elseif name == "adb" then
    return { sdk .. "/platform-tools/adb" }
  end
  -- avdmanager and sdkmanager live in the command-line tools, or in the legacy tools/ folder.
  local dirs = vim.fn.glob(sdk .. "/cmdline-tools/*", false, true)
  table.sort(dirs, function(a, b)
    return cmdline_rank(a) > cmdline_rank(b)
  end)
  local paths = {}
  for _, dir in ipairs(dirs) do
    paths[#paths + 1] = dir .. "/bin/" .. name
  end
  paths[#paths + 1] = sdk .. "/tools/bin/" .. name
  return paths
end

--- The first existing SDK directory, and every location that was considered.
---@param opts? devices.EnvOptions
---@return string? sdk
---@return { path: string, source: string }[] candidates
function M.android_sdk(opts)
  opts = opts or {}
  local candidates = sdk_candidates(opts, opts.os or M.os())
  for _, candidate in ipairs(candidates) do
    if is_dir(candidate.path) then
      return candidate.path, candidates
    end
  end
  return nil, candidates
end

--- Find an Android tool: "emulator", "adb", "avdmanager" or "sdkmanager". An SDK given in the
--- options wins, then PATH, then the SDK from the environment and the usual locations.
---@param name string
---@param opts? devices.EnvOptions
---@return { path: string, via: "sdk"|"path" }?
function M.find_android_tool(name, opts)
  opts = opts or {}
  local sdks = vim.tbl_filter(function(candidate)
    return is_dir(candidate.path)
  end, sdk_candidates(opts, opts.os or M.os()))

  local function from_sdks(wanted)
    for _, sdk in ipairs(sdks) do
      if wanted(sdk) then
        local path = first_executable(sdk_tool_paths(sdk.path, name))
        if path then
          return { path = path, via = "sdk" }
        end
      end
    end
  end

  local configured = from_sdks(function(sdk)
    return sdk.source == "config"
  end)
  if configured then
    return configured
  end

  local on_path = vim.fn.exepath(name)
  if on_path ~= "" then
    return { path = on_path, via = "path" }
  end

  return from_sdks(function(sdk)
    return sdk.source ~= "config"
  end)
end

-- Java ----------------------------------------------------------------------------------------

---@param output string
---@return string? version
---@return integer? major
local function parse_java_version(output)
  local version = output:match('version "([^"]+)"')
  if not version then
    return nil
  end
  local first, second = version:match("^(%d+)%.?(%d*)")
  local major = tonumber(first)
  -- Java 8 and older report "1.8.0".
  if major == 1 then
    major = tonumber(second)
  end
  return version, major
end

---@param opts devices.EnvOptions
---@param os devices.OS
---@return { java: string, home: string? }[]
local function java_candidates(opts, os)
  local list, seen = {}, {}
  local function add(java, home)
    if java and java ~= "" and not seen[java] then
      seen[java] = true
      list[#list + 1] = { java = java, home = home }
    end
  end
  local function add_home(home)
    if home and home ~= "" then
      add(vim.fs.normalize(home) .. "/bin/java", vim.fs.normalize(home))
    end
  end

  add_home(opts.java_home)
  add_home(vim.env.JAVA_HOME)
  -- A bare `java` on PATH may be a stub (macOS ships one that only prints an error), so it is
  -- verified like every other candidate. Its home stays unset: the tools find it themselves.
  add(vim.fn.exepath("java"), nil)

  if opts.java_fallbacks then
    for _, home in ipairs(opts.java_fallbacks) do
      add_home(home)
    end
  else
    local home = vim.uv.os_homedir() or ""
    if os == "macos" then
      add_home("/Applications/Android Studio.app/Contents/jbr/Contents/Home")
      add_home("/Applications/Android Studio Preview.app/Contents/jbr/Contents/Home")
    elseif os == "linux" then
      add_home(home .. "/android-studio/jbr")
      add_home("/opt/android-studio/jbr")
      add_home("/usr/local/android-studio/jbr")
    end
  end
  return list
end

---@class devices.JavaInfo
---@field path string
---@field home string? Set when it came from a known JDK home, so tools can be pointed at it.
---@field version string
---@field major integer

--- The first working JDK, or nil.
---@param opts devices.EnvOptions
---@param cb fun(java: devices.JavaInfo?)
function M.find_java(opts, cb)
  opts = opts or {}
  local candidates = java_candidates(opts, opts.os or M.os())

  local function try(index)
    local candidate = candidates[index]
    if not candidate then
      return cb(nil)
    end
    process.run({ candidate.java, "-version" }, { timeout = TOOL_TIMEOUT_MS }, function(res)
      -- `java -version` prints to stderr.
      local version, major = parse_java_version(res.stderr .. "\n" .. res.stdout)
      if res.code == 0 and version and major then
        return cb({ path = candidate.java, home = candidate.home, version = version, major = major })
      end
      try(index + 1)
    end)
  end
  try(1)
end

-- Xcode ---------------------------------------------------------------------------------------

---@class devices.IosEnv
---@field supported boolean False when this is not macOS. iOS is then hidden, not reported as broken.
---@field developer_dir string?
---@field xcode_version string?
---@field simctl boolean
---@field devicectl boolean Physical devices. Needs Xcode 15 or newer.
---@field problems devices.Problem[]

local SWITCH_HINT = "sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"

---@param code string
---@param severity "error"|"warning"|"info"
---@param message string
---@param hint? string
---@return devices.Problem
local function ios_problem(code, severity, message, hint)
  return { code = code, platform = "ios", severity = severity, message = message, hint = hint, guide = "ios" }
end

---@param opts? devices.EnvOptions
---@param cb fun(ios: devices.IosEnv)
function M.xcode(opts, cb)
  opts = opts or {}
  ---@type devices.IosEnv
  local env = { supported = (opts.os or M.os()) == "macos", simctl = false, devicectl = false, problems = {} }
  if not env.supported then
    vim.schedule(function()
      cb(env)
    end)
    return
  end

  process.run({ "xcode-select", "-p" }, { timeout = TOOL_TIMEOUT_MS }, function(selected)
    local dir = vim.trim(selected.stdout)
    if selected.code ~= 0 or dir == "" then
      table.insert(
        env.problems,
        ios_problem(
          "xcode_missing",
          "warning",
          "Xcode is not installed",
          "Install Xcode from the App Store, open it once, then run: " .. SWITCH_HINT
        )
      )
      return cb(env)
    end
    env.developer_dir = dir

    if dir:find("CommandLineTools", 1, true) then
      table.insert(
        env.problems,
        ios_problem(
          "xcode_clt_only",
          "warning",
          "Only the Command Line Tools are installed, and simulators need the full Xcode app",
          "Install Xcode from the App Store, then run: " .. SWITCH_HINT
        )
      )
      return cb(env)
    end

    async.all({
      function(done)
        process.run({ "xcrun", "--find", "simctl" }, { timeout = TOOL_TIMEOUT_MS }, done)
      end,
      function(done)
        process.run({ "xcrun", "--find", "devicectl" }, { timeout = TOOL_TIMEOUT_MS }, done)
      end,
      function(done)
        process.run({ "xcodebuild", "-version" }, { timeout = TOOL_TIMEOUT_MS }, done)
      end,
    }, function(results)
      local simctl, devicectl, version = results[1], results[2], results[3]

      env.simctl = simctl.code == 0
      if not env.simctl then
        table.insert(
          env.problems,
          ios_problem(
            "simctl_missing",
            "warning",
            "simctl was not found in the selected Xcode",
            "Open Xcode once to finish installing its components, then run: " .. SWITCH_HINT
          )
        )
      end

      env.devicectl = devicectl.code == 0
      if not env.devicectl then
        table.insert(
          env.problems,
          ios_problem(
            "devicectl_missing",
            "info",
            "Physical iOS devices are unavailable",
            "They need Xcode 15 or newer."
          )
        )
      end

      if version.code == 0 then
        env.xcode_version = version.stdout:match("Xcode%s+(%S+)")
      elseif (version.stderr .. version.stdout):lower():find("license", 1, true) then
        table.insert(
          env.problems,
          ios_problem(
            "xcode_license",
            "warning",
            "The Xcode license has not been accepted",
            "Accept it once with: sudo xcodebuild -license accept"
          )
        )
      end
      cb(env)
    end)
  end)
end

-- Android -------------------------------------------------------------------------------------

---@class devices.AndroidEnv
---@field sdk string?
---@field tools table<string, { path: string, via: "sdk"|"path" }> Keys: emulator, adb, avdmanager, sdkmanager.
---@field java devices.JavaInfo?
---@field problems devices.Problem[]

---@param code string
---@param severity "error"|"warning"|"info"
---@param message string
---@param hint? string
---@return devices.Problem
local function android_problem(code, severity, message, hint)
  return { code = code, platform = "android", severity = severity, message = message, hint = hint, guide = "android" }
end

---@param opts devices.EnvOptions
---@param java devices.JavaInfo?
---@return devices.AndroidEnv
local function android_env(opts, java)
  local sdk, candidates = M.android_sdk(opts)
  ---@type devices.AndroidEnv
  local env = { sdk = sdk, tools = {}, java = java, problems = {} }
  local problems = env.problems

  -- A location the user set explicitly that does not exist is a setup mistake, not a gap.
  for _, candidate in ipairs(candidates) do
    if candidate.source ~= "default" and not is_dir(candidate.path) then
      table.insert(
        problems,
        android_problem(
          "android_sdk_invalid",
          "error",
          candidate.source .. " points to " .. candidate.path .. ", which does not exist",
          "Fix it or unset it. The SDK is usually in Android Studio > Settings > Android SDK."
        )
      )
    end
  end

  for _, name in ipairs({ "emulator", "adb", "avdmanager", "sdkmanager" }) do
    env.tools[name] = M.find_android_tool(name, opts)
  end

  if not sdk and vim.tbl_isempty(env.tools) then
    local looked = {}
    for _, candidate in ipairs(candidates) do
      looked[#looked + 1] = candidate.path
    end
    table.insert(
      problems,
      android_problem(
        "android_sdk_missing",
        "warning",
        "The Android SDK was not found",
        "Install Android Studio or the command-line tools, or set android_sdk / ANDROID_HOME. Looked in: "
          .. (#looked > 0 and table.concat(looked, ", ") or "nowhere (no usual location on this OS)")
      )
    )
    return env
  end

  if not env.tools.emulator then
    table.insert(
      problems,
      android_problem(
        "android_emulator_missing",
        "warning",
        "The Android emulator is not installed",
        'Install it with: sdkmanager "emulator"'
      )
    )
  end
  if not env.tools.adb then
    table.insert(
      problems,
      android_problem(
        "android_adb_missing",
        "warning",
        "adb is not installed, so physical Android devices are unavailable",
        'Install it with: sdkmanager "platform-tools"'
      )
    )
  end
  if not env.tools.avdmanager then
    table.insert(
      problems,
      android_problem(
        "android_avdmanager_missing",
        "info",
        "avdmanager is not installed, so new Android devices cannot be created",
        'Install the command-line tools with: sdkmanager "cmdline-tools;latest"'
      )
    )
  elseif not java then
    table.insert(
      problems,
      android_problem(
        "java_missing",
        "info",
        "No working Java was found, and avdmanager and sdkmanager need one",
        "Install a JDK, or install Android Studio, which bundles one."
      )
    )
  end
  return env
end

-- Report ------------------------------------------------------------------------------------

---@class devices.Env
---@field os devices.OS
---@field arch string
---@field ios devices.IosEnv
---@field android devices.AndroidEnv

---@param opts? devices.EnvOptions
---@param cb fun(env: devices.Env)
function M.detect(opts, cb)
  opts = opts or {}
  async.all({
    function(done)
      M.xcode(opts, done)
    end,
    function(done)
      M.find_java(opts, done)
    end,
  }, function(results)
    cb({
      os = opts.os or M.os(),
      arch = M.arch(),
      ios = results[1],
      android = android_env(opts, results[2]),
    })
  end)
end

return M
