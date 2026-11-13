--- A fake Android SDK: `emulator`, `adb` and `avdmanager` that print what the real tools print
--- (recorded from emulator 36 and platform-tools 37), with state kept in files so a test can
--- start, list and stop emulators.
local h = require("helpers")

local M = {}

local PRELUDE = [[#!/bin/sh
PATH="/usr/bin:/bin:$PATH"
printf '%s\n' "$(basename "$0")" "$@" >> "$FAKE_STATE/calls.log"
echo '--' >> "$FAKE_STATE/calls.log"
]]

local EMULATOR = PRELUDE
  .. [==[
if [ "$1" = "-list-avds" ]; then
  # Newer emulators print log lines on stdout too.
  echo "INFO    | Storing crashdata in: /tmp/android-x/emu-crash.db"
  cat "$FAKE_STATE/avds"
  exit 0
fi
if [ "$1" = "-avd" ]; then
  case "$FAKE_EMULATOR" in
    die)
      echo "INFO    | Android emulator version 36.1.9.0"
      echo "ERROR   | Unknown AVD name [$2], use -list-avds to see valid list."
      exit 1 ;;
    *)
      # Becomes emulator-5554 for adb, running the AVD it was given.
      printf 'emulator-5554\tdevice product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1\n' >> "$FAKE_STATE/adb_devices"
      echo "$2" > "$FAKE_STATE/avd_emulator-5554"
      echo 1 > "$FAKE_STATE/booted_emulator-5554"
      echo $$ > "$FAKE_STATE/emulator.pid"
      exec sleep 30 ;;
  esac
fi
exit 1
]==]

local ADB = PRELUDE
  .. [==[
if [ "$1" = "devices" ]; then
  [ -n "$FAKE_ADB_FAIL" ] && { echo "adb: cannot connect to daemon" >&2; exit 1; }
  echo "List of devices attached"
  cat "$FAKE_STATE/adb_devices"
  echo
  exit 0
fi
case "$1" in
  connect)
    case "$2" in
      *:5555) echo "connected to $2" ;;
      *) echo "failed to connect to '$2': Connection refused" ;;
    esac
    exit 0 ;;
  pair)
    if [ "$3" = "123456" ]; then echo "Successfully paired to $2 [guid=adb-XYZ]"; else echo "Failed: Wrong password or connection was dropped."; fi
    exit 0 ;;
  disconnect)
    echo "disconnected $2"; exit 0 ;;
esac
if [ "$1" = "-s" ]; then
  serial="$2"; shift 2
  if ! grep -q "^$serial[[:space:]]" "$FAKE_STATE/adb_devices"; then
    echo "adb: device '$serial' not found" >&2; exit 1
  fi
  case "$1 $2" in
    "emu avd")
      [ -f "$FAKE_STATE/avd_$serial" ] || { echo "KO: unknown command" ; exit 1; }
      printf '%s\r\nOK\r\n' "$(cat "$FAKE_STATE/avd_$serial")"; exit 0 ;;
    "emu kill")
      grep -v "^$serial[[:space:]]" "$FAKE_STATE/adb_devices" > "$FAKE_STATE/tmp"; mv "$FAKE_STATE/tmp" "$FAKE_STATE/adb_devices"
      echo "OK: killing emulator, bye bye"; exit 0 ;;
    "shell getprop")
      case "$3" in
        sys.boot_completed) cat "$FAKE_STATE/booted_$serial" 2>/dev/null || echo "" ;;
        ro.build.version.release) echo "${FAKE_RELEASE:-16}" ;;
      esac
      exit 0 ;;
    "shell pidof")
      cat "$FAKE_STATE/pidof" 2>/dev/null; exit 0 ;;
    "logcat -v")
      echo $$ > "$FAKE_STATE/logcat.pid"
      cat "$FAKE_STATE/logcat" 2>/dev/null
      [ -n "$FAKE_LOGCAT_EXIT" ] && exit "$FAKE_LOGCAT_EXIT"
      exec sleep 30 ;;
  esac
fi
exit 1
]==]

