local h = require("helpers")
local eq = h.eq

local audit = require("devices.audit")

local T = {}

local function by_file(report)
  local found = {}
  for _, f in ipairs(report.findings) do
    found[#found + 1] = ("%s:%d:%s"):format(f.file, f.line, f.severity)
  end
  table.sort(found)
  return found
end

T["finds R8 rules that remove Log calls, and which ones"] = function()
  local root = h.tree({
    ["android/app/build.gradle"] = "android { buildTypes { release { minifyEnabled true } } }",
    ["android/app/proguard-rules.pro"] = table.concat({
      "-keep class io.flutter.** { *; }",
      "# -assumenosideeffects class android.util.Log { *; }",
      "-assumenosideeffects class android.util.Log {",
      "    public static int v(...);",
      "    public static int d(...);",
      "    public static boolean isLoggable(java.lang.String, int);",
      "}",
      "-maximumremovedandroidloglevel 4",
    }, "\n"),
  })
  local report = audit.run(root)
  eq(report.kinds, { "android" })
  eq(by_file(report), { "android/app/proguard-rules.pro:3:error", "android/app/proguard-rules.pro:8:error" })
  local block = report.findings[1].line == 3 and report.findings[1] or report.findings[2]
  eq(block.message, "R8 removes Log.v (verbose), Log.d (debug), Log.isLoggable from minified builds")
end

T["a commented-out rule is not a finding"] = function()
  local root = h.tree({ ["app/proguard-rules.pro"] = "# -assumenosideeffects class android.util.Log { *; }\n" })
  eq(audit.run(root).findings, {})
end

T["finds Babel's console removal and React Native's log threshold"] = function()
  local root = h.tree({
    ["package.json"] = '{ "dependencies": { "react-native": "0.76.0" } }',
    ["babel.config.js"] = "module.exports = {\n  env: { production: { plugins: ['transform-remove-console'] } },\n}",
    ["ios/App/AppDelegate.mm"] = "  RCTSetLogThreshold(RCTLogLevelInfo);",
    ["ios/App.xcodeproj/"] = "",
  })
  local report = audit.run(root)
  eq(report.kinds, { "ios", "react-native" })
  eq(by_file(report), { "babel.config.js:2:error", "ios/App/AppDelegate.mm:1:info" })
  -- Android, iOS and React Native notes: React Native targets both platforms.
  eq(#report.notes, 3)
end

T["finds a replaced debugPrint in a Flutter app, but not in tests"] = function()
  local root = h.tree({
    ["pubspec.yaml"] = "name: app\ndependencies:\n  flutter:\n    sdk: flutter",
    ["lib/main.dart"] = "void main() {\n  if (kReleaseMode) {\n    debugPrint = (String? m, {int? wrapWidth}) {};\n  }\n}",
    ["test/main_test.dart"] = "debugPrint = (String? m, {int? wrapWidth}) {};",
  })
  local report = audit.run(root)
  eq(report.kinds, { "flutter" })
  eq(by_file(report), { "lib/main.dart:3:warning" })
end

T["never looks inside dependencies or build output"] = function()
  local root = h.tree({
    ["node_modules/some-lib/babel.config.js"] = "plugins: ['transform-remove-console']",
    ["android/app/build/intermediates/proguard.txt"] = "-assumenosideeffects class android.util.Log { *; }",
    ["ios/Pods/X/Y.m"] = "RCTSetLogThreshold(1);",
  })
  eq(audit.run(root).findings, {})
end

T["an empty or missing directory is a clean report"] = function()
  eq(audit.run(h.tree({ ["README.md"] = "hi" })).findings, {})
  eq(audit.run("/does/not/exist").findings, {})
end

T["format: findings, then notes"] = function()
  local root =
    h.tree({ ["babel.config.js"] = "['transform-remove-console']", ["package.json"] = '{"react-native": "1"}' })
  local lines = audit.format(audit.run(root))
  eq(lines[2], "Project: react-native")
  eq(lines[4], "babel.config.js:1: [error] Babel removes console.* calls (transform-remove-console)")
  eq(vim.startswith(lines[#lines], "- React Native"), true)
end

return T
