local h = require("helpers")
local eq = h.eq

local env = require("devices.env")

local OK = "#!/bin/sh\nexit 0\n"
local JAVA_17 = "#!/bin/sh\necho 'openjdk version \"17.0.9\" 2023-10-17' >&2\nexit 0\n"
local JAVA_STUB = '#!/bin/sh\necho "Unable to locate a Java Runtime." >&2\nexit 1\n'

--- Options for a test that must not see this machine's SDK or JDK.
local function bare(extra)
  return vim.tbl_extend("force", { android_sdk_fallbacks = {}, java_fallbacks = {} }, extra or {})
end

--- A complete Android SDK layout under `<root>/sdk`.
local function full_sdk()
  return h.tree({
    ["sdk/emulator/emulator"] = OK,
    ["sdk/platform-tools/adb"] = OK,
    ["sdk/cmdline-tools/latest/bin/avdmanager"] = OK,
    ["sdk/cmdline-tools/latest/bin/sdkmanager"] = OK,
  })
end

--- Xcode tools on PATH. Each argument overrides one script.
local function xcode_tools(overrides)
  local scripts = vim.tbl_extend("force", {
    ["bin/xcode-select"] = "#!/bin/sh\necho /Applications/Xcode.app/Contents/Developer\n",
    ["bin/xcrun"] = '#!/bin/sh\ncase "$2" in simctl|devicectl) echo "/fake/$2"; exit 0;; esac\nexit 1\n',
    ["bin/xcodebuild"] = "#!/bin/sh\necho 'Xcode 27.2'\necho 'Build version 27B52'\n",
  }, overrides or {})
  return h.tree(scripts) .. "/bin"
end

local function has_problem(problems, code)
  for _, problem in ipairs(problems) do
    if problem.code == code then
      return problem
    end
  end
end

local T = {}

-- Platform ----------------------------------------------------------------------------------

T["os and arch: known values"] = function()
  eq(vim.tbl_contains({ "macos", "linux", "windows", "other" }, env.os()), true)
  eq(env.normalize_arch("arm64"), "arm64")
  eq(env.normalize_arch("aarch64"), "arm64")
  eq(env.normalize_arch("x86_64"), "x86_64")
  eq(env.normalize_arch("AMD64"), "x86_64")
  eq(env.normalize_arch("riscv64"), "riscv64")
end

-- Android SDK -------------------------------------------------------------------------------

T["android_sdk: ANDROID_HOME, then ANDROID_SDK_ROOT"] = function()
  local root = h.tree({ ["a/"] = "", ["b/"] = "" })
  h.with_env(h.isolated({ ANDROID_HOME = root .. "/a", ANDROID_SDK_ROOT = root .. "/b" }), function()
    local sdk, candidates = env.android_sdk(bare())
    eq(sdk, root .. "/a")
    eq(candidates[1].source, "ANDROID_HOME")
  end)
  h.with_env(h.isolated({ ANDROID_SDK_ROOT = root .. "/b" }), function()
    eq((env.android_sdk(bare())), root .. "/b")
  end)
end

T["android_sdk: a configured path wins, a missing one is skipped"] = function()
  local root = h.tree({ ["configured/"] = "", ["env/"] = "" })
  h.with_env(h.isolated({ ANDROID_HOME = root .. "/env" }), function()
    eq((env.android_sdk(bare({ android_sdk = root .. "/configured" }))), root .. "/configured")
    eq((env.android_sdk(bare({ android_sdk = root .. "/does-not-exist" }))), root .. "/env")
  end)
end

T["android_sdk: nothing found lists where it looked"] = function()
  h.with_env(h.isolated({ ANDROID_HOME = "/no/such/sdk" }), function()
    local sdk, candidates = env.android_sdk(bare())
    eq(sdk, nil)
    eq(candidates, { { path = "/no/such/sdk", source = "ANDROID_HOME" } })
  end)
end

T["android_sdk: the usual install location is found with no environment set"] = function()
  local home = h.tree({ ["Library/Android/sdk/"] = "", ["Android/Sdk/"] = "" })
  h.with_env(h.isolated({ HOME = home }), function()
    eq((env.android_sdk({ os = "macos" })), home .. "/Library/Android/sdk")
    eq((env.android_sdk({ os = "linux" })), home .. "/Android/Sdk")
  end)
end

-- Android tools -----------------------------------------------------------------------------

