local h = require("helpers")
local eq = h.eq

local err = require("devices.error")

local function result(fields)
  return vim.tbl_extend("force", {
    code = 0,
    signal = 0,
    stdout = "",
    stderr = "",
    timed_out = false,
    missing = false,
  }, fields)
end

local T = {}

T["from_process: a successful command is not an error"] = function()
  eq(err.from_process(result({}), { "adb", "devices" }), nil)
end

T["from_process: a missing tool carries its hint and guide"] = function()
  local e = err.from_process(
    result({ code = -1, missing = true }),
    { "/opt/sdk/platform-tools/adb", "devices" },
    { hint = "Install platform-tools", guide = "android" }
  )
  eq(e.code, "tool_missing")
  eq(e.message, "adb was not found")
  eq(e.hint, "Install platform-tools")
  eq(e.guide, "android")
end

T["from_process: a timeout"] = function()
  local e = err.from_process(result({ code = 124, timed_out = true }), { "xcrun", "simctl", "list" })
  eq(e.code, "timeout")
  eq(e.message, "xcrun did not finish in time")
end

T["from_process: a failure uses the first line of stderr"] = function()
  local e = err.from_process(
    result({ code = 2, stderr = "\n  Invalid device: nope\nsecond line\n" }),
    { "xcrun", "simctl", "boot", "nope" }
  )
  eq(e.code, "command_failed")
  eq(e.message, "xcrun failed: Invalid device: nope")
  eq(e.exit_code, 2)
  eq(e.cmd, { "xcrun", "simctl", "boot", "nope" })
end

T["from_process: a failure falls back to stdout, then to the exit code"] = function()
  local from_stdout = err.from_process(result({ code = 1, stdout = "bad thing\n" }), { "tool" })
  eq(from_stdout.message, "tool failed: bad thing")
  local bare = err.from_process(result({ code = 9 }), { "tool" })
  eq(bare.message, "tool failed (exit code 9)")
end

T["from_process: a very long stderr line is shortened"] = function()
  local e = err.from_process(result({ code = 1, stderr = string.rep("x", 5000) }), { "tool" })
  eq(#e.message < 300, true)
  eq(e.message:sub(-3), "...")
end

T["format: message and hint, or just the message"] = function()
  eq(err.format(err.new("tool_missing", "adb was not found", { hint = "Install it" })), "adb was not found\nInstall it")
  eq(err.format(err.new("timeout", "too slow")), "too slow")
  eq(err.format(err.new("timeout", "too slow", { hint = "" })), "too slow")
end

return T
