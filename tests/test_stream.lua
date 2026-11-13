local h = require("helpers")
local eq = h.eq

local process = require("devices.process")

--- Run a stream to the end (or until `stop_after` lines), collecting lines and the exit.
local function collect(argv, stop_after)
  local lines, exit = {}, nil
  local stream
  stream = process.stream(argv, nil, function(list, source)
    for _, line in ipairs(list) do
      lines[#lines + 1] = source .. ":" .. line
    end
    if stop_after and #lines >= stop_after then
      stream.stop()
    end
  end, function(res)
    exit = res
  end)
  assert(
    vim.wait(15000, function()
      return exit ~= nil
    end, 10),
    "the stream did not end"
  )
  return lines, exit, stream
end

local T = {}

T["stream: whole lines in order, from both outputs"] = function()
  local lines, exit = collect({ "sh", "-c", "printf 'a\\nb\\n'; printf 'oops\\n' >&2; printf 'c\\n'" })
  local out = vim.tbl_filter(function(l)
    return vim.startswith(l, "stdout:")
  end, lines)
  eq(out, { "stdout:a", "stdout:b", "stdout:c" })
  eq(vim.tbl_contains(lines, "stderr:oops"), true)
  eq(exit.code, 0)
  eq(exit.stopped, false)
end

T["stream: a line split across writes arrives once, whole"] = function()
  local lines = collect({ "sh", "-c", "printf 'hel'; sleep 0.2; printf 'lo\\nwor'; sleep 0.2; printf 'ld\\n'" })
  eq(lines, { "stdout:hello", "stdout:world" })
end

T["stream: the last line without a newline is not lost, and CRLF is trimmed"] = function()
  local lines = collect({ "sh", "-c", "printf 'one\\r\\ntwo'" })
  eq(lines, { "stdout:one", "stdout:two" })
end

T["stream: stop ends it, stops its children, and no lines come after"] = function()
  local pidfile = h.tree({}) .. "/child.pid"
  local lines, exit = collect({
    "sh",
    "-c",
    'sleep 30 & echo $! > "$1"; while :; do echo tick; sleep 0.05; done',
    "sh",
    pidfile,
  }, 3)
  eq(exit.stopped, true)
  -- Lines that were already on their way when stop() ran are dropped.
  eq(#lines >= 3 and #lines <= 4, true)
  local child = tonumber(vim.fn.readfile(pidfile)[1])
  local gone = vim.wait(3000, function()
    return vim.uv.kill(child, 0) ~= 0
  end, 20)
  if not gone then
    vim.uv.kill(child, "sigkill")
  end
  eq(gone, true)
end

T["stream: nothing is delivered after stop, even with output still in flight"] = function()
  local after_stop, stopped, exit = 0, false, nil
  local stream
  -- Output as fast as possible, so plenty is queued when stop() runs.
  stream = process.stream({ "sh", "-c", "while :; do echo tick; done" }, nil, function()
    if stopped then
      after_stop = after_stop + 1
      return
    end
    stopped = true
    stream.stop()
  end, function(res)
    exit = res
  end)
  assert(vim.wait(15000, function()
    return exit ~= nil
  end, 10))
  eq(exit.stopped, true)
  eq(after_stop, 0)
end

T["stream: a missing tool reports once, without throwing"] = function()
  local lines, exit = collect({ "devices-nvim-no-such-tool" })
  eq(lines, {})
  eq(exit.missing, true)
end

T["stream: stop after the end is harmless"] = function()
  local _, exit, stream = collect({ "true" })
  eq(exit.code, 0)
  stream.stop()
  stream.stop()
  eq(stream.is_running(), false)
end

return T
