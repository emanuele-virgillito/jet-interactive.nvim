local M = {}
local prepared = setmetatable({}, { __mode = "k" })

local targets = {
  ["jupyter.widget"] = true,
  ["jupyter.widget.control"] = true,
  -- FigureWidgetResampler may register Dash's auxiliary comm while it builds
  -- its Python-side callback machinery.  It is not a browser-facing widget,
  -- but Jet must leave it open instead of replying with an unsolicited close.
  ["dash"] = true,
}

local function kernel_id(kernel)
  return kernel.session_id or kernel.client_id
end

local function find_kernel(id)
  for _, kernel in pairs(require("jet.core.manager").kernels) do
    if kernel_id(kernel) == id then
      return kernel
    end
  end
end

-- vim.json.decode represents JSON null as vim.NIL (userdata). Jet's Lua/Rust
-- boundary accepts regular Lua values only, so forwarding vim.NIL makes
-- comm_send fail before the message reaches Jupyter. Widget protocols use
-- null-valued fields mainly to clear transient command traits (Plotly resets
-- _js2py_* this way); omitting those fields preserves the preceding command.
local function sanitize_for_jet(value)
  if value == vim.NIL then
    return nil
  end
  if type(value) ~= "table" then
    return value
  end

  local clean = {}
  for key, item in pairs(value) do
    local sanitized = sanitize_for_jet(item)
    if sanitized ~= nil then
      clean[key] = sanitized
    end
  end
  return clean
end

-- Jet 0.0.8 does not expose the binary buffers attached to Jupyter messages.
-- Plotly normally uses those buffers for numeric arrays, which would leave
-- only dtype/shape in Lua. FigureWidgetResampler sends a small downsampled
-- view, so JSON arrays are an acceptable and reliable transport here; the
-- full-resolution data remains in Python.
local python_bootstrap = {
  "try:",
  "    import numpy as _ji_numpy",
  "    import plotly.basewidget as _ji_basewidget",
  "    import plotly.serializers as _ji_serializers",
  "    from plotly.basedatatypes import Undefined as _ji_undefined",
  "    def _ji_to_json(value, widget_manager):",
  "        if isinstance(value, dict):",
  "            return {key: _ji_to_json(item, widget_manager) for key, item in value.items()}",
  "        if isinstance(value, (list, tuple)):",
  "            return [_ji_to_json(item, widget_manager) for item in value]",
  "        if isinstance(value, _ji_numpy.ndarray):",
  "            return value.tolist()",
  "        if value is _ji_undefined:",
  "            return '_undefined_'",
  "        return value",
  "    for _ji_trait in _ji_basewidget.BaseFigureWidget.class_traits().values():",
  "        if _ji_trait.metadata.get('to_json') is _ji_serializers._py_to_js:",
  "            _ji_trait.metadata['to_json'] = _ji_to_json",
  "except ImportError:",
  "    pass",
}

---Prevent Jet from closing widget comms before the web frontend can handle
---them. Their actual messages are captured by the regular Jet hook.
function M.attach(kernel)
  for target in pairs(targets) do
    if kernel.known_comms[target] == nil then
      kernel.known_comms[target] = function() end
    end
  end
end

---Prepare Python Plotly widgets once per Jet client. The silent request is
---queued before user executions and does not appear in Interactive history.
function M.prepare(kernel)
  M.attach(kernel)
  if prepared[kernel] then
    return
  end
  local status = type(kernel.status) == "function" and select(1, kernel:status()) or kernel.status
  local language = (kernel.spec or {}).language
  if status ~= "connected" or (kernel.filetype ~= "python" and language ~= "python") then
    return
  end
  prepared[kernel] = true
  local ok = pcall(kernel.send_lua, kernel, python_bootstrap, true)
  if not ok then
    prepared[kernel] = nil
  end
end

function M.handle_browser_message(message)
  local kernel = find_kernel(message.kernel_id)
  if not kernel then
    vim.notify("Sessione Jet non disponibile per il widget", vim.log.levels.WARN, { title = "Jet Interactive" })
    return
  end

  if message.type == "widget.comm_msg.request" then
    kernel:comm_send(message.comm_id, sanitize_for_jet(message.data or {}))
  elseif message.type == "widget.comm_close.request" then
    kernel:comm_close(message.comm_id)
  end
end

-- Exposed only to keep the JSON/Lua protocol boundary independently testable.
M._sanitize_for_jet = sanitize_for_jet

return M
