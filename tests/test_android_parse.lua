local h = require("helpers")
local eq = h.eq

local android = require("devices.backend.android")

local T = {}

T["avd names: skips the emulator's log lines and blanks"] = function()
  local text = table.concat({
    "INFO    | Storing crashdata in: /tmp/android-x/emu-crash-36.1.9.db, detection is enabled for process: 1234",
    "Pixel_9_Pro",
    "",
    "Pixel_9a",
    "  Medium_Phone_API_35  ",
    "WARNING | some warning",
  }, "\n")
  eq(android.parse_avd_names(text), { "Pixel_9_Pro", "Pixel_9a", "Medium_Phone_API_35" })
end

T["avd names: CRLF output and nothing at all"] = function()
  eq(android.parse_avd_names("A\r\nB\r\n"), { "A", "B" })
  eq(android.parse_avd_names(""), {})
end

T["adb devices: the real -l format"] = function()
  local text = table.concat({
    "* daemon not running; starting now at tcp:5037",
    "* daemon started successfully",
    "List of devices attached",
    "emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1",
    "R5CT1234567            unauthorized usb:1-1 transport_id:3",
    "192.168.1.20:5555      offline product:husky model:Pixel_8_Pro device:husky transport_id:4",
    "0A1B2C3D               no permissions (missing udev rules? user is in the plugdev group); see [http://developer.android.com/tools/device.html] usb:1-2 transport_id:5",
    "",
  }, "\n")
  local entries = android.parse_adb_devices(text)
  eq(#entries, 4)
  eq(entries[1].serial, "emulator-5554")
  eq(entries[1].state, "device")
  eq(entries[1].props.model, "sdk_gphone64_arm64")
  eq(entries[1].props.transport_id, "1")
  eq(entries[2].state, "unauthorized")
  eq(entries[3].state, "offline")
  eq(entries[3].props.model, "Pixel_8_Pro")
  eq(entries[4].state, "no permissions")
  eq(entries[4].props.usb, "1-2")
end

T["adb devices: no devices"] = function()
  eq(android.parse_adb_devices("List of devices attached\n\n"), {})
end

T["serial kinds"] = function()
  eq(android.is_emulator_serial("emulator-5554"), true)
  eq(android.is_emulator_serial("emulator-"), false)
  eq(android.is_wifi_serial("192.168.1.20:5555"), true)
  eq(android.is_wifi_serial("adb-R5CT123-AbCdEf._adb-tls-connect._tcp"), true)
  eq(android.is_wifi_serial("R5CT1234567"), false)
  eq(android.is_wifi_serial("emulator-5554"), false)
end

T["release names by API level"] = function()
  eq(android.release_for_api("36"), "16")
  eq(android.release_for_api(32), "12L")
  eq(android.release_for_api("99"), "API 99")
  eq(android.release_for_api(nil), nil)
  eq(android.release_for_api("Baklava"), nil)
end

local function entry(serial, state, model)
  return { serial = serial, state = state, props = { model = model } }
end

T["combine: an AVD is linked to the emulator running it"] = function()
  local devices = android.combine(
    { "Pixel_9a", "Pixel_9_Pro" },
    { entry("emulator-5554", "device", "sdk_gphone64_arm64") },
    { ["emulator-5554"] = { avd = "Pixel_9a", booted = true, release = "16" } },
    { avd_home = "/nowhere" }
  )
  eq(#devices, 2)
  local a9 = devices[1]
  eq(a9.id, "Pixel_9a")
  eq(a9.kind, "emulator")
  eq(a9.state, "booted")
  eq(a9.serial, "emulator-5554")
  eq(a9.source, "emulator")
  eq(devices[2].state, "shutdown")
  eq(devices[2].serial, nil)
end

T["combine: an emulator that has not finished booting"] = function()
  local devices = android.combine(
    { "Pixel_9a" },
    { entry("emulator-5554", "device") },
    { ["emulator-5554"] = { avd = "Pixel_9a", booted = false } },
    { avd_home = "/nowhere" }
  )
  eq(devices[1].state, "booting")
end

T["combine: an emulator whose AVD is unknown is still listed"] = function()
  local devices = android.combine({}, { entry("emulator-5556", "device") }, {}, { avd_home = "/nowhere" })
  eq(#devices, 1)
  eq(devices[1].id, "emulator-5556")
  eq(devices[1].kind, "emulator")
  eq(devices[1].source, "adb")
  eq(devices[1].state, "booted")
end

T["combine: physical phones over USB and Wi-Fi, with advice for bad states"] = function()
  local devices = android.combine({}, {
    entry("R5CT1234567", "device", "Pixel_8_Pro"),
    entry("192.168.1.20:5555", "device", "Pixel_7"),
    entry("R5CT0000000", "unauthorized"),
    entry("0A1B2C3D", "no permissions"),
    entry("R5CT1111111", "offline", "Pixel_6"),
    entry("R5CT2222222", "recovery"),
  }, { ["R5CT1234567"] = { release = "15" } }, { avd_home = "/nowhere" })
  eq(#devices, 6)
  eq(devices[1].name, "Pixel 8 Pro")
  eq(devices[1].state, "connected")
  eq(devices[1].transport, "usb")
  eq(devices[1].os_version, "15")
  eq(devices[2].transport, "wifi")
  eq(devices[3].state, "unauthorized")
  eq(devices[3].name, "R5CT0000000")
  eq(devices[3].detail:find("USB debugging", 1, true) ~= nil, true)
  eq(devices[4].state, "unauthorized")
  eq(devices[4].detail:find("udev", 1, true) ~= nil, true)
  eq(devices[5].state, "offline")
  eq(devices[6].state, "unknown")
end

T["avd info: reads the display name, API level and device profile"] = function()
  local root = h.tree({
    ["avd/Pixel_9a.ini"] = "avd.ini.encoding=UTF-8\npath=/moved/elsewhere\ntarget=android-36",
    ["avd/Pixel_9a.avd/config.ini"] = table.concat({
      "avd.ini.displayname=Pixel 9a",
      "hw.device.name=pixel_9a",
      "abi.type=arm64-v8a",
      "tag.id=google_apis_playstore",
      "image.sysdir.1=system-images/android-36/google_apis_playstore/arm64-v8a/",
    }, "\n"),
  })
  -- The pointer's path does not exist, so the default location is used.
  local info = android.avd_info("Pixel_9a", { avd_home = root .. "/avd" })
  eq(info.display_name, "Pixel 9a")
  eq(info.api, "36")
  eq(info.device_type, "pixel_9a")
  eq(info.abi, "arm64-v8a")
end

T["avd info: missing files give empty info, never an error"] = function()
  eq(android.avd_info("Nope", { avd_home = "/does/not/exist" }), {})
end

T["avd home: follows the emulator's environment variables"] = function()
  h.with_env(h.isolated({ ANDROID_AVD_HOME = "/a/avd" }), function()
    eq(android.avd_home(), "/a/avd")
  end)
  h.with_env(h.isolated({ ANDROID_USER_HOME = "/u" }), function()
    eq(android.avd_home(), "/u/avd")
  end)
  h.with_env(h.isolated({ ANDROID_SDK_HOME = "/s" }), function()
    eq(android.avd_home(), "/s/.android/avd")
  end)
  eq(android.avd_home({ avd_home = "/opt" }), "/opt")
end

T["names and addresses are validated before any command runs"] = function()
  eq(android.valid_avd_name("Pixel_9a"), true)
  eq(android.valid_avd_name("my phone"), false)
  eq(android.valid_avd_name("-rf"), false)
  eq(android.valid_avd_name(""), false)
  eq(android.valid_address("192.168.1.20:37123"), true)
  eq(android.valid_address("[fe80::1]:5555"), true)
  eq(android.valid_address("192.168.1.20"), false)
  eq(android.valid_address("host:port; rm -rf"), false)
end

return T
