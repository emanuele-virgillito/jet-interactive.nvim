# jet-interactive.nvim

An Interactive Window for [jet.nvim](https://github.com/wurli/jet.nvim). Jet remains the sole Jupyter kernel manager; this plugin correlates Jupyter messages with cell executions and renders the same in-memory history in Neovim and in a local browser.

## Development setup

```lua
{
  dir = "/path/to/jet-interactive.nvim",
  dependencies = { "wurli/jet.nvim", "folke/snacks.nvim" },
  opts = {
    web = { enabled = true, auto_start = true, open_local = true },
    history = { persist = false },
  },
}
```

Build the bridge with `:JetInteractiveBuild` or:

```sh
./scripts/vendor.sh
cargo build --release
```

Use `:JetInteractiveBrowser` locally. `web.browser` accepts `"auto"` (the
default), `"chrome"`, `"chromium"`, or `"firefox"`. Chrome and Chromium open
the window in app mode; Firefox opens a dedicated regular window.

For a remote Neovim session, install the same `jet-interactive` executable on
the local desktop and run:

```sh
jet-interactive attach ssh-host
```

The server binds only to remote loopback; the CLI discovers active sessions and creates a temporary SSH forwarding automatically.

To make `<leader>jw` open remote windows automatically, install the built
binary and watcher unit on the local desktop (not on the server):

```sh
./scripts/install-local.sh
systemctl --user enable --now jet-interactive-watch@odisseo.service
```

The watcher uses the ordinary OpenSSH alias `odisseo`, opens only sessions that
explicitly request a browser window, and removes its forwarding when the remote
Neovim session ends. It must be able to connect non-interactively, so configure
an SSH key and agent for that alias before enabling the service.

## Supported output

Text streams, tracebacks, plain text, JSON, sanitized HTML, Markdown, LaTeX,
PNG, JPEG, SVG, and Plotly MIME bundles are supported.

The browser embeds the official Jupyter Widgets manager and controls bundle.
Standard ipywidgets 7/8 controls and layouts (including sliders, buttons,
checkboxes, text fields, selections, boxes, tabs, accordions and links) share
live state with the Jet kernel. The bundle is stored locally: Node and a CDN
are not needed at runtime. Third-party widget modules are not loaded
automatically and arbitrary output scripts are intentionally not executed.

A minimal controls test is:

```python
# %% Standard ipywidgets
import ipywidgets as widgets
from IPython.display import display

slider = widgets.IntSlider(value=7, min=0, max=20, description="Value")
button = widgets.Button(description="Apply", button_style="success")
name = widgets.Text(value="Jet", description="Name")
display(widgets.VBox([slider, name, button]))
```

Jet 0.0.8 does not expose Jupyter binary buffers to Lua. Scalar controls and
layouts work normally, while binary-dependent controls such as `FileUpload`
and widget media are not yet fully supported.

Plotly 6 `FigureWidget` outputs are supported through AnyWidget, including the
bidirectional `comm` updates required by `FigureWidgetResampler`. The Python
environment used by the Jet kernel must contain compatible `ipywidgets`,
`anywidget`, Plotly and `plotly-resampler` versions.

Jet 0.0.8 does not expose Jupyter binary buffers to Lua. The plugin therefore
configures Plotly widgets once per Python kernel to serialize their displayed,
downsampled arrays as JSON. High-resolution `plotly-resampler` data remains in
the Python kernel and is not transferred until a zoom or pan requests a new
downsampled view.

A minimal interactive test cell is:

```python
# %% Plotly Resampler
import numpy as np
import plotly.graph_objects as go
from IPython.display import display
from plotly_resampler import FigureWidgetResampler

x = np.arange(1_000_000, dtype=np.float64)
figure = FigureWidgetResampler(go.Figure())
figure.add_trace(
    go.Scattergl(name="signal"),
    hf_x=x,
    hf_y=np.sin(x / 1_000),
)
display(figure)
```

Open the web view, run the cell, then zoom or pan the plot. Each viewport
change is sent to the Python kernel and the displayed trace is resampled there.

## Variable inspector

`:JetInteractiveVariables` opens a Python-only tree for the current Jet
kernel. Press `r` to refresh, `<CR>` to expand containers and objects, and `q`
to close it. Inspection requests are silent and do not create executions in
the Interactive Window history.
