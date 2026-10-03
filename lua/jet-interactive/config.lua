local M = {}

M.defaults = {
  web = {
    enabled = true,
    auto_start = true,
    open_local = true,
    -- auto prefers Chrome, then Chromium, then Firefox. Chrome and Chromium
    -- use app mode; Firefox deliberately retains its regular browser chrome.
    browser = "auto",
    auto_install = true,
    binary_path = nil,
    release = "latest",
    repository = "emanuele-virgillito/jet-interactive.nvim",
  },
  history = {
    persist = false,
  },
  native = {
    split = "right",
    image_max_width = 60,
    image_max_height = 20,
  },
  variables = {
    split = "left",
    width = 58,
    auto_refresh = true,
    max_repr = 120,
    max_children = 200,
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(options)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), options or {})
  return M.options
end

return M
