use std::{
    fs,
    io::{self, Write},
    net::TcpListener as StdTcpListener,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, bail};
use axum::{
    Router,
    body::Body,
    extract::{
        State, WebSocketUpgrade,
        ws::{Message, WebSocket},
    },
    http::{HeaderValue, Request, Response, StatusCode, header},
    response::IntoResponse,
    routing::get,
};
use clap::{Parser, Subcommand, ValueEnum};
use futures_util::{SinkExt, StreamExt};
use include_dir::{Dir, include_dir};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::{
    io::{AsyncBufReadExt, BufReader},
    net::TcpListener,
    sync::{RwLock, broadcast},
};

const PROTOCOL: &str = "v1";
static KATEX_FONTS: Dir<'_> = include_dir!("$CARGO_MANIFEST_DIR/assets/vendor/fonts");

#[derive(Parser)]
#[command(version, about)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Serve the browser UI and read protocol events from stdin.
    Serve,
    /// List active Interactive Window sessions on an SSH host.
    Sessions { host: String },
    /// Attach a local browser to an Interactive Window on an SSH host.
    Attach {
        host: String,
        #[arg(long)]
        session: Option<String>,
        #[arg(long)]
        no_open: bool,
        #[arg(long, value_enum, default_value_t = Browser::Auto)]
        browser: Browser,
    },
    /// Watch an SSH host and open requested Interactive Windows automatically.
    Watch {
        host: String,
        #[arg(long, value_enum, default_value_t = Browser::Auto)]
        browser: Browser,
        #[arg(long, default_value_t = 1)]
        interval: u64,
    },
    /// Open an Interactive Window URL in the requested browser mode.
    Open {
        url: String,
        #[arg(long, value_enum, default_value_t = Browser::Auto)]
        browser: Browser,
    },
}