T["find_android_tool: finds every tool in an SDK that is not on PATH"] = function()
  local root = full_sdk()
  h.with_env(h.isolated({ ANDROID_HOME = root .. "/sdk" }), function()
    local opts = bare()
    eq(env.find_android_tool("emulator", opts), { path = root .. "/sdk/emulator/emulator", via = "sdk" })
    eq(env.find_android_tool("adb", opts), { path = root .. "/sdk/platform-tools/adb", via = "sdk" })
    eq(env.find_android_tool("avdmanager", opts).path, root .. "/sdk/cmdline-tools/latest/bin/avdmanager")
    eq(env.find_android_tool("sdkmanager", opts).path, root .. "/sdk/cmdline-tools/latest/bin/sdkmanager")
  end)
end

T["find_android_tool: prefers latest, then the highest version number, then legacy tools"] = function()
  local both = h.tree({
    ["sdk/cmdline-tools/latest/bin/avdmanager"] = OK,
    ["sdk/cmdline-tools/9.0/bin/avdmanager"] = OK,
  })
  local numbered = h.tree({
    ["sdk/cmdline-tools/11.0/bin/avdmanager"] = OK,
    ["sdk/cmdline-tools/19.0/bin/avdmanager"] = OK,
    ["sdk/cmdline-tools/2.1/bin/avdmanager"] = OK,
  })
  local legacy = h.tree({ ["sdk/tools/bin/avdmanager"] = OK })

  h.with_env(h.isolated({ ANDROID_HOME = both .. "/sdk" }), function()
    eq(env.find_android_tool("avdmanager", bare()).path, both .. "/sdk/cmdline-tools/latest/bin/avdmanager")
  end)
  h.with_env(h.isolated({ ANDROID_HOME = numbered .. "/sdk" }), function()
    -- 19.0 is the highest number. As text, "11.0" comes first and "2.1" comes last, so neither
    -- an alphabetical nor a reverse-alphabetical order finds it.
    eq(env.find_android_tool("avdmanager", bare()).path, numbered .. "/sdk/cmdline-tools/19.0/bin/avdmanager")
  end)
  h.with_env(h.isolated({ ANDROID_HOME = legacy .. "/sdk" }), function()
    eq(env.find_android_tool("avdmanager", bare()).path, legacy .. "/sdk/tools/bin/avdmanager")
  end)
end

T["find_android_tool: PATH beats the environment SDK, and a configured SDK beats PATH"] = function()
  local sdk = full_sdk()
  local on_path = h.tree({ ["bin/adb"] = OK })
  local configured = h.tree({ ["sdk/platform-tools/adb"] = OK })
  h.with_env(h.isolated({ PATH = on_path .. "/bin", ANDROID_HOME = sdk .. "/sdk" }), function()
    eq(env.find_android_tool("adb", bare()), { path = on_path .. "/bin/adb", via = "path" })
    eq(
      env.find_android_tool("adb", bare({ android_sdk = configured .. "/sdk" })),
      { path = configured .. "/sdk/platform-tools/adb", via = "sdk" }
    )
  end)
end

T["find_android_tool: a configured SDK without the tool falls through to PATH"] = function()
  local on_path = h.tree({ ["bin/adb"] = OK })
  local empty_sdk = h.tree({ ["sdk/"] = "" })
  h.with_env(h.isolated({ PATH = on_path .. "/bin" }), function()
    eq(env.find_android_tool("adb", bare({ android_sdk = empty_sdk .. "/sdk" })).via, "path")
  end)
end

T["find_android_tool: a file that is not executable is not a tool"] = function()
  local root = h.tree({ ["sdk/platform-tools/adb"] = "not a script" })
  h.with_env(h.isolated({ ANDROID_HOME = root .. "/sdk" }), function()
    eq(env.find_android_tool("adb", bare()), nil)
  end)
end

T["find_android_tool: nothing anywhere"] = function()
  h.with_env(h.isolated(), function()
    eq(env.find_android_tool("emulator", bare()), nil)
  end)
end

-- Java --------------------------------------------------------------------------------------

T["find_java: a working java on PATH"] = function()
  local bin = h.tree({ ["bin/java"] = JAVA_17 })
  h.with_env(h.isolated({ PATH = bin .. "/bin" }), function()
    local java = h.await(function(cb)
      env.find_java(bare(), cb)
    end)
    eq(java, { path = bin .. "/bin/java", home = nil, version = "17.0.9", major = 17 })
  end)
end

T["find_java: reads the old 1.8 version format"] = function()
  local bin = h.tree({ ["bin/java"] = "#!/bin/sh\necho 'java version \"1.8.0_292\"' >&2\n" })
  h.with_env(h.isolated({ PATH = bin .. "/bin" }), function()
    local java = h.await(function(cb)
      env.find_java(bare(), cb)
    end)
    eq(java.major, 8)
    eq(java.version, "1.8.0_292")
  end)
