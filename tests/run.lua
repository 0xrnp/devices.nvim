-- Dependency-free test runner: `nvim -l tests/run.lua [test_file.lua ...]`
--
-- A test file returns a table of `name = function`. A test fails when it throws.
-- Exits 0 when every test passes and 1 otherwise.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path

local files = #arg > 0 and arg or vim.fn.glob(root .. "/tests/test_*.lua", false, true)
table.sort(files)

local passed, failures = 0, {}
for _, file in ipairs(files) do
  local suite = dofile(file)
  local names = vim.tbl_keys(suite)
  table.sort(names)
  for _, name in ipairs(names) do
    local ok, err = xpcall(suite[name], debug.traceback)
    require("helpers").cleanup()
    if ok then
      passed = passed + 1
      io.stdout:write("  ok    ", name, "\n")
    else
      failures[#failures + 1] = name
      io.stdout:write("  FAIL  ", name, "\n", tostring(err), "\n")
    end
  end
end

io.stdout:write(string.format("\n%d passed, %d failed (nvim %s)\n", passed, #failures, tostring(vim.version())))
os.exit(#failures == 0 and 0 or 1)
