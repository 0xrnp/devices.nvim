local h = require("helpers")
local eq, await = h.eq, h.await

local android = require("devices.backend.android")
local fake_android = require("fake_android")

local PIXEL = { ["avd.ini.displayname"] = "Pixel 9a", ["hw.device.name"] = "pixel_9a" }

local function new_fake(opts)
  return fake_android.new(
    vim.tbl_extend("force", { avds = { "Pixel_9a" }, configs = { Pixel_9a = PIXEL } }, opts or {})
  )
end

--- list() returning (devices, errors).
local function list(fake, extra)
  local devices, errors
  await(function(cb)
    android.list(fake.opts(extra), function(d, e)
      devices, errors = d, e
      cb(true)
    end)
  end)
  return devices, errors
end

local function avd(fake, name)
  for _, d in ipairs((list(fake))) do
    if d.id == name then
      return d
    end
  end
end

local T = {}

T["list: AVDs with their display names and versions"] = function()
  local fake = new_fake()
  h.with_env(fake.env(), function()
    local devices, errors = list(fake)
    eq(errors, {})
    eq(#devices, 1)
    eq(devices[1].name, "Pixel 9a")
    eq(devices[1].os_version, "16")
    eq(devices[1].state, "shutdown")
  end)
end

T["list: an empty display name falls back to the AVD name"] = function()
  local fake = new_fake({ configs = { Pixel_9a = { ["avd.ini.displayname"] = "", ["hw.device.name"] = "" } } })
  h.with_env(fake.env(), function()
    local devices, errors = list(fake)
    eq(errors, {})
    eq(devices[1].name, "Pixel 9a")
    eq(devices[1].model, nil)
  end)
end

T["list: a running emulator and a phone, each asked for details"] = function()
  local fake = new_fake({
    adb_devices = {
      "emulator-5554\tdevice product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1",
      "R5CT1234567\tdevice product:husky model:Pixel_8_Pro device:husky transport_id:2",
    },
  })
  fake.write("avd_emulator-5554", { "Pixel_9a" })
  fake.write("booted_emulator-5554", { "1" })
  h.with_env(fake.env({ FAKE_RELEASE = "15" }), function()
    local devices, errors = list(fake)
    eq(errors, {})
    eq(#devices, 2)
    local phone, emu = devices[1], devices[2]
    eq(phone.name, "Pixel 8 Pro")
    eq(phone.state, "connected")
    eq(phone.os_version, "15")
    eq(emu.id, "Pixel_9a")
    eq(emu.state, "booted")
    eq(emu.serial, "emulator-5554")
  end)
end

T["list: a missing adb still lists the AVDs, and says how to install adb"] = function()
  local fake = new_fake()
  vim.fn.delete(fake.root .. "/sdk/platform-tools", "rf")
  h.with_env(fake.env(), function()
    local devices, errors = list(fake)
    eq(#devices, 1)
    eq(#errors, 1)
    eq(errors[1].code, "tool_missing")
    eq(errors[1].hint:find("platform-tools", 1, true) ~= nil, true)
  end)
end

T["list: a failing adb does not hide the AVDs"] = function()
  local fake = new_fake()
  h.with_env(fake.env({ FAKE_ADB_FAIL = "1" }), function()
    local devices, errors = list(fake)
    eq(#devices, 1)
    eq(errors[1].code, "command_failed")
  end)
end

T["boot: starts the emulator detached and returns once it stays up"] = function()
  local fake = new_fake()
  h.with_env(fake.env(), function()
    local e = await(function(cb)
      android.boot(avd(fake, "Pixel_9a"), fake.opts({ cold = true, headless = true, args = { "-gpu", "host" } }), cb)
    end)
    fake.kill_emulator()
    eq(e, nil)
    local call = vim.tbl_filter(function(c)
      return c[1] == "emulator" and c[2] == "-avd"
    end, fake.calls())[1]
    eq(call, { "emulator", "-avd", "Pixel_9a", "-no-snapshot-load", "-no-window", "-gpu", "host" })
  end)
end

T["boot: wipe asks for -wipe-data"] = function()
  local fake = new_fake()
  h.with_env(fake.env(), function()
    await(function(cb)
      android.boot(avd(fake, "Pixel_9a"), fake.opts({ wipe = true }), cb)
    end)
    fake.kill_emulator()
    local call = vim.tbl_filter(function(c)
      return c[1] == "emulator" and c[2] == "-avd"
    end, fake.calls())[1]
    eq(call, { "emulator", "-avd", "Pixel_9a", "-wipe-data" })
  end)
end

T["boot: an emulator that dies at once is an error with the reason from its log"] = function()
  local fake = new_fake()
  h.with_env(fake.env({ FAKE_EMULATOR = "die" }), function()
    local e = await(function(cb)
      android.boot(avd(fake, "Pixel_9a"), fake.opts(), cb)
    end)
    eq(e.code, "command_failed")
    eq(e.message:find("Unknown AVD name", 1, true) ~= nil, true)
    eq(e.hint:find("Full log", 1, true) ~= nil, true)
  end)
end

T["boot: running already is a success, but cold boot or wipe is refused"] = function()
  local fake = new_fake()
  local running = {
    id = "Pixel_9a",
    name = "Pixel 9a",
    platform = "android",
    kind = "emulator",
    state = "booted",
    serial = "emulator-5554",
    source = "emulator",
  }
  h.with_env(fake.env(), function()
    eq(
      await(function(cb)
        android.boot(running, fake.opts(), cb)
      end),
      nil
    )
    local e = await(function(cb)
      android.boot(running, fake.opts({ wipe = true }), cb)
    end)
    eq(e.code, "invalid_state")
    eq(e.hint, "Shut it down first.")
    eq(fake.calls(), {})
  end)
end

T["boot: refuses a phone and runs nothing"] = function()
  local fake = new_fake()
  h.with_env(fake.env(), function()
    local e = await(function(cb)
      android.boot({
        id = "R5CT",
        name = "Phone",
        platform = "android",
        kind = "physical",
        state = "connected",
        source = "adb",
      }, fake.opts(), cb)
    end)
    eq(e.code, "unsupported")
    eq(fake.calls(), {})
  end)
end

T["boot then wait: calls back once Android reports it booted"] = function()
  local fake = new_fake()
  h.with_env(fake.env(), function()
    local e = await(function(cb)
      android.boot(avd(fake, "Pixel_9a"), fake.opts({ wait = true, grace_ms = 200 }), cb)
    end, 20000)
    fake.kill_emulator()
    eq(e, nil)
  end)
end

T["shutdown: asks the running emulator to stop; a stopped one is a success"] = function()
  local fake = new_fake({ adb_devices = { "emulator-5554\tdevice transport_id:1" } })
  fake.write("avd_emulator-5554", { "Pixel_9a" })
  fake.write("booted_emulator-5554", { "1" })
  h.with_env(fake.env(), function()
    local device = avd(fake, "Pixel_9a")
    eq(device.state, "booted")
    eq(
      await(function(cb)
        android.shutdown(device, fake.opts(), cb)
      end),
      nil
    )
    eq(avd(fake, "Pixel_9a").state, "shutdown")
    local before = #fake.calls()
    eq(
      await(function(cb)
        android.shutdown(avd(fake, "Pixel_9a"), fake.opts(), cb)
      end),
      nil
    )
    -- Listing ran, but nothing was sent to a device: no emulator is running.
    local device_calls = vim.tbl_filter(function(c)
      return c[1] == "adb" and c[2] == "-s"
    end, vim.list_slice(fake.calls(), before + 1))
    eq(device_calls, {})
  end)
end

T["system images: only complete ones this machine runs natively, newest first"] = function()
  local fake = new_fake()
  local arm = android.system_images(fake.opts({ arch = "arm64" }))
  eq(
    vim.tbl_map(function(i)
      return i.id
    end, arm),
    {
      "system-images;android-36;google_apis_playstore;arm64-v8a",
      "system-images;android-35;google_apis;arm64-v8a",
    }
  )
  eq(arm[1].label, "Android 16 (API 36) · google_apis_playstore · arm64-v8a")
  local intel = android.system_images(fake.opts({ arch = "x86_64" }))
  eq(#intel, 1)
  eq(intel[1].abi, "x86_64")
end

T["create: runs avdmanager with the JDK, answers its prompt, and the AVD appears"] = function()
  local fake = new_fake()
  h.with_env(fake.env(), function()
    local e = await(function(cb)
      android.create(
        { name = "Test_Phone", image = "system-images;android-36;google_apis;arm64-v8a", device_type = "pixel_9" },
        fake.opts(),
        cb
      )
    end)
    eq(e, nil)
    eq(fake.read("avdmanager_stdin"), { "no" })
    eq(fake.read("avdmanager_env"), { "JAVA_HOME=" .. fake.root .. "/jdk" })
    local call = vim.tbl_filter(function(c)
      return c[1] == "avdmanager"
    end, fake.calls())[1]
    eq(call, {
      "avdmanager",
      "create",
      "avd",
      "-n",
      "Test_Phone",
      "-k",
      "system-images;android-36;google_apis;arm64-v8a",
      "-d",
      "pixel_9",
    })
    local names = vim.tbl_map(function(d)
      return d.id
    end, (list(fake)))
    eq(vim.tbl_contains(names, "Test_Phone"), true)
  end)
end

T["create: an error printed with exit code 0 is still an error"] = function()
  local fake = new_fake()
  h.with_env(fake.env({ FAKE_AVDMANAGER_ERROR = "1", FAKE_AVDMANAGER_EXIT = "0" }), function()
    local e = await(function(cb)
      android.create({ name = "X", image = "bad" }, fake.opts(), cb)
    end)
    eq(e.code, "command_failed")
    eq(e.message:find("Package path is not valid", 1, true) ~= nil, true)
  end)
end

T["create: a bad name is refused before anything runs"] = function()
  local fake = new_fake()
  h.with_env(fake.env(), function()
    local e = await(function(cb)
      android.create({ name = "my phone; rm", image = "x" }, fake.opts(), cb)
    end)
    eq(e.code, "invalid_state")
    eq(fake.calls(), {})
  end)
end

T["create: no Java is a clear error"] = function()
  local fake = new_fake()
  h.with_env(fake.env(), function()
    local e = await(function(cb)
      android.create({ name = "X", image = "x" }, fake.opts({ java_home = "/no/jdk" }), cb)
    end)
    eq(e.code, "tool_missing")
    eq(e.message:find("Java", 1, true) ~= nil, true)
  end)
end

T["device types: avdmanager's profile ids"] = function()
  local fake = new_fake()
  h.with_env(fake.env(), function()
    local ids
    await(function(cb)
      android.device_types(fake.opts(), function(list_of_ids, e)
        eq(e, nil)
        ids = list_of_ids
        cb(true)
      end)
    end)
    eq(ids, { "pixel_9", "pixel_9a", "medium_phone" })
  end)
end

T["delete: removes a stopped AVD and refuses a running one"] = function()
  local fake = new_fake()
  h.with_env(fake.env(), function()
    local device = avd(fake, "Pixel_9a")
    local running = vim.tbl_extend("force", device, { state = "booted", serial = "emulator-5554" })
    local e = await(function(cb)
      android.delete(running, fake.opts(), cb)
    end)
    eq(e.code, "invalid_state")
    eq(
      await(function(cb)
        android.delete(device, fake.opts(), cb)
      end),
      nil
    )
    eq(#list(fake), 0)
  end)
end

T["wifi: connect reads adb's output, since adb exits 0 either way"] = function()
  local fake = new_fake()
  h.with_env(fake.env(), function()
    eq(
      await(function(cb)
        android.connect("192.168.1.20:5555", fake.opts(), cb)
      end),
      nil
    )
    local e = await(function(cb)
      android.connect("192.168.1.20:4444", fake.opts(), cb)
    end)
    eq(e.code, "command_failed")
    eq(e.message:find("Connection refused", 1, true) ~= nil, true)
  end)
end

T["wifi: pairing checks the code format and adb's answer"] = function()
  local fake = new_fake()
  h.with_env(fake.env(), function()
    eq(
      await(function(cb)
        android.pair("192.168.1.20:37000", "123456", fake.opts(), cb)
      end),
      nil
    )
    eq(
      await(function(cb)
        android.pair("192.168.1.20:37000", "654321", fake.opts(), cb)
      end).code,
      "command_failed"
    )
    local before = #fake.calls()
    eq(
      await(function(cb)
        android.pair("192.168.1.20:37000", "12ab", fake.opts(), cb)
      end).code,
      "invalid_state"
    )
    eq(
      await(function(cb)
        android.connect("not an address", fake.opts(), cb)
      end).code,
      "invalid_state"
    )
    eq(#fake.calls(), before)
  end)
end

return T
