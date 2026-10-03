local config = require("jet-interactive.config")
local variables = require("jet-interactive.variables")

local M = {}
local variable_buf
local current_kernel
local row_nodes = {}

local function set_highlights()
  -- Match dap-view's semantic palette while keeping this view independent
  -- from dap-view: names are identifiers, types are types, and scalar values
  -- use the corresponding syntax group.
  vim.api.nvim_set_hl(0, "JetVariablesMarker", { default = true, link = "Special" })
  vim.api.nvim_set_hl(0, "JetVariablesName", { default = true, link = "Identifier" })
  vim.api.nvim_set_hl(0, "JetVariablesType", { default = true, link = "Type" })
  vim.api.nvim_set_hl(0, "JetVariablesMetadata", { default = true, link = "Comment" })
end

vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("JetInteractiveVariableHighlights", { clear = true }),
  callback = set_highlights,
})

local function value_highlight(type_name)
  type_name = (type_name or ""):lower():match("([^.]+)$") or ""
  if type_name == "bool" or type_name == "boolean" then
    return "Boolean"
  elseif type_name == "int" or type_name == "long" then
    return "Number"
  elseif type_name == "float" or type_name == "double" or type_name == "complex" then
    return "Float"
  elseif type_name == "str" or type_name == "string" or type_name == "bytes" or type_name == "bytearray" then
    return "String"
  elseif type_name == "nonetype" or type_name == "nil" then
    return "Constant"
  elseif type_name == "function" or type_name == "method" then
    return "Function"
  end
  return "Normal"
end

local function buffer()
  if variable_buf and vim.api.nvim_buf_is_valid(variable_buf) then
    return variable_buf
  end
  variable_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(variable_buf, "Jet Variables")
  vim.bo[variable_buf].buftype = "nofile"
  vim.bo[variable_buf].bufhidden = "hide"
  vim.bo[variable_buf].swapfile = false
  vim.bo[variable_buf].filetype = "jetvariables"
  vim.bo[variable_buf].modifiable = false
  set_highlights()
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = variable_buf, silent = true, desc = "Close Jet variables" })
  vim.keymap.set("n", "r", function()
    if current_kernel then
      variables.refresh(current_kernel)
    end
  end, { buffer = variable_buf, silent = true, desc = "Refresh variables" })
  vim.keymap.set("n", "<CR>", function()
    local node = row_nodes[vim.api.nvim_win_get_cursor(0)[1]]
    if node and current_kernel then
      variables.expand(current_kernel, node)
    end
  end, { buffer = variable_buf, silent = true, desc = "Expand variable" })
  return variable_buf
end

local function append_node(lines, highlights, node, depth)
  local prefix = string.rep("  ", depth)
  local marker = node.loading and "◌" or (node.expandable and (node.open and "▾" or "▸") or " ")
  local name = node.name or ""
  local type_name = node.type or ""
  local value = node.value or ""
  local name_field = ("%-20s"):format(name)
  local type_field = ("%-22s"):format(type_name)
  local details = node.shape and ("  shape=" .. node.shape) or ""
  if node.dtype then
    details = details .. "  dtype=" .. node.dtype
  end
  local line = prefix .. marker .. " " .. name_field .. " " .. type_field .. " " .. value .. details
  table.insert(lines, line)
  row_nodes[#lines] = node

  local line_number = #lines - 1
  local marker_start = #prefix
  local name_start = marker_start + #marker + 1
  local type_start = name_start + #name_field + 1
  local value_start = type_start + #type_field + 1
  table.insert(highlights, { line = line_number, group = "JetVariablesMarker", start_col = marker_start, end_col = marker_start + #marker })
  table.insert(highlights, { line = line_number, group = "JetVariablesName", start_col = name_start, end_col = name_start + #name })
  table.insert(highlights, { line = line_number, group = "JetVariablesType", start_col = type_start, end_col = type_start + #type_name })
  table.insert(highlights, { line = line_number, group = value_highlight(type_name), start_col = value_start, end_col = value_start + #value })
  if details ~= "" then
    table.insert(highlights, {
      line = line_number,
      group = "JetVariablesMetadata",
      start_col = value_start + #value,
      end_col = -1,
    })
  end
  if node.error then
    table.insert(lines, prefix .. "    " .. node.error)
    table.insert(highlights, { line = #lines - 1, group = "DiagnosticError" })
  end
  if node.open then
    for _, child in ipairs(node.children or {}) do
      append_node(lines, highlights, child, depth + 1)
    end
  end
end

function M.render(current)
  if not current_kernel or current.kernel ~= current_kernel then
    return
  end
  local buf = buffer()
  local kernel_name = ((current.kernel or {}).spec or {}).display_name or "Python"
  local lines = { "Jet Variables — " .. kernel_name, "", "   Name                 Type                   Value" }
  local highlights = { { line = 0, group = "Title" }, { line = 2, group = "Comment" } }
  row_nodes = {}
  if current.loading and #current.nodes == 0 then
    vim.list_extend(lines, { "", "Caricamento…" })
  elseif current.error then
    vim.list_extend(lines, { "", "Errore: " .. current.error })
    table.insert(highlights, { line = #lines - 1, group = "DiagnosticError" })
  elseif #current.nodes == 0 then
    vim.list_extend(lines, { "", "Nessuna variabile utente." })
  else
    for _, node in ipairs(current.nodes) do
      append_node(lines, highlights, node, 0)
    end
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, -1, 0, -1)
  for _, highlight in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(
      buf,
      -1,
      highlight.group,
      highlight.line,
      highlight.start_col or 0,
      highlight.end_col or -1
    )
  end
  vim.bo[buf].modifiable = false
end

function M.visible()
  if not variable_buf then
    return false
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == variable_buf then
      return true
    end
  end
  return false
end

function M.open(kernel, focus)
  current_kernel = kernel
  local buf = buffer()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      if focus then
        vim.api.nvim_set_current_win(win)
      end
      M.render(variables.get(kernel))
      return
    end
  end
  local win = vim.api.nvim_open_win(buf, focus, {
    split = config.options.variables.split,
    win = -1,
    style = "minimal",
  })
  vim.api.nvim_win_set_width(win, config.options.variables.width)
  vim.wo[win].wrap = false
  M.render(variables.get(kernel))
end

function M.toggle(kernel)
  if M.visible() then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == variable_buf then
        vim.api.nvim_win_close(win, false)
        break
      end
    end
    return false
  end
  M.open(kernel, true)
  return true
end

function M.kernel()
  return current_kernel
end

return M
