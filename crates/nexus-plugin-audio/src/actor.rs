use async_trait::async_trait;
use nexus_actor_system::{EventBus, NexusActor, NexusCommand, NexusEvent};
use nexus_protocol::{AudioPayload, NexusPacket, PacketPayload};
use nexus_types::{DeviceId, NexusResult};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::{debug, info};

use crate::capture::generate_wav_header;
#[cfg(not(target_os = "windows"))]
use crate::constants::SAMPLES_PER_10MS;
use crate::volume::{set_windows_master_volume, toggle_pc_speakers_mute};
use crate::web::get_player_html;

/// Audio Relay Plugin Actor
#[derive(Clone)]
pub struct AudioPluginActor {
    pub device_id: DeviceId,
    pub is_streaming: Arc<AtomicBool>,
    pub master_volume: Arc<RwLock<f32>>,
    pub is_muted: Arc<AtomicBool>,
    pub target_peer: Arc<RwLock<Option<DeviceId>>>,
    pub http_clients: Arc<RwLock<Vec<tokio::sync::mpsc::UnboundedSender<Vec<u8>>>>>,
    pub ws_clients: Arc<RwLock<Vec<tokio::sync::mpsc::UnboundedSender<Vec<u8>>>>>,
}

impl AudioPluginActor {
    pub fn new(device_id: DeviceId) -> Self {
        Self {
            device_id,
            is_streaming: Arc::new(AtomicBool::new(true)),
            master_volume: Arc::new(RwLock::new(0.85)),
            is_muted: Arc::new(AtomicBool::new(false)),
            target_peer: Arc::new(RwLock::new(None)),
            http_clients: Arc::new(RwLock::new(Vec::new())),
            ws_clients: Arc::new(RwLock::new(Vec::new())),
        }
    }

    /// Starts streaming local system audio (PC -> Smartphone Private Listening)
    pub async fn start_streaming_to_peer(&self, bus: &EventBus, peer_id: DeviceId) -> NexusResult<()> {
        self.is_streaming.store(true, Ordering::SeqCst);
        {
            let mut target = self.target_peer.write().await;
            *target = Some(peer_id);
        }

        info!("Audio Relay: Started streaming system audio to peer {}", peer_id);
        bus.publish(NexusEvent::AudioStreamingActive(true));

        let control_payload = PacketPayload::Audio(AudioPayload::StreamControl {
            is_streaming: true,
            master_volume: *self.master_volume.read().await,
        });

        let packet = NexusPacket::new(self.device_id, control_payload).with_target(peer_id);
        bus.send_command(NexusCommand::SendPacket {
            target: peer_id,
            packet,
        })
        .await?;

        Ok(())
    }

    /// Stops the audio stream
    pub async fn stop_streaming(&self, bus: &EventBus) -> NexusResult<()> {
        let was_streaming = self.is_streaming.swap(false, Ordering::SeqCst);
        if was_streaming {
            let target = *self.target_peer.read().await;
            if let Some(peer_id) = target {
                let control_payload = PacketPayload::Audio(AudioPayload::StreamControl {
                    is_streaming: false,
                    master_volume: *self.master_volume.read().await,
                });

                let packet = NexusPacket::new(self.device_id, control_payload).with_target(peer_id);
                let _ = bus
                    .send_command(NexusCommand::SendPacket {
                        target: peer_id,
                        packet,
                    })
                    .await;
            }
            bus.publish(NexusEvent::AudioStreamingActive(false));
            info!("Audio Relay: Stopped streaming system audio");
        }
        Ok(())
    }

    /// Sets the master volume (0.0 to 1.0)
    pub async fn set_volume(&self, volume: f32) {
        let clamped = volume.clamp(0.0, 1.0);
        let mut vol = self.master_volume.write().await;
        *vol = clamped;
        if clamped > 0.0 {
            self.is_muted.store(false, Ordering::Relaxed);
        }
        debug!("Audio master volume set to: {:.2}", clamped);

        // Update real OS master volume on Windows and Linux
        #[cfg(any(target_os = "windows", target_os = "linux"))]
        {
            set_windows_master_volume(clamped);
        }
    }

    pub fn toggle_mute(&self) -> bool {
        let prev = self.is_muted.fetch_xor(true, Ordering::SeqCst);
        !prev
    }

    pub fn set_mute(&self, muted: bool) {
        self.is_muted.store(muted, Ordering::SeqCst);
    }
}

