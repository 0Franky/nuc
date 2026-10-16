#![cfg(target_os = "linux")]
use futures_util::{SinkExt, StreamExt};
use nexus_actor_system::{ActorSupervisor, EventBus};
use nexus_plugin_media::MediaPluginActor;
use nexus_types::DeviceId;
use serde_json::{json, Value};
use std::time::Duration;
use tokio::net::TcpStream;
use tokio_tungstenite::{connect_async, tungstenite::Message, MaybeTlsStream, WebSocketStream};
type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;

async fn receive(ws: &mut Socket, kind: &str) -> Value {
    tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            let message = ws.next().await.unwrap().unwrap();
            if let Ok(text) = message.into_text() {
                let value: Value = serde_json::from_str(&text).unwrap();
                if value["type"] == kind {
                    return value;
                }
            }
        }
    })
    .await
    .unwrap_or_else(|_| panic!("Missing {kind}"))
}
async fn send(ws: &mut Socket, value: Value) {
    ws.send(Message::Text(value.to_string())).await.unwrap();
}

#[tokio::test]
#[ignore = "Requires isolated X11 display and free TCP 28471; run under xvfb-run -s '-screen 0 1024x768x24 -noreset'"]
async fn websocket_snapshot_routing_rename_disconnect_and_linux_input() {
    let host = DeviceId::new_random();
    let (bus, _commands) = EventBus::new(128, 128);
    ActorSupervisor::spawn_actor(
        MediaPluginActor::new(host).with_device_name("Linux Studio".into()),
        bus,
    );
    let mut a = tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            if let Ok((ws, _)) = connect_async("ws://127.0.0.1:28471/media").await {
                break ws;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .unwrap();
    assert_eq!(
        receive(&mut a, "PEER_ANNOUNCE").await["name"],
        "Linux Studio"
    );
    let a_id = DeviceId::new_random().to_string();
    send(&mut a, json!({"type":"PEER_ANNOUNCE","id":a_id,"name":"Phone A","device_type":"Mobile","os":"android"})).await;
    assert_eq!(receive(&mut a, "PEER_ANNOUNCE").await["id"], a_id);
    let (mut b, _) = connect_async("ws://127.0.0.1:28471/media").await.unwrap();
    assert_eq!(
        receive(&mut b, "PEER_ANNOUNCE").await["id"],
        host.to_string()
    );
    assert_eq!(receive(&mut b, "PEER_ANNOUNCE").await["id"], a_id);
    // A command for a mobile client is delivered there, never executed on the router.
    send(
        &mut b,
        json!({"type":"OPEN_URL","target_device_id":a_id,"url":"https://example.com/"}),
    )
    .await;
    assert_eq!(receive(&mut a, "OPEN_URL").await["target_device_id"], a_id);
    // Same UUID, new name: reconnecting clients see one renamed peer.
    send(&mut a, json!({"type":"PEER_METADATA","id":a_id,"name":"Renamed Phone","device_type":"Mobile","os":"android"})).await;
    assert_eq!(
        receive(&mut b, "PEER_ANNOUNCE").await["name"],
        "Renamed Phone"
    );
    nexus_plugin_input::NativeInputInjector::inject_mouse_move_absolute(200, 200, 1024, 768)
        .unwrap();
    send(
        &mut b,
        json!({"type":"TOUCHPAD_DELTA","target_device_id":host.to_string(),"dx":17,"dy":-9}),
    )
    .await;
    assert_eq!(receive(&mut b, "INPUT_STATUS").await["ok"], true);
    let (dx, dy) = nexus_plugin_input::TouchpadBallistics::default().calculate_delta(17.0, -9.0);
    let location = std::process::Command::new("xdotool")
        .args(["getmouselocation", "--shell"])
        .output()
        .unwrap();
    let location = String::from_utf8(location.stdout).unwrap();
    assert!(
        location.lines().any(|l| l == format!("X={}", 200 + dx)),
        "{location}"
    );
    assert!(
        location.lines().any(|l| l == format!("Y={}", 200 + dy)),
        "{location}"
    );
    // Real backend error is returned over the same network connection.
    // Changing DISPLAY cannot invalidate the native injector's cached X11 connection.
    // Keyboard commands use a new xdotool process, so a missing display is
    // a deterministic backend error and cannot generate any input event.
    std::env::set_var("DISPLAY", "invalid-display");
    send(
        &mut b,
        json!({"type":"KEYBOARD_KEY","target_device_id":host.to_string(),"key":"Enter"}),
    )
    .await;
    assert_eq!(receive(&mut b, "INPUT_STATUS").await["ok"], false);
    a.close(None).await.unwrap();
    assert_eq!(receive(&mut b, "PEER_DISCONNECTED").await["id"], a_id);
    b.close(None).await.unwrap();
}

#[tokio::test]
#[ignore = "Requires an isolated network namespace and private XDG_CONFIG_HOME; no input is injected"]
async fn optional_input_metadata_survives_relay_and_reconnection() {
    let host = DeviceId::new_random();
    let (bus, _commands) = EventBus::new(128, 128);
    ActorSupervisor::spawn_actor(MediaPluginActor::new(host).with_device_name("Router".into()), bus);
    let mut peer = tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            if let Ok((socket, _)) = connect_async("ws://127.0.0.1:28471/media").await { break socket; }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }).await.unwrap();
    receive(&mut peer, "PEER_ANNOUNCE").await;
    let id = DeviceId::new_random().to_string();
    let ready = json!({"fingerprint":"test-identity", "emulation_ready":true, "capture_ready":true, "port":4243});
    send(&mut peer, json!({"type":"PEER_ANNOUNCE", "id":id, "name":"Linux", "os":"linux", "shared_input":ready})).await;
    assert_eq!(receive(&mut peer, "PEER_ANNOUNCE").await["shared_input"], ready);
    send(&mut peer, json!({"type":"PEER_METADATA", "id":id, "name":"Linux Renamed", "os":"linux"})).await;
    let relayed = receive(&mut peer, "PEER_ANNOUNCE").await;
    assert!(relayed.get("shared_input").is_none(), "Absent metadata must not become a destructive null: {relayed}");
    let (mut observer, _) = connect_async("ws://127.0.0.1:28471/media").await.unwrap();
    receive(&mut observer, "PEER_ANNOUNCE").await;
    let snapshot = receive(&mut observer, "PEER_ANNOUNCE").await;
    assert_eq!(snapshot["id"], id);
    assert_eq!(snapshot["shared_input"], ready, "Cached reconnect snapshot must preserve previous metadata");
    observer.close(None).await.unwrap();

    send(&mut peer, json!({"type":"PEER_METADATA", "id":id, "name":"Linux", "shared_input":null})).await;
    assert_eq!(receive(&mut peer, "PEER_ANNOUNCE").await.get("shared_input"), Some(&Value::Null));
    send(&mut peer, json!({"type":"PEER_ANNOUNCE", "id":id, "name":"Linux"})).await;
    assert!(receive(&mut peer, "PEER_ANNOUNCE").await.get("shared_input").is_none());
    let (mut observer, _) = connect_async("ws://127.0.0.1:28471/media").await.unwrap();
    receive(&mut observer, "PEER_ANNOUNCE").await;
    assert_eq!(receive(&mut observer, "PEER_ANNOUNCE").await.get("shared_input"), Some(&Value::Null));
    observer.close(None).await.unwrap();

    send(&mut peer, json!({"type":"PEER_METADATA", "id":host.to_string(), "name":"Router", "shared_input":ready})).await;
    assert_eq!(receive(&mut peer, "PEER_METADATA").await["shared_input"], ready);
    send(&mut peer, json!({"type":"PEER_METADATA", "id":host.to_string(), "name":"Router Renamed"})).await;
    assert!(receive(&mut peer, "PEER_METADATA").await.get("shared_input").is_none());
    let (mut observer, _) = connect_async("ws://127.0.0.1:28471/media").await.unwrap();
    assert_eq!(receive(&mut observer, "PEER_ANNOUNCE").await["shared_input"], ready, "Local rename must not wipe ready state");
    observer.close(None).await.unwrap();
    send(&mut peer, json!({"type":"PEER_METADATA", "id":host.to_string(), "name":"Router", "shared_input":null})).await;
    assert_eq!(receive(&mut peer, "PEER_METADATA").await.get("shared_input"), Some(&Value::Null));
    let (mut observer, _) = connect_async("ws://127.0.0.1:28471/media").await.unwrap();
    assert_eq!(receive(&mut observer, "PEER_ANNOUNCE").await.get("shared_input"), Some(&Value::Null));
    observer.close(None).await.unwrap();
    peer.close(None).await.unwrap();
}
