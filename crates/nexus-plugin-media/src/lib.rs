use async_trait::async_trait;
use nexus_actor_system::{EventBus, NexusActor, NexusCommand, NexusEvent};
use nexus_protocol::{MediaPayload, NexusPacket, PacketPayload};
use nexus_types::{DeviceId, NexusError, NexusResult};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::info;
pub fn append_log(file_name: &str, line: &str) {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let formatted = format!("[timestamp_ms: {}] {}\n", now, line);
    let log_path = std::path::PathBuf::from("logs").join(file_name);
    if let Some(parent) = log_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&log_path) {
        use std::io::Write;
        let _ = f.write_all(formatted.as_bytes());
    }
}

/// Active Media Playback Session on the Local Node
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct ActiveMediaSession {
    pub session_id: String,
    pub source_app: String,         // e.g. "YouTube (Chrome)", "Spotify", "VLC"
    pub media_title: String,
    pub media_url: String,
    pub position_ms: u64,
    pub duration_ms: u64,
    pub is_playing: bool,
    pub last_updated_ms: u64,
}

/// Media Plugin Actor: Orchestrates Continuity, Timestamp Sync & Browser/OS Hooks
#[derive(Clone)]
pub struct MediaPluginActor {
    pub device_id: DeviceId,
    current_session: Arc<RwLock<Option<ActiveMediaSession>>>,
    connected_clients: Arc<RwLock<Vec<tokio::sync::mpsc::UnboundedSender<String>>>>,
    has_fired_departure_handoff: Arc<std::sync::atomic::AtomicBool>,
}

