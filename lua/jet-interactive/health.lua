local M = {}

function M.check()
  vim.health.start("jet-interactive.nvim")
  local binary = require("jet-interactive.bridge").binary_path()
  if binary then
    vim.health.ok("bridge executable: " .. binary)
  else
    vim.health.error("jet-interactive executable not found", {
      "Run :JetInteractiveBuild for a development checkout",
      "or enable web.auto_install to download a released binary",
    })
  end
  if vim.fn.executable("ssh") == 1 then
    vim.health.ok("ssh available for remote attach")
  else
    vim.health.warn("ssh not found; remote attach will be unavailable")
  end
  if vim.fn.executable("cargo") == 1 then
    vim.health.ok("cargo available for local builds")
  else
    vim.health.info("cargo not found; use a prebuilt release")
  end
end

return M
