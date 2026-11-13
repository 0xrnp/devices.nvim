--- The :Devices command.
local M = {}

---@class devices.Subcommand
---@field desc string
---@field device? "any"|"running"|"stopped" Which devices it acts on, when one is asked for.
---@field flags? string[] "--flag" options it accepts.
---@field keys? string[] "key=value" options it accepts.

---@type table<string, devices.Subcommand>
M.subcommands = {
  list = { desc = "Show every device" },
  boot = { desc = "Boot a simulator or start an emulator", device = "stopped", flags = { "--cold", "--wipe" } },
  shutdown = { desc = "Shut a simulator or emulator down", device = "running" },
  erase = { desc = "Erase a simulator, or start an emulator with its data wiped", device = "stopped" },
  delete = { desc = "Delete a simulator or an emulator", device = "stopped" },
  logs = { desc = "Open a live log", device = "running", keys = { "app", "mode" } },
  copy = { desc = "Copy a device id (for flutter -d, adb -s, xcrun)", device = "any" },
  create = { desc = "Create a simulator or an emulator" },
  connect = { desc = "Connect an Android phone over Wi-Fi" },
  disconnect = { desc = "Disconnect an Android phone on Wi-Fi", device = "running" },
  audit = { desc = "Check a project for settings that remove release logs" },
  doctor = { desc = "Check what is installed (:checkhealth devices)" },
}

---@class devices.ParsedCommand
---@field sub string?
---@field query string? The device, by id or name. Words are joined, so names may have spaces.
---@field flags table<string, boolean>
---@field keys table<string, string>
---@field error string?

--- Split `:Devices` arguments. Pure, for tests.
---@param args string[]
---@return devices.ParsedCommand
function M.parse(args)
  local parsed = { flags = {}, keys = {} }
  if #args == 0 then
    return parsed
  end
  local sub = args[1]
  local spec = M.subcommands[sub]
  if not spec then
    parsed.error = "Unknown subcommand: " .. sub
    return parsed
  end
  parsed.sub = sub
  local words = {}
  for i = 2, #args do
    local arg = args[i]
    local key, value = arg:match("^(%w+)=(.*)$")
    if arg:match("^%-%-") then
      if not vim.tbl_contains(spec.flags or {}, arg) then
        parsed.error = ("%s does not take %s"):format(sub, arg)
        return parsed
      end
      parsed.flags[arg:sub(3)] = true
    elseif key and vim.tbl_contains(spec.keys or {}, key) then
      parsed.keys[key] = value
    else
      words[#words + 1] = arg
    end
  end
  if #words > 0 then
    parsed.query = table.concat(words, " ")
  end
  if parsed.flags.cold and parsed.flags.wipe then
    parsed.error = "Use --cold or --wipe, not both"
  end
  return parsed
end

---@param kind "any"|"running"|"stopped"
---@return fun(device: devices.Device): boolean
local function device_filter(kind)
  local Device = require("devices.device")
  return function(device)
    if kind == "running" then
      return Device.is_ready(device) or device.state == "booting"
    elseif kind == "stopped" then
      return device.state == "shutdown"
    end
    return true
  end
end

--- Run a subcommand on a device: the one named, or one picked from a list.
---@param parsed devices.ParsedCommand
---@param fn fun(device: devices.Device)
local function with_device(parsed, fn)
  local ui = require("devices.ui")
  if parsed.query then
    return require("devices").find(parsed.query, function(device, failure)
      if failure then
        return ui.error(failure)
      end
      fn(device)
    end)
  end
  local spec = M.subcommands[parsed.sub]
  ui.pick({ prompt = spec.desc, filter = device_filter(spec.device) }, function(device)
    if device then
      fn(device)
    end
  end)
end

---@param parsed devices.ParsedCommand
function M.run(parsed)
  local ui = require("devices.ui")
  local devices = require("devices")
  if parsed.error then
    return ui.notify(parsed.error, vim.log.levels.ERROR)
  end
  local sub = parsed.sub
  if not sub then
    return ui.main()
  end

  if sub == "list" then
    devices.list(function(list, failures)
      local lines = {}
      for _, d in ipairs(list) do
        lines[#lines + 1] = ui.label(d) .. "   " .. devices.target_id(d)
      end
      for _, f in ipairs(failures) do
        lines[#lines + 1] = "! " .. require("devices.error").format(f):gsub("\n", " · ")
      end
      ui.notify(#lines > 0 and table.concat(lines, "\n") or "No devices found. Run :checkhealth devices.")
    end)
  elseif sub == "boot" then
    with_device(parsed, function(device)
      if parsed.flags.wipe and device.platform == "android" then
        -- Same confirmation as the action menu, since the data is gone afterwards.
        return ui.run_action("wipe", device)
      end
      ui.notify(("Starting %s..."):format(device.name))
      devices.boot(
        device,
        { cold = parsed.flags.cold, wipe = parsed.flags.wipe },
        ui.report(device.name .. " is starting")
      )
    end)
  elseif sub == "shutdown" or sub == "erase" or sub == "delete" or sub == "disconnect" or sub == "copy" then
    local action = sub == "copy" and "copy_id" or sub
    with_device(parsed, function(device)
      -- Erasing an emulator means starting it wiped, which the "wipe" action says correctly.
      if action == "erase" and device.platform == "android" then
        return ui.run_action("wipe", device)
      end
      ui.run_action(action, device)
    end)
  elseif sub == "logs" then
    with_device(parsed, function(device)
      ui.logs(device, { app = parsed.keys.app, mode = parsed.keys.mode })
    end)
  elseif sub == "create" then
    ui.create()
  elseif sub == "connect" then
    ui.connect()
  elseif sub == "audit" then
    ui.audit(parsed.query and vim.fn.expand(parsed.query) or nil)
  elseif sub == "doctor" then
    vim.cmd("checkhealth devices")
  end
end

-- Names from the last listing, for completion, which cannot wait for a fresh one.
---@type string[]
M.recent = {}

--- Complete `:Devices` arguments.
---@param arg_lead string
---@param cmdline string
---@return string[]
function M.complete(arg_lead, cmdline)
  local words = vim.split(cmdline, "%s+", { trimempty = true })
  -- Drop the command name. A trailing space means a new word is being typed.
  table.remove(words, 1)
  local typing_new = cmdline:match("%s$") ~= nil
  local position = #words + (typing_new and 1 or 0)

  local function matching(list)
    return vim.tbl_filter(function(item)
      return vim.startswith(item, arg_lead)
    end, list)
  end

  if position <= 1 then
    local subs = vim.tbl_keys(M.subcommands)
    table.sort(subs)
    return matching(subs)
  end
  local spec = M.subcommands[words[1]]
  if not spec then
    return {}
  end
  local options = {}
  for _, flag in ipairs(spec.flags or {}) do
    options[#options + 1] = flag
  end
  for _, key in ipairs(spec.keys or {}) do
    options[#options + 1] = key .. "="
  end
  if spec.device then
    vim.list_extend(options, M.recent)
  end
  return matching(options)
end

function M.register()
  vim.api.nvim_create_user_command("Devices", function(info)
    M.run(M.parse(info.fargs))
  end, {
    nargs = "*",
    desc = "Simulators, emulators and devices",
    complete = M.complete,
  })
end

return M
