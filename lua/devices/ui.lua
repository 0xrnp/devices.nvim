--- Pickers, menus and messages. Uses vim.ui.select and vim.ui.input, so it follows whatever
--- picker the user has (fzf-lua, snacks, telescope-ui-select, dressing) or the built-in one.
local android = require("devices.backend.android")
local config = require("devices.config")
local Device = require("devices.device")
local env = require("devices.env")
local errors = require("devices.error")
local ios = require("devices.backend.ios")

local M = {}

local TITLE = "devices.nvim"

---@param message string
---@param level? integer
function M.notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = TITLE })
end

---@param failure devices.Error
function M.error(failure)
  local text = errors.format(failure)
  if failure.guide then
    text = text .. "\nSetup help: :checkhealth devices"
  end
  M.notify(text, vim.log.levels.ERROR)
end

--- Report the result of an action: an error, or `success`.
---@param success string
---@return fun(failure: devices.Error?)
function M.report(success)
  return function(failure)
    if failure then
      M.error(failure)
    else
      M.notify(success)
    end
  end
end

---@param device devices.Device
---@return string
function M.label(device)
  local icon = Device.is_ready(device) and "●" or "○"
  local text = icon .. " " .. Device.label(device)
  if device.detail then
    text = text .. "  ⚠ " .. device.detail
  end
  return text
end

--- Pick a device from a fresh list.
---@param opts? { prompt?: string, filter?: fun(device: devices.Device): boolean }
---@param cb fun(device: devices.Device?)
function M.pick(opts, cb)
  opts = opts or {}
  require("devices").list(function(devices, failures)
    for _, failure in ipairs(failures) do
      -- A missing tool for one platform is normal; say it once, quietly.
      M.notify(errors.format(failure), failure.code == "tool_missing" and vim.log.levels.WARN or vim.log.levels.ERROR)
    end
    if opts.filter then
      devices = vim.tbl_filter(opts.filter, devices)
    end
    if #devices == 0 then
      M.notify("No devices found. Run :checkhealth devices to see what is missing.", vim.log.levels.WARN)
      return cb(nil)
    end
    vim.ui.select(devices, { prompt = opts.prompt or "Device", format_item = M.label, kind = "devices" }, cb)
  end)
end

local ACTION_LABELS = {
  boot = "Boot",
  cold_boot = "Cold boot (ignore the saved state)",
  wipe = "Wipe data and boot",
  shutdown = "Shut down",
  erase = "Erase content and settings",
  delete = "Delete",
  logs = "Logs",
  disconnect = "Disconnect (Wi-Fi)",
  copy_id = "Copy id",
}

---@param prompt string
---@param cb fun()
local function confirm(prompt, cb)
  vim.ui.select({ "No", "Yes" }, { prompt = prompt }, function(choice)
    if choice == "Yes" then
      cb()
    end
  end)
end

--- Run a built-in action on a device.
---@param id string
---@param device devices.Device
function M.run_action(id, device)
  local devices = require("devices")
  if id == "boot" or id == "cold_boot" then
    M.notify(("Starting %s..."):format(device.name))
    devices.boot(device, { cold = id == "cold_boot" }, M.report(device.name .. " is starting"))
  elseif id == "wipe" then
    confirm(("Erase all data on %s?"):format(device.name), function()
      devices.erase(device, M.report(device.name .. " is starting with its data wiped"))
    end)
  elseif id == "erase" then
    confirm(("Erase all content and settings of %s?"):format(device.name), function()
      devices.erase(device, M.report(device.name .. " was erased"))
    end)
  elseif id == "delete" then
    confirm(("Delete %s? This cannot be undone."):format(device.name), function()
      devices.delete(device, M.report(device.name .. " was deleted"))
    end)
  elseif id == "shutdown" then
    devices.shutdown(device, M.report(device.name .. " is shutting down"))
  elseif id == "disconnect" then
    android.disconnect(device, config.android(), M.report(device.name .. " was disconnected"))
  elseif id == "logs" then
    M.logs(device)
  elseif id == "copy_id" then
    local target = devices.target_id(device)
    vim.fn.setreg('"', target)
    pcall(vim.fn.setreg, "+", target)
    M.notify("Copied " .. target)
  end
