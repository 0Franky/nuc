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
    std::env::set_var("DISPLAY", "invalid-display");
    send(
        &mut b,
        json!({"type":"TOUCHPAD_DELTA","target_device_id":host.to_string(),"dx":1,"dy":1}),
    )
    .await;
    assert_eq!(receive(&mut b, "INPUT_STATUS").await["ok"], false);
    a.close(None).await.unwrap();
    assert_eq!(receive(&mut b, "PEER_DISCONNECTED").await["id"], a_id);
    b.close(None).await.unwrap();
}
