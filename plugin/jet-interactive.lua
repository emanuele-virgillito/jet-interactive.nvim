if vim.g.loaded_jet_interactive then
  return
end
vim.g.loaded_jet_interactive = true

vim.api.nvim_create_user_command("JetInteractiveBrowser", function()
  require("jet-interactive").open_browser()
end, { desc = "Open the Jet Interactive browser" })

vim.api.nvim_create_user_command("JetInteractiveClear", function()
  require("jet-interactive").clear()
end, { desc = "Clear Jet Interactive history" })

vim.api.nvim_create_user_command("JetInteractiveVariables", function()
  require("jet.api").get_kernel({
    filetype = "python",
    current = true,
    status = { "connected" },
  }, function(kernel)
    require("jet-interactive").toggle_variables(kernel)
  end)
end, { desc = "Toggle the Jet variable inspector" })

vim.api.nvim_create_user_command("JetInteractiveBuild", function()
  local source = debug.getinfo(1, "S").source:sub(2)
  local root = vim.fs.dirname(vim.fs.dirname(source))
  vim.notify("Compilazione di jet-interactive…", vim.log.levels.INFO)
  vim.system({ "cargo", "build", "--release" }, { cwd = root, text = true }, function(result)
    vim.schedule(function()
      if result.code == 0 then
        vim.notify("jet-interactive compilato correttamente", vim.log.levels.INFO)
      else
        vim.notify(result.stderr, vim.log.levels.ERROR, { title = "JetInteractiveBuild" })
      end
    end)
  end)
end, { desc = "Build the Jet Interactive bridge" })