#[async_trait]
impl NexusActor for AudioPluginActor {
    fn name(&self) -> &'static str {
        "nexus-plugin-audio"
    }

    async fn run(&mut self, bus: EventBus) -> NexusResult<()> {
        let mut event_sub = bus.subscribe();
        let is_streaming_clone = self.is_streaming.clone();
        let http_clients_clone = self.http_clients.clone();
        let ws_clients_clone = self.ws_clients.clone();

        // 1. Real System Audio Capture via WASAPI Loopback (Windows) or Fallback
        #[cfg(target_os = "windows")]
        {
            let is_streaming = is_streaming_clone.clone();
            let master_volume = self.master_volume.clone();
            let is_muted = self.is_muted.clone();
            let http_clients = http_clients_clone.clone();
            let ws_clients = ws_clients_clone.clone();

            std::thread::spawn(move || {
                let _ = wasapi::initialize_mta();
                while is_streaming.load(Ordering::Relaxed) {
                    let res: Result<(), Box<dyn std::error::Error>> = (|| {
                        let device = wasapi::get_default_device(&wasapi::Direction::Render)?;
                        let mut audio_client = device.get_iaudioclient()?;
                        let format = audio_client.get_mixformat()?;

                        let stream_mode = wasapi::StreamMode::PollingShared {
                            autoconvert: true,
                            buffer_duration_hns: 0,
                        };

                        audio_client.initialize_client(
                            &format,
                            &wasapi::Direction::Capture,
                            &stream_mode,
                        )?;

                        let capture_client = audio_client.get_audiocaptureclient()?;
                        audio_client.start_stream()?;
                        info!("🔊 Real Windows WASAPI Loopback Capture active! Streaming live PC audio to mobile.");

                        let bit_depth = format.get_bitspersample();
                        let mut chunk_raw = vec![0u8; 48000 * 8];

                        while is_streaming.load(Ordering::Relaxed) {
                            let _nbr_frames = match capture_client.get_next_packet_size()? {
                                Some(n) if n > 0 => n,
                                _ => {
                                    std::thread::sleep(std::time::Duration::from_millis(3));
                                    continue;
                                }
                            };

                            let (frames_read, _flags) = capture_client.read_from_device(&mut chunk_raw)?;
                            if frames_read == 0 {
                                continue;
                            }

                            let vol = if is_muted.load(Ordering::Relaxed) {
                                0.0
                            } else {
                                futures::executor::block_on(async { *master_volume.read().await })
                            };
                            let bytes_read = frames_read as usize * (format.get_blockalign() as usize);
                            let valid_slice = &chunk_raw[..bytes_read.min(chunk_raw.len())];

                            // Convert to standard 16-bit 48kHz Stereo PCM
                            let mut pcm_bytes = Vec::with_capacity(bytes_read);
                            if bit_depth == 32 {
                                // 32-bit Float PCM
                                for float_bytes in valid_slice.chunks_exact(4) {
                                    let sample_f32 = f32::from_le_bytes([
                                        float_bytes[0],
                                        float_bytes[1],
                                        float_bytes[2],
                                        float_bytes[3],
                                    ]);
                                    let s = (sample_f32 * vol).clamp(-1.0, 1.0);
                                    let sample_i16 = (s * 32767.0).round() as i16;
                                    pcm_bytes.extend_from_slice(&sample_i16.to_le_bytes());
                                }
                            } else {
                                // 16-bit Int PCM
                                for int_bytes in valid_slice.chunks_exact(2) {
                                    let sample_i16 = i16::from_le_bytes([int_bytes[0], int_bytes[1]]);
                                    let s = ((sample_i16 as f32) * vol)
                                        .clamp(-32768.0, 32767.0)
                                        .round() as i16;
                                    pcm_bytes.extend_from_slice(&s.to_le_bytes());
                                }
                            }

                            if !pcm_bytes.is_empty() {
                                // Broadcast to active WebSocket clients (Ultra-low latency ~12ms)
                                {
                                    let mut ws = futures::executor::block_on(async {
                                        ws_clients.write().await
                                    });
                                    ws.retain(|client_tx| client_tx.send(pcm_bytes.clone()).is_ok());
                                }

                                // Broadcast to active HTTP streaming clients
                                {
                                    let mut http = futures::executor::block_on(async {
                                        http_clients.write().await
                                    });
                                    http.retain(|client_tx| client_tx.send(pcm_bytes.clone()).is_ok());
                                }
                            }
                        }
                        let _ = audio_client.stop_stream();
                        Ok(())
                    })();

                    if let Err(e) = res {
                        tracing::warn!("WASAPI Loopback Capture retry in 1s: {:?}", e);
                        std::thread::sleep(std::time::Duration::from_millis(1000));
                    }
                }
            });
        }

        #[cfg(target_os = "linux")]
        {
            let is_streaming = is_streaming_clone.clone();
            let http_clients = http_clients_clone.clone();
            let ws_clients = ws_clients_clone.clone();

            std::thread::spawn(move || {
                use std::io::Read;
                use std::process::{Command, Stdio};

                while is_streaming.load(Ordering::Relaxed) {
                    let child = Command::new("pw-record")
                        .args(["--format", "s16", "--rate", "48000", "--channels", "2", "-"])
                        .stdout(Stdio::piped())
                        .stderr(Stdio::null())
                        .spawn()
                        .or_else(|_| {
                            Command::new("parec")
                                .args(["--format=s16le", "--rate=48000", "--channels=2", "-d", "@DEFAULT_MONITOR@"])
                                .stdout(Stdio::piped())
                                .stderr(Stdio::null())
                                .spawn()
                        });

                    if let Ok(mut proc) = child {
                        if let Some(mut stdout) = proc.stdout.take() {
                            let mut buf = vec![0u8; SAMPLES_PER_10MS * 4];
                            while is_streaming.load(Ordering::Relaxed) {
                                match stdout.read_exact(&mut buf) {
                                    Ok(_) => {
                                        let pcm_bytes = buf.clone();
                                        futures::executor::block_on(async {
                                            let mut http = http_clients.write().await;
                                            http.retain(|client_tx| client_tx.send(pcm_bytes.clone()).is_ok());
                                            let mut ws = ws_clients.write().await;
                                            ws.retain(|client_tx| client_tx.send(pcm_bytes.clone()).is_ok());
                                        });
                                    }
                                    Err(_) => break,
                                }
                            }
                        }
                        let _ = proc.kill();
                    } else {
                        std::thread::sleep(std::time::Duration::from_millis(500));
                    }
                }
            });
        }

        #[cfg(all(not(target_os = "windows"), not(target_os = "linux")))]
        {
            // Other platforms without active audio capture loopback backend
        }

        // 2. Spawn Mobile Web Audio Relay Server on 0.0.0.0:28472
        let http_clients_srv = self.http_clients.clone();
        let ws_clients_srv = self.ws_clients.clone();
        let master_vol_srv = self.master_volume.clone();
        let is_muted_srv = self.is_muted.clone();
        let bus_srv = bus.clone();

        tokio::spawn(async move {
            if let Ok(listener) = tokio::net::TcpListener::bind("0.0.0.0:28472").await {
                info!("🎧 Private Listening Audio Web Server listening on http://0.0.0.0:28472");
                while let Ok((mut stream, _addr)) = listener.accept().await {
                    let http_clients = http_clients_srv.clone();
                    let ws_clients = ws_clients_srv.clone();
                    let master_vol = master_vol_srv.clone();
                    let is_muted = is_muted_srv.clone();
                    let bus_conn = bus_srv.clone();

                    tokio::spawn(async move {
                        use tokio::io::{AsyncReadExt, AsyncWriteExt};
                        let mut buf = [0u8; 2048];
                        let n = match stream.read(&mut buf).await {
                            Ok(n) if n > 0 => n,
                            _ => return,
                        };

                        let req = String::from_utf8_lossy(&buf[..n]).to_string();

                        // A. Ultra-Low-Latency WebSocket Upgrade (ws://<ip>:28472/)
                        if req.to_lowercase().contains("upgrade: websocket") {
                            if let Some(key_idx) = req.to_lowercase().find("sec-websocket-key:") {
                                let key_line = &req[key_idx..];
                                if let Some(end_idx) = key_line.find("\r\n") {
                                    let key = key_line["sec-websocket-key:".len()..end_idx].trim();
                                    let mut sha = sha1::Sha1::new();
                                    use sha1::Digest;
                                    sha.update(key.as_bytes());
                                    sha.update(b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
                                    let hash = sha.finalize();
                                    use base64::Engine;
                                    let accept_key =
                                        base64::engine::general_purpose::STANDARD.encode(hash);

                                    let ws_handshake = format!(
                                        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {}\r\n\r\n",
                                        accept_key
                                    );
                                    if stream.write_all(ws_handshake.as_bytes()).await.is_ok() {
                                        let (tx, mut rx) =
                                            tokio::sync::mpsc::unbounded_channel::<Vec<u8>>();
                                        {
                                            let mut clients = ws_clients.write().await;
                                            clients.push(tx);
                                        }

                                        while let Some(pcm_data) = rx.recv().await {
                                            // Send binary WebSocket frame (opcode 0x82)
                                            let mut frame = Vec::with_capacity(pcm_data.len() + 10);
                                            frame.push(0x82); // FIN + Binary Frame
                                            let len = pcm_data.len();
                                            if len <= 125 {
                                                frame.push(len as u8);
                                            } else if len <= 65535 {
                                                frame.push(126);
                                                frame.extend_from_slice(&(len as u16).to_be_bytes());
                                            } else {
                                                frame.push(127);
                                                frame.extend_from_slice(&(len as u64).to_be_bytes());
                                            }
                                            frame.extend_from_slice(&pcm_data);

                                            if stream.write_all(&frame).await.is_err() {
                                                break;
                                            }
                                        }
                                        return;
                                    }
                                }
                            }
                        }

                        // B. Endpoint: Continuous WAV Audio Stream (/stream.wav or /audio)
                        if req.starts_with("GET /stream.wav") || req.starts_with("GET /audio") {
                            let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<Vec<u8>>();
                            {
                                let mut clients = http_clients.write().await;
                                clients.push(tx);
                            }

                            let wav_header = generate_wav_header();
                            let http_header = "HTTP/1.1 200 OK\r\nContent-Type: audio/x-wav\r\nCache-Control: no-cache\r\nPragma: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n\r\n";

                            if stream.write_all(http_header.as_bytes()).await.is_ok()
                                && stream.write_all(&wav_header).await.is_ok()
                            {
                                while let Some(pcm_chunk) = rx.recv().await {
                                    if stream.write_all(&pcm_chunk).await.is_err() {
                                        break;
                                    }
                                }
                            }
                            return;
                        }

                        // B.1. Endpoint: GET /api/volume?v=...
                        if req.starts_with("GET /api/volume") {
                            #[cfg_attr(not(target_os = "windows"), allow(unused_mut))]
                            let mut current_vol = *master_vol.read().await;
                            if let Some(idx) = req.find("?v=") {
                                let val_str = &req[idx + 3..];
                                let end_idx = val_str
                                    .find(|c: char| !c.is_numeric() && c != '.')
                                    .unwrap_or(val_str.len());
                                if let Ok(v) = val_str[..end_idx].parse::<f32>() {
                                    let clamped = v.clamp(0.0, 1.0);
                                    *master_vol.write().await = clamped;
                                    if clamped > 0.0 {
                                        is_muted.store(false, Ordering::Relaxed);
                                    }
                                    current_vol = clamped;
                                    bus_conn.publish(NexusEvent::AudioVolumeChanged(clamped));
                                }
                            }
                            let body = format!(
                                r#"{{"volume":{:.2},"muted":{}}}"#,
                                current_vol,
                                is_muted.load(Ordering::Relaxed)
                            );
                            let res = format!(
                                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                                body.len(),
                                body
                            );
                            let _ = stream.write_all(res.as_bytes()).await;
                            return;
                        }

                        // B.2. Endpoint: GET /api/mute
                        if req.starts_with("GET /api/mute") {
                            let prev = is_muted.fetch_xor(true, Ordering::SeqCst);
                            let new_muted = !prev;
                            bus_conn.publish(NexusEvent::AudioMuteToggled(new_muted));
                            let body = format!(r#"{{"muted":{}}}"#, new_muted);
                            let res = format!(
                                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                                body.len(),
                                body
                            );
                            let _ = stream.write_all(res.as_bytes()).await;
                            return;
                        }

                        // B.3. Endpoint: GET /api/pc_mute
                        if req.starts_with("GET /api/pc_mute") {
                            toggle_pc_speakers_mute();
                            let body = r#"{"status":"ok","action":"MUTE_PC_SPEAKERS"}"#;
                            let res = format!(
                                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                                body.len(),
                                body
                            );
                            let _ = stream.write_all(res.as_bytes()).await;
                            return;
                        }

                        // C. Endpoint: Interactive Dual-Mode Web Audio Player (/)
                        let vol = *master_vol.read().await;
                        let html = get_player_html(vol);

                        let response = format!(
                            "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=UTF-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                            html.len(),
                            html
                        );
                        let _ = stream.write_all(response.as_bytes()).await;
                        let _ = stream.flush().await;
                    });
                }
            } else {
                tracing::warn!("Audio Relay port 28472 already in use");
            }
        });

        while let Ok(event) = event_sub.recv().await {
            match event {
                NexusEvent::PeerDisconnected(peer_id) => {
                    let current_target = *self.target_peer.read().await;
                    if current_target == Some(peer_id) {
                        info!("Target peer {} disconnected, stopping audio relay", peer_id);
                        let _ = self.stop_streaming(&bus).await;
                    }
                }
                NexusEvent::AudioVolumeChanged(vol) => {
                    self.set_volume(vol).await;
                }
                NexusEvent::AudioMuteToggled(muted) => {
                    self.set_mute(muted);
                }
                _ => {}
            }
        }

        Ok(())
    }
}
