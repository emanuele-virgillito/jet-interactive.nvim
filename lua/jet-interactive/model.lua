local M = {}

local state = {
  executions = {},
  history = {},
  displays = {},
  pending_images = {},
  kernels = {},
  widgets = {},
}

local subscribers = {}
local kernel_metadata

local function copy(value)
  if value == nil then
    return nil
  end

  -- Jupyter messages are JSON data. Copying through the JSON codec handles
  -- `vim.NIL` and parser-owned tables found in rich MIME bundles, while
  -- `vim.deepcopy()` is only safe for ordinary Lua tables.
  return vim.json.decode(vim.json.encode(value))
end

local function emit(event)
  event.protocol = "v1"
  for _, subscriber in pairs(subscribers) do
    subscriber(copy(event))
  end
end

local function execution_for(message)
  return state.executions[(message.parent_header or {}).msg_id]
end

local function encoded_buffers(message)
  local result = {}
  for _, buffer in ipairs(message.buffers or {}) do
    if type(buffer) == "string" and vim.base64 then
      table.insert(result, vim.base64.encode(buffer))
    end
  end
  return result
end

local function merge_widget_state(widget, data)
  if (data.method ~= "update" and data.method ~= "echo_update") or type(data.state) ~= "table" then
    return
  end
  widget.state = widget.state or {}
  for name, value in pairs(data.state) do
    widget.state[name] = copy(value)
  end
end

local function handle_widget_message(kernel, message)
  local kind = (message.header or {}).msg_type
  if kind ~= "comm_open" and kind ~= "comm_msg" and kind ~= "comm_close" then
    return false
  end

  local content = message.content or {}
  local comm_id = content.comm_id
  if not comm_id then
    return false
  end

  local kernel_info = kernel_metadata(kernel)
  if kind == "comm_open" then
    if content.target_name ~= "jupyter.widget" then
      return false
    end
    local data = copy(content.data or {})
    local widget = {
      comm_id = comm_id,
      kernel = kernel_info,
      target_name = content.target_name,
      state = data.state or {},
      buffer_paths = data.buffer_paths or {},
      buffers = encoded_buffers(message),
      closed = false,
    }
    state.widgets[comm_id] = widget
    emit({ type = "widget.comm_open", widget = widget })
  elseif kind == "comm_msg" then
    local widget = state.widgets[comm_id]
    if not widget then
      return false
    end
    local data = copy(content.data or {})
    merge_widget_state(widget, data)
    emit({
      type = "widget.comm_msg",
      kernel_id = kernel_info.id,
      comm_id = comm_id,
      data = data,
      buffers = encoded_buffers(message),
    })
  else
    local widget = state.widgets[comm_id]
    if not widget then
      return false
    end
    widget.closed = true
    emit({ type = "widget.comm_close", kernel_id = kernel_info.id, comm_id = comm_id })
  end
  return true
end

kernel_metadata = function(kernel)
  local spec = kernel.spec or {}
  return {
    id = kernel.session_id or kernel.client_id,
    name = kernel.session_name or spec.display_name or spec.name or kernel.session_id or "Jupyter",
  }
end

local function remove_display_references(execution)
  for _, output in ipairs(execution.outputs) do
    if output.display_id then
      state.displays[output.display_id] = nil
    end
  end
end

local function clear_outputs(execution, notify)
  remove_display_references(execution)
  execution.outputs = {}
  if notify then
    emit({ type = "output.clear", execution_id = execution.id })
  end
end

local function prepare_output(execution)
  if execution.clear_pending then
    execution.clear_pending = false
    clear_outputs(execution, true)
  end
end

local function display_output(kernel, message)
  local content = message.content or {}
  local output = {
    kind = "display",
    data = copy(content.data or {}),
    metadata = copy(content.metadata or {}),
    display_id = content.transient and content.transient.display_id,
  }
  if output.data["image/png"] then
    output.image_path = state.pending_images[kernel]
    state.pending_images[kernel] = nil
  end
  return output
end

local function append_output(execution, output)
  table.insert(execution.outputs, output)
  if output.display_id then
    state.displays[output.display_id] = output
  end
  emit({ type = "output.append", execution_id = execution.id, output = output })