local AVDMANAGER = PRELUDE
  .. [==[
echo "JAVA_HOME=$JAVA_HOME" >> "$FAKE_STATE/avdmanager_env"
case "$1 $2" in
  "list device")
    printf 'pixel_9\npixel_9a\nmedium_phone\n'; exit 0 ;;
  "create avd")
    cat > "$FAKE_STATE/avdmanager_stdin"
    if [ -n "$FAKE_AVDMANAGER_ERROR" ]; then
      echo "Error: Package path is not valid. Valid system image paths are:" >&2
      exit "${FAKE_AVDMANAGER_EXIT:-1}"
    fi
    echo "$4" >> "$FAKE_STATE/avds"; exit 0 ;;
  "delete avd")
    grep -vx "$4" "$FAKE_STATE/avds" > "$FAKE_STATE/tmp"; mv "$FAKE_STATE/tmp" "$FAKE_STATE/avds"
    echo "AVD '$4' deleted."; exit 0 ;;
esac
exit 1
]==]

local JAVA = "#!/bin/sh\necho 'openjdk version \"17.0.9\" 2023-10-17' >&2\n"

---@param opts? { avds?: string[], adb_devices?: string[], configs?: table<string, table<string, string>> }
function M.new(opts)
  opts = opts or {}
  local spec = {
    ["sdk/emulator/emulator"] = EMULATOR,
    ["sdk/platform-tools/adb"] = ADB,
    ["sdk/cmdline-tools/latest/bin/avdmanager"] = AVDMANAGER,
    ["sdk/system-images/android-36/google_apis_playstore/arm64-v8a/system.img"] = "img",
    ["sdk/system-images/android-35/google_apis/arm64-v8a/system.img"] = "img",
    ["sdk/system-images/android-36/google_apis/x86_64/system.img"] = "img",
    -- A folder without system.img is a broken or partial download.
    ["sdk/system-images/android-34/default/arm64-v8a/"] = "",
    ["jdk/bin/java"] = JAVA,
    ["avd/"] = "",
    ["state/"] = "",
  }
  for name, config in pairs(opts.configs or {}) do
    local lines = {}
    for k, v in pairs(config) do
      lines[#lines + 1] = k .. "=" .. v
    end
    table.sort(lines)
    spec["avd/" .. name .. ".avd/config.ini"] = table.concat(lines, "\n")
  end
  local root = h.tree(spec)
  for name in pairs(opts.configs or {}) do
    vim.fn.writefile(
      { "path=" .. root .. "/avd/" .. name .. ".avd", "target=android-36" },
      root .. "/avd/" .. name .. ".ini"
    )
  end
  vim.fn.writefile(opts.avds or {}, root .. "/state/avds")
  vim.fn.writefile(opts.adb_devices or {}, root .. "/state/adb_devices")
  vim.fn.writefile({}, root .. "/state/calls.log")

  local fake = { root = root, state = root .. "/state" }

  --- Options for the Android backend that point at this SDK only.
  function fake.opts(extra)
    return vim.tbl_extend("force", {
      android_sdk = root .. "/sdk",
      android_sdk_fallbacks = {},
      java_fallbacks = {},
      java_home = root .. "/jdk",
      avd_home = root .. "/avd",
      os = "macos",
      arch = "arm64",
    }, extra or {})
  end

  function fake.env(extra)
    return h.isolated(vim.tbl_extend("force", { FAKE_STATE = root .. "/state" }, extra or {}))
  end

  ---@param name string
  ---@param lines string[]
  function fake.write(name, lines)
    vim.fn.writefile(lines, root .. "/state/" .. name)
  end

  ---@param name string
  ---@return string[]
  function fake.read(name)
    local ok, lines = pcall(vim.fn.readfile, root .. "/state/" .. name)
    return ok and lines or {}
  end

  ---@return string[][]
  function fake.calls()
    local calls, current = {}, {}
    for _, line in ipairs(fake.read("calls.log")) do
      if line == "--" then
        calls[#calls + 1] = current
        current = {}
      else
        current[#current + 1] = line
      end
    end
    return calls
  end

  --- Stop the emulator the fake started, if any.
  function fake.kill_emulator()
    local pid = tonumber(fake.read("emulator.pid")[1] or "")
    if pid then
      vim.uv.kill(pid, "sigkill")
    end
  end

  return fake
end

return M
