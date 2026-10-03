local config = require("jet-interactive.config")

local M = {}
local subscribers = {}
local states = setmetatable({}, { __mode = "k" })

-- Installed in the Python namespace on every request. Reusing the inspector
-- preserves opaque references while a tree is expanded; refreshing the roots
-- clears them so inspected objects are not kept alive indefinitely.
local PYTHON_HELPER = [==[
import base64 as __ji_b64, json as __ji_json

class __JetInteractiveInspector:
    def __init__(self):
        self.refs, self.next_ref = {}, 1

    def _remember(self, value):
        ref = str(self.next_ref)
        self.next_ref += 1
        self.refs[ref] = value
        return ref

    def _repr(self, value, limit):
        try:
            text = repr(value).replace("\n", " ")
        except Exception as error:
            text = "<repr failed: %s>" % type(error).__name__
        return text if len(text) <= limit else text[:limit - 1] + "…"

    def _expandable(self, value):
        if isinstance(value, (str, bytes, bytearray, int, float, complex, bool, type(None))):
            return False
        try:
            if isinstance(value, (dict, list, tuple, set, frozenset)):
                return len(value) > 0
            return bool(vars(value))
        except Exception:
            return False

    def _node(self, name, value, limit):
        cls = type(value)
        type_name = cls.__name__
        if cls.__module__ not in ("builtins", "__main__"):
            type_name = cls.__module__ + "." + type_name
        node = {"name": str(name), "type": type_name,
                "value": self._repr(value, limit),
                "expandable": self._expandable(value)}
        if node["expandable"]:
            node["ref"] = self._remember(value)
        shape = getattr(value, "shape", None)
        if shape is not None:
            try:
                node["shape"] = " × ".join(str(item) for item in shape)
            except Exception:
                pass
        dtype = getattr(value, "dtype", None)
        if dtype is not None:
            try:
                node["dtype"] = str(dtype)
            except Exception:
                pass
        return node

    def roots(self, namespace, limit):
        self.refs, self.next_ref = {}, 1
        hidden = {"In", "Out", "get_ipython", "exit", "quit", "open"}
        return [self._node(name, value, limit)
                for name, value in sorted(namespace.items())
                if not name.startswith("_") and name not in hidden]

    def children(self, ref, limit, maximum):
        value = self.refs.get(str(ref))
        if value is None:
            return []
        try:
            if isinstance(value, dict):
                items = [("[%s]" % self._repr(key, 40), child)
                         for key, child in value.items()]
            elif isinstance(value, (list, tuple, set, frozenset)):
                items = [("[%d]" % index, child)
                         for index, child in enumerate(value)]
            else:
                items = sorted(vars(value).items())
        except Exception:
            return []
        return [self._node(name, child, limit) for name, child in items[:maximum]]

try:
    __jet_interactive_inspector
except NameError:
    __jet_interactive_inspector = __JetInteractiveInspector()
]==]

local function state(kernel)
  local current = states[kernel]
  if not current then
    current = { kernel = kernel, nodes = {}, loading = false, generation = 0 }
    states[kernel] = current
  end
  return current
end

local function notify(current)
  for _, callback in pairs(subscribers) do
    callback(current)
  end
end

local function decode_result(message)
  if ((message.header or {}).msg_type) ~= "execute_reply" then
    return nil
  end
  local expression = ((message.content or {}).user_expressions or {}).jet_interactive
  if not expression or expression.status == "error" then
    return false, expression and (expression.evalue or expression.ename) or "Risposta inspector non valida"
  end
  local encoded = (expression.data or {})["text/plain"]
  if type(encoded) ~= "string" then
    return false, "Il kernel non ha restituito dati"
  end
  encoded = encoded:match("^['\"](.-)['\"]$") or encoded
  local ok, decoded = pcall(vim.base64.decode, encoded)
  if not ok then
    return false, decoded
  end
  ok, decoded = pcall(vim.json.decode, decoded)
  return ok, decoded
end

-- Use a silent execute request with a Jupyter user_expression. Unlike stdout,
-- user expressions remain available for silent requests and do not pollute
-- the REPL, execution count, or the Interactive Window history.
local function request(kernel, expression, callback)
  local responder = require("jet.core.engine").execute_code(kernel.client_id, PYTHON_HELPER, true, false, {
    jet_interactive = "__ji_b64.b64encode(__ji_json.dumps(" .. expression .. ").encode()).decode()",
  })
  require("jet.core.utils").poll(function()
    local response = responder()
    if response.value then
      local ok, value = decode_result(response.value)
      if ok ~= nil then
        vim.schedule(function()
          callback(ok, value)
        end)
      end
    end
    return response.status
  end, { interval = 30, alias = "Jet variable inspector" })
end

function M.subscribe(name, callback)
  subscribers[name] = callback
end

function M.get(kernel)
  return state(kernel)
end

function M.refresh(kernel)
  local current = state(kernel)
  if current.loading then
    return
  end
  current.loading, current.error = true, nil
  notify(current)
  request(kernel, ("__jet_interactive_inspector.roots(globals(), %d)"):format(config.options.variables.max_repr), function(ok, value)
    current.loading = false
    if ok then
      current.nodes = value
      current.generation = current.generation + 1
    else
      current.error = tostring(value)
    end
    notify(current)
  end)
end

function M.expand(kernel, node)
  if not node.expandable then
    return
  end
  if node.children then
    node.open = not node.open
    notify(state(kernel))
    return
  end
  node.loading = true
  notify(state(kernel))
  local options = config.options.variables
  local expression = ("__jet_interactive_inspector.children(%q, %d, %d)")
    :format(node.ref, options.max_repr, options.max_children)
  request(kernel, expression, function(ok, value)
    node.loading = false
    if ok then
      node.children, node.open = value, true
    else
      node.error = tostring(value)
    end
    notify(state(kernel))
  end)
end

return M
