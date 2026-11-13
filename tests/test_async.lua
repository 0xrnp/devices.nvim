local h = require("helpers")
local eq = h.eq

local async = require("devices.async")

local T = {}

T["all: returns results in task order, whatever order they finish in"] = function()
  local results = h.await(function(cb)
    async.all({
      function(done)
        vim.defer_fn(function()
          done("slow")
        end, 80)
      end,
      function(done)
        done("instant")
      end,
      function(done)
        vim.defer_fn(function()
          done("medium")
        end, 20)
      end,
    }, cb)
  end)
  eq(results, { "slow", "instant", "medium" })
end

T["all: finishes with no tasks"] = function()
  local results = h.await(function(cb)
    async.all({}, cb)
  end)
  eq(results, {})
end

T["all: calls back once even when a task reports twice"] = function()
  local results, calls = h.await(function(cb)
    async.all({
      function(done)
        done("first")
        done("second")
      end,
      function(done)
        vim.defer_fn(function()
          done("other")
        end, 10)
      end,
    }, cb)
  end)
  eq(results, { "first", "other" })
  eq(calls, 1)
end

T["all: runs tasks concurrently"] = function()
  local started = vim.uv.hrtime()
  h.await(function(cb)
    local tasks = {}
    for _ = 1, 5 do
      tasks[#tasks + 1] = function(done)
        vim.defer_fn(function()
          done(true)
        end, 200)
      end
    end
    async.all(tasks, cb)
  end)
  local elapsed_ms = (vim.uv.hrtime() - started) / 1e6
  -- Run one after another this would take a second.
  eq(elapsed_ms < 700, true)
end

return T
