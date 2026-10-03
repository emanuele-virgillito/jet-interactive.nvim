local config = require("jet-interactive.config")

local M = {}
local output_buf
local kernel_filter

local function buffer()
  if output_buf and vim.api.nvim_buf_is_valid(output_buf) then
    return output_buf
  end
  output_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(output_buf, "Jet Output")
  vim.bo[output_buf].buftype = "nofile"
  vim.bo[output_buf].bufhidden = "hide"
  vim.bo[output_buf].swapfile = false
  vim.bo[output_buf].filetype = "jetoutput"
  vim.bo[output_buf].modifiable = false
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = output_buf, silent = true, desc = "Close Jet output" })
  vim.keymap.set("n", "C", function()
    require("jet-interactive").clear()
  end, { buffer = output_buf, silent = true, desc = "Clear Jet output" })
  vim.keymap.set("n", "a", function()
    M.set_kernel_filter(nil)
  end, { buffer = output_buf, silent = true, desc = "Show output from all kernels" })
  vim.keymap.set("n", "s", function()
    M.select_kernel_filter()
  end, { buffer = output_buf, silent = true, desc = "Select output kernel" })
  return output_buf
end

local function clean_lines(text)
  local clean = tostring(text):gsub("\27%[[0-9;]*m", "")
  return vim.split(clean, "\n", { plain = true })
end

local function add_text(lines, text)
  for _, line in ipairs(clean_lines(text)) do
    table.insert(lines, "  " .. line)
  end
end

local function mime_text(output)
  local data = output.data or {}
  if data["text/html"] then
    return "[Output HTML disponibile nella Interactive Window web]"
  elseif data["application/vnd.plotly.v1+json"] then
    return "[Grafico Plotly disponibile nella Interactive Window web]"
  elseif data["text/plain"] then
    return type(data["text/plain"]) == "table" and table.concat(data["text/plain"], "") or data["text/plain"]
  end
  return "[Rich output disponibile nella Interactive Window web]"
end

local function image_supported(path)
  return path
    and _G.Snacks
    and Snacks.image
    and Snacks.image.config
    and Snacks.image.config.enabled ~= false
    and Snacks.image.supports(path)
end

local function render_images(buf, images)
  if not (_G.Snacks and Snacks.image and Snacks.image.placement) then
    return
  end
  Snacks.image.placement.clean(buf)
  for _, image in ipairs(images) do
    Snacks.image.placement.new(buf, image.path, {
      inline = true,
      pos = { image.line, 2 },
      max_width = config.options.native.image_max_width,
      max_height = config.options.native.image_max_height,
      auto_resize = true,
    })
  end
end

local function status(execution)
  if execution.status == "error" then
    return "✗ errore", "DiagnosticError"
  elseif execution.status == "done" then
    return "✓ completata", "DiagnosticOk"
  end
  return "● in esecuzione", "DiagnosticInfo"
end

local function filtered_history(history)
  if not kernel_filter then
    return history
  end
  return vim.tbl_filter(function(execution)
    return (execution.kernel or {}).id == kernel_filter
  end, history)
end

local function filter_label(history)
  if not kernel_filter then
    return "tutte le sessioni"
  end
  local known = require("jet-interactive.model").kernels()[kernel_filter]
  if known then
    return known.name .. " · " .. kernel_filter
  end
  for _, execution in ipairs(history) do
    local kernel = execution.kernel or {}
    if kernel.id == kernel_filter then
      return kernel.name .. " · " .. kernel_filter
    end
  end
  return kernel_filter
end

function M.render(history)
  local buf = buffer()
  local visible_history = filtered_history(history)
  local lines = { "Jet Output — " .. filter_label(history) }
  local highlights = { { line = 0, group = "Title" } }
  local images = {}
  if #visible_history == 0 then
    vim.list_extend(lines, { "", "Nessuna esecuzione." })
  end
  for _, execution in ipairs(visible_history) do
    local status_text, status_highlight = status(execution)
    local count = execution.count and tostring(execution.count) or "…"
    local source = execution.source and (" · " .. execution.source) or ""
    table.insert(lines, "")
    table.insert(lines, ("── In [%s] · %s%s · %s ──"):format(count, execution.label, source, status_text))
    table.insert(highlights, { line = #lines - 1, group = status_highlight })
    table.insert(lines, "Codice")
    table.insert(highlights, { line = #lines - 1, group = "Comment" })
    for _, line in ipairs(execution.code) do
      table.insert(lines, "  " .. line)
    end
    table.insert(lines, "Output")
    table.insert(highlights, { line = #lines - 1, group = "Comment" })
    if #execution.outputs == 0 then
      table.insert(lines, "  …")
    else
      for _, output in ipairs(execution.outputs) do
        if output.image_path and image_supported(output.image_path) then
          table.insert(lines, "  ")
          table.insert(images, { line = #lines, path = output.image_path })
        elseif output.kind == "display" then
          add_text(lines, mime_text(output))
        else
          add_text(lines, output.text or "")
        end
      end
    end
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, -1, 0, -1)
  for _, highlight in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(buf, -1, highlight.group, highlight.line, 0, -1)
  end
  vim.bo[buf].modifiable = false
  render_images(buf, images)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      vim.api.nvim_win_set_cursor(win, { #lines, 0 })
    end
  end
end

function M.set_kernel_filter(session_id)
  kernel_filter = session_id
  M.render(require("jet-interactive.model").history())
end

function M.select_kernel_filter()
  local kernels = {}
  local seen = {}
  for _, execution in ipairs(require("jet-interactive.model").history()) do
    local kernel = execution.kernel or {}
    if kernel.id and not seen[kernel.id] then
      seen[kernel.id] = true
      table.insert(kernels, kernel)
    end
  end
  if #kernels == 0 then
    vim.notify("Non ci sono ancora sessioni con output", vim.log.levels.INFO)
    return
  end
  vim.ui.select(kernels, {
    prompt = "Mostra output della sessione",
    format_item = function(kernel)
      return ("%s · %s"):format(kernel.name or "Jupyter", kernel.id)
    end,
  }, function(kernel)
    if kernel then
      M.set_kernel_filter(kernel.id)
    end
  end)
end

function M.open(focus)
  local buf = buffer()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      if focus then
        vim.api.nvim_set_current_win(win)
      end
      return
    end
  end
  vim.api.nvim_open_win(buf, focus, { split = config.options.native.split, win = -1, style = "minimal" })
end

function M.toggle()
  local buf = buffer()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      vim.api.nvim_win_close(win, false)
      return
    end
  end
  M.open(true)
end

return M