end

--- The action menu for one device: built-in actions, then the user's own.
---@param device devices.Device
function M.actions(device)
  local items = {}
  for _, id in ipairs(require("devices").actions(device)) do
    items[#items + 1] = {
      label = ACTION_LABELS[id],
      run = function()
        M.run_action(id, device)
      end,
    }
  end
  for _, action in ipairs(config.options.actions) do
    local ok, wanted = pcall(function()
      return not action.when or action.when(device)
    end)
    if ok and wanted then
      items[#items + 1] = {
        label = action.name,
        run = function()
          local ran, problem = pcall(action.run, device)
          if not ran then
            M.notify(action.name .. " failed: " .. tostring(problem), vim.log.levels.ERROR)
          end
        end,
      }
    end
  end
  vim.ui.select(items, {
    prompt = device.name,
    format_item = function(item)
      return item.label
    end,
  }, function(item)
    if item then
      item.run()
    end
  end)
end

--- Pick a device, then an action for it.
function M.main()
  M.pick({}, function(device)
    if device then
      M.actions(device)
    end
  end)
end

--- Ask which log to open for a device, and for which app.
---@param device devices.Device
---@param preset? { mode?: devices.LogMode, app?: string }
function M.logs(device, preset)
  preset = preset or {}
  local logs = require("devices.logs")
  local modes = logs.modes(device)
  if #modes == 0 then
    return M.notify(device.name .. " is not running. Boot or connect it first.", vim.log.levels.WARN)
  end

  local function with_mode(mode)
    local function open(app)
      require("devices").logs(device, { mode = mode.id, app = app })
    end
    if preset.app or mode.app == "never" then
      return open(preset.app)
    end
    local what = device.platform == "android" and "package (com.example.app)" or "bundle id (com.example.app)"
    local prompt = mode.app == "required" and ("App " .. what .. ": ")
      or ("Only one app? " .. what .. ", empty for all: ")
    vim.ui.input({ prompt = prompt, default = vim.g.devices_last_app or "" }, function(input)
      if input == nil then
        return
      end
      input = vim.trim(input)
      if input == "" then
        if mode.app == "required" then
          return M.notify("An app id is needed to launch the app.", vim.log.levels.WARN)
        end
        return open(nil)
      end
      if not logs.valid_app_id(input) then
        return M.notify("That does not look like an app id: " .. input, vim.log.levels.ERROR)
      end
      vim.g.devices_last_app = input
      open(input)
    end)
  end

  if preset.mode then
    for _, mode in ipairs(modes) do
      if mode.id == preset.mode then
        return with_mode(mode)
      end
    end
    return M.notify(("%s has no %s log"):format(device.name, preset.mode), vim.log.levels.ERROR)
  end
  if #modes == 1 then
    return with_mode(modes[1])
  end
  vim.ui.select(modes, {
    prompt = "Log",
    format_item = function(mode)
      return mode.label
    end,
  }, function(mode)
    if mode then
      with_mode(mode)
    end
  end)
end

-- Creating devices ----------------------------------------------------------------------------

---@param default string
---@param cb fun(name: string)
local function ask_name(default, cb)
  vim.ui.input({ prompt = "Name: ", default = default }, function(name)
    if name and vim.trim(name) ~= "" then
      cb(vim.trim(name))
    end
  end)
end

function M.create_ios()
  ios.runtimes(function(runtimes, failure)
    if failure then
      return M.error(failure)
    end
    if #runtimes == 0 then
      return M.notify(
        "No iOS runtime is installed. Install one in Xcode > Settings > Components, or run: xcodebuild -downloadPlatform iOS",
        vim.log.levels.WARN
      )
    end
    vim.ui.select(runtimes, {
      prompt = "iOS version",
      format_item = function(r)
        return r.name
      end,
    }, function(runtime)
      if not runtime then
        return
      end
      vim.ui.select(runtime.device_types, {
        prompt = "Device",
        format_item = function(t)
          return t.name
        end,
      }, function(device_type)
        if not device_type then
          return
        end
        ask_name(device_type.name, function(name)
          ios.create({ name = name, device_type = device_type.id, runtime = runtime.id }, function(_, create_error)
            if create_error then
              return M.error(create_error)
            end
            M.notify(("Created %s (%s)"):format(name, runtime.name))
          end)
        end)
      end)
    end)
  end)
