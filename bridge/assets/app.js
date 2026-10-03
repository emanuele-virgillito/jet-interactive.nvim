(() => {
  "use strict";

  const feed = document.querySelector("#feed");
  const connection = document.querySelector("#connection");
  const autoscroll = document.querySelector("#autoscroll");
  const clear = document.querySelector("#clear");
  const kernelFilter = document.querySelector("#kernel-filter");
  const fragmentToken = new URLSearchParams(location.hash.slice(1)).get("token");
  if (fragmentToken) sessionStorage.setItem("jet-interactive-token", fragmentToken);
  const token = fragmentToken || sessionStorage.getItem("jet-interactive-token") || "";
  history.replaceState(null, "", location.pathname);

  const state = { executions: [], kernels: {} };
  let socket;

  // Jet's Jupyter transport normally forwards rich MIME values as objects,
  // but some kernel/Jet combinations preserve them as JSON strings. Plotly
  // silently accepts an empty `data` fallback in that case, which looks like
  // a WebGL failure although no trace ever reached plotly.js.
  function decodeJson(value) {
    if (typeof value !== "string") return value;
    try { return JSON.parse(value); } catch (_) { return value; }
  }

  function normalisePlotlyState(state) {
    const result = state || {};
    for (const [name, value] of Object.entries(result)) {
      if (name === "_widget_data" || name === "_widget_layout" || name === "_config" || name.startsWith("_py2js_")) {
        result[name] = decodeJson(value);
      }
    }
    return result;
  }

  class AnyWidgetModel {
    constructor(manager, widget) {
      this.manager = manager;
      this.commId = widget.comm_id;
      this.kernelId = widget.kernel?.id;
      this.state = normalisePlotlyState(
        restoreBuffers(structuredClone(widget.state || {}), widget.buffer_paths, widget.buffers),
      );
      this.listeners = new Map();
      this.changed = {};
    }

    get(name) { return this.state[name]; }

    set(name, value) {
      const values = typeof name === "object" ? name : { [name]: value };
      Object.entries(values).forEach(([key, next]) => {
        this.state[key] = next;
        this.changed[key] = next;
        this.emit(`change:${key}`, this, next);
      });
      this.emit("change", this);
    }

    on(names, callback) {
      String(names).split(/\s+/).forEach((name) => {
        if (!name) return;
        const callbacks = this.listeners.get(name) || [];
        callbacks.push(callback);
        this.listeners.set(name, callbacks);
      });
    }

    off(names, callback) {
      String(names).split(/\s+/).forEach((name) => {
        if (!name) return;
        const callbacks = this.listeners.get(name) || [];
        this.listeners.set(name, callbacks.filter((item) => item !== callback));
      });
    }

    emit(name, ...args) {
      (this.listeners.get(name) || []).forEach((callback) => callback(...args));
    }

    save_changes() {
      if (!Object.keys(this.changed).length) return;
      this.manager.send(this, { method: "update", state: this.changed, buffer_paths: [] });
      this.changed = {};
    }

    // Plotly's FigureWidget view follows the Jupyter Backbone convention and
    // calls `touch()` after `set()`.  In that API touch flushes dirty traits
    // to the kernel; without it Plotly can leave its edit protocol half-sent.
    touch() { this.save_changes(); }

    apply(data, buffers) {
      if (data?.method !== "update" && data?.method !== "echo_update") return;
      const update = normalisePlotlyState(
        restoreBuffers(structuredClone(data.state || {}), data.buffer_paths, buffers),
      );
      Object.entries(update).forEach(([name, value]) => {
        this.state[name] = value;
        this.emit(`change:${name}`, this, value);
      });
      this.emit("change", this);
    }
  }

  // Plotly ships its own AnyWidget frontend, but it also bundles a second
  // Plotly runtime. In a standalone page that runtime can create the graph in
  // a child node while retaining the outer mount as FigureView.el; subsequent
  // relayout/update calls then target an element without Plotly state. Use the
  // page's single vendored Plotly instance and bridge the FigureWidget traits
  // explicitly. This is also the path used by FigureWidgetResampler.
  async function renderPlotlyWidget(model, container) {
    const viewId = crypto.randomUUID();
    let applyingKernelUpdate = false;
    const listeners = [];
    const listen = (name, callback) => {
      model.on(name, callback);
      listeners.push([name, callback]);
    };
    const value = (name, fallback) => decodeJson(model.get(name)) ?? fallback;

    await window.Plotly.newPlot(
      container,
      structuredClone(value("_widget_data", [])),
      structuredClone(value("_widget_layout", {})),
      structuredClone(value("_config", {})),
    );

    const sendTrait = (name, payload) => {
      if (applyingKernelUpdate) return;
      model.set(name, payload);
      model.save_changes();
    };
    const onRelayout = (relayoutData) => sendTrait("_js2py_relayout", {
      relayout_data: relayoutData,
      source_view_id: viewId,
    });
    const onRestyle = (event) => sendTrait("_js2py_restyle", {
      style_data: event[0],
      style_traces: event[1],
      source_view_id: viewId,
    });
    container.on("plotly_relayout", onRelayout);
    container.on("plotly_restyle", onRestyle);

    const fromKernel = (callback) => async () => {
      applyingKernelUpdate = true;
      try { await callback(); } finally { applyingKernelUpdate = false; }
    };
    listen("change:_py2js_relayout", fromKernel(async () => {
      const update = value("_py2js_relayout", null);
      if (update && update.source_view_id !== viewId) {
        await window.Plotly.relayout(container, update.relayout_data || {});
      }
    }));
    listen("change:_py2js_restyle", fromKernel(async () => {
      const update = value("_py2js_restyle", null);
      if (update) {
        await window.Plotly.restyle(container, update.restyle_data || {}, update.restyle_traces);
      }
    }));
    listen("change:_py2js_update", fromKernel(async () => {
      const update = value("_py2js_update", null);
      if (update) {
        await window.Plotly.update(
          container,
          update.style_data || {},
          update.layout_data || {},
          update.style_traces,
        );
      }
    }));

    return () => {
      listeners.forEach(([name, callback]) => model.off(name, callback));
      window.Plotly.purge(container);
    };
  }

  class LiveComm {
    constructor(owner, widget) {
      this.owner = owner;
      this.comm_id = widget.comm_id;
      this.target_name = widget.target_name || "jupyter.widget";
      this.kernelId = widget.kernel?.id;
      this.messageHandler = null;
      this.closeHandler = null;
    }

    open(data = {}, callbacks, metadata = {}, buffers = []) {
      return this.owner.send(this, "widget.comm_open.request", data, callbacks, metadata, buffers);
    }

    send(data = {}, callbacks, metadata = {}, buffers = []) {
      return this.owner.send(this, "widget.comm_msg.request", data, callbacks, metadata, buffers);
    }

    close(data = {}, callbacks, metadata = {}, buffers = []) {
      const id = this.owner.send(this, "widget.comm_close.request", data, callbacks, metadata, buffers);
      this.closeHandler?.({ content: { data } });
      return id;
    }

    on_msg(callback) { this.messageHandler = callback; }
    on_close(callback) { this.closeHandler = callback; }

    receive(data, buffers) {
      this.messageHandler?.({
        header: { msg_type: "comm_msg" },
        parent_header: {},
        metadata: {},
        content: { comm_id: this.comm_id, data: data || {} },
        buffers: decodeBuffers(buffers),
      });
    }

    receiveClose() {
      this.closeHandler?.({
        header: { msg_type: "comm_close" },
        parent_header: {},
        metadata: {},
        content: { comm_id: this.comm_id, data: {} },
      });
    }
  }

  class StandardWidgetManager {
    constructor() {
      this.manager = null;
      this.comms = new Map();
      this.views = [];
      this.reset();
    }

    reset() {
      this.disposeViews();
      this.comms.clear();
      this.manager = new JetWidgets.HTMLManager();
    }

    supports(widget) {
      const module = widget.state?._model_module || "";
      return module.startsWith("@jupyter-widgets/");
    }

    has(commId) { return this.comms.has(commId); }

    open(widget) {
      const comm = new LiveComm(this, widget);
      this.comms.set(widget.comm_id, comm);
      const buffers = decodeBuffers(widget.buffers);
      const message = {
        header: { msg_type: "comm_open" },
        parent_header: {},
        metadata: { version: "2.1.0" },
        content: {
          comm_id: widget.comm_id,
          target_name: widget.target_name || "jupyter.widget",
          data: {
            state: structuredClone(widget.state || {}),
            buffer_paths: widget.buffer_paths || [],
          },
        },
        buffers,
      };
      // The manager registers the model promise synchronously, before it
      // resolves references such as Layout and children. This lets related
      // widget comms arrive in normal Jupyter order without custom handling.
      comm.model = this.manager.handle_comm_open(comm, message);
      comm.model.catch((error) => console.error("Could not open Jupyter widget", error));
    }

    message(event) { this.comms.get(event.comm_id)?.receive(event.data, event.buffers); }

    close(commId) {
      this.comms.get(commId)?.receiveClose();
      this.comms.delete(commId);
    }

    send(comm, type, data, callbacks, metadata, buffers) {
      const msgId = crypto.randomUUID();
      const encoded = encodeBuffers(buffers);
      if (encoded.length) {
        console.warn("Jet 0.0.8 cannot forward browser widget binary buffers yet");
      }
      if (socket?.readyState === WebSocket.OPEN) {
        socket.send(JSON.stringify({
          type,
          kernel_id: comm.kernelId,
          comm_id: comm.comm_id,
          data,
          metadata,
          buffers: encoded,
        }));
      }
      // Jet does not currently expose the status reply for a comm_send. Core
      // controls use it only for throttling, so acknowledge the queued update
      // after it has been handed to the bridge.
      queueMicrotask(() => callbacks?.iopub?.status?.({
        header: { msg_type: "status" },
        parent_header: { msg_id: msgId },
        content: { execution_state: "idle" },
      }));
      return msgId;
    }

    async render(modelId, container) {
      const model = await this.manager.get_model(modelId);
      const view = await this.manager.create_view(model);
      if (!container.isConnected) await new Promise((resolve) => requestAnimationFrame(resolve));
      if (!container.isConnected) {
        view.remove();
        return;
      }
      await this.manager.display_view(view, container);
      this.views.push(view);
    }

    disposeViews() {
      this.views.splice(0).forEach((view) => {
        try { view.remove(); } catch (error) { console.warn(error); }
      });
    }
  }

  class WidgetManager {
    constructor() {
      this.models = new Map();
      this.runtimes = new Map();
      this.cleanups = [];
      this.viewGeneration = 0;
      this.standard = new StandardWidgetManager();
    }

    replace(widgets) {
      this.disposeViews();
      this.models.clear();
      this.runtimes.clear();
      this.standard.reset();
      Object.values(widgets || {}).forEach((widget) => this.open(widget));
    }

    open(widget) {
      if (this.standard.supports(widget)) {
        this.standard.open(widget);
      } else {
        this.models.set(widget.comm_id, new AnyWidgetModel(this, widget));
      }
    }

    message(event) {
      if (this.standard.has(event.comm_id)) this.standard.message(event);
      else this.models.get(event.comm_id)?.apply(event.data, event.buffers);
    }

    close(commId) {
      if (this.standard.has(commId)) {
        this.standard.close(commId);
        return;
      }
      const model = this.models.get(commId);
      if (model) model.closed = true;
    }

    send(model, data) {
      if (socket?.readyState !== WebSocket.OPEN) return;
      socket.send(JSON.stringify({
        type: "widget.comm_msg.request",
        kernel_id: model.kernelId,
        comm_id: model.commId,
        data,
      }));
    }

    disposeViews() {
      this.viewGeneration += 1;
      this.standard.disposeViews();
      this.cleanups.splice(0).forEach((cleanup) => {
        try { cleanup?.(); } catch (error) { console.warn(error); }
      });
    }

    async runtime(model) {
      if (this.runtimes.has(model.commId)) return this.runtimes.get(model.commId);
      const promise = (async () => {
        if (model.get("_model_module") !== "anywidget") {
          throw new Error(`Unsupported widget module: ${model.get("_model_module") || "unknown"}`);
        }
        const widgetId = model.get("_anywidget_id") || "";
        if (!widgetId.startsWith("plotly.") && !widgetId.startsWith("plotly_resampler.")) {
          throw new Error(`AnyWidget is not allowed: ${widgetId || "unknown"}`);
        }
        const source = model.get("_esm");
        if (!source) throw new Error("The widget did not provide an ESM frontend");
        const url = URL.createObjectURL(new Blob([source], { type: "text/javascript" }));
        try {
          const module = await import(url);
          const runtime = typeof module.default === "function" ? module.default() : module.default;
          if (!runtime?.render) throw new Error("Invalid AnyWidget frontend");
          await runtime.initialize?.({ model });
          return runtime;
        } finally {
          URL.revokeObjectURL(url);
        }
      })();
      this.runtimes.set(model.commId, promise);
      return promise;
    }

    async render(modelId, container) {
      if (this.standard.has(modelId)) {
        try {
          await this.standard.render(modelId, container);
        } catch (error) {
          console.error(error);
          container.replaceChildren(element("p", "widget-error", `Widget error: ${error.message || error}`));
        }
        return;
      }
      const model = this.models.get(modelId);
      if (!model) {
        container.append(element("p", "widget-error", `Widget ${shortId(modelId)} not available`));
        return;
      }
      try {
        const generation = this.viewGeneration;
        const css = model.get("_css");
        if (css) container.append(Object.assign(document.createElement("style"), { textContent: css }));
        const widgetId = model.get("_anywidget_id") || "";
        const cleanup = widgetId.startsWith("plotly.") || widgetId.startsWith("plotly_resampler.")
          ? await renderPlotlyWidget(model, container)
          : await (await this.runtime(model)).render({ model, el: container });
        if (generation !== this.viewGeneration || !container.isConnected) {
          if (typeof cleanup === "function") cleanup();
          return;
        }
        if (typeof cleanup === "function") this.cleanups.push(cleanup);
      } catch (error) {
        console.error(error);
        container.replaceChildren(element("p", "widget-error", `Widget error: ${error.message}`));
      }
    }
  }

  const widgetManager = new WidgetManager();

  function connect() {
    const scheme = location.protocol === "https:" ? "wss" : "ws";
    socket = new WebSocket(`${scheme}://${location.host}/ws`);
    socket.addEventListener("open", () => {
      socket.send(JSON.stringify({ type: "auth", token }));
      connection.textContent = "connected";
      connection.classList.add("connected");
    });
    socket.addEventListener("close", () => {
      connection.textContent = "disconnected — retrying";
      connection.classList.remove("connected");
      setTimeout(connect, 1000);
    });
    socket.addEventListener("message", ({ data }) => {
      try { applyEvent(JSON.parse(data)); } catch (error) { console.error(error); }
    });
  }

  function execution(id) { return state.executions.find((item) => item.id === id); }

  function applyEvent(event) {
    if (event.protocol !== "v1") return;
    switch (event.type) {
      case "session.snapshot":
        state.executions = event.executions || [];
        state.kernels = Object.fromEntries(Object.entries(event.kernels || {}).map(([id, kernel]) => [id, kernel]));
        widgetManager.replace(event.widgets || {});
        break;
      case "execution.started": {
        if (event.execution.kernel?.id) state.kernels[event.execution.kernel.id] = event.execution.kernel;
        const old = execution(event.execution.id);
        if (old) Object.assign(old, event.execution);
        else state.executions.push(event.execution);
        break;
      }
      case "kernel.status":
        if (event.kernel?.id) state.kernels[event.kernel.id] = event.kernel;
        break;
      case "output.append": {
        const item = execution(event.execution_id);
        if (item) (item.outputs ||= []).push(event.output);
        break;
      }
      case "output.update": {
        if (event.execution_id && event.output_index) {
          const item = execution(event.execution_id);
          if (item?.outputs?.[event.output_index - 1]) Object.assign(item.outputs[event.output_index - 1], event.output);
        } else {
          for (const item of state.executions) {
            const output = (item.outputs || []).find((candidate) => candidate.display_id && candidate.display_id === event.display_id);
            if (output) Object.assign(output, event.output);
          }
        }
        break;
      }
      case "output.clear": {
        const item = execution(event.execution_id);
        if (item) item.outputs = [];
        break;
      }
      case "execution.finished": {
        const item = execution(event.execution_id);
        if (item) item.status = event.status;
        break;
      }
      case "history.clear":
        state.executions = [];
        state.kernels = {};
        widgetManager.replace({});
        break;
      case "widget.comm_open":
        widgetManager.open(event.widget);
        return;
      case "widget.comm_msg":
        widgetManager.message(event);
        return;
      case "widget.comm_close":
        widgetManager.close(event.comm_id);
        return;
    }
    render();
  }

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function render() {
    const selected = kernelFilter.value;
    const current = new Map();
    Object.values(state.kernels).forEach((kernel) => current.set(kernel.id, kernel));
    state.executions.forEach((item) => {
      if (item.kernel?.id) current.set(item.kernel.id, item.kernel);
    });
    kernelFilter.replaceChildren(element("option", "", "All sessions"));
    kernelFilter.firstChild.value = "";
    [...current.values()].sort((a, b) => (a.name || "").localeCompare(b.name || "")).forEach((kernel) => {
      const option = element("option", "", `${kernel.name || "Jupyter"} · ${shortId(kernel.id)}`);
      option.value = kernel.id;
      kernelFilter.append(option);
    });
    kernelFilter.value = current.has(selected) ? selected : "";
    widgetManager.disposeViews();
    feed.replaceChildren();
    const executions = state.executions.filter((item) => !kernelFilter.value || item.kernel?.id === kernelFilter.value);
    if (!executions.length) {
      feed.append(element("p", "empty", kernelFilter.value ? "No executions for this session yet." : "No executions yet."));
      return;
    }
    executions.forEach((item) => feed.append(renderExecution(item)));
    if (autoscroll.checked) window.scrollTo({ top: document.body.scrollHeight, behavior: "smooth" });
  }

  function renderExecution(item) {
    const cell = element("article", `cell ${item.status || "running"}`);
    const head = element("div", "cell-head");
    head.append(
      element("strong", "", `In [${item.count ?? "…"}] · ${item.label || "Execution"}`),
      element("span", "cell-meta", [item.source, state.kernels[item.kernel?.id]?.name || item.kernel?.name, item.status].filter(Boolean).join(" · ")),
    );
    const details = element("details", "code");
    details.open = item.status === "running";
    details.append(element("summary", "", "Code"), element("pre", "", (item.code || []).join("\n")));
    const outputs = element("section", "outputs");
    (item.outputs || []).forEach((output) => outputs.append(renderOutput(output)));
    cell.append(head, details, outputs);
    return cell;
  }

  function renderOutput(output) {
    const wrapper = element("div", `output ${output.name || ""}`);
    if (output.kind === "stream") {
      wrapper.append(renderAnsi(output.text || "", output.name === "stderr" ? "stderr" : ""));
    } else if (output.kind === "error") {
      wrapper.append(element("pre", "traceback", stripAnsi(output.text || "")));
    } else {
      renderMime(wrapper, output.data || {}, output.metadata || {});
    }
    return wrapper;
  }

  function renderMime(container, data, metadata) {
    if (data["application/vnd.jupyter.widget-view+json"]) {
      const view = data["application/vnd.jupyter.widget-view+json"];
      const node = element("div", "jupyter-widget");
      container.append(node);
      widgetManager.render(view.model_id, node);
      return;
    }
    if (data["application/vnd.plotly.v1+json"] && window.Plotly) {
      const plot = element("div", "plotly");
      container.append(plot);
      const figure = decodeJson(data["application/vnd.plotly.v1+json"]);
      queueMicrotask(() => Plotly.newPlot(plot, figure.data || [], figure.layout || {}, { responsive: true, displaylogo: false }));
      return;
    }
    if (data["text/html"]) {
      const html = Array.isArray(data["text/html"]) ? data["text/html"].join("") : data["text/html"];
      const clean = DOMPurify.sanitize(html, { FORBID_TAGS: ["script"], FORBID_ATTR: ["onerror", "onload"] });
      const frame = document.createElement("iframe");
      frame.setAttribute("sandbox", "");
      frame.srcdoc = `<!doctype html><meta charset=utf-8><style>body{font-family:system-ui;color:#222}img,svg{max-width:100%}</style>${clean}`;
      container.append(frame);
      return;
    }
    if (data["text/markdown"] && window.marked) {
      const node = element("div", "markdown");
      node.innerHTML = DOMPurify.sanitize(marked.parse(join(data["text/markdown"])));
      container.append(node);
      return;
    }
    if (data["text/latex"] && window.katex) {
      const node = element("div", "latex");
      katex.render(join(data["text/latex"]).replace(/^\$|\$$/g, ""), node, { throwOnError: false, displayMode: true });
      container.append(node);
      return;
    }
    for (const mime of ["image/svg+xml", "image/png", "image/jpeg"]) {
      if (!data[mime]) continue;
      if (mime === "image/svg+xml") {
        const node = element("div", "svg");
        node.innerHTML = DOMPurify.sanitize(join(data[mime]), { USE_PROFILES: { svg: true } });
        container.append(node);
      } else {
        const image = document.createElement("img");
        image.alt = "Jupyter output";
        image.src = `data:${mime};base64,${join(data[mime])}`;
        container.append(image);
      }
      return;
    }
    if (data["application/json"]) {
      container.append(element("pre", "", JSON.stringify(data["application/json"], null, 2)));
      return;
    }
    container.append(element("pre", "", join(data["text/plain"] ?? "")));
  }

  function join(value) { return Array.isArray(value) ? value.join("") : String(value ?? ""); }
  function shortId(value) { return String(value || "").slice(-8); }
  function restoreBuffers(value, paths = [], buffers = []) {
    paths.forEach((path, index) => {
      if (!buffers[index]) return;
      const binary = atob(buffers[index]);
      const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
      let target = value;
      for (let part = 0; part < path.length - 1; part += 1) target = target[path[part]];
      target[path[path.length - 1]] = bytes;
    });
    return value;
  }
  function decodeBuffers(buffers = []) {
    return buffers.map((encoded) => {
      const binary = atob(encoded);
      const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
      return new DataView(bytes.buffer);
    });
  }
  function encodeBuffers(buffers = []) {
    return buffers.map((buffer) => {
      const bytes = buffer instanceof ArrayBuffer
        ? new Uint8Array(buffer)
        : new Uint8Array(buffer.buffer, buffer.byteOffset, buffer.byteLength);
      let binary = "";
      for (let offset = 0; offset < bytes.length; offset += 0x8000) {
        binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
      }
      return btoa(binary);
    });
  }
  function stripAnsi(text) { return text.replace(/\x1b\[[0-9;]*m/g, ""); }
  function renderAnsi(text, className) {
    const pre = element("pre", className);
    const colors = ["#282828", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#a89984"];
    const bright = ["#928374", "#fb4934", "#b8bb26", "#fabd2f", "#83a598", "#d3869b", "#8ec07c", "#ebdbb2"];
    let style = {};
    let cursor = 0;
    const expression = /\x1b\[([0-9;]*)m/g;
    for (const match of text.matchAll(expression)) {
      if (match.index > cursor) {
        const span = element("span", "", text.slice(cursor, match.index));
        Object.assign(span.style, style);
        pre.append(span);
      }
      const codes = (match[1] || "0").split(";").map(Number);
      for (const code of codes) {
        if (code === 0) style = {};
        else if (code === 1) style.fontWeight = "bold";
        else if (code === 22) delete style.fontWeight;
        else if (code === 39) delete style.color;
        else if (code >= 30 && code <= 37) style.color = colors[code - 30];
        else if (code >= 90 && code <= 97) style.color = bright[code - 90];
      }
      cursor = match.index + match[0].length;
    }
    if (cursor < text.length) {
      const span = element("span", "", text.slice(cursor));
      Object.assign(span.style, style);
      pre.append(span);
    }
    return pre;
  }

  clear.addEventListener("click", () => socket?.send(JSON.stringify({ type: "history.clear.request" })));
  kernelFilter.addEventListener("change", render);
  connect();
})();
