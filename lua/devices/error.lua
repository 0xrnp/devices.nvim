--- Runtime failures are values, not exceptions. Every async API reports a `devices.Error`.
local M = {}

local MAX_DETAIL = 200

---@alias devices.ErrorCode
---| "tool_missing" a required command is not installed or not on the path
---| "timeout" a command did not finish in time
---| "command_failed" a command exited with an error
---| "parse_failed" a command succeeded but its output was not what we expected
---| "unsupported" the platform or tool version cannot do this
---| "not_found" the requested device does not exist
---| "invalid_state" the device is not in a state that allows this

---@class devices.Error
---@field code devices.ErrorCode
---@field message string What went wrong, one line.
---@field hint string? What to do about it.
---@field guide string? Setup guide topic that explains how to fix it.
---@field cmd string[]? The command that failed.
---@field exit_code integer? Its exit code.
---@field stderr string? Its error output.

---@param code devices.ErrorCode
---@param message string
---@param fields? { hint?: string, guide?: string, cmd?: string[], exit_code?: integer, stderr?: string }
---@return devices.Error
function M.new(code, message, fields)
  return vim.tbl_extend("force", { code = code, message = message }, fields or {})
end

---@param text string
---@return string
local function first_line(text)
  local line = vim.trim(text):match("^[^\r\n]*") or ""
  if #line > MAX_DETAIL then
    line = line:sub(1, MAX_DETAIL) .. "..."
  end
  return line
end

--- Turn a process result into an error, or nil when the command succeeded.
---@param res devices.ProcessResult
---@param argv string[]
---@param opts? { hint?: string, guide?: string } Used when the tool is missing.
---@return devices.Error?
function M.from_process(res, argv, opts)
  opts = opts or {}
  local tool = vim.fn.fnamemodify(argv[1], ":t")

  if res.missing then
    return M.new("tool_missing", tool .. " was not found", { hint = opts.hint, guide = opts.guide, cmd = argv })
  elseif res.timed_out then
    return M.new("timeout", tool .. " did not finish in time", { cmd = argv, stderr = res.stderr })
  elseif res.code ~= 0 then
    local detail = first_line(res.stderr)
    if detail == "" then
      detail = first_line(res.stdout)
    end
    local message = tool .. " failed"
    message = detail ~= "" and (message .. ": " .. detail) or (message .. " (exit code " .. res.code .. ")")
    return M.new("command_failed", message, { cmd = argv, exit_code = res.code, stderr = res.stderr })
  end
  return nil
end

--- The message and hint as one user-facing string.
---@param err devices.Error
---@return string
function M.format(err)
  if err.hint and err.hint ~= "" then
    return err.message .. "\n" .. err.hint
  end
  return err.message
end

return M