end

function M.create_android()
  local opts = config.android()
  local images = android.system_images(opts)
  if #images == 0 then
    return M.notify(
      "No Android system image for this machine is installed. Install one in Android Studio > SDK Manager, "
        .. 'or: sdkmanager "system-images;android-36;google_apis_playstore;'
        .. (env.arch() == "arm64" and "arm64-v8a" or "x86_64")
        .. '"',
      vim.log.levels.WARN
    )
  end
  vim.ui.select(images, {
    prompt = "System image",
    format_item = function(image)
      return image.label
    end,
  }, function(image)
    if not image then
      return
    end
    M.notify("Reading device profiles...")
    android.device_types(opts, function(types, failure)
      if failure then
        return M.error(failure)
      end
      vim.ui.select(types, { prompt = "Device profile" }, function(device_type)
        if not device_type then
          return
        end
        local default = ("%s_API_%s"):format(device_type:gsub("[^%w]", "_"), image.api:gsub("[^%w]", "_"))
        ask_name(default, function(name)
          M.notify("Creating " .. name .. "...")
          android.create(
            { name = name, image = image.id, device_type = device_type },
            opts,
            M.report("Created " .. name)
          )
        end)
      end)
    end)
  end)
end

function M.create()
  local choices = { "Android emulator" }
  if env.os() == "macos" then
    table.insert(choices, 1, "iOS simulator")
  end
  vim.ui.select(choices, { prompt = "Create" }, function(choice)
    if choice == "iOS simulator" then
      M.create_ios()
    elseif choice == "Android emulator" then
      M.create_android()
    end
  end)
end

-- Wireless Android ----------------------------------------------------------------------------

function M.connect()
  local opts = config.android()
  vim.ui.select({ "Connect (already paired)", "Pair with a code, then connect" }, {
    prompt = "Android over Wi-Fi",
  }, function(choice)
    if not choice then
      return
    end
    local function connect()
      vim.ui.input({ prompt = "Address shown under Wireless debugging (ip:port): " }, function(address)
        if not address or vim.trim(address) == "" then
          return
        end
        android.connect(vim.trim(address), opts, M.report("Connected to " .. vim.trim(address)))
      end)
    end
    if choice:match("^Connect") then
      return connect()
    end
    vim.ui.input({ prompt = "Pairing address (ip:port from 'Pair device with pairing code'): " }, function(address)
      if not address or vim.trim(address) == "" then
        return
      end
      vim.ui.input({ prompt = "Six-digit pairing code: " }, function(code)
        if not code then
          return
        end
        android.pair(vim.trim(address), vim.trim(code), opts, function(failure)
          if failure then
            return M.error(failure)
          end
          M.notify("Paired. Now enter the connect address (it has a different port).")
          connect()
        end)
      end)
    end)
  end)
end

-- Release log check ---------------------------------------------------------------------------

---@param root? string
function M.audit(root)
  local report = require("devices").audit(root)
  local lines = require("devices.audit").format(report)
  local items = {}
  for _, f in ipairs(report.findings) do
    items[#items + 1] = {
      filename = report.root .. "/" .. f.file,
      lnum = f.line,
      type = f.severity == "error" and "E" or (f.severity == "warning" and "W" or "I"),
      text = f.message .. (f.hint and (" " .. f.hint) or ""),
    }
  end
  if #items > 0 then
    vim.fn.setqflist({}, " ", { title = "Release log check", items = items })
    vim.cmd("copen")
  end
  M.notify(table.concat(lines, "\n"), #items > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
end

return M