end

local function add_display(execution, kernel, message, update)
  prepare_output(execution)
  local output = display_output(kernel, message)
  local previous = output.display_id and state.displays[output.display_id] or nil
  if update and previous then
    previous.data = output.data
    previous.metadata = output.metadata
    previous.image_path = output.image_path
    emit({ type = "output.update", display_id = output.display_id, output = previous })
    return
  end
  append_output(execution, output)
end

function M.subscribe(name, callback)
  subscribers[name] = callback
end

function M.unsubscribe(name)
  subscribers[name] = nil
end

function M.snapshot()
  return {
    protocol = "v1",
    type = "session.snapshot",
    executions = copy(state.history),
    kernels = copy(state.kernels),
    widgets = copy(state.widgets),
  }
end

function M.start(kernel, message_id, lines, metadata)
  metadata = metadata or {}
  local kernel_info = kernel_metadata(kernel)
  state.kernels[kernel_info.id] = kernel_info
  local execution = {
    id = message_id,
    label = metadata.label or "Esecuzione",
    source = metadata.source,
    range = copy(metadata.range),
    code = copy(lines),
    kernel = kernel_info,
    outputs = {},
    status = "running",
  }
  state.executions[message_id] = execution
  table.insert(state.history, execution)
  emit({ type = "execution.started", execution = execution })
  return execution
end

function M.pending_image(kernel, path)
  state.pending_images[kernel] = path
end

function M.handle_message(kernel, message)
  if handle_widget_message(kernel, message) then
    return true
  end
  local execution = execution_for(message)
  if not execution then
    return false
  end

  local kind = (message.header or {}).msg_type
  local content = message.content or {}

  if kind == "execute_input" then
    execution.count = content.execution_count
    emit({ type = "execution.started", execution = execution })
  elseif kind == "stream" and content.text then
    prepare_output(execution)
    local previous = execution.outputs[#execution.outputs]
    if previous and previous.kind == "stream" and previous.name == content.name then
      previous.text = previous.text .. content.text
      emit({ type = "output.update", execution_id = execution.id, output_index = #execution.outputs, output = previous })
    else
      append_output(execution, {
        kind = "stream",
        name = content.name,
        text = content.text,
      })
    end
  elseif kind == "execute_result" or kind == "display_data" then
    add_display(execution, kernel, message, false)
  elseif kind == "update_display_data" then
    add_display(execution, kernel, message, true)
  elseif kind == "clear_output" then
    if content.wait then
      execution.clear_pending = true
    else
      clear_outputs(execution, true)
    end
  elseif kind == "error" then
    prepare_output(execution)
    execution.status = "error"
    append_output(execution, {
      kind = "error",
      text = table.concat(content.traceback or {
        (content.ename or "Python error") .. ": " .. (content.evalue or ""),
      }, "\n"),
    })
  elseif kind == "status" and content.execution_state == "idle" then
    if execution.status ~= "error" then
      execution.status = "done"
    end
    emit({ type = "execution.finished", execution_id = execution.id, status = execution.status })
  else
    return false
  end
  return true
end

function M.sync_kernel(kernel)
  local status = type(kernel.status) == "function" and select(1, kernel:status()) or kernel.status
  local kernel_info = kernel_metadata(kernel)
  -- Jet clears both identifiers while closing an owned kernel. There is no
  -- session left to expose in the views at that point.
  if not kernel_info.id then
    return
  end
  local previous = state.kernels[kernel_info.id]
  if previous and previous.name == kernel_info.name and previous.status == status then
    return
  end
  kernel_info.status = status
  state.kernels[kernel_info.id] = kernel_info
  emit({ type = "kernel.status", kernel = kernel_info, status = status })
end

M.kernel_status = M.sync_kernel

function M.kernels()
  return state.kernels
end

function M.clear()
  state.executions = {}
  state.history = {}
  state.displays = {}
  state.pending_images = {}
  state.kernels = {}
  state.widgets = {}
  emit({ type = "history.clear" })
end

function M.history()
  return state.history
end

return M