#[derive(Clone, Copy, Debug, Default, ValueEnum)]
enum Browser {
    #[default]
    Auto,
    Chrome,
    Chromium,
    Firefox,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct OpenRequest {
    id: u64,
    browser: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Descriptor {
    protocol: String,
    session_id: String,
    token: String,
    host: String,
    port: u16,
    pid: u32,
    started_at: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    open_request: Option<OpenRequest>,
}

#[derive(Default)]
struct EventLog {
    snapshot: Option<String>,
    tail: Vec<String>,
}

struct AppState {
    token: String,
    events: RwLock<EventLog>,
    tx: broadcast::Sender<String>,
    descriptor: RwLock<Descriptor>,
    descriptor_path: PathBuf,
    next_open_request: RwLock<u64>,
}

struct DescriptorGuard(PathBuf);

struct ChildGuard(Child);

impl Drop for DescriptorGuard {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

impl Drop for ChildGuard {
    fn drop(&mut self) {
        if self.0.try_wait().ok().flatten().is_none() {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    match Cli::parse().command {
        Commands::Serve => serve().await,
        Commands::Sessions { host } => {
            for session in remote_sessions(&host)? {
                println!(
                    "{}\t{}\t127.0.0.1:{}\tpid {}",
                    session.session_id, session.host, session.port, session.pid
                );
            }
            Ok(())
        }
        Commands::Attach {
            host,
            session,
            no_open,
            browser,
        } => attach(&host, session.as_deref(), no_open, browser),
        Commands::Watch {
            host,
            browser,
            interval,
        } => watch(&host, browser, interval),
        Commands::Open { url, browser } => open_browser(&url, browser),
    }
}

async fn serve() -> Result<()> {
    let listener = TcpListener::bind(("127.0.0.1", 0)).await?;
    let port = listener.local_addr()?.port();
    let descriptor = new_descriptor(port);
    let descriptor_path = write_descriptor(&descriptor)?;
    let _guard = DescriptorGuard(descriptor_path.clone());
    let shutdown_descriptor_path = descriptor_path.clone();

    // WebSocket clients may remain open indefinitely. Remove discovery state
    // and terminate immediately on SIGINT/SIGTERM instead of waiting for every
    // browser connection during editor shutdown.
    tokio::spawn(async move {
        shutdown_signal().await;
        let _ = fs::remove_file(shutdown_descriptor_path);
        std::process::exit(0);
    });

    let (tx, _) = broadcast::channel(512);
    let state = Arc::new(AppState {
        token: descriptor.token.clone(),
        events: RwLock::new(EventLog::default()),
        tx,
        descriptor: RwLock::new(descriptor.clone()),
        descriptor_path,
        next_open_request: RwLock::new(1),
    });

    emit_control(json!({
        "protocol": PROTOCOL,
        "type": "bridge.ready",
        "session_id": descriptor.session_id,
        "port": descriptor.port,
        "token": descriptor.token,
    }));

    let stdin_state = state.clone();
    tokio::spawn(async move {
        if let Err(error) = read_neovim_events(stdin_state).await {
            eprintln!("jet-interactive stdin error: {error:#}");
        }
    });

    let app = Router::new()
        .route("/", get(index))
        .route("/app.js", get(app_js))
        .route("/style.css", get(style_css))
        .route("/vendor/plotly.min.js", get(plotly_js))
        .route("/vendor/purify.min.js", get(purify_js))
        .route("/vendor/marked.min.js", get(marked_js))
        .route("/vendor/katex.min.js", get(katex_js))
        .route("/vendor/katex.min.css", get(katex_css))
        .route("/vendor/jupyter-widgets.js", get(jupyter_widgets_js))
        .route("/vendor/jupyter-widgets.css", get(jupyter_widgets_css))
        .route("/vendor/fonts/{*path}", get(katex_font))
        .route("/ws", get(websocket))
        .fallback(not_found)
        .with_state(state);

    axum::serve(listener, app).await?;
    Ok(())
}

async fn shutdown_signal() {
    #[cfg(unix)]
    {
        let mut terminate =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                .expect("install SIGTERM handler");
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {},
            _ = terminate.recv() => {},
        }
    }
    #[cfg(not(unix))]
    let _ = tokio::signal::ctrl_c().await;
}

async fn read_neovim_events(state: Arc<AppState>) -> Result<()> {
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    while let Some(line) = lines.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }
        let value: Value = match serde_json::from_str(&line) {
            Ok(value) => value,
            Err(error) => {
                eprintln!("ignoring invalid protocol line: {error}");
                continue;
            }
        };
        if value.get("protocol").and_then(Value::as_str) != Some(PROTOCOL) {
            continue;
        }

        let mut events = state.events.write().await;
        if value.get("type").and_then(Value::as_str) == Some("browser.open") {
            let browser = value
                .get("browser")
                .and_then(Value::as_str)
                .unwrap_or("auto")
                .to_owned();
            let mut next_request = state.next_open_request.write().await;
            let mut descriptor = state.descriptor.write().await;
            descriptor.open_request = Some(OpenRequest {
                id: *next_request,
                browser,
            });
            *next_request += 1;
            write_descriptor_at(&state.descriptor_path, &descriptor)?;
        } else if value.get("type").and_then(Value::as_str) == Some("session.snapshot") {
            events.snapshot = Some(line.clone());
            events.tail.clear();
        } else {
            events.tail.push(line.clone());
            if events.tail.len() > 10_000 {
                events.tail.remove(0);
            }
        }
        drop(events);
        let _ = state.tx.send(line);
    }
    Ok(())
}

async fn websocket(ws: WebSocketUpgrade, State(state): State<Arc<AppState>>) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_socket(socket, state))
}

