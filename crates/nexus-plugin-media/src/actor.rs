use async_trait::async_trait;
use futures_util::{SinkExt, StreamExt};
use nexus_actor_system::{EventBus, NexusActor, NexusCommand, NexusEvent};
use nexus_protocol::{MediaPayload, NexusPacket, PacketPayload};
use nexus_types::{DeviceId, NexusError, NexusResult};
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::info;

use crate::session::{append_log, ActiveMediaSession};

/// Media Plugin Actor: Orchestrates Continuity, Timestamp Sync & Browser/OS Hooks
#[derive(Clone)]
pub struct MediaPluginActor {
    pub device_id: DeviceId,
    device_name: Arc<RwLock<String>>,
    shared_input_metadata: Arc<RwLock<serde_json::Value>>,
    peers: Arc<RwLock<std::collections::BTreeMap<String, (serde_json::Value, tokio::sync::mpsc::UnboundedSender<String>)>>>,
    current_session: Arc<RwLock<Option<ActiveMediaSession>>>,
    connected_clients: Arc<RwLock<Vec<tokio::sync::mpsc::UnboundedSender<String>>>>,
    has_fired_departure_handoff: Arc<std::sync::atomic::AtomicBool>,
}

impl MediaPluginActor {
    pub fn new(device_id: DeviceId) -> Self {
        Self {
            device_id,
            device_name: Arc::new(RwLock::new(format!("Nexus-{}", &device_id.to_string()[..4]))),
            shared_input_metadata: Arc::new(RwLock::new(serde_json::Value::Null)),
            peers: Arc::new(RwLock::new(std::collections::BTreeMap::new())),
            current_session: Arc::new(RwLock::new(None)),
            connected_clients: Arc::new(RwLock::new(Vec::new())),
            has_fired_departure_handoff: Arc::new(std::sync::atomic::AtomicBool::new(false)),
        }
    }

    pub fn with_device_name(mut self, name: String) -> Self {
        self.device_name = Arc::new(RwLock::new(name));
        self
    }

    pub fn clone_handle(&self) -> Self {
        self.clone()
    }

    /// Returns a shared reference to the connected WebSocket clients list.
    /// Used by NotificationPluginActor to broadcast notifications on the same WebSocket.
    pub fn shared_clients(&self) -> Arc<RwLock<Vec<tokio::sync::mpsc::UnboundedSender<String>>>> {
        self.connected_clients.clone()
    }

    /// Called when local browser extension or OS media controller detects a playback update
    #[allow(clippy::too_many_arguments)]
    pub async fn update_local_playback(
        &self,
        bus: &EventBus,
        source_app: String,
        media_title: String,
        media_url: String,
        position_ms: u64,
        duration_ms: u64,
        is_playing: bool,
    ) {
        let session_id = format!("sess-{}", uuid::Uuid::new_v4());
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;

        let session = ActiveMediaSession {
            session_id: session_id.clone(),
            source_app: source_app.clone(),
            media_title: media_title.clone(),
            media_url: media_url.clone(),
            position_ms,
            duration_ms,
            is_playing,
            last_updated_ms: now_ms,
        };

        {
            let mut current = self.current_session.write().await;
            *current = Some(session.clone());
        }

        info!(
            "Local playback updated: '{}' - '{}' at {}ms (playing: {})",
            source_app, media_title, position_ms, is_playing
        );

        // Broadcast to all connected clients (UI apps, other extensions)
        if let Ok(msg_json) = serde_json::to_string(&session) {
            let mut clients = self.connected_clients.write().await;
            clients.retain(|tx| tx.send(msg_json.clone()).is_ok());
        }

        bus.publish(NexusEvent::LocalPlaybackChanged {
            source_app,
            media_title,
            media_url: Some(media_url),
            position_ms,
            is_playing,
        });
    }

    /// Sends a remote control command (PLAY, PAUSE, SEEK) to connected browser extensions
    pub async fn send_remote_command(&self, action: String, position_ms: Option<u64>) {
        let cmd = serde_json::json!({
            "action": action,
            "position_ms": position_ms,
        });
        if let Ok(cmd_str) = serde_json::to_string(&cmd) {
            let mut clients = self.connected_clients.write().await;
            clients.retain(|tx| tx.send(cmd_str.clone()).is_ok());
            append_log(
                "nexus_daemon.log",
                &format!("[Remote Control] Sent command to browser: {}", cmd_str),
            );
        }
    }

    /// Triggers handoff to a specific peer
    pub async fn offer_handoff_to_peer(
        &self,
        bus: &EventBus,
        target_peer: DeviceId,
    ) -> NexusResult<()> {
        let current = self.current_session.read().await;
        let session = match &*current {
            Some(s) => s.clone(),
            None => {
                return Err(NexusError::Plugin {
                    plugin: "media.handoff",
                    message: "No active media session to handoff".into(),
                })
            }
        };

        let payload = PacketPayload::Media(MediaPayload::OfferHandoff {
            session_id: session.session_id.clone(),
            source_app: session.source_app.clone(),
            media_title: session.media_title.clone(),
            media_url: session.media_url.clone(),
            position_ms: session.position_ms,
            duration_ms: session.duration_ms,
            is_playing: session.is_playing,
        });

        let packet = NexusPacket::new(self.device_id, payload).with_target(target_peer);

        bus.send_command(NexusCommand::SendPacket {
            target: target_peer,
            packet,
        })
        .await?;

        info!(
            "Handoff offer sent to peer {}: '{}' @ {}ms",
            target_peer, session.media_title, session.position_ms
        );
        Ok(())
    }

