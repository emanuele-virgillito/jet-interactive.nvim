use std::process::Stdio;

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    process::Command,
};
use tokio_tungstenite::{connect_async, tungstenite::Message};

#[tokio::test]
async fn authenticated_client_receives_the_cached_snapshot() {
    let mut child = Command::new(env!("CARGO_BIN_EXE_jet-interactive"))
        .arg("serve")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    let mut stdout = BufReader::new(stdout).lines();
    let ready: Value = serde_json::from_str(&stdout.next_line().await.unwrap().unwrap()).unwrap();

    let snapshot = json!({
        "protocol": "v1",
        "type": "session.snapshot",
        "executions": [{ "id": "request-1", "outputs": [] }],
    });
    let stdin = child.stdin.as_mut().unwrap();
    stdin
        .write_all(snapshot.to_string().as_bytes())
        .await
        .unwrap();
    stdin.write_all(b"\n").await.unwrap();
    stdin.flush().await.unwrap();

    let url = format!("ws://127.0.0.1:{}/ws", ready["port"].as_u64().unwrap());
    let (mut socket, _) = connect_async(url).await.unwrap();
    socket
        .send(Message::Text(
            json!({ "type": "auth", "token": ready["token"] })
                .to_string()
                .into(),
        ))
        .await
        .unwrap();
    let received: Value = serde_json::from_str(
        socket
            .next()
            .await
            .unwrap()
            .unwrap()
            .into_text()
            .unwrap()
            .as_ref(),
    )
    .unwrap();
    assert_eq!(received["type"], "session.snapshot");
    assert_eq!(received["executions"][0]["id"], "request-1");

    socket
        .send(Message::Text(
            json!({
                "type": "widget.comm_msg.request",
                "kernel_id": "kernel-1",
                "comm_id": "widget-1",
                "data": { "method": "update", "state": { "zoom": 2 } },
            })
            .to_string()
            .into(),
        ))
        .await
        .unwrap();
    let control: Value = serde_json::from_str(&stdout.next_line().await.unwrap().unwrap()).unwrap();
    assert_eq!(control["protocol"], "v1");
    assert_eq!(control["type"], "widget.comm_msg.request");
    assert_eq!(control["comm_id"], "widget-1");

    Command::new("kill")
        .args(["-TERM", &child.id().unwrap().to_string()])
        .status()
        .await
        .unwrap();
    assert!(child.wait().await.unwrap().success());
}
