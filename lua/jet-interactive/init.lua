local config = require("jet-interactive.config")
local model = require("jet-interactive.model")
local native_view = require("jet-interactive.view.nvim")
local bridge = require("jet-interactive.bridge")
local variables = require("jet-interactive.variables")
local variable_view = require("jet-interactive.view.variables")
local widgets = require("jet-interactive.widgets")

local M = {}
local configured = false
local kernel_sync_timer

local function ensure_setup()
  if not configured then
    M.setup()
  end
end

local function close_automatic_image_window(kernel)
  local image = kernel.bufs and kernel.bufs.img
  if not (image and image.buf) then
    return
  end
  vim.schedule(function()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == image.buf then
        kernel:img_toggle()
        return
      end
    end
  end)
end

local function install_jet_hooks()
  local hooks = require("jet").hooks
  hooks.on_image_display_pre.jet_interactive = function(kernel, path)
    model.pending_image(kernel, path)
  end
  hooks.on_win_open.jet_interactive_image_keys = function(kernel, _, buf)
    if vim.bo[buf].filetype == "jetimg" then
      vim.keymap.set("n", "q", function()
        kernel:img_toggle()
      end, { buffer = buf, silent = true, desc = "Close Jet images" })
    end
  end
  hooks.on_message_received.jet_interactive = function(kernel, message)
    local handled = model.handle_message(kernel, message)
    if handled then
      local data = (message.content or {}).data or {}
      if data["image/png"] then
        close_automatic_image_window(kernel)
      end
      local content = message.content or {}
      if ((message.header or {}).msg_type) == "status"
        and content.execution_state == "idle"
        and config.options.variables.auto_refresh
        and variable_view.visible()
        and variable_view.kernel() == kernel
      then
        variables.refresh(kernel)
      end
    end
  end
  hooks.on_status_changed.jet_interactive = function(kernel)
    widgets.prepare(kernel)
    model.kernel_status(kernel)
  end
end

function M.setup(options)
  config.setup(options)
  if configured then
    return
  end
  configured = true
  model.subscribe("native", function()
    native_view.render(model.history())
  end)
  model.subscribe("web", bridge.publish)
  variables.subscribe("native", variable_view.render)
  install_jet_hooks()
  for _, kernel in pairs(require("jet.core.manager").kernels) do
    widgets.prepare(kernel)
  end
  -- :Jet currently updates `kernel.session_name` directly. Polling the small
  -- in-memory kernel table lets both output views reflect a rename immediately
  -- without modifying Jet itself.
  kernel_sync_timer = vim.uv.new_timer()
  kernel_sync_timer:start(1000, 1000, vim.schedule_wrap(function()
    for _, kernel in pairs(require("jet.core.manager").kernels) do
      model.sync_kernel(kernel)
    end
  end))
  if config.options.web.enabled and config.options.web.auto_start then
    bridge.start()
  end
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("JetInteractive", { clear = true }),
    callback = function()
      bridge.stop()
      if kernel_sync_timer then
        kernel_sync_timer:stop()
        kernel_sync_timer:close()
        kernel_sync_timer = nil
      end
    end,
  })
end

function M.send_lines(kernel, lines, metadata)
  ensure_setup()
  if #lines == 0 then
    vim.notify("Nessun codice da eseguire", vim.log.levels.INFO)
    return
  end
  widgets.prepare(kernel)
  local message_id = kernel:send_lua(lines, false)
  return model.start(kernel, message_id, lines, metadata)
end

function M.clear()
  ensure_setup()
  model.clear()
end

function M.toggle()
  ensure_setup()
  native_view.toggle()
end

function M.open_browser()
  ensure_setup()
  bridge.open_browser()
end

function M.toggle_variables(kernel)
  ensure_setup()
  if variable_view.toggle(kernel) then
    variables.refresh(kernel)
  end
end

function M.refresh_variables(kernel)
  ensure_setup()
  variable_view.open(kernel, false)
  variables.refresh(kernel)
end

return M
