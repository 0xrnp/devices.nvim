-- The `devices` terminal command: `nvim -l lua/devices/cli.lua <command> [args]`.
-- bin/devices is the launcher. Exit codes: 0 success, 1 failure, 2 wrong usage.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
vim.opt.runtimepath:prepend(root)

local devices = require("devices")
local errors = require("devices.error")

local USAGE = [[
Usage: devices <command> [arguments]

  list [--json]                       every simulator, emulator and device
  boot <device> [--cold|--wipe --yes] [--wait]
  shutdown <device>
  erase <device> --yes                simulator: erase. emulator: start wiped.
  delete <device> --yes
  logs <device> [--app <id>] [--mode logcat|system|console]
  audit [directory]                   settings that remove release logs
  doctor                              what is installed, and how to fix the rest
  id <device>                         the id for flutter -d, adb -s, xcrun

<device> is an id, an adb serial, or a name ("iPhone 16", or a unique part of one).
]]

local function out(text)
  io.stdout:write(text, "\n")
end

local function fail(text, code)
  io.stderr:write(text, "\n")
  os.exit(code or 1)
end

--- Run an async function and wait for its callback.
local function await(start)
  local done, results = false, nil
  start(function(...)
    results = vim.F.pack_len(...)
    done = true
  end)
  vim.wait(2 ^ 31 - 1, function()
    return done
  end, 20)
  return vim.F.unpack_len(results)
end

---@param list string[]
---@return string[] positional
---@return table<string, string|boolean> options
local function parse(list)
  local positional, options = {}, {}
  local i = 1
  while i <= #list do
    local a = list[i]
    local name = a:match("^%-%-(.+)$")
    if name == "app" or name == "mode" then
      options[name] = list[i + 1]
      if not options[name] then
        fail("--" .. name .. " needs a value", 2)
      end
      i = i + 1
    elseif name then
      options[name] = true
    else
      positional[#positional + 1] = a
    end
    i = i + 1
  end
  return positional, options
end

local function find(query)
  if not query then
    fail("Which device? Run `devices list` to see them.", 2)
  end
  local device, failure = await(function(cb)
    devices.find(query, cb)
  end)
  if failure then
    fail(errors.format(failure))
  end
  return device
end

local function check(failure, success)
  if failure then
    fail(errors.format(failure))
  end
  out(success)
end

local commands = {}

function commands.list(_, options)
  local list, failures = await(devices.list)
  if options.json then
    out(vim.json.encode(list))
  else
    local rows = { { "STATE", "PLATFORM", "KIND", "OS", "NAME", "ID" } }
    for _, d in ipairs(list) do
      rows[#rows + 1] = {
        d.state,
        d.platform,
        d.kind,
        d.os_version or "-",
        d.name,
        devices.target_id(d),
      }
    end
    local widths = {}
    for _, row in ipairs(rows) do
      for c, cell in ipairs(row) do
        widths[c] = math.max(widths[c] or 0, vim.fn.strdisplaywidth(cell))
      end
    end
    for _, row in ipairs(rows) do
      local cells = {}
      for c, cell in ipairs(row) do
        cells[c] = c < #row and (cell .. string.rep(" ", widths[c] - vim.fn.strdisplaywidth(cell))) or cell
      end
      out(table.concat(cells, "  "))
    end
  end
  for _, f in ipairs(failures) do
    io.stderr:write("! ", (errors.format(f):gsub("\n", "\n  ")), "\n")
  end
end

function commands.boot(positional, options)
  local device = find(positional[1])
  if options.cold and options.wipe then
    fail("Use --cold or --wipe, not both", 2)
  end
  if options.wipe and not options.yes then
    fail(("This erases all data on %s. Add --yes to confirm."):format(device.name), 2)
  end
  local failure = await(function(cb)
    devices.boot(device, { cold = options.cold, wipe = options.wipe, wait = options.wait }, cb)
  end)
  check(failure, options.wait and (device.name .. " is ready") or (device.name .. " is starting"))
end

function commands.shutdown(positional)
  local device = find(positional[1])
  check(
    await(function(cb)
      devices.shutdown(device, cb)
    end),
    device.name .. " is shutting down"
  )
end

function commands.erase(positional, options)
  local device = find(positional[1])
  if not options.yes then
    fail(("This erases all data on %s. Add --yes to confirm."):format(device.name), 2)
  end
  check(
    await(function(cb)
      devices.erase(device, cb)
    end),
    device.platform == "ios" and (device.name .. " was erased") or (device.name .. " is starting with its data wiped")
  )
end

function commands.delete(positional, options)
  local device = find(positional[1])
  if not options.yes then
    fail(("This deletes %s for good. Add --yes to confirm."):format(device.name), 2)
  end
  check(
    await(function(cb)
      devices.delete(device, cb)
    end),
    device.name .. " was deleted"
  )
end

function commands.id(positional)
  out(devices.target_id(find(positional[1])))
end

function commands.logs(positional, options)
  local device = find(positional[1])
  local logs = require("devices.logs")
  local modes = logs.modes(device)
  if #modes == 0 then
    fail(device.name .. " is not running. Boot or connect it first.")
  end
  local mode = options.mode or modes[1].id
  local done, exit_code = false, 0
  -- detach = false keeps the stream in the terminal's foreground process group, so Ctrl-C (or
  -- closing the terminal) reaches it directly. Headless Neovim exits on SIGINT at once, before
  -- any Lua handler could stop the stream for it.
  logs.start({ device = device, mode = mode, app = options.app, tail = 1000, detach = false }, {
    on_lines = function(lines)
      for _, line in ipairs(lines) do
        io.stdout:write(line.text, "\n")
      end
      io.stdout:flush()
    end,
    on_status = function(message)
      io.stderr:write("-- ", message, " --\n")
    end,
    on_exit = function(failure)
      if failure then
        io.stderr:write(errors.format(failure), "\n")
        exit_code = 1
      end
      done = true
    end,
  })
  vim.wait(2 ^ 31 - 1, function()
    return done
  end, 50)
  os.exit(exit_code)
