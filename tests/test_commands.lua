local h = require("helpers")
local eq = h.eq

local commands = require("devices.commands")
local config = require("devices.config")
local devices = require("devices")

local T = {}

T["parse: no arguments opens the picker"] = function()
  eq(commands.parse({}), { flags = {}, keys = {} })
end

T["parse: a device name with spaces, flags and keys"] = function()
  local p = commands.parse({ "boot", "iPhone", "16", "Pro", "--cold" })
  eq(p.sub, "boot")
  eq(p.query, "iPhone 16 Pro")
  eq(p.flags, { cold = true })
  eq(p.error, nil)
  local l = commands.parse({ "logs", "Pixel_9a", "app=com.example.app", "mode=logcat" })
  eq(l.query, "Pixel_9a")
  eq(l.keys, { app = "com.example.app", mode = "logcat" })
end

T["parse: mistakes are reported, not guessed"] = function()
  eq(commands.parse({ "launch" }).error, "Unknown subcommand: launch")
  eq(commands.parse({ "shutdown", "--cold" }).error, "shutdown does not take --cold")
  eq(commands.parse({ "boot", "--cold", "--wipe" }).error, "Use --cold or --wipe, not both")
  -- A key a subcommand does not know is part of the name.
  eq(commands.parse({ "boot", "app=x" }).query, "app=x")
end

T["complete: subcommands, then options and recent device names"] = function()
  commands.recent = { "iPhone\\ 16", "Pixel_9a" }
  eq(commands.complete("bo", "Devices bo"), { "boot" })
  eq(#commands.complete("", "Devices "), vim.tbl_count(commands.subcommands))
  eq(commands.complete("", "Devices boot "), { "--cold", "--wipe", "iPhone\\ 16", "Pixel_9a" })
  eq(commands.complete("P", "Devices logs P"), { "Pixel_9a" })
  eq(commands.complete("a", "Devices logs a"), { "app=" })
  eq(commands.complete("", "Devices create "), {})
  eq(commands.complete("", "Devices nope "), {})
end

T["config: defaults, merging, and lists that replace instead of merge"] = function()
  config.setup({ logs = { open = "tab" }, android = { emulator_args = { "-gpu", "host" } } })
  eq(config.options.logs.open, "tab")
  eq(config.options.logs.max_lines, config.defaults.logs.max_lines)
  eq(config.options.android.emulator_args, { "-gpu", "host" })
  config.setup({})
  eq(config.options.android.emulator_args, {})
  eq(config.options, config.defaults)
end

T["config: wrong types fail loudly, naming the option"] = function()
  local function message(opts)
    local ok, e = pcall(config.setup, opts)
    eq(ok, false)
    return tostring(e)
  end
  eq(message({ logs = { open = "float" } }):find("logs.open", 1, true) ~= nil, true)
  eq(message({ android = { sdk = 5 } }):find("android.sdk", 1, true) ~= nil, true)
  eq(message({ on_boot = "yes" }):find("on_boot", 1, true) ~= nil, true)
  eq(message({ actions = { { name = "x" } } }):find("actions[1].run", 1, true) ~= nil, true)
  config.setup({})
end

local function dev(fields)
  return vim.tbl_extend("force", { platform = "android", source = "emulator", id = "X", name = "X" }, fields)
end

T["actions: depend on the kind of device and its state"] = function()
  eq(devices.actions(dev({ kind = "emulator", state = "shutdown" })), {
    "boot",
    "cold_boot",
    "wipe",
    "delete",
    "copy_id",
  })
  eq(devices.actions(dev({ kind = "emulator", state = "booted", serial = "emulator-5554" })), {
    "logs",
    "shutdown",
    "copy_id",
  })
  eq(devices.actions(dev({ platform = "ios", kind = "simulator", state = "shutdown" })), {
    "boot",
    "erase",
    "delete",
    "copy_id",
  })
  eq(devices.actions(dev({ kind = "physical", state = "connected", transport = "wifi", source = "adb" })), {
    "logs",
    "disconnect",
    "copy_id",
  })
  eq(devices.actions(dev({ kind = "physical", state = "unauthorized", transport = "usb", source = "adb" })), {
    "copy_id",
  })
end

T["target id: a running emulator's adb serial, else the id"] = function()
  eq(devices.target_id(dev({ kind = "emulator", serial = "emulator-5554", id = "Pixel_9a" })), "emulator-5554")
  eq(devices.target_id(dev({ kind = "emulator", id = "Pixel_9a" })), "Pixel_9a")
  eq(devices.target_id(dev({ platform = "ios", kind = "simulator", id = "UDID" })), "UDID")
end

T["boot: on_boot runs after a boot, not for a device that was already running"] = function()
  local android = require("devices.backend.android")
  local saved = { boot = android.boot, wait = android.wait_booted, list = devices.list }
  local function later(_, _, cb)
    vim.schedule(function()
      cb(nil)
    end)
  end
  android.boot, android.wait_booted = later, later
  devices.list = function(cb)
    cb({}, {})
  end
  local hooked = {}
  config.setup({
    on_boot = function(d)
      hooked[#hooked + 1] = d.state
    end,
  })
  local ok, problem = pcall(function()
    local function boot(state)
      local done = false
      devices.boot(dev({ id = "Pixel_9a", kind = "emulator", state = state }), {}, function()
        done = true
      end)
      assert(vim.wait(2000, function()
        return done
      end, 10))
      vim.wait(100)
    end
    boot("shutdown")
    eq(hooked, { "shutdown" })
    boot("booted")
    eq(hooked, { "shutdown" })
  end)
  android.boot, android.wait_booted, devices.list = saved.boot, saved.wait, saved.list
  config.setup({})
  assert(ok, problem)
end

T["find: by id, serial, exact name, any case, or a unique part"] = function()
  local list = {
    dev({ id = "Pixel_9a", name = "Pixel 9a", kind = "emulator", serial = "emulator-5554" }),
    dev({ id = "Pixel_9_Pro", name = "Pixel 9 Pro", kind = "emulator" }),
    dev({ platform = "ios", id = "U-1", name = "iPhone 16", kind = "simulator" }),
    dev({ platform = "ios", id = "U-2", name = "iPhone 16 Pro", kind = "simulator" }),
    dev({ id = "Test_A", name = "Test", kind = "emulator" }),
    dev({ id = "Test_B", name = "test", kind = "emulator" }),
  }
  local original = devices.list
  devices.list = function(cb)
    cb(list, {})
  end
  local ok, problem = pcall(function()
    local function find(q)
      local found, failure
      devices.find(q, function(d, e)
        found, failure = d, e
      end)
      return found and found.id, failure and failure.code
    end
    eq({ find("emulator-5554") }, { "Pixel_9a" })
    eq({ find("Pixel_9_Pro") }, { "Pixel_9_Pro" })
    -- An exact name wins over a longer name that contains it.
    eq({ find("iPhone 16") }, { "U-1" })
    eq({ find("iphone 16 pro") }, { "U-2" })
    eq({ find("9a") }, { "Pixel_9a" })
    eq({ find("Pixel") }, { nil, "not_found" })
    eq({ find("Galaxy") }, { nil, "not_found" })
    -- Names that differ only in case: the exact one wins, any other case is ambiguous.
    eq({ find("Test") }, { "Test_A" })
    eq({ find("test") }, { "Test_B" })
    eq({ find("TEST") }, { nil, "not_found" })
  end)
  devices.list = original
  assert(ok, problem)
end

return T