async fn handle_socket(mut socket: WebSocket, state: Arc<AppState>) {
    let auth = tokio::time::timeout(Duration::from_secs(5), socket.recv()).await;
    let authenticated =
        match auth {
            Ok(Some(Ok(Message::Text(text)))) => serde_json::from_str::<Value>(&text)
                .ok()
                .is_some_and(|value| {
                    value.get("type").and_then(Value::as_str) == Some("auth")
                        && value.get("token").and_then(Value::as_str) == Some(state.token.as_str())
                }),
            _ => false,
        };
    if !authenticated {
        let _ = socket.send(Message::Close(None)).await;
        return;
    }

    let replay = state.events.read().await;
    if let Some(snapshot) = &replay.snapshot {
        let _ = socket.send(Message::Text(snapshot.clone().into())).await;
    } else {
        emit_control(json!({ "protocol": PROTOCOL, "type": "snapshot.request" }));
    }
    for event in &replay.tail {
        let _ = socket.send(Message::Text(event.clone().into())).await;
    }
    drop(replay);

    let (mut sender, mut receiver) = socket.split();
    let mut subscription = state.tx.subscribe();
    let send_task = tokio::spawn(async move {
        while let Ok(event) = subscription.recv().await {
            if sender.send(Message::Text(event.into())).await.is_err() {
                break;
            }
        }
    });

    while let Some(Ok(message)) = receiver.next().await {
        if let Message::Text(text) = message
            && let Ok(mut value) = serde_json::from_str::<Value>(&text)
        {
            let allowed = matches!(
                value.get("type").and_then(Value::as_str),
                Some(
                    "history.clear.request"
                        | "widget.comm_msg.request"
                        | "widget.comm_close.request"
                )
            );
            if allowed {
                value["protocol"] = Value::String(PROTOCOL.to_owned());
                emit_control(value);
            }
        }
    }
    send_task.abort();
}

fn emit_control(value: Value) {
    println!("{value}");
    let _ = io::stdout().flush();
}

fn new_descriptor(port: u16) -> Descriptor {
    let mut random = [0_u8; 32];
    rand::rng().fill_bytes(&mut random);
    let token: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
    let session_id = token[..12].to_string();
    let host = std::env::var("HOSTNAME")
        .ok()
        .filter(|value| !value.is_empty())
        .or_else(|| {
            fs::read_to_string("/etc/hostname")
                .ok()
                .map(|s| s.trim().to_owned())
        })
        .unwrap_or_else(|| "localhost".to_owned());
    let started_at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    Descriptor {
        protocol: PROTOCOL.to_owned(),
        session_id,
        token,
        host,
        port,
        pid: std::process::id(),
        started_at,
        open_request: None,
    }
}

fn session_dir() -> Result<PathBuf> {
    let home = std::env::var_os("HOME").context("HOME is not set")?;
    Ok(PathBuf::from(home).join(".cache/jet-interactive/sessions"))
}

fn write_descriptor(descriptor: &Descriptor) -> Result<PathBuf> {
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    let directory = session_dir()?;
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&directory)?;
    clean_stale_descriptors(&directory);
    let path = directory.join(format!("{}.json", descriptor.session_id));
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)?;
    serde_json::to_writer(&mut file, descriptor)?;
    Ok(path)
}

fn write_descriptor_at(path: &Path, descriptor: &Descriptor) -> Result<()> {
    let file = fs::OpenOptions::new()
        .write(true)
        .truncate(true)
        .open(path)?;
    serde_json::to_writer(file, descriptor)?;
    Ok(())
}

fn clean_stale_descriptors(directory: &Path) {
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(data) = fs::read(&path) else { continue };
        let Ok(descriptor) = serde_json::from_slice::<Descriptor>(&data) else {
            continue;
        };
        if !Path::new(&format!("/proc/{}", descriptor.pid)).exists() {
            let _ = fs::remove_file(path);
        }
    }
}