impl MediaPluginActor {
    pub fn new(device_id: DeviceId) -> Self {
        Self {
            device_id,
            current_session: Arc::new(RwLock::new(None)),
            connected_clients: Arc::new(RwLock::new(Vec::new())),
            has_fired_departure_handoff: Arc::new(std::sync::atomic::AtomicBool::new(false)),
        }
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
            append_log("nexus_daemon.log", &format!("[Remote Control] Sent command to browser: {}", cmd_str));
        }
    }

    /// Triggers handoff to a specific peer
    pub async fn offer_handoff_to_peer(&self, bus: &EventBus, target_peer: DeviceId) -> NexusResult<()> {
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

        info!("Media handoff accepted from peer {} at position {}ms", from_peer, start_position_ms);
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
                            use futures_util::{SinkExt, StreamExt};
                            if let Ok(ws_stream) = tokio_tungstenite::accept_async(stream).await {
                                info!("🔌 Client connected via WebSocket from {}", addr);
                                let (mut write, mut read) = ws_stream.split();
                                let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<String>();

                                {
                                    let mut clients = actor.connected_clients.write().await;
                                    clients.push(tx.clone());
                                }

                                // Send current active media playback snapshot immediately to new client
                                if let Some(session) = actor.get_current_session().await {
                                    if let Ok(sess_json) = serde_json::to_string(&session) {
                                        let _ = tx.send(sess_json);
                                    }
                                }

                                // Forward outgoing broadcast messages
                                let write_task = tokio::spawn(async move {
                                    while let Some(msg_text) = rx.recv().await {
                                        if write.send(tokio_tungstenite::tungstenite::Message::Text(msg_text)).await.is_err() {
                                            break;
                                        }
                                    }
                                });

                                while let Some(Ok(msg)) = read.next().await {
                                    if let Ok(text) = msg.into_text() {
                                        if let Ok(json_val) = serde_json::from_str::<serde_json::Value>(&text) {
                                            let msg_type = json_val["type"].as_str().unwrap_or("");

                                            if msg_type == "PING" {
                                                continue;
                                            }

                                            if msg_type == "PEER_ANNOUNCE" {
                                                let peer_name = json_val["name"].as_str().unwrap_or("Smartphone Android").to_string();
                                                let peer_id_str = json_val["id"].as_str().unwrap_or("").to_string();
                                                append_log("nexus_daemon.log", &format!("[LAN Peer Connected] {} ({}) from {}", peer_name, peer_id_str, addr));
                                                let peer_id = match uuid::Uuid::parse_str(&peer_id_str) {
                                                    Ok(u) => DeviceId::from_bytes(*u.as_bytes()),
                                                    Err(_) => DeviceId::new_random(),
                                                };
                                                bus_inner.publish(NexusEvent::PeerDiscovered(nexus_types::PeerInfo {
                                                    id: peer_id,
                                                    name: peer_name.clone(),
                                                    device_type: nexus_types::DeviceType::Mobile,
                                                    os: nexus_types::OsType::Android,
                                                    capabilities: nexus_types::CapabilityMap::new().with_capability(nexus_types::Capability::MediaHandoff),
                                                    protocol_version: 1,
                                                    public_key_fingerprint: String::new(),
                                                    screen_geometry: None,
                                                    spatial_arrangement: nexus_types::SpatialArrangement::None,
                                                }));

                                                // Broadcast peer discovery to all other connected clients (like nexus_ui desktop app)
                                                let announce_msg = serde_json::json!({
                                                    "type": "PEER_ANNOUNCE",
                                                    "name": peer_name,
                                                    "id": peer_id.to_string(),
                                                    "device_type": "Mobile",
                                                    "os": "Android",
                                                    "ip": addr.ip().to_string(),
                                                });
                                                if let Ok(announce_str) = serde_json::to_string(&announce_msg) {
                                                    let mut clients = actor.connected_clients.write().await;
                                                    clients.retain(|c| c.send(announce_str.clone()).is_ok());
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
                                                let ballistics = nexus_plugin_input::TouchpadBallistics::default();
                                                let (scaled_dx, scaled_dy) = ballistics.calculate_delta(dx as f32, dy as f32);
                                                let _ = nexus_plugin_input::NativeInputInjector::inject_mouse_move_relative(scaled_dx, scaled_dy);
                                                continue;
                                            }

                                            if msg_type == "TOUCHPAD_CLICK" {
                                                let btn_str = json_val["button"].as_str().unwrap_or("Left");
                                                let btn = if btn_str.eq_ignore_ascii_case("right") {
                                                    nexus_protocol::MouseButton::Right
                                                } else {
                                                    nexus_protocol::MouseButton::Left
                                                };
                                                let _ = nexus_plugin_input::NativeInputInjector::inject_mouse_click(btn);
                                                continue;
                                            }

                                            if msg_type == "TOUCHPAD_BUTTON" {
                                                let btn_str = json_val["button"].as_str().unwrap_or("Left");
                                                let is_down = json_val["is_down"].as_bool().unwrap_or(true);
                                                let btn = if btn_str.eq_ignore_ascii_case("right") {
                                                    nexus_protocol::MouseButton::Right
                                                } else if btn_str.eq_ignore_ascii_case("middle") {
                                                    nexus_protocol::MouseButton::Middle
                                                } else {
                                                    nexus_protocol::MouseButton::Left
                                                };
                                                let _ = nexus_plugin_input::NativeInputInjector::inject_mouse_button(btn, is_down);
                                                continue;
                                            }

                                             if msg_type == "TOUCHPAD_SCROLL" {
                                                let dy = json_val["dy"].as_i64().unwrap_or(0) as i32;
                                                let _ = nexus_plugin_input::NativeInputInjector::inject_mouse_wheel(dy);
                                                continue;
                                            }

                                            if msg_type == "KEYBOARD_KEY" {
                                                let key_str = json_val["key"].as_str().unwrap_or("");
                                                let is_down = json_val["is_down"].as_bool();
                                                append_log("nexus_daemon.log", &format!("[Keyboard Key] key: {}, down: {:?}", key_str, is_down));
                                                let _ = nexus_plugin_input::NativeInputInjector::inject_keyboard_key(key_str, is_down);
                                                continue;
                                            }

                                            if msg_type == "KEYBOARD_COMBO" {
                                                let keys_arr = json_val["keys"].as_array();
                                                if let Some(arr) = keys_arr {
                                                    let keys_vec: Vec<&str> = arr.iter().filter_map(|v| v.as_str()).collect();
                                                    append_log("nexus_daemon.log", &format!("[Keyboard Combo] keys: {:?}", keys_vec));
                                                    let _ = nexus_plugin_input::NativeInputInjector::inject_keyboard_combo(&keys_vec);
                                                }
                                                continue;
                                            }

                                            if msg_type == "KEYBOARD_TEXT" {
                                                let text_val = json_val["text"].as_str().unwrap_or("");
                                                append_log("nexus_daemon.log", &format!("[Keyboard Unicode Text] length: {} chars", text_val.len()));
                                                let _ = nexus_plugin_input::NativeInputInjector::inject_unicode_text(text_val);
                                                continue;
                                            }

                                            if msg_type == "OPEN_URL" {
                                                let url_val = json_val["url"].as_str().unwrap_or("");
                                                let title_val = json_val["title"].as_str().unwrap_or("Video");
                                                append_log("nexus_daemon.log", &format!("[Handoff Forward] Opening URL: {} ({})", url_val, title_val));
                                                let open_msg = serde_json::json!({
                                                    "type": "OPEN_URL",
                                                    "url": url_val,
                                                    "title": title_val,
                                                    "position_ms": json_val["position_ms"].as_u64().unwrap_or(0),
                                                });
                                                if let Ok(msg_str) = serde_json::to_string(&open_msg) {
                                                    let mut clients = actor.connected_clients.write().await;
                                                    clients.retain(|c| c.send(msg_str.clone()).is_ok());
                                                }
                                                continue;
                                            }

                                            if msg_type == "CLIPBOARD_SYNC" {
                                                let text = json_val["text"].as_str().unwrap_or("");
                                                append_log("nexus_daemon.log", &format!("[Clipboard Synced] Content length: {} chars", text.len()));
                                                let clip_msg = serde_json::json!({
                                                    "type": "CLIPBOARD_SYNC",
                                                    "text": text,
                                                });
                                                if let Ok(msg_str) = serde_json::to_string(&clip_msg) {
                                                    let mut clients = actor.connected_clients.write().await;
                                                    clients.retain(|c| c.send(msg_str.clone()).is_ok());
                                                }
                                                continue;
                                            }

                                            if msg_type == "CLIPBOARD_SECRET_ANNOUNCE" || msg_type == "CLIPBOARD_REVEAL_REQUEST" || msg_type == "CLIPBOARD_REVEAL_RESPONSE"
                                                || msg_type == "NOTIFICATION_SYNC" || msg_type == "NOTIFICATION_REVEAL_REQUEST" || msg_type == "NOTIFICATION_REVEAL_RESPONSE" {
                                                append_log("nexus_daemon.log", &format!("[Cross-Device Event] type: {}", msg_type));
                                                if let Ok(msg_str) = serde_json::to_string(&json_val) {
                                                    let mut clients = actor.connected_clients.write().await;
                                                    clients.retain(|c| c.send(msg_str.clone()).is_ok());
                                                }
                                                continue;
                                            }

                                            if msg_type == "FILE_OFFER" || msg_type == "FILE_ACCEPT" || msg_type == "FILE_CHUNK" || msg_type == "FILE_COMPLETE" || msg_type == "FILE_CANCEL" || msg_type == "FILE_RESUME_REQUEST" {
                                                if msg_type == "FILE_OFFER" || msg_type == "FILE_COMPLETE" {
                                                    append_log("nexus_daemon.log", &format!("[File Transfer Message] type: {}, file: {}", msg_type, json_val["file_name"].as_str().unwrap_or("unknown")));
                                                }
                                                if let Ok(msg_str) = serde_json::to_string(&json_val) {
                                                    let mut clients = actor.connected_clients.write().await;
                                                    clients.retain(|c| c.send(msg_str.clone()).is_ok());
                                                }
                                                continue;
                                            }

                                            if msg_type == "PEER_METADATA" || msg_type == "SPATIAL_ARRANGEMENT" || msg_type == "PROXIMITY_UPDATE" {
                                                if let Ok(msg_str) = serde_json::to_string(&json_val) {
                                                    let mut clients = actor.connected_clients.write().await;
                                                    clients.retain(|c| c.send(msg_str.clone()).is_ok());
                                                }
                                                continue;
                                            }

                                            if msg_type == "UNIVERSAL_CONTROL_HOP" {
                                                let entry_x = json_val["entry_x"].as_i64().unwrap_or(100) as i32;
                                                let entry_y = json_val["entry_y"].as_i64().unwrap_or(100) as i32;
                                                let sw = json_val["screen_width"].as_i64().unwrap_or(1920) as i32;
                                                let sh = json_val["screen_height"].as_i64().unwrap_or(1080) as i32;
                                                let _ = nexus_plugin_input::NativeInputInjector::inject_mouse_move_absolute(entry_x, entry_y, sw, sh);
                                                continue;
                                            }

                                            if msg_type == "UNIVERSAL_CONTROL_DELTA" {
                                                let dx = json_val["dx"].as_i64().unwrap_or(0) as i32;
                                                let dy = json_val["dy"].as_i64().unwrap_or(0) as i32;
                                                let _ = nexus_plugin_input::NativeInputInjector::inject_mouse_move_relative(dx, dy);
                                                continue;
                                            }

                                            if msg_type == "PROXIMITY_TRIGGER" {
                                                let action = json_val["action"].as_str().unwrap_or("");
                                                if action == "LOCK_WORKSTATION" {
                                                    nexus_plugin_proximity::lock_workstation();
                                                } else if action == "PAUSE_ON_WALK_AWAY" || action == "PAUSE" {
                                                    let mut current = actor.current_session.write().await;
                                                    if let Some(session) = current.as_mut() {
                                                        session.is_playing = false;
                                                    }
                                                    drop(current);
                                                    let _ = nexus_plugin_input::NativeInputInjector::inject_media_key("PAUSE");
                                                    actor.send_remote_command("PAUSE".into(), None).await;
                                                }
                                                continue;
                                            }

                                            if msg_type == "VOLUME_UPDATE" {
                                                let vol = json_val["volume"].as_f64().unwrap_or(0.8) as f32;
                                                bus_inner.publish(NexusEvent::AudioVolumeChanged(vol));
                                                let vol_msg = serde_json::json!({
                                                    "type": "VOLUME_UPDATE",
                                                    "volume": vol,
                                                });
                                                if let Ok(msg_str) = serde_json::to_string(&vol_msg) {
                                                    let mut clients = actor.connected_clients.write().await;
                                                    clients.retain(|c| c.send(msg_str.clone()).is_ok());
                                                }
                                                continue;
                                            }

                                            if msg_type == "AUDIO_MUTE" {
                                                let muted = json_val["muted"].as_bool().unwrap_or(true);
                                                bus_inner.publish(NexusEvent::AudioMuteToggled(muted));
                                                let mute_msg = serde_json::json!({
                                                    "type": "AUDIO_MUTE",
                                                    "muted": muted,
                                                });
                                                if let Ok(msg_str) = serde_json::to_string(&mute_msg) {
                                                    let mut clients = actor.connected_clients.write().await;
                                                    clients.retain(|c| c.send(msg_str.clone()).is_ok());
                                                }
                                                continue;
                                            }

                                            // If message contains remote control action (PLAY, PAUSE, SEEK), broadcast to all clients
                                            if let Some(action) = json_val["action"].as_str() {
                                                let pos = json_val["position_ms"].as_u64();
                                                append_log("nexus_daemon.log", &format!("[Remote Command Ingest] Action: {} | Pos: {:?}", action, pos));
                                                let cmd = serde_json::json!({
                                                    "action": action,
                                                    "position_ms": pos,
                                                });
                                                if let Ok(cmd_str) = serde_json::to_string(&cmd) {
                                                    let mut clients = actor.connected_clients.write().await;
                                                    clients.retain(|client_tx| client_tx.send(cmd_str.clone()).is_ok());
                                                }
                                                // Also inject Windows Media Key so system media players pause immediately
                                                let _ = nexus_plugin_input::NativeInputInjector::inject_media_key(action);
                                                continue;
                                            }

                                            let source_app = json_val["source_app"].as_str().unwrap_or("Browser").to_string();
                                            let media_title = json_val["media_title"].as_str().unwrap_or("").to_string();
                                            let media_url = json_val["media_url"].as_str().unwrap_or("").to_string();
                                            let position_ms = json_val["position_ms"].as_u64().unwrap_or(0);
                                            let duration_ms = json_val["duration_ms"].as_u64().unwrap_or(0);
                                            let is_playing = json_val["is_playing"].as_bool().unwrap_or(true);

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
                                                actor.update_local_playback(
                                                    &bus_inner,
                                                    source_app,
                                                    media_title,
                                                    media_url,
                                                    position_ms,
                                                    duration_ms,
                                                    is_playing,
                                                ).await;
                                            }
                                        }
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
                        use futures_util::{SinkExt, StreamExt};
                        loop {
                            if let Ok((ws_stream, _)) = tokio_tungstenite::connect_async("ws://127.0.0.1:28471/media").await {
                                let (mut write, mut read) = ws_stream.split();
                                let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<String>();
                                {
                                    let mut clients = actor.connected_clients.write().await;
                                    clients.push(tx);
                                }

                                let write_task = tokio::spawn(async move {
                                    while let Some(msg_text) = rx.recv().await {
                                        if write.send(tokio_tungstenite::tungstenite::Message::Text(msg_text)).await.is_err() {
                                            break;
                                        }
                                    }
                                });

                                while let Some(Ok(msg)) = read.next().await {
                                    if let Ok(text) = msg.into_text() {
                                        if let Ok(json_val) = serde_json::from_str::<serde_json::Value>(&text) {
                                            if json_val["type"] == "PEER_ANNOUNCE" {
                                                let peer_name = json_val["name"].as_str().unwrap_or("Dispositivo Mobile").to_string();
                                                let peer_id_str = json_val["id"].as_str().unwrap_or("").to_string();
                                                let peer_id = match uuid::Uuid::parse_str(&peer_id_str) {
                                                    Ok(u) => DeviceId::from_bytes(*u.as_bytes()),
                                                    Err(_) => DeviceId::new_random(),
                                                };
                                                bus_sub.publish(NexusEvent::PeerDiscovered(nexus_types::PeerInfo {
                                                    id: peer_id,
                                                    name: peer_name,
                                                    device_type: nexus_types::DeviceType::Mobile,
                                                    os: nexus_types::OsType::Android,
                                                    capabilities: nexus_types::CapabilityMap::new().with_capability(nexus_types::Capability::MediaHandoff),
                                                    protocol_version: 1,
                                                    public_key_fingerprint: String::new(),
                                                    screen_geometry: None,
                                                    spatial_arrangement: nexus_types::SpatialArrangement::None,
                                                }));
                                                continue;
                                            }

                                            if let Ok(session) = serde_json::from_value::<ActiveMediaSession>(json_val) {
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
                    info!("Remote peer {} accepted handoff of session {}", from_peer, session_id);
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
                NexusEvent::ProximityChanged { peer_id, estimated_meters, is_near } => {
                    if is_near && estimated_meters <= 1.5 {
                        self.has_fired_departure_handoff.store(false, std::sync::atomic::Ordering::SeqCst);
                    }
                    if (!is_near || estimated_meters > 3.0) && !self.has_fired_departure_handoff.swap(true, std::sync::atomic::Ordering::SeqCst) {
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

                                let _ = nexus_plugin_input::NativeInputInjector::inject_media_key("PAUSE");
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
                NexusEvent::ProximityMotionChanged { peer_id, motion, distance_m } => {
                    if motion == nexus_types::ProximityMotion::Approaching && distance_m <= 1.5 {
                        self.has_fired_departure_handoff.store(false, std::sync::atomic::Ordering::SeqCst);
                    }
                    if motion == nexus_types::ProximityMotion::MovingAway && distance_m > 2.5 && !self.has_fired_departure_handoff.swap(true, std::sync::atomic::Ordering::SeqCst) {
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

                                let _ = nexus_plugin_input::NativeInputInjector::inject_media_key("PAUSE");
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

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_media_playback_update_and_handoff_cycle() {
        let (bus, mut cmd_rx) = EventBus::new(100, 100);

        let pc_id = DeviceId::new_random();
        let phone_id = DeviceId::new_random();

        let pc_media_actor = MediaPluginActor::new(pc_id);
        let phone_media_actor = MediaPluginActor::new(phone_id);

        // 1. PC starts playing YouTube at 14:22 (862,000 ms)
        pc_media_actor
            .update_local_playback(
                &bus,
                "YouTube (Chrome)".into(),
                "Rust Concurrency in Depth".into(),
                "https://youtube.com/watch?v=rust101".into(),
                862_000,
                1_800_000,
                true,
            )
            .await;

        let session = pc_media_actor.get_current_session().await.unwrap();
        assert_eq!(session.position_ms, 862_000);
        assert!(session.is_playing);

        // 2. User walks away -> PC offers handoff to Phone
        pc_media_actor
            .offer_handoff_to_peer(&bus, phone_id)
            .await
            .unwrap();

        // Check that command was sent
        let cmd = cmd_rx.recv().await.expect("No command received on bus");
        match cmd {
            NexusCommand::SendPacket { target, packet } => {
                assert_eq!(target, phone_id);
                if let PacketPayload::Media(MediaPayload::OfferHandoff {
                    position_ms,
                    media_title,
                    session_id,
                    ..
                }) = packet.payload
                {
                    assert_eq!(position_ms, 862_000);
                    assert_eq!(media_title, "Rust Concurrency in Depth");

                    // 3. Phone accepts handoff
                    phone_media_actor
                        .accept_handoff(&bus, pc_id, session_id.clone(), position_ms)
                        .await
                        .unwrap();

                    // 4. PC pauses local playback upon acceptance
                    pc_media_actor
                        .on_handoff_accepted_by_remote(&session_id)
                        .await
                        .unwrap();
                } else {
                    panic!("Unexpected payload");
                }
            }
            _ => panic!("Unexpected command"),
        }

        // Verify PC state is now paused
        let updated_session = pc_media_actor.get_current_session().await.unwrap();
        assert!(!updated_session.is_playing);
    }

    #[tokio::test]
    async fn test_cannot_offer_handoff_without_active_session() {
        let (bus, _rx) = EventBus::new(10, 10);
        let pc_id = DeviceId::new_random();
        let phone_id = DeviceId::new_random();

        let actor = MediaPluginActor::new(pc_id);

        // Attempting to offer handoff when no video session is initialized must return an Err
        let result = actor.offer_handoff_to_peer(&bus, phone_id).await;
        assert!(result.is_err(), "Offering handoff without active media must fail");
    }

    #[tokio::test]
    async fn test_unmatched_session_id_rejection() {
        let (bus, _rx) = EventBus::new(10, 10);
        let pc_id = DeviceId::new_random();
        let actor = MediaPluginActor::new(pc_id);

        actor
            .update_local_playback(
                &bus,
                "VLC".into(),
                "Movie.mp4".into(),
                "file:///movie.mp4".into(),
                12000,
                120000,
                true,
            )
            .await;

        // Remote node sends acceptance for a bogus / foreign session ID
        actor.on_handoff_accepted_by_remote("foreign-session-uuid-999").await.unwrap();

        // Current session must remain unchanged and still playing
        let session = actor.get_current_session().await.unwrap();
        assert!(session.is_playing, "Unmatched session ID must not pause active media");
    }

    #[tokio::test]
    async fn test_websocket_media_update_and_state_query() {
        use futures_util::{SinkExt, StreamExt};
        let (bus, _rx) = EventBus::new(10, 10);
        let pc_id = DeviceId::new_random();
        let actor = MediaPluginActor::new(pc_id);

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let actor_clone = actor.clone();
        let bus_clone = bus.clone();

        tokio::spawn(async move {
            if let Ok((stream, _)) = listener.accept().await {
                if let Ok(mut ws_stream) = tokio_tungstenite::accept_async(stream).await {
                    if let Some(Ok(msg)) = ws_stream.next().await {
                        if let Ok(text) = msg.into_text() {
                            if let Ok(json_val) = serde_json::from_str::<serde_json::Value>(&text) {
                                actor_clone.update_local_playback(
                                    &bus_clone,
                                    json_val["source_app"].as_str().unwrap().to_string(),
                                    json_val["media_title"].as_str().unwrap().to_string(),
                                    json_val["media_url"].as_str().unwrap().to_string(),
                                    json_val["position_ms"].as_u64().unwrap(),
                                    json_val["duration_ms"].as_u64().unwrap(),
                                    json_val["is_playing"].as_bool().unwrap(),
                                ).await;
                            }
                        }
                    }
                }
            }
        });

        // Connect client and send YouTube update
        let ws_url = format!("ws://127.0.0.1:{}/media", port);
        let (mut client_ws, _) = tokio_tungstenite::connect_async(&ws_url).await.unwrap();
        let update_json = serde_json::json!({
            "type": "NEXUS_MEDIA_STATE_UPDATE",
            "source_app": "YouTube (Chrome)",
            "media_title": "Interstellar - Main Theme (Official)",
            "media_url": "https://www.youtube.com/watch?v=UDVtMYqUAyw",
            "position_ms": 75000,
            "duration_ms": 300000,
            "is_playing": true
        });

        client_ws.send(tokio_tungstenite::tungstenite::Message::Text(update_json.to_string())).await.unwrap();
        tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;

        // Verify session was updated accurately in actor
        let session = actor.get_current_session().await.expect("Session must be present");
        assert_eq!(session.media_title, "Interstellar - Main Theme (Official)");
        assert_eq!(session.media_url, "https://www.youtube.com/watch?v=UDVtMYqUAyw");
        assert_eq!(session.position_ms, 75000);
        assert_eq!(session.duration_ms, 300000);
        assert!(session.is_playing);
    }

    #[tokio::test]
    async fn test_proximity_departure_auto_pauses_media() {
        let (bus, _rx) = EventBus::new(10, 10);
        let pc_id = DeviceId::new_random();
        let actor = MediaPluginActor::new(pc_id);

        actor
            .update_local_playback(
                &bus,
                "YouTube (Chrome)".into(),
                "BBC Earth - Dynasties 4K".into(),
                "https://youtube.com/watch?v=earth".into(),
                45000,
                300000,
                true,
            )
            .await;

        let session = actor.get_current_session().await.unwrap();
        assert!(session.is_playing);

        // Spawn actor run loop in background
        let mut actor_clone = actor.clone();
        let bus_clone = bus.clone();
        let run_handle = tokio::spawn(async move {
            let _ = actor_clone.run(bus_clone).await;
        });

        // Give the spawned task a few milliseconds to initialize event subscription
        tokio::time::sleep(tokio::time::Duration::from_millis(60)).await;

        // Publish Proximity departure event (user walked away: 4.2 meters, is_near = false)
        let phone_id = DeviceId::new_random();
        bus.publish(NexusEvent::ProximityChanged {
            peer_id: phone_id,
            estimated_meters: 4.2,
            is_near: false,
        });

        tokio::time::sleep(tokio::time::Duration::from_millis(150)).await;

        // Verify that local playback is now automatically PAUSED
        let session_after = actor.get_current_session().await.unwrap();
        assert!(!session_after.is_playing, "Proximity departure MUST auto-pause local playback");

        run_handle.abort();
    }
}

