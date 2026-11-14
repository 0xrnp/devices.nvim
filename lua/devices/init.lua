--- devices.nvim: iOS simulators, Android emulators and physical devices from Neovim.
---
--- Every function is asynchronous, never throws for runtime problems, and reports a
--- `devices.Error` (see devices.error) through its callback.
local android = require("devices.backend.android")
local async = require("devices.async")
local config = require("devices.config")
local Device = require("devices.device")
local env = require("devices.env")
local err = require("devices.error")
local ios = require("devices.backend.ios")

local M = {}

---@param opts? table See devices.Config.
function M.setup(opts)
  config.setup(opts)
end

---@param cb function
---@param ... any
local function later(cb, ...)
  local args = vim.F.pack_len(...)
  vim.schedule(function()
    cb(vim.F.unpack_len(args))
  end)
end

--- Every device on this machine, ready ones first. A platform that fails does not hide the
--- others: the errors come alongside.
---@param cb fun(devices: devices.Device[], errors: devices.Error[])
function M.list(cb)
  local tasks = {}
  if env.os() == "macos" then
    tasks[#tasks + 1] = function(done)
      ios.list({}, function(devices, errors)
        done({ devices = devices, errors = errors })
      end)
    end
  end
  tasks[#tasks + 1] = function(done)
    android.list(config.android(), function(devices, errors)
      done({ devices = devices, errors = errors })
    end)
  end
  async.all(tasks, function(results)
    local devices, errors = {}, {}
    for _, r in ipairs(results) do
      vim.list_extend(devices, r.devices)
      vim.list_extend(errors, r.errors)
    end
    devices = Device.sort(devices)
    -- Remembered for :Devices completion. A space in a name is escaped so it stays one word.
    require("devices.commands").recent = vim.tbl_map(function(d)
      return (d.name:gsub(" ", "\\ "))
    end, devices)
    cb(devices, errors)
  end)
end

--- Find one device by id, adb serial, or name (exact, then case-insensitive, then a unique
--- partial match).
---@param query string
---@param cb fun(device: devices.Device?, error: devices.Error?)
function M.find(query, cb)
  M.list(function(devices, errors)
    local lower = query:lower()
    local function first(pred)
      local found = {}
      for _, d in ipairs(devices) do
        if pred(d) then
          found[#found + 1] = d
        end
      end
      return found
    end
    for _, pred in ipairs({
      function(d)
        return d.id == query or d.serial == query
      end,
      function(d)
        return d.name == query
      end,
      function(d)
        return d.name:lower() == lower
      end,
      function(d)
        return d.name:lower():find(lower, 1, true) ~= nil
      end,
    }) do
      local found = first(pred)
      if #found == 1 then
        return cb(found[1])
      elseif #found > 1 then
        local names = vim.tbl_map(function(d)
          return d.name .. " (" .. d.id .. ")"
        end, found)
        return cb(
          nil,
          err.new("not_found", ("%q matches %d devices: %s"):format(query, #found, table.concat(names, ", ")), {
            hint = "Use the id to pick one.",
          })
        )
      end
    end
    local hint = #errors > 0 and ("Some devices could not be listed: " .. errors[1].message) or nil
    cb(nil, err.new("not_found", ("No device matches %q"):format(query), { hint = hint }))
  end)
end

--- The id other tools (flutter -d, adb -s, xcrun) want: a running emulator's adb serial, else
--- the device id.
---@param device devices.Device
---@return string
function M.target_id(device)
  if device.platform == "android" then
    return device.serial or device.id
  end
  return device.id
end

--- Call on_boot once the device has finished booting, in the background.
---@param device devices.Device
local function after_boot(device)
  local hook = config.options.on_boot
  if not hook then
    return
  end
  local function run_hook()
    M.find(device.id, function(fresh)
      local ok, problem = pcall(hook, fresh or device)
      if not ok then
        vim.notify("devices.nvim: on_boot failed: " .. tostring(problem), vim.log.levels.ERROR)
      end
    end)
  end
  if device.platform == "ios" then
    ios.wait_booted(device, nil, function(failure)
      if not failure then
        run_hook()
      end
    end)
  else
    android.wait_booted(device, { android = config.android() }, function(failure)
      if not failure then
        run_hook()
      end
    end)
  end
end

---@class devices.BootOptions
---@field cold? boolean Android: ignore the saved snapshot.
---@field wipe? boolean Android: erase user data first.
---@field wait? boolean Call back only once it has finished booting.

--- Boot a simulator or start an emulator. Already running is a success.
---@param device devices.Device
---@param opts? devices.BootOptions
---@param cb fun(error: devices.Error?)
function M.boot(device, opts, cb)
  opts = opts or {}
  -- Booting a running device succeeds without doing anything, so on_boot has already run for it.
  local was_running = device.state == "booted" or device.state == "booting"
  local function done(failure)
    if not failure and not was_running then
      after_boot(device)
    end
    cb(failure)
  end
  if device.platform == "ios" then
    if opts.cold or opts.wipe then
      return later(
        cb,
        err.new("unsupported", "Cold boot and wipe are Android emulator options", {
          hint = "For a simulator, use erase: it resets content and settings.",
        })
      )
    end
    return ios.boot(device, { open_app = config.options.ios.open_simulator_app, wait = opts.wait }, done)
  end
  local a = config.options.android
  android.boot(
    device,
    vim.tbl_extend("force", config.android(), {
      cold = opts.cold,
      wipe = opts.wipe,
      wait = opts.wait,
      headless = a.headless,
      args = a.emulator_args,
    }),
    done
  )
end

---@param device devices.Device
---@param cb fun(error: devices.Error?)
function M.shutdown(device, cb)
  if device.platform == "ios" then
    return ios.shutdown(device, function(failure)
      if failure or not config.options.ios.quit_simulator_app then
        return cb(failure)
      end
      -- The simulator did shut down, so failing to quit the app is only a warning.
      ios.quit_simulator_apps(function(quit_error)
        if quit_error then
          vim.notify(err.format(quit_error), vim.log.levels.WARN, { title = "devices.nvim" })
        end
        cb(nil)
      end)
    end)
  end
  android.shutdown(device, config.android(), cb)
end

--- iOS simulator: erase content and settings (must be shut down).
--- Android emulator: start it with its data wiped (must be shut down).
---@param device devices.Device
---@param cb fun(error: devices.Error?)
function M.erase(device, cb)
  if device.platform == "ios" then
    return ios.erase(device, cb)
  end
  M.boot(device, { wipe = true }, cb)
end

--- Delete a simulator or an AVD.
---@param device devices.Device
---@param cb fun(error: devices.Error?)
function M.delete(device, cb)
  if device.platform == "ios" then
    return ios.delete(device, cb)
  end
  android.delete(device, config.android(), cb)
end

--- What can be done with a device right now, for menus.
---@param device devices.Device
---@return string[] ids of built-in actions, in menu order
function M.actions(device)
  local list = {}
  local ready = Device.is_ready(device)
  local function add(id)
    list[#list + 1] = id
  end
  if device.kind == "simulator" then
    if device.state == "shutdown" then
      add("boot")
      add("erase")
      add("delete")
    else
      add("logs")
      add("shutdown")
    end
  elseif device.kind == "emulator" then
    if device.source == "emulator" and device.state == "shutdown" then
      add("boot")
      add("cold_boot")
      add("wipe")
      add("delete")
    else
      if ready then
        add("logs")
      end
      add("shutdown")
    end
  else
    if ready then
      add("logs")
    end
    if device.platform == "android" and device.transport == "wifi" then
      add("disconnect")
    end
  end
  add("copy_id")
  return list
end

--- Open a live log for a device. See devices.logs for the modes.
---@param device devices.Device
---@param spec { mode: devices.LogMode, app?: string }
function M.logs(device, spec)
  require("devices.view").open(vim.tbl_extend("force", {
    device = device,
    tail = config.options.logs.tail,
    android = config.android(),
  }, spec))
end

--- Look through a project for settings that remove logs from release builds.
---@param root? string Default: the current directory.
---@return devices.AuditReport
function M.audit(root)
  return require("devices.audit").run(root or vim.fn.getcwd())
end

--- Pick a device with vim.ui.select.
---@param opts? { prompt?: string, filter?: fun(device: devices.Device): boolean }
---@param cb fun(device: devices.Device?)
function M.pick(opts, cb)
  require("devices.ui").pick(opts, cb)
end

return M
