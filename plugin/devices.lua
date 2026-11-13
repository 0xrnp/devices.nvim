if vim.g.loaded_devices then
  return
end
vim.g.loaded_devices = true

if vim.fn.has("nvim-0.10") == 0 then
  vim.api.nvim_create_user_command("Devices", function()
    vim.notify("devices.nvim needs Neovim 0.10 or newer", vim.log.levels.ERROR)
  end, { nargs = "*" })
  return
end

-- Only the command is defined at startup. Everything else loads on first use.
require("devices.commands").register()
