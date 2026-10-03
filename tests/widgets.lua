local root = vim.env.JET_INTERACTIVE_ROOT or vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local widgets = require("jet-interactive.widgets")
local sanitize = widgets._sanitize_for_jet

local source = {
  method = "update",
  state = {
    _js2py_relayout = vim.NIL,
    retained = {
      range = { 1.5, 3.5 },
      enabled = true,
    },
  },
}

local result = sanitize(source)
assert(result ~= source)
assert(result.method == "update")
assert(result.state._js2py_relayout == nil)
assert(result.state.retained.range[1] == 1.5)
assert(result.state.retained.range[2] == 3.5)
assert(result.state.retained.enabled == true)
assert(source.state._js2py_relayout == vim.NIL)

print("widget protocol tests: ok")
