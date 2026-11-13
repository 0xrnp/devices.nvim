local M = {}

--- Fail unless `actual` deeply equals `expected`.
function M.eq(actual, expected)
  if not vim.deep_equal(actual, expected) then
    error(string.format("expected %s\n     got %s", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

--- Fail unless `fn` throws.
function M.expect_error(fn)
  if pcall(fn) then
    error("expected an error, got none", 2)
  end
end

--- Start an async call and block until its callback fires. Fails if it never does.
--- Returns the callback argument and how many times the callback ran.
---@param start fun(cb: fun(res: any))
---@param timeout? integer
function M.await(start, timeout)
  local calls, last = 0, nil
  start(function(res)
    calls = calls + 1
    last = res
  end)
  local ok = vim.wait(timeout or 10000, function()
    return calls > 0
  end, 10)
  assert(ok, "callback was not called in time")
  -- Let an accidental second call arrive before counting.
  vim.wait(100)
  return last, calls
end

local created = {}

--- Create a temporary directory tree and return its root. `spec` maps a relative path to file
--- content. A path ending in "/" is a directory. Content starting with "#!" is made executable,
--- so `{ ["bin/adb"] = "#!/bin/sh\necho hi" }` is a working fake tool.
---@param spec table<string, string>
---@return string root
function M.tree(spec)
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  created[#created + 1] = root
  for path, content in pairs(spec) do
    if path:sub(-1) == "/" then
      vim.fn.mkdir(root .. "/" .. path, "p")
    else
      vim.fn.mkdir(vim.fn.fnamemodify(root .. "/" .. path, ":h"), "p")
      vim.fn.writefile(vim.split(content, "\n", { plain = true }), root .. "/" .. path)
      if content:sub(1, 2) == "#!" then
        vim.uv.fs_chmod(root .. "/" .. path, tonumber("755", 8))
      end
    end
  end
  return root
end

--- Delete everything `tree` created. The runner calls this after every test.
function M.cleanup()
  for _, root in ipairs(created) do
    vim.fn.delete(root, "rf")
  end
  created = {}
end

--- Run `fn` with environment variables set (a nil value unsets), then restore them, even when
--- `fn` throws. Child processes and `exepath` see the changed values.
---@param vars table<string, string|false>
---@param fn fun()
function M.with_env(vars, fn)
  local saved = {}
  for name, value in pairs(vars) do
    saved[name] = vim.env[name] or false
    vim.env[name] = value or nil
  end
  local ok, err = pcall(fn)
  for name, value in pairs(saved) do
    vim.env[name] = value or nil
  end
  if not ok then
    error(err, 0)
  end
end

--- An environment with no Android or Java configuration and nothing on PATH, so a test only
--- sees the tools it creates. Merge more variables in with `extra`.
---@param extra? table<string, string|false>
---@return table<string, string|false>
function M.isolated(extra)
  local empty = M.tree({ ["bin/"] = "" })
  return vim.tbl_extend("force", {
    PATH = empty .. "/bin",
    HOME = empty,
    ANDROID_HOME = false,
    ANDROID_SDK_ROOT = false,
    ANDROID_AVD_HOME = false,
    ANDROID_USER_HOME = false,
    ANDROID_SDK_HOME = false,
    JAVA_HOME = false,
  }, extra or {})
end

return M
