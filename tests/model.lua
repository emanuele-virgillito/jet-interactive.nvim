local root = assert(vim.env.JET_INTERACTIVE_ROOT)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local model = require("jet-interactive.model")
local events = {}
model.subscribe("test", function(event)
  -- Every event crosses the NDJSON bridge and must remain JSON-only.
  assert(vim.json.encode(event))
  table.insert(events, event)
end)

local kernel = { session_id = "kernel-1", spec = { display_name = "Python" } }
function kernel:status()
  return "connected", "icon"
end

model.kernel_status(kernel)
assert(events[#events].status == "connected")
model.start(kernel, "request-1", { "print('hello')" }, { label = "Test", source = "example.py" })
model.handle_message(kernel, {
  header = { msg_type = "stream" },
  parent_header = { msg_id = "request-1" },
  content = { name = "stdout", text = "hello\n" },
})
model.handle_message(kernel, {
  header = { msg_type = "display_data" },
  parent_header = { msg_id = "request-1" },
  content = { data = { ["text/plain"] = "42" }, transient = { display_id = "display-1" } },
})
model.handle_message(kernel, {
  header = { msg_type = "update_display_data" },
  parent_header = { msg_id = "request-1" },
  content = { data = { ["text/plain"] = "43" }, transient = { display_id = "display-1" } },
})
model.handle_message(kernel, {
  header = { msg_type = "status" },
  parent_header = { msg_id = "request-1" },
  content = { execution_state = "idle" },
})

local snapshot = model.snapshot()
assert(#snapshot.executions == 1)
assert(snapshot.executions[1].outputs[1].text == "hello\n")
assert(snapshot.executions[1].outputs[2].data["text/plain"] == "43")
assert(snapshot.executions[1].status == "done")
assert(events[#events].type == "execution.finished")

model.start(kernel, "request-plotly", { "figure.show()" }, { label = "Plotly" })
model.handle_message(kernel, {
  header = { msg_type = "display_data" },
  parent_header = { msg_id = "request-plotly" },
  content = {
    data = {
      ["application/vnd.plotly.v1+json"] = {
        data = { { x = { 1, vim.NIL, 3 }, y = { 1, 4, 9 } } },
        layout = { title = vim.NIL },
      },
      ["text/plain"] = "Figure()",
    },
    metadata = { plotly = vim.NIL },
  },
})
snapshot = model.snapshot()
local plotly = snapshot.executions[2].outputs[1].data["application/vnd.plotly.v1+json"]
assert(plotly.data[1].x[2] == vim.NIL)
assert(vim.json.encode(snapshot))

-- Widget comms are independent from execute requests and must survive in a
-- snapshot so a browser can reconnect without asking the kernel to recreate
-- the figure.
model.handle_message(kernel, {
  header = { msg_type = "comm_open" },
  content = {
    comm_id = "widget-1",
    target_name = "jupyter.widget",
    data = {
      state = {
        _model_module = "anywidget",
        _esm = "export default { render() {} }",
        _widget_data = { { x = { 1, 2 }, y = { 3, 4 } } },
      },
      buffer_paths = {},
    },
  },
})
model.handle_message(kernel, {
  header = { msg_type = "comm_msg" },
  content = {
    comm_id = "widget-1",
    data = { method = "update", state = { _py2js_relayout = { relayout_data = { ["xaxis.range"] = { 1, 2 } } } } },
  },
})
snapshot = model.snapshot()
assert(snapshot.widgets["widget-1"].state._model_module == "anywidget")
assert(snapshot.widgets["widget-1"].state._py2js_relayout.relayout_data["xaxis.range"][2] == 2)
assert(events[#events].type == "widget.comm_msg")

model.clear()
assert(#model.snapshot().executions == 0)
assert(next(model.snapshot().widgets) == nil)
print("model tests: ok")
