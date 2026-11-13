-- Run as `nvim --headless -l tests/fixtures/run_and_quit.lua <repo root> <pid file>`.
-- Starts a long command through process.run, waits until it is running, then quits Neovim, so a
-- test can check that quitting stopped it.
vim.opt.runtimepath:prepend(arg[1])
local pidfile = arg[2]

require("devices.process").run(
  { "sh", "-c", 'echo $$ > "$1"; sleep 30', "sh", pidfile },
  { timeout = 60000 },
  function() end
)
vim.wait(5000, function()
  return vim.uv.fs_stat(pidfile) ~= nil and vim.fn.readfile(pidfile)[1] ~= nil
end, 10)

vim.cmd("qall!")