fn remote_sessions(host: &str) -> Result<Vec<Descriptor>> {
    let script = r#"for f in "$HOME"/.cache/jet-interactive/sessions/*.json; do
      [ -f "$f" ] || continue
      pid=$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "$f")
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then cat "$f"; printf '\n'; else rm -f "$f"; fi
    done"#;
    // OpenSSH concatenates remote command arguments into a command string.
    // Passing the script as an argument to `sh -c` would therefore let the
    // user's login shell (Fish, for example) parse shell assignments first.
    // Feed it to POSIX sh over stdin instead, independently of the login shell.
    let mut child = Command::new("ssh")
        .args([host, "sh", "-s"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("failed to run ssh for {host}"))?;
    child
        .stdin
        .take()
        .context("failed to open remote discovery stdin")?
        .write_all(script.as_bytes())?;
    let output = child.wait_with_output()?;
    if !output.status.success() {
        bail!(
            "ssh discovery failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    let mut sessions: Vec<Descriptor> = String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| serde_json::from_str(line).ok())
        .filter(|session: &Descriptor| session.protocol == PROTOCOL)
        .collect();
    sessions.sort_by_key(|session| std::cmp::Reverse(session.started_at));
    Ok(sessions)
}

fn choose_session(sessions: Vec<Descriptor>, requested: Option<&str>) -> Result<Descriptor> {
    if let Some(requested) = requested {
        return sessions
            .into_iter()
            .find(|session| session.session_id == requested)
            .with_context(|| format!("session {requested} not found"));
    }
    match sessions.len() {
        0 => bail!("no active jet-interactive sessions found"),
        1 => Ok(sessions.into_iter().next().unwrap()),
        _ => {
            eprintln!("Active sessions:");
            for (index, session) in sessions.iter().enumerate() {
                eprintln!(
                    "  {}) {} on {} (pid {})",
                    index + 1,
                    session.session_id,
                    session.host,
                    session.pid
                );
            }
            eprint!("Select session: ");
            io::stderr().flush()?;
            let mut choice = String::new();
            io::stdin().read_line(&mut choice)?;
            let index: usize = choice.trim().parse().context("invalid session number")?;
            sessions
                .into_iter()
                .nth(index.saturating_sub(1))
                .context("session number out of range")
        }
    }
}

struct Forward {
    child: ChildGuard,
    local_port: u16,
}

fn start_forward(host: &str, session: &Descriptor) -> Result<Forward> {
    let local_port = {
        let listener = StdTcpListener::bind(("127.0.0.1", 0))?;
        listener.local_addr()?.port()
    };
    let forwarding = format!("127.0.0.1:{local_port}:127.0.0.1:{}", session.port);
    let ssh = Command::new("ssh")
        .args([
            "-o",
            "ExitOnForwardFailure=yes",
            "-N",
            "-L",
            &forwarding,
            host,
        ])
        .stdin(Stdio::null())
        .spawn()
        .context("failed to start SSH forwarding")?;
    let mut child = ChildGuard(ssh);
    std::thread::sleep(Duration::from_millis(500));
    if let Some(status) = child.0.try_wait()? {
        bail!("SSH forwarding exited early with {status}");
    }
    Ok(Forward { child, local_port })
}

fn url_for(local_port: u16, session: &Descriptor) -> String {
    format!("http://127.0.0.1:{local_port}/#token={}", session.token)
}

fn executable_in_path(names: &[&str]) -> Option<String> {
    let path = std::env::var_os("PATH")?;
    for directory in std::env::split_paths(&path) {
        for name in names {
            let candidate = directory.join(name);
            if candidate.is_file() {
                return Some(candidate.to_string_lossy().into_owned());
            }
        }
    }
    None
}

fn open_browser(url: &str, browser: Browser) -> Result<()> {
    let (program, arguments) = match browser {
        Browser::Auto => {
            if let Some(program) = executable_in_path(&["google-chrome", "google-chrome-stable"]) {
                (program, vec![format!("--app={url}")])
            } else if let Some(program) = executable_in_path(&["chromium", "chromium-browser"]) {
                (program, vec![format!("--app={url}")])
            } else if let Some(program) = executable_in_path(&["firefox"]) {
                (program, vec!["--new-window".to_owned(), url.to_owned()])
            } else {
                bail!("no supported browser found (tried Chrome, Chromium, Firefox)")
            }
        }
        Browser::Chrome => (
            executable_in_path(&["google-chrome", "google-chrome-stable"])
                .context("Chrome was selected but is not installed")?,
            vec![format!("--app={url}")],
        ),
        Browser::Chromium => (
            executable_in_path(&["chromium", "chromium-browser"])
                .context("Chromium was selected but is not installed")?,
            vec![format!("--app={url}")],
        ),
        Browser::Firefox => (
            executable_in_path(&["firefox"])
                .context("Firefox was selected but is not installed")?,
            vec!["--new-window".to_owned(), url.to_owned()],
        ),
    };
    Command::new(program)
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .context("failed to start browser")?;
    Ok(())
}

#[derive(Default, Serialize, Deserialize)]
struct WatchState {
    handled_requests: std::collections::HashSet<String>,
}

fn watcher_state_path(host: &str) -> Result<PathBuf> {
    let base = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/state")))
        .context("HOME is not set")?;
    let safe_host: String = host
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || character == '-' || character == '_' {
                character
            } else {
                '_'
            }
        })
        .collect();
    Ok(base
        .join("jet-interactive/watch")
        .join(format!("{safe_host}.json")))
}