    /// Called by receiving peer to accept the handoff and resume playback
    pub async fn accept_handoff(
        &self,
        bus: &EventBus,
        from_peer: DeviceId,
        session_id: String,
        start_position_ms: u64,
    ) -> NexusResult<()> {
        let payload = PacketPayload::Media(MediaPayload::AcceptHandoff {
            session_id: session_id.clone(),
            start_position_ms,
        });

        let packet = NexusPacket::new(self.device_id, payload).with_target(from_peer);

        bus.send_command(NexusCommand::SendPacket {
            target: from_peer,
            packet,
        })
        .await?;

        info!(
            "Media handoff accepted from peer {} at position {}ms",
            from_peer, start_position_ms
        );
        Ok(())
    }

    /// Called on source peer when remote peer accepted: pauses local playback
    pub async fn on_handoff_accepted_by_remote(&self, session_id: &str) -> NexusResult<()> {
        let mut current = self.current_session.write().await;
        if let Some(session) = current.as_mut() {
            if session.session_id == session_id {
                session.is_playing = false;
                info!("Local playback paused automatically following successful remote handoff");
                return Ok(());
            }
        }
        Ok(())
    }

    pub async fn get_current_session(&self) -> Option<ActiveMediaSession> {
        self.current_session.read().await.clone()
    }
}