end

T["find_java: JAVA_HOME wins over PATH and sets the home"] = function()
  local jdk = h.tree({ ["jdk/bin/java"] = JAVA_17 })
  local bin = h.tree({ ["bin/java"] = "#!/bin/sh\necho 'openjdk version \"21.0.1\"' >&2\n" })
  h.with_env(h.isolated({ PATH = bin .. "/bin", JAVA_HOME = jdk .. "/jdk" }), function()
    local java = h.await(function(cb)
      env.find_java(bare(), cb)
    end)
    eq(java.major, 17)
    eq(java.home, jdk .. "/jdk")
  end)
end

T["find_java: skips the macOS stub that only prints an error"] = function()
  local stub = h.tree({ ["bin/java"] = JAVA_STUB })
  local studio = h.tree({ ["jbr/bin/java"] = JAVA_17 })
  h.with_env(h.isolated({ PATH = stub .. "/bin" }), function()
    local none = h.await(function(cb)
      env.find_java(bare(), cb)
    end)
    eq(none, nil)

    local java = h.await(function(cb)
      env.find_java(bare({ java_fallbacks = { studio .. "/jbr" } }), cb)
    end)
    eq(java.major, 17)
    eq(java.home, studio .. "/jbr")
  end)
end

T["find_java: output that is not a version does not count"] = function()
  local bin = h.tree({ ["bin/java"] = "#!/bin/sh\necho 'hello'\nexit 0\n" })
  h.with_env(h.isolated({ PATH = bin .. "/bin" }), function()
    local java = h.await(function(cb)
      env.find_java(bare(), cb)
    end)
    eq(java, nil)
  end)
end

T["find_java: no java at all"] = function()
  h.with_env(h.isolated(), function()
    local java, calls = h.await(function(cb)
      env.find_java(bare(), cb)
    end)
    eq(java, nil)
    eq(calls, 1)
  end)
end

-- Xcode -------------------------------------------------------------------------------------

T["xcode: another OS is unsupported, not broken, and nothing is run"] = function()
  local marker = h.tree({ ["marker"] = "" }) .. "/marker"
  local bin = xcode_tools({ ["bin/xcode-select"] = "#!/bin/sh\necho ran > " .. marker .. "\n" })
  h.with_env(h.isolated({ PATH = bin }), function()
    local ios = h.await(function(cb)
      env.xcode({ os = "linux" }, cb)
    end)
    eq(ios, { supported = false, simctl = false, devicectl = false, problems = {} })
    -- The fake xcode-select would have overwritten the marker if it had run.
    eq(vim.fn.readfile(marker), { "" })
  end)
end

T["xcode: a healthy install"] = function()
  h.with_env(h.isolated({ PATH = xcode_tools() }), function()
    local ios = h.await(function(cb)
      env.xcode({ os = "macos" }, cb)
    end)
    eq(ios.supported, true)
    eq(ios.simctl, true)
    eq(ios.devicectl, true)
    eq(ios.xcode_version, "27.2")
    eq(ios.developer_dir, "/Applications/Xcode.app/Contents/Developer")
    eq(ios.problems, {})
  end)
end