end

function commands.audit(positional)
  local audit = require("devices.audit")
  local report = audit.run(positional[1] or vim.fn.getcwd())
  out(table.concat(audit.format(report), "\n"))
  local removes = vim.tbl_filter(function(f)
    return f.severity == "error"
  end, report.findings)
  os.exit(#removes > 0 and 1 or 0)
end

function commands.doctor()
  local env = require("devices.env")
  local result = await(function(cb)
    env.detect(require("devices.config").android(), cb)
  end)
  out(("OS: %s (%s)"):format(result.os, result.arch))
  local problems = {}
  vim.list_extend(problems, result.ios.problems or {})
  vim.list_extend(problems, result.android.problems or {})
  if result.ios.supported then
    out("iOS simulators: " .. (result.ios.simctl and "ready" or "unavailable"))
    out("iOS devices:    " .. (result.ios.devicectl and "ready" or "unavailable"))
  end
  for _, name in ipairs({ "adb", "emulator", "avdmanager", "sdkmanager" }) do
    local tool = result.android.tools[name]
    out(("%-15s %s"):format(name .. ":", tool and tool.path or "not found"))
  end
  out("java:           " .. (result.android.java and result.android.java.path or "not found"))
  if #problems > 0 then
    out("")
    for _, p in ipairs(problems) do
      out(("[%s] %s"):format(p.severity, p.message))
      if p.hint then
        out("    " .. p.hint)
      end
    end
  end
  local errors_found = vim.tbl_filter(function(p)
    return p.severity == "error"
  end, problems)
  os.exit(#errors_found > 0 and 1 or 0)
end

local list = _G.arg or {}
local name = list[1]
if not name or name == "help" or name == "--help" or name == "-h" then
  io.stdout:write(USAGE)
  os.exit(name and 0 or 2)
end
local command = commands[name]
if not command then
  io.stderr:write("Unknown command: ", name, "\n\n", USAGE)
  os.exit(2)
end
local positional, options = parse(vim.list_slice(list, 2))
command(positional, options)
os.exit(0)
