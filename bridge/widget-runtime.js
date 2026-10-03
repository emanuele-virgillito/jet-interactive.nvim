// Build-time entry point for the official Jupyter Widgets frontend. The
// generated files are embedded in the Rust bridge, so Node is not needed at
// runtime and the Interactive Window never fetches widget code from a CDN.
// Import the manager implementation directly. The package root also imports
// its static HTML embedder, which assumes Webpack's `__webpack_public_path__`
// global; that embedder is not used by our live WebSocket transport.
export { HTMLManager } from "@jupyter-widgets/html-manager/lib/htmlmanager.js";
