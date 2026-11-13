local M = {}

--- Run async tasks concurrently and call `cb` once with their results, in task order.
--- A task is `function(done)` and must call `done(result)`. A second call to `done` is ignored.
---@param tasks (fun(done: fun(result: any)))[]
---@param cb fun(results: any[])
function M.all(tasks, cb)
  local remaining = #tasks
  if remaining == 0 then
    vim.schedule(function()
      cb({})
    end)
    return
  end

  local results = {}
  for index, task in ipairs(tasks) do
    local finished = false
    task(function(result)
      if finished then
        return
      end
      finished = true
      results[index] = result
      remaining = remaining - 1
      if remaining == 0 then
        cb(results)
      end
    end)
  end
end

return M