T["xcode: nothing selected"] = function()
  local bin =
    xcode_tools({ ["bin/xcode-select"] = "#!/bin/sh\necho 'xcode-select: error: no developer tools' >&2\nexit 2\n" })
  h.with_env(h.isolated({ PATH = bin }), function()
    local ios = h.await(function(cb)
      env.xcode({ os = "macos" }, cb)
    end)
    eq(ios.simctl, false)
    local problem = has_problem(ios.problems, "xcode_missing")
    eq(problem ~= nil, true)
    eq(problem.severity, "warning")
    eq(problem.guide, "ios")
    eq(#ios.problems, 1)
  end)
end

T["xcode: only the Command Line Tools"] = function()
  local bin = xcode_tools({ ["bin/xcode-select"] = "#!/bin/sh\necho /Library/Developer/CommandLineTools\n" })
  h.with_env(h.isolated({ PATH = bin }), function()
    local ios = h.await(function(cb)
      env.xcode({ os = "macos" }, cb)
    end)
    eq(ios.developer_dir, "/Library/Developer/CommandLineTools")
    eq(ios.simctl, false)
    eq(#ios.problems, 1)
    eq(ios.problems[1].code, "xcode_clt_only")
  end)
end

T["xcode: simctl missing"] = function()
  local bin = xcode_tools({ ["bin/xcrun"] = "#!/bin/sh\nexit 1\n" })
  h.with_env(h.isolated({ PATH = bin }), function()
    local ios = h.await(function(cb)
      env.xcode({ os = "macos" }, cb)
    end)
    eq(ios.simctl, false)
    eq(has_problem(ios.problems, "simctl_missing") ~= nil, true)
  end)
end

T["xcode: an Xcode without devicectl only costs physical devices, as info"] = function()
  local bin =
    xcode_tools({ ["bin/xcrun"] = '#!/bin/sh\n[ "$2" = simctl ] && { echo /fake/simctl; exit 0; }\nexit 1\n' })
  h.with_env(h.isolated({ PATH = bin }), function()
    local ios = h.await(function(cb)
      env.xcode({ os = "macos" }, cb)
    end)
    eq(ios.simctl, true)
    eq(ios.devicectl, false)
    eq(#ios.problems, 1)
    eq(ios.problems[1].code, "devicectl_missing")
    eq(ios.problems[1].severity, "info")
  end)
end

T["xcode: an unaccepted license"] = function()
  local bin = xcode_tools({
    ["bin/xcodebuild"] = "#!/bin/sh\necho 'You have not agreed to the Xcode license agreements.' >&2\nexit 69\n",
  })
  h.with_env(h.isolated({ PATH = bin }), function()
    local ios = h.await(function(cb)
      env.xcode({ os = "macos" }, cb)
    end)
    eq(ios.xcode_version, nil)
    eq(has_problem(ios.problems, "xcode_license") ~= nil, true)
  end)
end

-- detect ------------------------------------------------------------------------------------

T["detect: a complete setup has no problems"] = function()
  local sdk = full_sdk()
  local bin = xcode_tools({ ["bin/java"] = JAVA_17 })
  h.with_env(h.isolated({ PATH = bin, ANDROID_HOME = sdk .. "/sdk" }), function()
    local report = h.await(function(cb)
      env.detect(bare({ os = "macos" }), cb)
    end)
    eq(report.os, "macos")
    eq(report.ios.problems, {})
    eq(report.android.problems, {})
    eq(report.android.sdk, sdk .. "/sdk")
    eq(report.android.java.major, 17)
    eq(vim.tbl_count(report.android.tools), 4)
  end)
end

T["detect: nothing installed explains each platform and never throws"] = function()
  h.with_env(h.isolated(), function()
    local report, calls = h.await(function(cb)
      env.detect(bare({ os = "macos" }), cb)
    end)
    eq(calls, 1)
    eq(report.ios.supported, true)
    eq(has_problem(report.android.problems, "android_sdk_missing") ~= nil, true)
    eq(has_problem(report.android.problems, "android_sdk_missing").guide, "android")
    eq(report.android.sdk, nil)
  end)
end

T["detect: a Linux host hides iOS instead of reporting it broken"] = function()
  h.with_env(h.isolated(), function()
    local report = h.await(function(cb)
      env.detect(bare({ os = "linux" }), cb)
    end)
    eq(report.ios.supported, false)
    eq(report.ios.problems, {})
  end)
end

T["detect: a wrong ANDROID_HOME is an error even when another SDK works"] = function()
  local sdk = full_sdk()
  h.with_env(h.isolated({ ANDROID_HOME = "/no/such/sdk", ANDROID_SDK_ROOT = sdk .. "/sdk" }), function()
    local report = h.await(function(cb)
      env.detect(bare({ os = "linux" }), cb)
    end)
    local problem = has_problem(report.android.problems, "android_sdk_invalid")
    eq(problem ~= nil, true)
    eq(problem.severity, "error")
    eq(report.android.sdk, sdk .. "/sdk")
    eq(report.android.tools.emulator ~= nil, true)
  end)
end

T["detect: a partial SDK reports each missing piece at the right severity"] = function()
  local sdk = h.tree({ ["sdk/emulator/emulator"] = OK, ["sdk/cmdline-tools/latest/bin/avdmanager"] = OK })
  h.with_env(h.isolated({ ANDROID_HOME = sdk .. "/sdk" }), function()
    local report = h.await(function(cb)
      env.detect(bare({ os = "linux" }), cb)
    end)
    local problems = report.android.problems
    eq(has_problem(problems, "android_adb_missing").severity, "warning")
    eq(has_problem(problems, "java_missing").severity, "info")
    eq(has_problem(problems, "android_emulator_missing"), nil)
    eq(has_problem(problems, "android_avdmanager_missing"), nil)
  end)
end

return T
