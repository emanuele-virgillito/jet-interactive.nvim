local config = require("jet-interactive.config")

local M = {}
local process
local ready
local pending = {}
local stdout_buffer = ""
local installing = false
local open_when_ready = false

local function plugin_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function executable()
  if config.options.web.binary_path then
    return vim.fn.expand(config.options.web.binary_path)
  end
  local installed = vim.fn.stdpath("data") .. "/jet-interactive/bin/jet-interactive"
  if vim.fn.executable(installed) == 1 then
    return installed
  end
  local development = plugin_root() .. "/target/release/jet-interactive"
  if vim.fn.executable(development) == 1 then
    return development
  end
  return vim.fn.exepath("jet-interactive") ~= "" and vim.fn.exepath("jet-interactive") or nil
end

local function send(event)
  if not (process and process:is_closing() == false) then
    table.insert(pending, event)
    return
  end
  local ok, encoded = pcall(vim.json.encode, event)
  if not ok then
    vim.schedule(function()
      vim.notify(
        ("Evento web non serializzabile (%s): %s"):format(event.type or "sconosciuto", encoded),
        vim.log.levels.ERROR,
        { title = "Jet Interactive" }
      )
    end)
    return
  end
  process:write(encoded .. "\n")
end

local function handle_control(message)
  if message.type == "bridge.ready" then
    ready = message
    send(require("jet-interactive.model").snapshot())
    -- Detach the queue before flushing it. The bridge may terminate between
    -- emitting `bridge.ready` and this scheduled callback; in that case
    -- `send()` queues the event again instead of extending the table that is
    -- currently being iterated forever.
    local queued = pending
    pending = {}
    for _, event in ipairs(queued) do
      send(event)
    end
    if open_when_ready then
      open_when_ready = false
      vim.schedule(M.open_browser)
    end
  elseif message.type == "snapshot.request" then
    send(require("jet-interactive.model").snapshot())
  elseif message.type == "history.clear.request" then
    require("jet-interactive").clear()
  elseif message.type == "widget.comm_msg.request" or message.type == "widget.comm_close.request" then
    require("jet-interactive.widgets").handle_browser_message(message)
  end
end

local function consume_stdout(error, data)
  if error then
    vim.schedule(function()
      vim.notify("Jet Interactive bridge: " .. error, vim.log.levels.ERROR)
    end)
    return
  end
  if not data then
    return
  end
  stdout_buffer = stdout_buffer .. data
  while true do
    local newline = stdout_buffer:find("\n", 1, true)
    if not newline then
      break
    end
    local line = stdout_buffer:sub(1, newline - 1)
    stdout_buffer = stdout_buffer:sub(newline + 1)
    local ok, message = pcall(vim.json.decode, line)
    if ok then
      vim.schedule(function()
        handle_control(message)
      end)
    end
  end
end

function M.start()
  if process and process:is_closing() == false then
    return true
  end
  local binary = executable()
  if not binary then
    if config.options.web.auto_install and not installing then
      installing = true
      vim.notify("Installazione del bridge jet-interactive…", vim.log.levels.INFO)
      require("jet-interactive.installer").ensure(function(path, error)
        installing = false
        vim.schedule(function()
          if path then
            M.start()
          else
            vim.notify("Installazione bridge fallita: " .. error, vim.log.levels.ERROR)
          end
        end)
      end)
      return true
    end
    vim.notify("jet-interactive binary non trovato. Esegui :JetInteractiveBuild", vim.log.levels.ERROR)
    return false
  end
  ready = nil
  stdout_buffer = ""
  process = vim.system({ binary, "serve" }, {
    stdin = true,
    stdout = consume_stdout,
    stderr = function(_, data)
      if data and data:find("%S") then
        vim.schedule(function()
          vim.notify(vim.trim(data), vim.log.levels.WARN, { title = "Jet Interactive" })
        end)
      end
    end,
  }, function(result)
    process = nil
    ready = nil
    if result.code ~= 0 then
      vim.schedule(function()
        vim.notify("Jet Interactive bridge terminato con codice " .. result.code, vim.log.levels.ERROR)
      end)
    end
  end)
  return true
end

function M.stop()
  if process and process:is_closing() == false then
    process:kill(15)
  end
end

function M.publish(event)
  if not config.options.web.enabled then
    return
  end
  if not process and not M.start() then
    return
  end
  if ready then
    send(event)
  else
    table.insert(pending, event)
  end
end

function M.open_browser()
  if not ready then
    open_when_ready = true
    if M.start() then
      vim.notify("Avvio della Interactive Window…", vim.log.levels.INFO)
    end
    return
  end
  local url = ("http://127.0.0.1:%d/#token=%s"):format(ready.port, ready.token)
  if vim.env.SSH_CONNECTION and vim.env.SSH_CONNECTION ~= "" then
    send({
      protocol = "v1",
      type = "browser.open",
      browser = config.options.web.browser,
    })
    vim.notify(("Apertura richiesta per la sessione web %s. Il watcher locale la collegherà automaticamente."):format(
      ready.session_id
    ), vim.log.levels.INFO, { title = "Jet Interactive" })
    return
  end

  if not config.options.web.open_local then
    vim.notify("Interactive Window pronta: " .. url, vim.log.levels.INFO, { title = "Jet Interactive" })
    return
  end

  local binary = executable()
  vim.system({ binary, "open", url, "--browser", config.options.web.browser }, { text = true }, function(result)
    if result.code ~= 0 then
      vim.schedule(function()
        vim.notify(vim.trim(result.stderr), vim.log.levels.ERROR, { title = "Jet Interactive" })
      end)
    end
  end)
end

function M.binary_path()
  return executable()
end

return M