#[async_trait]
impl NexusActor for MediaPluginActor {
    fn name(&self) -> &'static str {
        "nexus-plugin-media"
    }

    async fn run(&mut self, bus: EventBus) -> NexusResult<()> {
        let mut event_sub = bus.subscribe();
        let actor_self = self.clone();
        let bus_clone = bus.clone();

        // 1. Try to start WebSocket Server on 0.0.0.0:28471 for Browser Extension & UI / LAN Clients
        tokio::spawn(async move {
            match tokio::net::TcpListener::bind("0.0.0.0:28471").await {
                Ok(listener) => {
                    info!("🌐 Media Plugin WebSocket Server listening on ws://0.0.0.0:28471/media for browser & mobile clients");
                    while let Ok((stream, addr)) = listener.accept().await {
                        let actor = actor_self.clone();
                        let bus_inner = bus_clone.clone();

                        tokio::spawn(async move {
                            if let Ok(ws_stream) = tokio_tungstenite::accept_async(stream).await {
                                info!("🔌 Client connected via WebSocket from {}", addr);
                                let (mut write, mut read) = ws_stream.split();
                                let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<String>();

                                {
                                    let mut clients = actor.connected_clients.write().await;
                                    clients.push(tx.clone());
                                }

                                // Send host's own identity announcement immediately to new client
                                let self_name = actor.device_name.read().await.clone();
                                let self_announce = serde_json::json!({
                                    "type": "PEER_ANNOUNCE",
                                    "name": self_name,
                                    "is_host": true,
                                    "shared_input": actor.shared_input_metadata.read().await.clone(),
                                    "id": actor.device_id.to_string(),
                                    "device_id": actor.device_id.to_string(),
                                    "device_type": "Desktop",
                                    "os": std::env::consts::OS,
                                    "spatial_position": "Center",
                                });
                                if let Ok(ann_str) = serde_json::to_string(&self_announce) {
                                    let _ = tx.send(ann_str);
                                }

                                for (metadata, _) in actor.peers.read().await.values() {
                                    let _ = tx.send(metadata.to_string());
                                }
                                let mut registered_peer: Option<DeviceId> = None;

                                // Send current active media playback snapshot immediately to new client
                                if let Some(session) = actor.get_current_session().await {
                                    if let Ok(sess_json) = serde_json::to_string(&session) {
                                        let _ = tx.send(sess_json);
                                    }
                                }

                                // Forward outgoing broadcast messages
                                let write_task = tokio::spawn(async move {
                                    while let Some(msg_text) = rx.recv().await {
                                        if write
                                            .send(tokio_tungstenite::tungstenite::Message::Text(
                                                msg_text,
                                            ))
                                            .await
                                            .is_err()
                                        {
                                            break;
                                        }
                                    }
                                });

                                while let Some(Ok(msg)) = read.next().await {
                                    if let Ok(text) = msg.into_text() {
                                        if let Ok(json_val) =
                                            serde_json::from_str::<serde_json::Value>(&text)
                                        {
                                            let msg_type = json_val["type"].as_str().unwrap_or("");

                                            if let Some(target) = json_val["target_device_id"].as_str() {
                                                if target != actor.device_id.to_string() {
                                                    let peers = actor.peers.read().await;
                                                    if let Some((_, destination)) = peers.get(target) {
                                                        let _ = destination.send(text.clone());
                                                    } else {
                                                        let _ = tx.send(input_status(DeviceId::from_bytes(*uuid::Uuid::parse_str(target).unwrap_or_default().as_bytes()), Err(NexusError::Plugin {
                                                            plugin: "routing", message: "Dispositivo destinazione non connesso".into(),
                                                        })));
                                                    }
                                                    continue;
                                                }
                                            }

                                            if msg_type == "PING" {
                                                continue;
                                            }

                                            if msg_type == "PEER_ANNOUNCE" || msg_type == "PEER_METADATA" {
                                                let peer_name = json_val["name"]
                                                    .as_str()
                                                    .unwrap_or("Dispositivo Remoto")
                                                    .to_string();
                                                let peer_id_str = json_val["id"]
                                                    .as_str()
                                                    .or_else(|| json_val["device_id"].as_str())
                                                    .unwrap_or("")
                                                    .to_string();
                                                let peer_device_type_str = json_val["device_type"]
                                                    .as_str()
                                                    .unwrap_or("Desktop");
                                                let peer_os_str = json_val["os"]
                                                    .as_str()
                                                    .unwrap_or(std::env::consts::OS);
                                                let peer_pos_str = json_val["spatial_position"]
                                                    .as_str()
                                                    .unwrap_or("Center");

                                                append_log(
                                                    "nexus_daemon.log",
                                                    &format!(
                                                        "[LAN Peer Connected] {} ({}) type: {} os: {} from {}",
                                                        peer_name, peer_id_str, peer_device_type_str, peer_os_str, addr
                                                    ),
                                                );
                                                let peer_id =
                                                    match uuid::Uuid::parse_str(&peer_id_str) {
                                                        Ok(u) => DeviceId::from_bytes(*u.as_bytes()),
                                                        Err(_) => continue,
                                                    };

                                                if peer_id == actor.device_id {
                                                    if addr.ip().is_loopback() && !peer_name.trim().is_empty() {
                                                        *actor.device_name.write().await = peer_name.clone();
                                                        *actor.shared_input_metadata.write().await = json_val["shared_input"].clone();
                                                        if let Err(error) = nexus_crypto::DeviceIdentity::save_device_name(&peer_name) {
                                                            tracing::warn!("Cannot persist device name: {error}");
                                                        }
                                                        let metadata = serde_json::json!({
                                                            "type": "PEER_METADATA", "id": actor.device_id.to_string(),
                                                            "name": peer_name, "device_type": "Desktop", "os": std::env::consts::OS,
                                                            "shared_input": actor.shared_input_metadata.read().await.clone(),
                                                        }).to_string();
                                                        actor.connected_clients.write().await.retain(|c| c.send(metadata.clone()).is_ok());
                                                    }
                                                    continue;
                                                }
                                                // One identity per connection; renaming must not create a new device.
                                                if registered_peer.is_some_and(|id| id != peer_id) { continue; }
                                                registered_peer = Some(peer_id);

                                                let device_type = match peer_device_type_str.to_lowercase().as_str() {
                                                    "mobile" | "phone" | "smartphone" => nexus_types::DeviceType::Mobile,
                                                    "tablet" => nexus_types::DeviceType::Tablet,
                                                    "laptop" => nexus_types::DeviceType::Laptop,
                                                    _ => nexus_types::DeviceType::Desktop,
                                                };

                                                let os_type = match peer_os_str.to_lowercase().as_str() {
                                                    "windows" => nexus_types::OsType::Windows,
                                                    "macos" | "darwin" => nexus_types::OsType::MacOS,
                                                    "linux" => nexus_types::OsType::Linux,
                                                    "android" => nexus_types::OsType::Android,
                                                    "ios" => nexus_types::OsType::IOS,
                                                    _ => nexus_types::OsType::Unknown,
                                                };

                                                bus_inner.publish(NexusEvent::PeerDiscovered(
                                                    nexus_types::PeerInfo {
                                                        id: peer_id,
                                                        name: peer_name.clone(),
                                                        device_type,
                                                        os: os_type,
                                                        capabilities: nexus_types::CapabilityMap::new()
                                                            .with_capability(
                                                                nexus_types::Capability::MediaHandoff,
                                                            ),
                                                        protocol_version: 1,
                                                        public_key_fingerprint: String::new(),
                                                        screen_geometry: None,
                                                        spatial_arrangement:
                                                            nexus_types::SpatialArrangement::None,
                                                    },
                                                ));

                                                // Broadcast peer discovery to all other connected clients (like nexus_ui desktop app)
                                                let announce_msg = serde_json::json!({
                                                    "type": "PEER_ANNOUNCE",
                                                    "name": peer_name,
                                                    "id": peer_id.to_string(),
                                                    "device_id": peer_id.to_string(),
                                                    "device_type": peer_device_type_str,
                                                    "os": peer_os_str,
                                                    "spatial_position": peer_pos_str,
                                                    "ip": addr.ip().to_string(),
                                                    "shared_input": json_val["shared_input"],
                                                });
                                                actor.peers.write().await.insert(peer_id.to_string(), (announce_msg.clone(), tx.clone()));
                                                if let Ok(announce_str) =
                                                    serde_json::to_string(&announce_msg)
                                                {
                                                    let mut clients =
                                                        actor.connected_clients.write().await;
                                                    clients.retain(|c| {
                                                        c.send(announce_str.clone()).is_ok()
                                                    });
                                                }
                                                continue;
                                            }

                                            if msg_type == "EXTENSION_LOG" {
                                                if let Some(log_text) = json_val["log"].as_str() {
                                                    append_log("nexus_extension.log", log_text);
                                                }
                                                continue;
                                            }

                                            if msg_type == "TOUCHPAD_DELTA" {
                                                let dx = json_val["dx"].as_i64().unwrap_or(0) as i32;
                                                let dy = json_val["dy"].as_i64().unwrap_or(0) as i32;
                                                let ballistics =
                                                    nexus_plugin_input::TouchpadBallistics::default();
                                                let (scaled_dx, scaled_dy) =
                                                    ballistics.calculate_delta(dx as f32, dy as f32);
                                                let result = nexus_plugin_input::NativeInputInjector::inject_mouse_move_relative(
                                                    scaled_dx, scaled_dy,
                                                );
                                                let _ = tx.send(input_status(actor.device_id, result));
                                                continue;
                                            }

                                            if msg_type == "TOUCHPAD_CLICK" {
                                                let btn_str =
                                                    json_val["button"].as_str().unwrap_or("Left");
                                                let btn = if btn_str.eq_ignore_ascii_case("right") {
                                                    nexus_protocol::MouseButton::Right
                                                } else {
                                                    nexus_protocol::MouseButton::Left
                                                };
                                                let result = nexus_plugin_input::NativeInputInjector::inject_mouse_click(
                                                    btn,
                                                );
                                                let _ = tx.send(input_status(actor.device_id, result));
                                                continue;
                                            }

                                            if msg_type == "TOUCHPAD_BUTTON" {
                                                let btn_str =
                                                    json_val["button"].as_str().unwrap_or("Left");
                                                let is_down =
                                                    json_val["is_down"].as_bool().unwrap_or(true);
                                                let btn = if btn_str.eq_ignore_ascii_case("right") {
                                                    nexus_protocol::MouseButton::Right
                                                } else if btn_str.eq_ignore_ascii_case("middle") {
                                                    nexus_protocol::MouseButton::Middle
                                                } else {
                                                    nexus_protocol::MouseButton::Left
                                                };
                                                let result = nexus_plugin_input::NativeInputInjector::inject_mouse_button(
                                                    btn, is_down,
                                                );
                                                let _ = tx.send(input_status(actor.device_id, result));
                                                continue;
                                            }

                                            if msg_type == "TOUCHPAD_SCROLL" {
                                                let dy = json_val["dy"].as_i64().unwrap_or(0) as i32;
                                                let result = nexus_plugin_input::NativeInputInjector::inject_mouse_wheel(
                                                    dy,
                                                );
                                                let _ = tx.send(input_status(actor.device_id, result));
                                                continue;
                                            }

                                            if msg_type == "KEYBOARD_KEY" {
                                                let key_str =
                                                    json_val["key"].as_str().unwrap_or("");
                                                let is_down = json_val["is_down"].as_bool();
                                                append_log(
                                                    "nexus_daemon.log",
                                                    &format!(
                                                        "[Keyboard Key] key: {}, down: {:?}",
                                                        key_str, is_down
                                                    ),
                                                );
                                                let result = nexus_plugin_input::NativeInputInjector::inject_keyboard_key(
                                                    key_str, is_down,
                                                );
                                                let _ = tx.send(input_status(actor.device_id, result));
                                                continue;
                                            }

                                            if msg_type == "KEYBOARD_COMBO" {
                                                let keys_arr = json_val["keys"].as_array();
                                                if let Some(arr) = keys_arr {
                                                    let keys_vec: Vec<&str> =
                                                        arr.iter().filter_map(|v| v.as_str()).collect();
                                                    append_log(
                                                        "nexus_daemon.log",
                                                        &format!(
                                                            "[Keyboard Combo] keys: {:?}",
                                                            keys_vec
                                                        ),
                                                    );
                                                    let result = nexus_plugin_input::NativeInputInjector::inject_keyboard_combo(
                                                        &keys_vec,
                                                    );
                                                let _ = tx.send(input_status(actor.device_id, result));
                                                }
                                                continue;
                                            }

                                            if msg_type == "KEYBOARD_TEXT" {
                                                let text_val =
                                                    json_val["text"].as_str().unwrap_or("");
                                                append_log(
                                                    "nexus_daemon.log",
                                                    &format!(
                                                        "[Keyboard Unicode Text] length: {} chars",
                                                        text_val.len()
                                                    ),
                                                );
                                                let result = nexus_plugin_input::NativeInputInjector::inject_unicode_text(
                                                    text_val,
                                                );
                                                let _ = tx.send(input_status(actor.device_id, result));
                                                continue;
                                            }

                                            if msg_type == "OPEN_URL" {
                                                let url_val =
                                                    json_val["url"].as_str().unwrap_or("");
                                                let title_val =
                                                    json_val["title"].as_str().unwrap_or("Video");
                                                append_log(
                                                    "nexus_daemon.log",
                                                    &format!(
                                                        "[Handoff Forward] Opening URL: {} ({})",
                                                        url_val, title_val
                                                    ),
                                                );
                                                let open_msg = serde_json::json!({
                                                    "type": "OPEN_URL",
                                                    "url": url_val,
                                                    "title": title_val,
                                                    "position_ms": json_val["position_ms"].as_u64().unwrap_or(0),
                                                });
                                                if let Ok(msg_str) =
                                                    serde_json::to_string(&open_msg)
                                                {
                                                    let mut clients =
                                                        actor.connected_clients.write().await;
                                                    clients.retain(|c| {
                                                        c.send(msg_str.clone()).is_ok()
                                                    });
                                                }
                                                continue;
                                            }

                                            if msg_type == "CLIPBOARD_SYNC" {
                                                let text = json_val["text"].as_str().unwrap_or("");
                                                append_log(
                                                    "nexus_daemon.log",
                                                    &format!(
                                                        "[Clipboard Synced] Content length: {} chars",
                                                        text.len()
                                                    ),
                                                );
                                                let clip_msg = serde_json::json!({
                                                    "type": "CLIPBOARD_SYNC",
                                                    "text": text,
                                                });
                                                if let Ok(msg_str) =
                                                    serde_json::to_string(&clip_msg)
                                                {
                                                    let mut clients =
                                                        actor.connected_clients.write().await;
                                                    clients.retain(|c| {
                                                        c.send(msg_str.clone()).is_ok()
                                                    });
                                                }
                                                continue;
                                            }

                                            if msg_type == "CLIPBOARD_SECRET_ANNOUNCE"
                                                || msg_type == "CLIPBOARD_REVEAL_REQUEST"
                                                || msg_type == "CLIPBOARD_REVEAL_RESPONSE"
                                                || msg_type == "NOTIFICATION_SYNC"
                                                || msg_type == "NOTIFICATION_REVEAL_REQUEST"
                                                || msg_type == "NOTIFICATION_REVEAL_RESPONSE"
                                            {
                                                append_log(
                                                    "nexus_daemon.log",
                                                    &format!("[Cross-Device Event] type: {}", msg_type),
                                                );
                                                if let Ok(msg_str) =
                                                    serde_json::to_string(&json_val)
                                                {
                                                    let mut clients =
                                                        actor.connected_clients.write().await;
                                                    clients.retain(|c| {
                                                        c.send(msg_str.clone()).is_ok()
                                                    });
                                                }
                                                continue;
                                            }

                                            if msg_type == "FILE_OFFER"
                                                || msg_type == "FILE_ACCEPT"
                                                || msg_type == "FILE_CHUNK"
                                                || msg_type == "FILE_COMPLETE"
                                                || msg_type == "FILE_CANCEL"
                                                || msg_type == "FILE_RESUME_REQUEST"
                                            {
                                                if msg_type == "FILE_OFFER"
                                                    || msg_type == "FILE_COMPLETE"
                                                {
                                                    append_log(
                                                        "nexus_daemon.log",
                                                        &format!(
                                                            "[File Transfer Message] type: {}, file: {}",
                                                            msg_type,
                                                            json_val["file_name"].as_str().unwrap_or("unknown")
                                                        ),
                                                    );
                                                }
                                                if let Ok(msg_str) =
                                                    serde_json::to_string(&json_val)
                                                {
                                                    let mut clients =
                                                        actor.connected_clients.write().await;
                                                    clients.retain(|c| {
                                                        c.send(msg_str.clone()).is_ok()
                                                    });
                                                }
                                                continue;
                                            }

                                            if msg_type == "PEER_METADATA"
                                                || msg_type == "PEER_ANNOUNCE"
                                                || msg_type == "SPATIAL_ARRANGEMENT"
                                                || msg_type == "TOPOLOGY_SYNC"
                                                || msg_type == "PROXIMITY_UPDATE"
                                            {
                                                if let Ok(msg_str) =
                                                    serde_json::to_string(&json_val)
                                                {
                                                    let mut clients =
                                                        actor.connected_clients.write().await;
                                                    clients.retain(|c| {
                                                        c.send(msg_str.clone()).is_ok()
                                                    });
                                                }
                                                continue;
                                            }

                                            if msg_type == "UNIVERSAL_CONTROL_HOP" {
                                                let entry_x =
                                                    json_val["entry_x"].as_i64().unwrap_or(100) as i32;
                                                let entry_y =
                                                    json_val["entry_y"].as_i64().unwrap_or(100) as i32;
                                                let sw = json_val["screen_width"]
                                                    .as_i64()
                                                    .unwrap_or(1920)
                                                    as i32;
                                                let sh = json_val["screen_height"]
                                                    .as_i64()
                                                    .unwrap_or(1080)
                                                    as i32;
                                                let result = nexus_plugin_input::NativeInputInjector::inject_mouse_move_absolute(
                                                    entry_x, entry_y, sw, sh,
                                                );
                                                let _ = tx.send(input_status(actor.device_id, result));
                                                continue;
                                            }

                                            if msg_type == "UNIVERSAL_CONTROL_DELTA" {
                                                let dx = json_val["dx"].as_i64().unwrap_or(0) as i32;
                                                let dy = json_val["dy"].as_i64().unwrap_or(0) as i32;
                                                let result = nexus_plugin_input::NativeInputInjector::inject_mouse_move_relative(
                                                    dx, dy,
                                                );
                                                let _ = tx.send(input_status(actor.device_id, result));
                                                continue;
                                            }

                                            if msg_type == "PROXIMITY_TRIGGER" {
                                                let action =
                                                    json_val["action"].as_str().unwrap_or("");
                                                if action == "LOCK_WORKSTATION" {
                                                    nexus_plugin_proximity::lock_workstation();
                                                } else if action == "PAUSE_ON_WALK_AWAY"
                                                    || action == "PAUSE"
                                                {
                                                    let mut current =
                                                        actor.current_session.write().await;
                                                    if let Some(session) = current.as_mut() {
                                                        session.is_playing = false;
                                                    }
                                                    drop(current);
                                                    let result = nexus_plugin_input::NativeInputInjector::inject_media_key(
                                                        "PAUSE",
                                                    );
                                                let _ = tx.send(input_status(actor.device_id, result));
                                                    actor.send_remote_command("PAUSE".into(), None).await;
                                                }
                                                continue;
                                            }

                                            if msg_type == "VOLUME_UPDATE" || msg_type == "VOLUME_SET" {
                                                let vol =
                                                    json_val["volume"].as_f64().unwrap_or(0.8) as f32;
                                                bus_inner.publish(NexusEvent::AudioVolumeChanged(vol));
                                                let vol_msg = serde_json::json!({
                                                    "type": "VOLUME_UPDATE",
                                                    "volume": vol,
                                                });
                                                if let Ok(msg_str) =
                                                    serde_json::to_string(&vol_msg)
                                                {
                                                    let mut clients =
                                                        actor.connected_clients.write().await;
                                                    clients.retain(|c| {
                                                        c.send(msg_str.clone()).is_ok()
                                                    });
                                                }
                                                continue;
                                            }

                                            if msg_type == "AUDIO_MUTE" {
                                                let muted =
                                                    json_val["muted"].as_bool().unwrap_or(true);
                                                bus_inner.publish(NexusEvent::AudioMuteToggled(muted));
                                                let mute_msg = serde_json::json!({
                                                    "type": "AUDIO_MUTE",
                                                    "muted": muted,
                                                });
                                                if let Ok(msg_str) =
                                                    serde_json::to_string(&mute_msg)
                                                {
                                                    let mut clients =
                                                        actor.connected_clients.write().await;
                                                    clients.retain(|c| {
                                                        c.send(msg_str.clone()).is_ok()
                                                    });
                                                }
                                                continue;
                                            }

                                            // If message contains remote control action (PLAY, PAUSE, SEEK), broadcast to all clients
                                            if let Some(action) = json_val["action"].as_str() {
                                                let pos = json_val["position_ms"].as_u64();
                                                append_log(
                                                    "nexus_daemon.log",
                                                    &format!(
                                                        "[Remote Command Ingest] Action: {} | Pos: {:?}",
                                                        action, pos
                                                    ),
                                                );

                                                // Update internal session play state if applicable
                                                let upper_action = action.to_uppercase();
                                                {
                                                    let mut current = actor.current_session.write().await;
                                                    if let Some(session) = current.as_mut() {
                                                        if upper_action == "PAUSE" {
                                                            session.is_playing = false;
                                                        } else if upper_action == "PLAY" {
                                                            session.is_playing = true;
                                                        } else if upper_action == "PLAY_PAUSE" || upper_action == "TOGGLE" {
                                                            session.is_playing = !session.is_playing;
                                                        }
                                                        if let Some(p) = pos {
                                                            session.position_ms = p;
                                                        }
                                                    }
                                                }

                                                let cmd = serde_json::json!({
                                                    "action": action,
                                                    "position_ms": pos,
                                                });
                                                if let Ok(cmd_str) = serde_json::to_string(&cmd) {
                                                    let mut clients =
                                                        actor.connected_clients.write().await;
                                                    clients.retain(|client_tx| {
                                                        client_tx.send(cmd_str.clone()).is_ok()
                                                    });
                                                }
                                                // Also inject Media Key so system media players react immediately
                                                let result = nexus_plugin_input::NativeInputInjector::inject_media_key(
                                                    action,
                                                );
                                                let _ = tx.send(input_status(actor.device_id, result));
                                                continue;
                                            }

                                            let source_app = json_val["source_app"]
                                                .as_str()
                                                .unwrap_or("Browser")
                                                .to_string();
                                            let media_title = json_val["media_title"]
                                                .as_str()
                                                .unwrap_or("")
                                                .to_string();
                                            let media_url = json_val["media_url"]
                                                .as_str()
                                                .unwrap_or("")
                                                .to_string();
                                            let position_ms =
                                                json_val["position_ms"].as_u64().unwrap_or(0);
                                            let duration_ms =
                                                json_val["duration_ms"].as_u64().unwrap_or(0);
                                            let is_playing =
                                                json_val["is_playing"].as_bool().unwrap_or(true);

                                            append_log(
                                                "nexus_daemon.log",
                                                &format!(
                                                    "[Media Ingest] App: '{}' | Title: '{}' | URL: '{}' | Pos: {}ms | Dur: {}ms | Playing: {}",
                                                    source_app, media_title, media_url, position_ms, duration_ms, is_playing
                                                ),
                                            );
                                            append_log(
                                                "nexus_extension.log",
                                                &format!(
                                                    "[Media Ingested by Daemon] Title: '{}' | Pos: {}ms | Playing: {}",
                                                    media_title, position_ms, is_playing
                                                ),
                                            );

                                            if !media_title.is_empty() {
                                                actor
                                                    .update_local_playback(
                                                        &bus_inner,
                                                        source_app,
                                                        media_title,
                                                        media_url,
                                                        position_ms,
                                                        duration_ms,
                                                        is_playing,
                                                    )
                                                    .await;
                                            }
                                        }
                                    }
                                }

                                if let Some(peer_id) = registered_peer {
                                    let mut peers = actor.peers.write().await;
                                    let id = peer_id.to_string();
                                    if peers.get(&id).is_some_and(|(_, sender)| sender.same_channel(&tx)) {
                                        peers.remove(&id);
                                        bus_inner.publish(NexusEvent::PeerDisconnected(peer_id));
                                        let message = serde_json::json!({"type": "PEER_DISCONNECTED", "id": id}).to_string();
                                        actor.connected_clients.write().await.retain(|c| c.send(message.clone()).is_ok());
                                    }
                                }
                                write_task.abort();
                            }
                        });
                    }
                }
                Err(_) => {
                    // Port already bound by background daemon -> Connect as a client to sync state and send commands in real time!
                    info!("ℹ️ Port 28471 active on daemon: connecting as live subscriber client...");
                    let actor = actor_self.clone();
                    let bus_sub = bus_clone.clone();

                    tokio::spawn(async move {
                        loop {
                            if let Ok((ws_stream, _)) =
                                tokio_tungstenite::connect_async("ws://127.0.0.1:28471/media").await
                            {
                                let (mut write, mut read) = ws_stream.split();
                                let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<String>();
                                {
                                    let mut clients = actor.connected_clients.write().await;
                                    clients.push(tx);
                                }

                                let write_task = tokio::spawn(async move {
                                    while let Some(msg_text) = rx.recv().await {
                                        if write
                                            .send(tokio_tungstenite::tungstenite::Message::Text(
                                                msg_text,
                                            ))
                                            .await
                                            .is_err()
                                        {
                                            break;
                                        }
                                    }
                                });

                                while let Some(Ok(msg)) = read.next().await {
                                    if let Ok(text) = msg.into_text() {
                                        if let Ok(json_val) =
                                            serde_json::from_str::<serde_json::Value>(&text)
                                        {
                                            if json_val["type"] == "PEER_ANNOUNCE" {
                                                let peer_name = json_val["name"]
                                                    .as_str()
                                                    .unwrap_or("Dispositivo Mobile")
                                                    .to_string();
                                                let peer_id_str =
                                                    json_val["id"].as_str().unwrap_or("").to_string();
                                                let peer_id =
                                                    match uuid::Uuid::parse_str(&peer_id_str) {
                                                        Ok(u) => DeviceId::from_bytes(*u.as_bytes()),
                                                        Err(_) => DeviceId::new_random(),
                                                    };
                                                bus_sub.publish(NexusEvent::PeerDiscovered(
                                                    nexus_types::PeerInfo {
                                                        id: peer_id,
                                                        name: peer_name,
                                                        device_type: nexus_types::DeviceType::Mobile,
                                                        os: nexus_types::OsType::Android,
                                                        capabilities: nexus_types::CapabilityMap::new()
                                                            .with_capability(
                                                                nexus_types::Capability::MediaHandoff,
                                                            ),
                                                        protocol_version: 1,
                                                        public_key_fingerprint: String::new(),
                                                        screen_geometry: None,
                                                        spatial_arrangement:
                                                            nexus_types::SpatialArrangement::None,
                                                    },
                                                ));
                                                continue;
                                            }

                                            if let Ok(session) =
                                                serde_json::from_value::<ActiveMediaSession>(json_val)
                                            {
                                                let mut curr = actor.current_session.write().await;
                                                *curr = Some(session);
                                            }
                                        }
                                    }
                                }

                                write_task.abort();
                            }
                            tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;
                        }
                    });
                }
            }
        });

        while let Ok(event) = event_sub.recv().await {
            match event {
                NexusEvent::HandoffAccepted {
                    from_peer,
                    session_id,
                    ..
                } => {
                    info!(
                        "Remote peer {} accepted handoff of session {}",
                        from_peer, session_id
                    );
                    let _ = self.on_handoff_accepted_by_remote(&session_id).await;
                }
                NexusEvent::AudioVolumeChanged(vol) => {
                    let vol_msg = serde_json::json!({
                        "type": "VOLUME_UPDATE",
                        "volume": vol,
                    });
                    if let Ok(msg_str) = serde_json::to_string(&vol_msg) {
                        let mut clients = self.connected_clients.write().await;
                        clients.retain(|c| c.send(msg_str.clone()).is_ok());
                    }
                }
                NexusEvent::AudioMuteToggled(muted) => {
                    let mute_msg = serde_json::json!({
                        "type": "AUDIO_MUTE",
                        "muted": muted,
                    });
                    if let Ok(msg_str) = serde_json::to_string(&mute_msg) {
                        let mut clients = self.connected_clients.write().await;
                        clients.retain(|c| c.send(msg_str.clone()).is_ok());
                    }
                }
                NexusEvent::ProximityChanged {
                    peer_id,
                    estimated_meters,
                    is_near,
                } => {
                    if is_near && estimated_meters <= 1.5 {
                        self.has_fired_departure_handoff
                            .store(false, std::sync::atomic::Ordering::SeqCst);
                    }
                    if (!is_near || estimated_meters > 3.0)
                        && !self
                            .has_fired_departure_handoff
                            .swap(true, std::sync::atomic::Ordering::SeqCst)
                    {
                        let mut current = self.current_session.write().await;
                        if let Some(session) = current.as_mut() {
                            if session.is_playing {
                                info!(
                                    "Proximity departure detected for peer {} (est: {:.2}m, is_near: {}). Auto-pausing PC media playback once.",
                                    peer_id, estimated_meters, is_near
                                );
                                session.is_playing = false;
                                let session_clone = session.clone();
                                drop(current);

                                let result = nexus_plugin_input::NativeInputInjector::inject_media_key("PAUSE");
                                if let Err(error) = result { tracing::warn!("Native media input failed: {error}"); }
                                self.send_remote_command("PAUSE".into(), None).await;

                                let handoff_msg = serde_json::json!({
                                    "type": "PROXIMITY_DEPARTURE_HANDOFF",
                                    "media_title": session_clone.media_title,
                                    "media_url": session_clone.media_url,
                                    "position_ms": session_clone.position_ms,
                                    "duration_ms": session_clone.duration_ms,
                                    "source_app": session_clone.source_app,
                                    "is_playing": false,
                                });
                                if let Ok(msg_str) = serde_json::to_string(&handoff_msg) {
                                    let mut clients = self.connected_clients.write().await;
                                    clients.retain(|c| c.send(msg_str.clone()).is_ok());
                                }
                            }
                        }
                    }
                }
                NexusEvent::ProximityMotionChanged {
                    peer_id,
                    motion,
                    distance_m,
                } => {
                    if motion == nexus_types::ProximityMotion::Approaching && distance_m <= 1.5 {
                        self.has_fired_departure_handoff
                            .store(false, std::sync::atomic::Ordering::SeqCst);
                    }
                    if motion == nexus_types::ProximityMotion::MovingAway
                        && distance_m > 2.5
                        && !self
                            .has_fired_departure_handoff
                            .swap(true, std::sync::atomic::Ordering::SeqCst)
                    {
                        let mut current = self.current_session.write().await;
                        if let Some(session) = current.as_mut() {
                            if session.is_playing {
                                info!(
                                    "Proximity moving away detected for peer {} (est: {:.2}m). Auto-pausing PC media playback once.",
                                    peer_id, distance_m
                                );
                                session.is_playing = false;
                                let session_clone = session.clone();
                                drop(current);

                                let result = nexus_plugin_input::NativeInputInjector::inject_media_key("PAUSE");
                                if let Err(error) = result { tracing::warn!("Native media input failed: {error}"); }
                                self.send_remote_command("PAUSE".into(), None).await;

                                let handoff_msg = serde_json::json!({
                                    "type": "PROXIMITY_DEPARTURE_HANDOFF",
                                    "media_title": session_clone.media_title,
                                    "media_url": session_clone.media_url,
                                    "position_ms": session_clone.position_ms,
                                    "duration_ms": session_clone.duration_ms,
                                    "source_app": session_clone.source_app,
                                    "is_playing": false,
                                });
                                if let Ok(msg_str) = serde_json::to_string(&handoff_msg) {
                                    let mut clients = self.connected_clients.write().await;
                                    clients.retain(|c| c.send(msg_str.clone()).is_ok());
                                }
                            }
                        }
                    }
                }
                _ => {}
            }
        }

        Ok(())
    }
}

fn input_status(device_id: DeviceId, result: NexusResult<()>) -> String {
    match result {
        Ok(()) => serde_json::json!({"type":"INPUT_STATUS", "ok":true, "device_id":device_id.to_string()}),
        Err(error) => serde_json::json!({"type":"INPUT_STATUS", "ok":false, "device_id":device_id.to_string(), "message":error.to_string()}),
    }.to_string()
}