fn load_watch_state(path: &Path) -> WatchState {
    fs::read(path)
        .ok()
        .and_then(|contents| serde_json::from_slice(&contents).ok())
        .unwrap_or_default()
}

fn save_watch_state(path: &Path, state: &WatchState) -> Result<()> {
    let directory = path
        .parent()
        .context("watcher state has no parent directory")?;
    fs::create_dir_all(directory)?;
    fs::write(path, serde_json::to_vec(state)?)?;
    Ok(())
}

fn watch(host: &str, default_browser: Browser, interval: u64) -> Result<()> {
    let state_path = watcher_state_path(host)?;
    let mut state = load_watch_state(&state_path);
    let mut forwards: std::collections::HashMap<String, Forward> = std::collections::HashMap::new();
    loop {
        match remote_sessions(host) {
            Ok(sessions) => {
                let active: std::collections::HashSet<String> = sessions
                    .iter()
                    .map(|session| session.session_id.clone())
                    .collect();
                forwards.retain(|session_id, _| active.contains(session_id));

                for session in sessions {
                    let Some(request) = &session.open_request else {
                        continue;
                    };
                    let key = format!("{}:{}:{}", host, session.session_id, request.id);
                    if state.handled_requests.contains(&key) {
                        continue;
                    }
                    let forward = match forwards.entry(session.session_id.clone()) {
                        std::collections::hash_map::Entry::Occupied(entry) => entry.into_mut(),
                        std::collections::hash_map::Entry::Vacant(entry) => {
                            entry.insert(start_forward(host, &session)?)
                        }
                    };
                    let browser = match request.browser.parse::<Browser>() {
                        Ok(browser) => browser,
                        Err(_) => default_browser,
                    };
                    open_browser(&url_for(forward.local_port, &session), browser)?;
                    state.handled_requests.insert(key);
                    save_watch_state(&state_path, &state)?;
                }
            }
            Err(error) => eprintln!("jet-interactive watch {host}: {error:#}"),
        }
        std::thread::sleep(Duration::from_secs(interval.max(1)));
    }
}

impl std::str::FromStr for Browser {
    type Err = ();

    fn from_str(value: &str) -> std::result::Result<Self, Self::Err> {
        match value {
            "auto" => Ok(Self::Auto),
            "chrome" => Ok(Self::Chrome),
            "chromium" => Ok(Self::Chromium),
            "firefox" => Ok(Self::Firefox),
            _ => Err(()),
        }
    }
}

