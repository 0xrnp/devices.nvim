-- Run as `nvim -l tests/fixtures/spawn_and_exit.lua <repo root>`.
-- Starts a detached process, prints its pid, and exits, so a test can check that the process
-- outlives the Neovim that started it.
vim.opt.runtimepath:prepend(arg[1])

local result
require("devices.process").spawn_detached({ "sleep", "30" }, { grace_ms = 200 }, function(res)
  result = res
end)
vim.wait(5000, function()
  return result ~= nil
end, 10)

io.stdout:write(tostring(result and result.pid))
os.exit(0)
