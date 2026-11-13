# devices.nvim

[![ci](https://github.com/0xrnp/devices.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/0xrnp/devices.nvim/actions/workflows/ci.yml)

Run and manage iOS simulators, Android emulators and physical devices (USB and Wi-Fi) from
Neovim, and read their logs, including logs from release builds.

- One list for every simulator, emulator, iPhone and Android phone on the machine.
- Boot, shut down, cold boot, wipe, erase, create and delete devices.
- Connect Android phones over Wi-Fi (pairing code or address).
- Live logs in a buffer: filter by app, level and text. Follows your app across restarts.
- `:Devices audit` finds build settings that strip logs from release builds.
- `:checkhealth devices` says what is missing and how to install it.
- A `devices` terminal command with the same features.
- No dependencies. Works with any picker through `vim.ui.select`.

Requirements: Neovim 0.10+, macOS or Linux. iOS needs macOS with Xcode. Android needs the
Android SDK (Android Studio or the command-line tools).

Xcode versions: tested on Xcode 27. Older `simctl` output formats (back to Xcode 10) are handled
and covered by tests. Physical iPhones need Xcode 15 or newer (`devicectl`). A booted simulator
opens in Simulator.app on Xcode 26 and earlier, and in DeviceHub on Xcode 27. With several
Xcodes installed, the app comes from the one `xcode-select -p` points to.

## Status

Early release. What has been run, and what has not:

| | Tested |
| --- | --- |
| Neovim 0.10.4 and 0.12 | Full test suite, and real simulators and emulators, on macOS |
| Neovim stable and nightly | Full test suite in CI, on Ubuntu and macOS |
| iOS simulators | Real Xcode 27.2: list, create, boot, logs, console, erase, delete |
| Android emulators | Real SDK: list, boot, logcat across app restarts, shutdown |
| iPhones, Android phones (USB, Wi-Fi), `idevicesyslog` | Fake tools only. No real device has been tried |
| Linux with a real Android SDK | CI runs the suite with fake tools. Not tried by hand |

If one of the untested paths fails for you, please
[open an issue](https://github.com/0xrnp/devices.nvim/issues/new/choose) with the output of
`:checkhealth devices`.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "0xrnp/devices.nvim",
  cmd = "Devices",
  opts = {},
}
```

Releases are tagged. To stay on the latest release instead of the main branch, add
`version = "*"`.

To try a local checkout, use `dir` instead:

```lua
{
  dir = "~/path/to/devices.nvim",
  name = "devices.nvim",
  cmd = "Devices",
  opts = {},
}
```

Then run `:Devices doctor` (the same as `:checkhealth devices`, and it also loads a lazy-loaded
plugin first).

## Usage

`:Devices` opens a list of every device. Pick one to see what you can do with it.

| Command | What it does |
| --- | --- |
| `:Devices` | Pick a device, then an action |
| `:Devices list` | Show every device and its id |
| `:Devices boot [device] [--cold\|--wipe]` | Boot a simulator or start an emulator |
| `:Devices shutdown [device]` | Shut it down |
| `:Devices erase [device]` | Simulator: erase content and settings. Emulator: start with its data wiped. Asks first |
| `:Devices delete [device]` | Delete a simulator or emulator. Asks first |
| `:Devices logs [device] [app=<id>] [mode=<mode>]` | Live log in a buffer |
| `:Devices copy [device]` | Copy the id for `flutter -d`, `adb -s`, `xcrun` |
| `:Devices create` | Create a simulator or emulator |
| `:Devices connect` | Pair and connect an Android phone over Wi-Fi |
| `:Devices disconnect [device]` | Disconnect a Wi-Fi phone |
| `:Devices audit [dir]` | Find settings that remove release logs |
| `:Devices doctor` | Same as `:checkhealth devices` |

`[device]` is an id, an adb serial or a name (`iPhone 16`, or a unique part of one). Leave it
out to pick from a list. `<Tab>` completes subcommands, and device names once the devices have
been listed in the session. `--wipe` asks before erasing.

## Logs

`:Devices logs` streams into a buffer.

| Key | Action |
| --- | --- |
| `f` | Filter by text (empty clears) |
| `l` | Minimum level |
| `p` | Pause or resume (nothing is lost) |
| `c` | Clear |
| `r` | Restart the stream |
| `s` | Save what is shown to a file |
| `G` | Jump to the end and follow |
| `q` | Stop and close |
| `g?` | Help |

What each device offers:

| Device | Modes |
| --- | --- |
| Android emulator or phone | `logcat`, optionally only one app (package name) |
| iOS simulator | `system` log, optionally one app (bundle id); `console`: launch the app and show its output |
| iPhone | `console`: launch the app and show its output; `system` log (needs `idevicesyslog`) |

When you give an Android package, the log keeps following the app when it restarts and gets a
new process id, and keeps crash reports and system messages that name it.

### Why release logs go missing

Some missing logs can be shown, and some never reach the device.

Shown by devices.nvim:

- A release iOS app's `print()` and `NSLog` output goes to its standard output, which only the
  tool that launched it sees. Use the `console` mode: it launches the app and shows that output.
- Android viewers that filter by process id lose the app when it restarts. The app filter
  follows it.
- iOS debug-level messages are hidden by default. With an app filter they are included.

Removed when the app was built, so no viewer can show them:

- R8 rules such as `-assumenosideeffects class android.util.Log { ... }` or
  `-maximumremovedandroidloglevel`. Rules from libraries can do this too.
- Babel's `transform-remove-console` in React Native production builds.
- `debugPrint` replaced with a no-op in Flutter release builds.
- iOS `os_log`/`Logger` values appear as `<private>` unless marked `privacy: .public`.

`:Devices audit` looks for these in your project and lists them in the quickfix list.

## Configuration

Defaults:

```lua
require("devices").setup({
  android = {
    sdk = nil,            -- default: ANDROID_HOME, ANDROID_SDK_ROOT, PATH, usual places
    java_home = nil,      -- JDK for avdmanager. Default: JAVA_HOME, PATH, Android Studio's JDK
    avd_home = nil,       -- default: the emulator's own lookup
    emulator_args = {},   -- added to every emulator start, e.g. { "-gpu", "host" }
    headless = false,     -- start emulators without a window
  },
  ios = {
    open_simulator_app = true, -- open Simulator.app (DeviceHub in Xcode 27) when one boots
  },
  logs = {
    tail = 1000,          -- Android: earlier lines to show first
    max_lines = 20000,    -- lines kept in a log buffer
    open = "split",       -- "split", "vsplit", "tab" or "current"
  },
  on_boot = nil,          -- function(device) called once a device you booted is ready
  actions = {},           -- your own entries in the action menu
})
```

### Your own actions

Entries in `actions` appear in each device's menu. For example, run a Flutter app on the device:

```lua
actions = {
  {
    name = "flutter run",
    when = function(device)
      return device.state == "booted" or device.state == "connected"
    end,
    run = function(device)
      vim.cmd("FlutterRun -d " .. require("devices").target_id(device))
    end,
  },
},
```

## Terminal command

`bin/devices` runs the same code through Neovim, without your config:

```sh
ln -s ~/path/to/devices.nvim/bin/devices ~/.local/bin/devices

devices list [--json]
devices boot "Pixel 9a" --cold --wait
devices boot "Pixel 9a" --wipe --yes
devices shutdown "Pixel 9a"
devices erase "iPhone 16" --yes
devices delete "iPhone 16" --yes
devices logs "iPhone 16" --app com.example.app --mode console
devices id "Pixel 9a"          # emulator-5554 when running, for flutter -d / adb -s
devices audit ./my_app
devices doctor
```

Commands that erase or delete data need `--yes`. Exit codes: 0 success, 1 failure, 2 wrong
usage. Set `DEVICES_NVIM` to use another `nvim`.

## Lua API

Functions that run tools take a callback. None of them throw for runtime problems; they report
them as values. `logs` opens the buffer and returns it, `target_id` and `audit` return their
result directly:

```lua
local devices = require("devices")

devices.list(function(list, errors) end)
devices.find("Pixel 9a", function(device, err) end)
devices.boot(device, { cold = false, wipe = false, wait = false }, function(err) end)
devices.shutdown(device, function(err) end)
devices.erase(device, function(err) end)
devices.delete(device, function(err) end)
devices.logs(device, { mode = "logcat", app = "com.example.app" })
devices.pick({ filter = function(d) return d.platform == "android" end }, function(device) end)
devices.target_id(device) -- the id flutter -d, adb -s and xcrun want
devices.audit(dir)
```

An error has `code` (`tool_missing`, `timeout`, `command_failed`, `parse_failed`,
`unsupported`, `not_found`, `invalid_state`), `message`, and often a `hint`.

## Troubleshooting

Run `:checkhealth devices` first.

- **No Android devices**: the SDK was not found. Set `ANDROID_HOME` or `android.sdk`.
- **Phone shows "unauthorized"**: unlock it and accept the USB debugging prompt.
- **Linux: "no permissions"**: install udev rules for Android devices (`android-udev-rules`).
- **Simulators stop when DeviceHub quits (Xcode 27)**: that is DeviceHub's "Stop simulators on
  quit" setting. Turn it off in DeviceHub's settings, or quit with "Quit and Keep Simulators
  Running" (hold Option in the DeviceHub menu).
- **iPhone shows "disconnected"**: connect it once by cable, trust the computer, and turn on
  Developer Mode in Settings > Privacy & Security.
- **Creating an Android emulator fails about Java**: install a JDK 17+, or set
  `android.java_home`.

## Development

```sh
make test                              # unit tests, with fake Xcode and Android tools
nvim -l tests/real/ios_smoke.lua       # real Xcode: lists, then uses a throwaway simulator
nvim -l tests/real/android_smoke.lua   # real SDK: boots an AVD read-only, then shuts it down
make fmt lint
```

Contributions are welcome. Run `make test` and `make fmt` first. The unit tests use fake `xcrun`,
`simctl`, `adb` and `emulator` scripts, so they run anywhere and never touch a real device. A fix
for a parsing or tool-output problem should come with a test built from the real output.

## License

MIT
