--- The log buffer: a live, filterable view of a devices.logs session.
local config = require("devices.config")
local errors = require("devices.error")
local logs = require("devices.logs")

local M = {}

local NS = vim.api.nvim_create_namespace("devices.logs")
local FLUSH_MS = 100

local LEVEL_HL = {
  [1] = "Comment",
  [2] = "Comment",
  [4] = "DiagnosticWarn",
  [5] = "DiagnosticError",
  [6] = "DiagnosticError",
}

---@class devices.LogView
---@field buf integer
---@field spec devices.LogSpec
---@field session devices.LogSession?
---@field lines devices.LogLine[] Everything received, up to max_lines, for re-filtering.
---@field pending devices.LogLine[] Received but not drawn yet.
---@field filter string? Case-insensitive text every shown line must contain.
---@field min_level integer Lines below this level are hidden. Lines without a level are kept.
---@field paused boolean
---@field state "running"|"stopped"|"ended"
---@field timer uv.uv_timer_t

---@type table<integer, devices.LogView>
local views = {}

---@param view devices.LogView
---@param line devices.LogLine
---@return boolean
local function visible(view, line)
  if line.level and line.level < view.min_level then
    return false
  end
  if view.filter and not line.text:lower():find(view.filter, 1, true) then
    return false
  end
  return true
end

