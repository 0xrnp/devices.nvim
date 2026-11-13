--- A fake `xcrun` and `open` on PATH. It keeps each simulator's state in a file and refuses the
--- same transitions the real simctl refuses, with the same exit codes (148 unknown device, 149
--- wrong state) and messages, as recorded from a real Xcode.
local h = require("helpers")

local M = {}

local XCRUN = [[#!/bin/sh
# The test PATH holds only the fakes, so the script needs the system tools for itself.
PATH="/usr/bin:/bin:$PATH"
# Every call is logged: one argument per line, then a "--" line.
printf '%s\n' "$@" >> "$FAKE_STATE/calls.log"
echo '--' >> "$FAKE_STATE/calls.log"

wrong_state() {
  printf '%s\n' "An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError, code=405):" >&2
  printf '%s\n' "$1" >&2
  exit 149
}

case "$1" in
  simctl)
    if [ "$2" = list ]; then
      if [ -n "$FAKE_SIMCTL_LIST_FAIL" ]; then echo "simctl exploded" >&2; exit 1; fi
      if [ -n "$FAKE_SIMCTL_LIST_SLEEP" ]; then sleep "$FAKE_SIMCTL_LIST_SLEEP"; fi
      case "$3" in
        runtimes) [ -n "$FAKE_RUNTIMES_JSON" ] && cat "$FAKE_RUNTIMES_JSON" && exit 0 ;;
        devicetypes) [ -n "$FAKE_DEVICETYPES_JSON" ] && cat "$FAKE_DEVICETYPES_JSON" && exit 0 ;;
      esac
      cat "$FAKE_SIMCTL_JSON"
      exit 0
    fi
    verb="$2"
    udid="$3"
    if [ ! -f "$FAKE_STATE/dev/$udid" ]; then
      echo "Invalid device or device pair: $udid" >&2
      exit 148
    fi
    state=$(cat "$FAKE_STATE/dev/$udid")
    case "$verb" in
      boot)
        [ "$state" = Shutdown ] || wrong_state "Unable to boot device in current state: $state"
        echo Booted > "$FAKE_STATE/dev/$udid"
        ;;
      shutdown)
        [ "$state" = Booted ] || wrong_state "Unable to shutdown device in current state: $state"
        echo Shutdown > "$FAKE_STATE/dev/$udid"
        ;;
      erase)
        [ "$state" = Shutdown ] || wrong_state "Unable to erase contents and settings in current state: $state"
        ;;
      bootstatus)
        sleep "${FAKE_BOOTSTATUS_SLEEP:-0}"
        echo "Monitoring boot status for $udid."
        ;;
    esac
    exit 0
    ;;
  devicectl)
    # xcrun devicectl list devices --json-output <file>
    if [ -n "$FAKE_DEVICECTL_EXIT" ] && [ "$FAKE_DEVICECTL_EXIT" != 0 ]; then
      echo "devicectl: something went wrong" >&2
      exit "$FAKE_DEVICECTL_EXIT"
    fi
    cp "$FAKE_DEVICECTL_JSON" "$5"
    exit 0
    ;;
esac
exit 1
]]

local OPEN = [[#!/bin/sh
PATH="/usr/bin:/bin:$PATH"
printf '%s\n' "$@" >> "$FAKE_STATE/calls.log"
echo '--' >> "$FAKE_STATE/calls.log"
if [ -n "$FAKE_OPEN_EXIT" ] && [ "$FAKE_OPEN_EXIT" != 0 ]; then
  echo "open: unable to find application named 'Simulator'" >&2
  exit "$FAKE_OPEN_EXIT"
fi
# The apps this "Mac" has, by bundle id. Xcode 26 and earlier: Simulator. Xcode 27: DeviceHub.
apps="${FAKE_OPEN_APPS-com.apple.iphonesimulator}"
if [ "$1" = "-a" ]; then
  [ -d "$2" ] && exit 0
  echo "Unable to find application named '$2'" >&2
  exit 1
fi
if [ "$1" = "-b" ]; then
  case " $apps " in
    *" $2 "*) exit 0 ;;
  esac
  echo "LSCopyApplicationURLsForBundleIdentifier() failed while trying to determine the application with bundle identifier $2." >&2
  exit 1
fi
exit 0
]]

---@param opts? { simctl_json?: string, devicectl_json?: string }
function M.new(opts)
  opts = opts or {}
  local root = h.tree({
    ["bin/xcrun"] = XCRUN,
    ["bin/open"] = OPEN,
    -- The selected Xcode's Developer folder, or no Xcode selected.
    ["bin/xcode-select"] = '#!/bin/sh\n[ -n "$FAKE_DEVELOPER_DIR" ] || exit 1\necho "$FAKE_DEVELOPER_DIR"\n',
    ["state/dev/"] = "",
    ["simctl.json"] = opts.simctl_json or "",
    ["devicectl.json"] = opts.devicectl_json or "",
  })
  vim.fn.writefile({}, root .. "/state/calls.log")

  local fake = { root = root }

  --- Environment variables to pass to `h.with_env`. `extra` adds fake-tool switches.
  ---@param extra? table<string, string|false>
  function fake.env(extra)
    return h.isolated(vim.tbl_extend("force", {
      PATH = root .. "/bin",
      FAKE_STATE = root .. "/state",
      FAKE_SIMCTL_JSON = root .. "/simctl.json",
      FAKE_DEVICECTL_JSON = root .. "/devicectl.json",
    }, extra or {}))
  end

  function fake.set_state(udid, state)
    vim.fn.writefile({ state }, root .. "/state/dev/" .. udid)
  end

  function fake.get_state(udid)
    return vim.fn.readfile(root .. "/state/dev/" .. udid)[1]
  end

  --- Every call the fake tools received, each as a list of arguments.
  ---@return string[][]
  function fake.calls()
    local calls, current = {}, {}
    for _, line in ipairs(vim.fn.readfile(root .. "/state/calls.log")) do
      if line == "--" then
        calls[#calls + 1] = current
        current = {}
      else
        current[#current + 1] = line
      end
    end
    return calls
  end

  return fake
end

return M
