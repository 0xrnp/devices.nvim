local h = require("helpers")
local eq = h.eq

local config = require("devices.config")
local fake_android = require("fake_android")
local view = require("devices.view")

local LINES = {
  "11-13 20:49:44.298   917  1126 D Chatty: debug noise",
  "11-13 20:49:44.301   917   917 W Warn: a warning",
  "11-13 20:49:45.210   673  1000 E Boom: an error",
  "11-13 20:49:46.100  4242  4242 I flutter : hello from release",
}

--- Open a log buffer on a fake emulator and wait until it shows `count` lines.
local function open(fake, count)
  local buf = view.open({
    device = {
      id = "Pixel_9a",
      name = "Pixel 9a",
      platform = "android",
      kind = "emulator",
      state = "booted",
      serial = "emulator-5554",
      source = "emulator",
    },
    mode = "logcat",
    android = fake.opts(),
  })
  assert(
    vim.wait(10000, function()
      return #vim.api.nvim_buf_get_lines(buf, 0, -1, false) >= count
    end, 20),
    "the log did not fill: " .. vim.inspect(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  )
  return buf
end

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local function with_fake(fn)
  local fake = fake_android.new({ adb_devices = { "emulator-5554\tdevice transport_id:1" } })
  fake.write("logcat", LINES)
  h.with_env(fake.env(), function()
    fn(fake)
  end)
end

local T = {}

T["view: streams lines into a read-only buffer and highlights levels"] = function()
  with_fake(function(fake)
    local buf = open(fake, 4)
    eq(lines(buf), LINES)
    eq(vim.bo[buf].modifiable, false)
    eq(vim.bo[buf].buftype, "nofile")
    local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
    local groups = {}
    for _, m in ipairs(marks) do
      groups[m[2] + 1] = m[4].hl_group
    end
    eq(groups, { [1] = "Comment", [2] = "DiagnosticWarn", [3] = "DiagnosticError" })
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end

T["view: its window settings stay with the log buffer"] = function()
  local before = { number = vim.go.number, wrap = vim.go.wrap, winbar = vim.go.winbar }
  with_fake(function(fake)
    local buf = open(fake, 4)
    local win = vim.fn.bufwinid(buf)
    eq(vim.wo[win].number, false)
    eq(vim.wo[win].winbar ~= "", true)
    -- Another buffer in the same window gets the usual settings back.
    vim.api.nvim_win_call(win, function()
      vim.cmd("enew")
    end)
    eq(vim.wo[win].winbar, before.winbar)
    eq(vim.wo[win].number, before.number)
    eq({ number = vim.go.number, wrap = vim.go.wrap, winbar = vim.go.winbar }, before)
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end

T["view: filter and level re-render from what was received"] = function()
  with_fake(function(fake)
    local buf = open(fake, 4)
    local v = view.get(buf)
    v.filter = "flutter"
    -- The same redraw the f key does.
    v.min_level = 1
    press("<Ignore>")
    local ok = pcall(function()
      vim.ui.input = function(_, cb)
        cb("FLUTTER")
      end
      press("f")
    end)
    assert(ok)
    eq(lines(buf), { LINES[4] })
    vim.ui.select = function(items, _, cb)
      cb(items[4])
    end
    vim.ui.input = function(_, cb)
      cb("")
    end
    press("f")
    press("l")
    eq(lines(buf), { LINES[2], LINES[3] })
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end

T["view: pause keeps lines and shows them on resume"] = function()
  with_fake(function(fake)
    local buf = open(fake, 4)
    local v = view.get(buf)
    press("p")
    eq(v.paused, true)
    v.pending = { { text = "late line" } }
    vim.wait(300)
    eq(#lines(buf), 4)
    press("p")
    eq(lines(buf)[5], "late line")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end

T["view: old lines are dropped past max_lines"] = function()
  config.setup({ logs = { max_lines = 3 } })
  local ok, problem = pcall(with_fake, function(fake)
    local buf = open(fake, 3)
    vim.wait(300)
    eq(lines(buf), { LINES[2], LINES[3], LINES[4] })
    -- A later batch pushes the oldest shown lines out of the buffer.
    local v = assert(view.get(buf))
    v.pending = { { text = "later one" }, { text = "later two" } }
    assert(vim.wait(2000, function()
      return lines(buf)[3] == "later two"
    end, 20))
    eq(lines(buf), { LINES[4], "later one", "later two" })
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  config.setup({})
  assert(ok, problem)
end

T["view: closing the buffer stops the stream"] = function()
  with_fake(function(fake)
    local buf = open(fake, 4)
    local v = view.get(buf)
    local session = v.session
    press("q")
    eq(vim.api.nvim_buf_is_valid(buf), false)
    eq(view.get(buf), nil)
    eq(session.stopped, true)
  end)
end

T["view: a failed stream says why in the buffer"] = function()
  local fake = fake_android.new({ adb_devices = {} })
  h.with_env(fake.env(), function()
    local buf = view.open({
      device = {
        id = "GONE",
        name = "Gone",
        platform = "android",
        kind = "physical",
        state = "connected",
        serial = "GONE",
        source = "adb",
      },
      mode = "logcat",
      android = fake.opts(),
    })
    assert(vim.wait(10000, function()
      return view.get(buf).state == "ended"
    end, 20))
    local last = lines(buf)[#lines(buf)]
    assert(last:find("not found", 1, true), vim.inspect(lines(buf)))
    eq(last:find("not found", 1, true) ~= nil, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end

return T
