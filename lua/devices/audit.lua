--- "Why are my release logs missing?" Looks through a project for build settings that remove
--- logging from release builds. A log viewer cannot show what was compiled out, so this says
--- where that happens instead.
local M = {}

-- Directories that hold dependencies or build output, never the project's own settings.
local SKIP = {
  [".git"] = true,
  node_modules = true,
  build = true,
  [".gradle"] = true,
  [".dart_tool"] = true,
  Pods = true,
  DerivedData = true,
  [".build"] = true,
  dist = true,
  [".idea"] = true,
  [".cxx"] = true,
  [".expo"] = true,
}
local MAX_DEPTH = 8
local MAX_FILES = 50000
local MAX_FILE_BYTES = 1024 * 1024

---@class devices.Finding
---@field severity "error"|"warning"|"info" error: logs are removed. warning: some are. info: worth knowing.
---@field file string Relative to the project root.
---@field line integer
---@field message string
---@field hint string?

---@class devices.AuditReport
---@field root string
---@field kinds string[] What the project looks like: "android", "ios", "flutter", "react-native".
---@field findings devices.Finding[]
---@field notes string[] General advice for the kinds of project found.
---@field truncated boolean The file limit was reached, so not everything was searched.

---@param path string
---@return string[]?
local function read_lines(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.size > MAX_FILE_BYTES then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or nil
end

--- R8/ProGuard: `-assumenosideeffects class android.util.Log { ... }` deletes the listed calls.
---@param lines string[]
---@return { line: integer, methods: string[] }[] blocks
---@return integer? max_level_line
local function scan_proguard(lines)
  local blocks, max_level_line = {}, nil
  local i = 1
  while i <= #lines do
    local text = lines[i]:gsub("#.*$", "")
    if text:match("%-maximumremovedandroidloglevel") then
      max_level_line = max_level_line or i
    end
    if text:match("%-assumenosideeffects") and text:match("android%.util%.Log") then
      local start, methods = i, {}
      -- The block runs to the closing brace, possibly lines later.
      local j = i
      while j <= #lines do
        local body = lines[j]:gsub("#.*$", "")
        for name in body:gmatch("%s([vdiwe])%s*%(") do
          methods[#methods + 1] = name
        end
        for name in body:gmatch("%s(println)%s*%(") do
          methods[#methods + 1] = name
        end
        for name in body:gmatch("%s(isLoggable)%s*%(") do
          methods[#methods + 1] = name
        end
        if body:find("}", 1, true) then
          break
        end
        j = j + 1
      end
      blocks[#blocks + 1] = { line = start, methods = methods }
      i = j
    end
    i = i + 1
  end
  return blocks, max_level_line
end

local LEVEL_NAMES = { v = "verbose", d = "debug", i = "info", w = "warning", e = "error" }

--- Look through a project.
---@param root string
---@return devices.AuditReport
function M.run(root)
  root = vim.fs.normalize(vim.fn.fnamemodify(root, ":p")):gsub("/$", "")
  ---@type devices.AuditReport
  local report = { root = root, kinds = {}, findings = {}, notes = {}, truncated = false }
  local kinds = {}

  local function add(severity, rel, line, message, hint)
    table.insert(report.findings, { severity = severity, file = rel, line = line, message = message, hint = hint })
  end

  local count = 0
  local ok, iter = pcall(vim.fs.dir, root, {
    depth = MAX_DEPTH,
    -- Called with the directory's path relative to the root. false means do not enter it.
    skip = function(dir)
      return not SKIP[vim.fs.basename(dir)]
    end,
  })
  if not ok then
    return report
  end

  for rel, kind in iter do
    count = count + 1
    if count > MAX_FILES then
      report.truncated = true
      break
    end
    local name = vim.fs.basename(rel)
    local path = root .. "/" .. rel

    if kind == "directory" then
      if name:match("%.xcodeproj$") then
        kinds.ios = true
      end
    elseif kind == "file" then
      if name == "pubspec.yaml" then
        local lines = read_lines(path) or {}
        for _, l in ipairs(lines) do
          if l:match("^%s*flutter:") or l:match("sdk:%s*flutter") then
            kinds.flutter = true
            break
          end
        end
      elseif name == "package.json" then
        local content = table.concat(read_lines(path) or {}, "\n")
        if content:find('"react%-native"%s*:') then
          kinds["react-native"] = true
        end
      elseif name == "AndroidManifest.xml" or name:match("^build%.gradle") then
        kinds.android = true
      end

      if name:match("%.pro$") or name:match("^proguard.*%.txt$") then
        local lines = read_lines(path)
        if lines then
          local blocks, max_level = scan_proguard(lines)
          for _, block in ipairs(blocks) do
            local removed = {}
            for _, m in ipairs(block.methods) do
              removed[#removed + 1] = LEVEL_NAMES[m] and ("Log." .. m .. " (" .. LEVEL_NAMES[m] .. ")") or ("Log." .. m)
            end
            add(
              "error",
              rel,
              block.line,
              "R8 removes "
                .. (#removed > 0 and table.concat(removed, ", ") or "android.util.Log calls")
                .. " from minified builds",
              "These lines never reach logcat in release. Remove the rule, or keep it out of the build type you are testing."
            )
          end
          if max_level then
            add(
              "error",
              rel,
              max_level,
              "R8 removes Android log calls up to the level given by -maximumremovedandroidloglevel",
              "Those levels never reach logcat in minified builds."
            )
          end
        end
      elseif
        name:match("^%.?babel%.config%.[cm]?[jt]s$")
        or name:match("^%.babelrc")
        or name == "babel.config.json"
      then
        local lines = read_lines(path) or {}
        for i, l in ipairs(lines) do
          if l:find("transform-remove-console", 1, true) then
            add(
              "error",
              rel,
              i,
              "Babel removes console.* calls (transform-remove-console)",
              "Usually only for production builds: check the env it is under. Those logs are gone from release builds."
            )
          end
        end
      elseif name:match("%.dart$") and not rel:match("^test/") then
        local lines = read_lines(path) or {}
        for i, l in ipairs(lines) do
          if l:match("^%s*debugPrint%s*=") then
            add(
              "warning",
              rel,
              i,
              "debugPrint is replaced here",
              "If this silences it in release mode, debugPrint output will not reach the device log."
            )
          end
        end
      elseif name:match("%.mm?$") or name:match("%.swift$") then
        local lines = read_lines(path) or {}
        for i, l in ipairs(lines) do
          if l:find("RCTSetLogThreshold", 1, true) then
            add(
              "info",
              rel,
              i,
              "React Native's native log threshold is set here",
              "Messages below this level are dropped before they reach the device log."
            )
          end
        end
      end
    end
  end

  report.kinds = vim.tbl_keys(kinds)
  table.sort(report.kinds)

  if kinds.android or kinds.flutter or kinds["react-native"] then
    table.insert(
      report.notes,
      "Android: logcat receives release-build logs unless the build removes them. Rules from libraries "
        .. "(consumer ProGuard files inside dependencies) can also remove them and are not checked here."
    )
  end
  if kinds.ios or kinds.flutter or kinds["react-native"] then
    table.insert(
      report.notes,
      "iOS: print() and NSLog output from a release app is only visible when you launch it with "
        .. "the app console (:Devices logs > Launch an app). os_log/Logger values show as <private> "
        .. "unless marked privacy: .public."
    )
  end
  if kinds["react-native"] then
    table.insert(report.notes, "React Native: on Android, JavaScript console output uses the ReactNativeJS tag.")
  end
  return report
end

--- The report as lines for a buffer or a terminal.
---@param report devices.AuditReport
---@return string[]
function M.format(report)
  local lines = { "Release log check: " .. report.root }
  lines[#lines + 1] = "Project: " .. (#report.kinds > 0 and table.concat(report.kinds, ", ") or "nothing recognised")
  lines[#lines + 1] = ""
  if #report.findings == 0 then
    lines[#lines + 1] = "No settings that remove logs were found."
  else
    for _, f in ipairs(report.findings) do
      lines[#lines + 1] = ("%s:%d: [%s] %s"):format(f.file, f.line, f.severity, f.message)
      if f.hint then
        lines[#lines + 1] = "    " .. f.hint
      end
    end
  end
  if report.truncated then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Stopped after " .. MAX_FILES .. " files; open a subdirectory to check the rest."
  end
  if #report.notes > 0 then
    lines[#lines + 1] = ""
    for _, note in ipairs(report.notes) do
      lines[#lines + 1] = "- " .. note
    end
  end
  return lines
end

return M