fn attach(host: &str, requested: Option<&str>, no_open: bool, browser: Browser) -> Result<()> {
    let session = choose_session(remote_sessions(host)?, requested)?;
    let mut forward = start_forward(host, &session)?;
    let url = url_for(forward.local_port, &session);
    println!("{url}");
    if !no_open {
        open_browser(&url, browser)?;
    }
    forward.child.0.wait()?;
    Ok(())
}

fn response(content_type: &'static str, body: &'static [u8]) -> Response<Body> {
    let mut response = Response::new(Body::from(body));
    response
        .headers_mut()
        .insert(header::CONTENT_TYPE, HeaderValue::from_static(content_type));
    response.headers_mut().insert(
        header::CONTENT_SECURITY_POLICY,
        HeaderValue::from_static(
            // Plotly FigureWidget is an explicitly allow-listed AnyWidget.
            // Its ESM payload is imported through a blob URL, while Plotly's
            // WebGL renderer (regl) compiles draw functions at runtime. This
            // requires `blob:` and `unsafe-eval` respectively. The bridge is
            // loopback-only, generic HTML is sanitized/sandboxed and the
            // frontend rejects third-party AnyWidget modules before import.
            "default-src 'self'; script-src 'self' blob: 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self' ws: wss:; frame-src 'self' blob:; worker-src 'self' blob:; object-src 'none'; base-uri 'none'",
        ),
    );
    response
}

async fn index() -> Response<Body> {
    response(
        "text/html; charset=utf-8",
        include_bytes!("../assets/index.html"),
    )
}
async fn app_js() -> Response<Body> {
    response(
        "text/javascript; charset=utf-8",
        include_bytes!("../assets/app.js"),
    )
}
async fn style_css() -> Response<Body> {
    response(
        "text/css; charset=utf-8",
        include_bytes!("../assets/style.css"),
    )
}
async fn plotly_js() -> Response<Body> {
    response(
        "text/javascript; charset=utf-8",
        include_bytes!("../assets/vendor/plotly.min.js"),
    )
}
async fn purify_js() -> Response<Body> {
    response(
        "text/javascript; charset=utf-8",
        include_bytes!("../assets/vendor/purify.min.js"),
    )
}
async fn marked_js() -> Response<Body> {
    response(
        "text/javascript; charset=utf-8",
        include_bytes!("../assets/vendor/marked.min.js"),
    )
}
async fn katex_js() -> Response<Body> {
    response(
        "text/javascript; charset=utf-8",
        include_bytes!("../assets/vendor/katex.min.js"),
    )
}
async fn katex_css() -> Response<Body> {
    response(
        "text/css; charset=utf-8",
        include_bytes!("../assets/vendor/katex.min.css"),
    )
}
async fn jupyter_widgets_js() -> Response<Body> {
    response(
        "text/javascript; charset=utf-8",
        include_bytes!("../assets/vendor/jupyter-widgets.js"),
    )
}
async fn jupyter_widgets_css() -> Response<Body> {
    response(
        "text/css; charset=utf-8",
        include_bytes!("../assets/vendor/jupyter-widgets.css"),
    )
}
async fn katex_font(axum::extract::Path(path): axum::extract::Path<String>) -> Response<Body> {
    let Some(file) = KATEX_FONTS.get_file(&path) else {
        return Response::builder()
            .status(StatusCode::NOT_FOUND)
            .body(Body::empty())
            .unwrap();
    };
    let content_type = mime_guess::from_path(&path)
        .first_or_octet_stream()
        .to_string();
    Response::builder()
        .header(header::CONTENT_TYPE, content_type)
        .body(Body::from(file.contents()))
        .unwrap()
}
async fn not_found(_request: Request<Body>) -> impl IntoResponse {
    (StatusCode::NOT_FOUND, "Not found")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requested_session_is_selected() {
        let a = new_descriptor(1000);
        let mut b = new_descriptor(2000);
        b.session_id = "wanted".into();
        assert_eq!(
            choose_session(vec![a, b], Some("wanted")).unwrap().port,
            2000
        );
    }
}