---@param view devices.LogView
---@return string
local function status(view)
  local d = view.spec.device
  local parts = { d.name, view.spec.mode }
  if view.spec.app then
    parts[#parts + 1] = view.spec.app
  end
  if view.min_level > 1 then
    parts[#parts + 1] = "level ≥ " .. logs.levels[view.min_level]
  end
  if view.filter then
    parts[#parts + 1] = "filter: " .. view.filter
  end
  parts[#parts + 1] = view.paused and "PAUSED" or view.state
  return table.concat(parts, "  ·  ") .. "    (g? for keys)"
end

--- Set a window option for the buffer shown there only. `vim.wo[win].x = y` works like `:set`,
--- so the next buffer opened in that window would keep the log's winbar and settings.
---@param win integer
---@param name string
---@param value any
local function set_local(win, name, value)
  vim.api.nvim_set_option_value(name, value, { scope = "local", win = win })
end

---@param view devices.LogView
local function update_status(view)
  local text = status(view):gsub("%%", "%%%%")
  for _, win in ipairs(vim.fn.win_findbuf(view.buf)) do
    set_local(win, "winbar", text)
  end
end

--- Windows on this buffer whose cursor is on the last line, so they keep following.
---@param buf integer
---@return integer[]
local function following(buf)
  local wins, last = {}, vim.api.nvim_buf_line_count(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_get_cursor(win)[1] >= last then
      wins[#wins + 1] = win
    end
  end
  return wins
end

--- Append lines to the buffer, highlight them, and drop the oldest past max_lines.
---@param view devices.LogView
---@param list devices.LogLine[]
local function draw(view, list)
  local buf = view.buf
  if #list == 0 or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local follow = following(buf)
  local texts = {}
  for i, line in ipairs(list) do
    -- A buffer line cannot hold a newline.
    texts[i] = line.text:gsub("\n", " ")
  end

  vim.bo[buf].modifiable = true
  local count = vim.api.nvim_buf_line_count(buf)
  local empty = count == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
  local first = empty and 0 or count
  vim.api.nvim_buf_set_lines(buf, empty and 0 or -1, -1, false, texts)
  for i, line in ipairs(list) do
    local hl = line.level and LEVEL_HL[line.level]
    if hl then
      vim.api.nvim_buf_set_extmark(buf, NS, first + i - 1, 0, { end_col = #texts[i], hl_group = hl })
    end
  end
  local total = vim.api.nvim_buf_line_count(buf)
  local max = config.options.logs.max_lines
  if total > max then
    vim.api.nvim_buf_set_lines(buf, 0, total - max, false, {})
  end
  vim.bo[buf].modifiable = false

  local last = vim.api.nvim_buf_line_count(buf)
  for _, win in ipairs(follow) do
    vim.api.nvim_win_set_cursor(win, { last, 0 })
  end
end

---@param view devices.LogView
local function flush(view)
  if view.paused or #view.pending == 0 then
    return
  end
  local shown = {}
  for _, line in ipairs(view.pending) do
    if visible(view, line) then
      shown[#shown + 1] = line
    end
  end
  view.pending = {}
  draw(view, shown)
end

--- Redraw everything from the kept lines, after the filter or level changed.
---@param view devices.LogView
local function redraw(view)
  if not vim.api.nvim_buf_is_valid(view.buf) then
    return
  end
  vim.bo[view.buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(view.buf, NS, 0, -1)
  vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, {})
  vim.bo[view.buf].modifiable = false
  view.pending = {}
  local shown = {}
  for _, line in ipairs(view.lines) do
    if visible(view, line) then
      shown[#shown + 1] = line
    end
  end
  draw(view, shown)
  update_status(view)
end

---@param view devices.LogView
---@param text string
---@param hl? string
local function notice(view, text, hl)
  draw(view, { { text = "-- " .. text .. " --", level = hl == "error" and 5 or nil } })
end

---@param view devices.LogView
local function start(view)
  view.state = "running"
  update_status(view)
  local session
  -- After a restart, the previous session still reports its exit. Only the current one counts.
  local function current()
    return view.session == session and vim.api.nvim_buf_is_valid(view.buf)
  end
  session = logs.start(view.spec, {
    on_lines = function(list)
      if not current() then
        return
      end
      local max = config.options.logs.max_lines
      for _, line in ipairs(list) do
        view.lines[#view.lines + 1] = line
        view.pending[#view.pending + 1] = line
      end
      -- Keep memory bounded: drop the oldest kept lines in one go.
      if #view.lines > max * 1.25 then
        view.lines = vim.list_slice(view.lines, #view.lines - max + 1)
      end
      if #view.pending > max then
        view.pending = vim.list_slice(view.pending, #view.pending - max + 1)
      end
    end,
    on_status = function(message)
      if current() then
        notice(view, message)
      end
    end,
    on_exit = function(failure)
      if not current() then
        return
      end
      flush(view)
      if failure then
        view.state = "ended"
        notice(view, (errors.format(failure):gsub("\n", " · ")), "error")
      else
        view.state = "stopped"
        notice(view, "stopped (r restarts)")
      end
      update_status(view)
    end,
  })
  view.session = session
end

---@param view devices.LogView
local function stop(view)
  if view.session then
    view.session.stop()
  end
end

local HELP = {
  "q      stop and close",
  "p      pause or resume (nothing is lost while paused)",
  "f      filter by text (empty clears it)",
  "l      minimum level",
  "c      clear",
  "r      restart the stream",
  "s      save what is shown to a file",
  "G      jump to the end and follow new lines",
}

---@param view devices.LogView
local function set_keymaps(view)
  local buf = view.buf
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
  map("q", function()
    stop(view)
    vim.api.nvim_buf_delete(buf, { force = true })
  end, "Stop and close")
  map("p", function()
    view.paused = not view.paused
    if not view.paused then
      flush(view)
    end
    update_status(view)
  end, "Pause or resume")
  map("f", function()
    vim.ui.input({ prompt = "Filter (text): ", default = view.filter or "" }, function(input)
      if input == nil then
        return
      end
      input = vim.trim(input)
      view.filter = input ~= "" and input:lower() or nil
      redraw(view)
    end)
  end, "Filter")
  map("l", function()
    vim.ui.select(logs.levels, {
      prompt = "Show this level and above",
      format_item = function(level)
        return level
      end,
    }, function(choice)
      if choice then
        view.min_level = logs.rank[choice]
        redraw(view)
      end
    end)
  end, "Minimum level")
  map("c", function()
    view.lines, view.pending = {}, {}
    redraw(view)
  end, "Clear")
  map("r", function()
    stop(view)
    view.lines, view.pending = {}, {}
    redraw(view)
    -- The old stream reports "stopped" first; start the new one after it.
    vim.schedule(function()
      start(view)
    end)
  end, "Restart")
  map("s", function()
    local name = view.spec.device.name:gsub("[^%w._%-]", "_")
    local default = ("%s/devices-%s-%s.log"):format(vim.fn.getcwd(), name, os.date("%Y%m%d-%H%M%S"))
    vim.ui.input({ prompt = "Save to: ", default = default, completion = "file" }, function(path)
      if not path or vim.trim(path) == "" then
        return
      end
      path = vim.fn.expand(vim.trim(path))
      local ok, problem = pcall(vim.fn.writefile, vim.api.nvim_buf_get_lines(buf, 0, -1, false), path)
      vim.notify(
        ok and ("devices.nvim: saved " .. path) or ("devices.nvim: could not save: " .. tostring(problem)),
        ok and vim.log.levels.INFO or vim.log.levels.ERROR
      )
    end)
  end, "Save")
  map("G", function()
    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf), 0 })
  end, "Follow")
  map("g?", function()
    vim.notify(table.concat(HELP, "\n"), vim.log.levels.INFO, { title = "devices.nvim logs" })
  end, "Help")
end

---@param buf integer
local function show(buf)
  local where = config.options.logs.open
  if where == "tab" then
    vim.cmd("tab sbuffer " .. buf)
  elseif where == "vsplit" then
    vim.cmd("vertical sbuffer " .. buf)
  elseif where == "current" then
    vim.api.nvim_set_current_buf(buf)
  else
    vim.cmd("sbuffer " .. buf)
  end
  local win = vim.api.nvim_get_current_win()
  set_local(win, "wrap", false)
  set_local(win, "number", false)
  set_local(win, "relativenumber", false)
  set_local(win, "spell", false)
end

--- Open a log buffer and start streaming into it.
---@param spec devices.LogSpec
---@return integer buf
function M.open(spec)
  local buf = vim.api.nvim_create_buf(false, true)
  local title = ("devices://logs/%s/%s%s"):format(spec.device.name, spec.mode, spec.app and ("/" .. spec.app) or "")
  -- Two logs of the same device and app get distinct names.
  pcall(vim.api.nvim_buf_set_name, buf, title)
  if vim.api.nvim_buf_get_name(buf) == "" then
    pcall(vim.api.nvim_buf_set_name, buf, title .. "#" .. buf)
  end
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "deviceslog"

  local timer = assert(vim.uv.new_timer())
  ---@type devices.LogView
  local view = {
    buf = buf,
    spec = spec,
    lines = {},
    pending = {},
    min_level = 1,
    paused = false,
    state = "running",
    timer = timer,
  }
  views[buf] = view

  vim.uv.update_time()
  timer:start(
    FLUSH_MS,
    FLUSH_MS,
    vim.schedule_wrap(function()
      if vim.api.nvim_buf_is_valid(buf) then
        flush(view)
      end
    end)
  )

  -- :bdelete only unloads a hidden buffer, so stop on that as well as on a wipe.
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    buffer = buf,
    once = true,
    callback = function()
      stop(view)
      if not timer:is_closing() then
        timer:close()
      end
      views[buf] = nil
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = buf,
    callback = function()
      update_status(view)
    end,
  })

  set_keymaps(view)
  show(buf)
  start(view)
  return buf
end

--- The view behind a log buffer, for tests and integrations.
---@param buf integer
---@return devices.LogView?
function M.get(buf)
  return views[buf]
end

return M
