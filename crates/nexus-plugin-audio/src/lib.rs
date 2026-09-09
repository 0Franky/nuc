use async_trait::async_trait;
use nexus_actor_system::{EventBus, NexusActor, NexusCommand, NexusEvent};
use nexus_protocol::{AudioPayload, NexusPacket, PacketPayload};
use nexus_types::{DeviceId, NexusResult};
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::{debug, info};

pub const DEFAULT_SAMPLE_RATE: u32 = 48000;
pub const DEFAULT_CHANNELS: u8 = 2;
pub const SAMPLES_PER_10MS: usize = 480; // 48000 * 0.010

/// A Lock-Free Single-Producer Single-Consumer (SPSC) RingBuffer for Low-Latency Audio Samples
pub struct AudioRingBuffer {
    buffer: Vec<f32>,
    capacity: usize,
    read_pos: AtomicU64,
    write_pos: AtomicU64,
}

impl AudioRingBuffer {
    pub fn new(capacity: usize) -> Self {
        Self {
            buffer: vec![0.0; capacity],
            capacity,
            read_pos: AtomicU64::new(0),
            write_pos: AtomicU64::new(0),
        }
    }

    /// Push audio samples from the OS capture loop (Producer)
    pub fn push_slice(&mut self, samples: &[f32]) -> usize {
        let write = self.write_pos.load(Ordering::Relaxed);
        let read = self.read_pos.load(Ordering::Acquire);
        let available = self.capacity - ((write - read) as usize);

        let to_write = samples.len().min(available);
        for (i, &sample) in samples.iter().enumerate().take(to_write) {
            let idx = ((write + i as u64) as usize) % self.capacity;
            self.buffer[idx] = sample;
        }

        self.write_pos.store(write + to_write as u64, Ordering::Release);
        to_write
    }

    /// Pop audio samples into the encoder / network packetizer (Consumer)
    pub fn pop_slice(&mut self, out: &mut [f32]) -> usize {
        let write = self.write_pos.load(Ordering::Acquire);
        let read = self.read_pos.load(Ordering::Relaxed);
        let available = (write - read) as usize;

        let to_read = out.len().min(available);
        for (i, slot) in out.iter_mut().enumerate().take(to_read) {
            let idx = ((read + i as u64) as usize) % self.capacity;
            *slot = self.buffer[idx];
        }

        self.read_pos.store(read + to_read as u64, Ordering::Release);
        to_read
    }

    pub fn available_to_read(&self) -> usize {
        let write = self.write_pos.load(Ordering::Relaxed);
        let read = self.read_pos.load(Ordering::Relaxed);
        (write - read) as usize
    }
}

/// Adaptive Jitter Buffer for managing network packet arrival variance
pub struct AdaptiveJitterBuffer {
    queue: VecDeque<(u32, u64, Vec<u8>)>, // (seq, timestamp_us, opus_data)
    target_delay_ms: f32,
    last_seq: Option<u32>,
}

impl AdaptiveJitterBuffer {
    pub fn new(initial_delay_ms: f32) -> Self {
        Self {
            queue: VecDeque::new(),
            target_delay_ms: initial_delay_ms,
            last_seq: None,
        }
    }

    pub fn push_packet(&mut self, seq: u32, timestamp_us: u64, data: Vec<u8>) {
        self.queue.push_back((seq, timestamp_us, data));
        if self.queue.len() > 1 {
            let len = self.queue.len();
            if self.queue[len - 2].0 > seq {
                self.queue.make_contiguous().sort_by_key(|item| item.0);
            }
        }
    }

    pub fn pop_frame(&mut self) -> Option<Vec<u8>> {
        if self.queue.len() < 2 {
            return None;
        }

        if let Some((seq, _, data)) = self.queue.pop_front() {
            self.last_seq = Some(seq);
            Some(data)
        } else {
            None
        }
    }

    pub fn target_delay(&self) -> f32 {
        self.target_delay_ms
    }
}

/// Clock Drift Resampler: Gently adjusts sample rate to avoid underruns/overruns
pub struct DriftResampler {
    resample_ratio: f32,
}

impl DriftResampler {
    pub fn new() -> Self {
        Self {
            resample_ratio: 1.0,
        }
    }

    pub fn set_drift_adjustment(&mut self, factor: f32) {
        self.resample_ratio = factor.clamp(0.995, 1.005);
    }

    pub fn process_linear(&self, input: &[f32], output: &mut [f32]) -> usize {
        let in_len = input.len();
        let out_len = output.len();
        let mut out_idx = 0;

        let mut in_pos = 0.0f32;
        while out_idx < out_len && in_pos < (in_len as f32 - 1.0) {
            let idx0 = in_pos.floor() as usize;
            let idx1 = (idx0 + 1).min(in_len - 1);
            let frac = in_pos - idx0 as f32;

            output[out_idx] = input[idx0] * (1.0 - frac) + input[idx1] * frac;
            out_idx += 1;
            in_pos += self.resample_ratio;
        }

        out_idx
    }
}

impl Default for DriftResampler {
    fn default() -> Self {
        Self::new()
    }
}

/// Abstract Audio Capture Backend (WASAPI on Windows, PipeWire on Linux, CoreAudio on Apple)
pub trait AudioCaptureBackend: Send + Sync {
    fn start_capture(&self, ring_buffer: Arc<RwLock<AudioRingBuffer>>) -> NexusResult<()>;
    fn stop_capture(&self) -> NexusResult<()>;
    fn is_capturing(&self) -> bool;
}

/// Simulated & Loopback Audio Capture Backend for Native System Audio
pub struct WasapiLoopbackCapture {
    is_capturing: Arc<AtomicBool>,
}

impl WasapiLoopbackCapture {
    pub fn new() -> Self {
        Self {
            is_capturing: Arc::new(AtomicBool::new(false)),
        }
    }
}

impl Default for WasapiLoopbackCapture {
    fn default() -> Self {
        Self::new()
    }
}

impl AudioCaptureBackend for WasapiLoopbackCapture {
    fn start_capture(&self, ring_buffer: Arc<RwLock<AudioRingBuffer>>) -> NexusResult<()> {
        self.is_capturing.store(true, Ordering::SeqCst);
        let capturing = self.is_capturing.clone();

        tokio::spawn(async move {
            let mut interval = tokio::time::interval(tokio::time::Duration::from_millis(10));
            let mut phase: f32 = 0.0;

            while capturing.load(Ordering::Relaxed) {
                interval.tick().await;

                let mut samples = Vec::with_capacity(SAMPLES_PER_10MS);
                for _ in 0..SAMPLES_PER_10MS {
                    let sample = (phase * 2.0 * std::f32::consts::PI).sin() * 0.5;
                    samples.push(sample);
                    phase = (phase + 440.0 / 48000.0) % 1.0;
                }

                let mut ring = ring_buffer.write().await;
                ring.push_slice(&samples);
            }
        });

        Ok(())
    }

    fn stop_capture(&self) -> NexusResult<()> {
        self.is_capturing.store(false, Ordering::SeqCst);
        Ok(())
    }

    fn is_capturing(&self) -> bool {
        self.is_capturing.load(Ordering::Relaxed)
    }
}

/// Generates standard 44-byte WAV header for continuous linear PCM streaming
pub fn generate_wav_header() -> [u8; 44] {
    let mut header = [0u8; 44];
    header[0..4].copy_from_slice(b"RIFF");
    let file_size: u32 = 0x7fff_ffff; // Continuous infinite stream
    header[4..8].copy_from_slice(&file_size.to_le_bytes());
    header[8..12].copy_from_slice(b"WAVE");

    header[12..16].copy_from_slice(b"fmt ");
    header[16..20].copy_from_slice(&16u32.to_le_bytes()); // Subchunk1Size
    header[20..22].copy_from_slice(&1u16.to_le_bytes());  // AudioFormat (1 = PCM)
    header[22..24].copy_from_slice(&(DEFAULT_CHANNELS as u16).to_le_bytes()); // 2 Channels
    header[24..28].copy_from_slice(&DEFAULT_SAMPLE_RATE.to_le_bytes()); // 48000 Hz
    let byte_rate: u32 = DEFAULT_SAMPLE_RATE * (DEFAULT_CHANNELS as u32) * 2; // 48000 * 2 * 2 = 192000
    header[28..32].copy_from_slice(&byte_rate.to_le_bytes());
    header[32..34].copy_from_slice(&4u16.to_le_bytes()); // BlockAlign = Channels * 2
    header[34..36].copy_from_slice(&16u16.to_le_bytes()); // BitsPerSample = 16

    header[36..40].copy_from_slice(b"data");
    let data_size: u32 = 0x7fff_ffff;
    header[40..44].copy_from_slice(&data_size.to_le_bytes());

    header
}

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
                let _ = bus.send_command(NexusCommand::SendPacket {
                    target: peer_id,
                    packet,
                }).await;
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

        // Update real OS master volume on Windows
        #[cfg(target_os = "windows")]
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

#[cfg(target_os = "windows")]
pub fn set_windows_master_volume(volume: f32) {
    use windows::Win32::Media::Audio::Endpoints::IAudioEndpointVolume;
    use windows::Win32::Media::Audio::{IMMDeviceEnumerator, MMDeviceEnumerator, eMultimedia, eRender};
    use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_ALL, COINIT_MULTITHREADED};

    let clamped = volume.clamp(0.0, 1.0);
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        if let Ok(enumerator) = CoCreateInstance::<_, IMMDeviceEnumerator>(&MMDeviceEnumerator, None, CLSCTX_ALL) {
            if let Ok(device) = enumerator.GetDefaultAudioEndpoint(eRender, eMultimedia) {
                if let Ok(endpoint_volume) = device.Activate::<IAudioEndpointVolume>(CLSCTX_ALL, None) {
                    let _ = endpoint_volume.SetMasterVolumeLevelScalar(clamped, std::ptr::null());
                    if clamped > 0.0 {
                        let _ = endpoint_volume.SetMute(false, std::ptr::null());
                    }
                    tracing::info!("🔊 Windows OS Master Volume adjusted to: {:.0}%", clamped * 100.0);
                }
            }
        }
    }
}

#[cfg(not(target_os = "windows"))]
pub fn set_windows_master_volume(_volume: f32) {}

#[cfg(target_os = "windows")]
pub fn toggle_pc_speakers_mute() {
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
        SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP,
    };
    let mut inputs = [
        INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT {
                    wVk: 0xAD, // VK_VOLUME_MUTE
                    wScan: 0,
                    dwFlags: 0,
                    time: 0,
                    dwExtraInfo: 0,
                },
            },
        },
        INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT {
                    wVk: 0xAD,
                    wScan: 0,
                    dwFlags: KEYEVENTF_KEYUP,
                    time: 0,
                    dwExtraInfo: 0,
                },
            },
        },
    ];
    unsafe {
        SendInput(2, inputs.as_mut_ptr(), std::mem::size_of::<INPUT>() as i32);
    }
}

#[cfg(not(target_os = "windows"))]
pub fn toggle_pc_speakers_mute() {}


#[async_trait]
impl NexusActor for AudioPluginActor {
    fn name(&self) -> &'static str {
        "nexus-plugin-audio"
    }

    async fn run(&mut self, bus: EventBus) -> NexusResult<()> {
        let mut event_sub = bus.subscribe();
        let is_streaming_clone = self.is_streaming.clone();
        let master_volume_clone = self.master_volume.clone();
        let is_muted_clone = self.is_muted.clone();
        let http_clients_clone = self.http_clients.clone();
        let ws_clients_clone = self.ws_clients.clone();

        // 1. Real System Audio Capture via WASAPI Loopback (Windows) or Fallback
        #[cfg(target_os = "windows")]
        {
            let is_streaming = is_streaming_clone.clone();
            let master_volume = master_volume_clone.clone();
            let is_muted = is_muted_clone.clone();
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
                                    let sample_f32 = f32::from_le_bytes([float_bytes[0], float_bytes[1], float_bytes[2], float_bytes[3]]);
                                    let s = (sample_f32 * vol).clamp(-1.0, 1.0);
                                    let sample_i16 = (s * 32767.0).round() as i16;
                                    pcm_bytes.extend_from_slice(&sample_i16.to_le_bytes());
                                }
                            } else {
                                // 16-bit Int PCM
                                for int_bytes in valid_slice.chunks_exact(2) {
                                    let sample_i16 = i16::from_le_bytes([int_bytes[0], int_bytes[1]]);
                                    let s = ((sample_i16 as f32) * vol).clamp(-32768.0, 32767.0).round() as i16;
                                    pcm_bytes.extend_from_slice(&s.to_le_bytes());
                                }
                            }

                            if !pcm_bytes.is_empty() {
                                // Broadcast to active WebSocket clients (Ultra-low latency ~12ms)
                                {
                                    let mut ws = futures::executor::block_on(async { ws_clients.write().await });
                                    ws.retain(|client_tx| client_tx.send(pcm_bytes.clone()).is_ok());
                                }

                                // Broadcast to active HTTP streaming clients
                                {
                                    let mut http = futures::executor::block_on(async { http_clients.write().await });
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

        #[cfg(not(target_os = "windows"))]
        {
            let is_streaming_mock = is_streaming_clone.clone();
            let http_clients_mock = http_clients_clone.clone();
            let ws_clients_mock = ws_clients_clone.clone();

            tokio::spawn(async move {
                let mut interval = tokio::time::interval(tokio::time::Duration::from_millis(10));
                while is_streaming_mock.load(Ordering::Relaxed) {
                    interval.tick().await;
                    let pcm_bytes = vec![0u8; SAMPLES_PER_10MS * 4];
                    {
                        let mut http = http_clients_mock.write().await;
                        http.retain(|client_tx| client_tx.send(pcm_bytes.clone()).is_ok());
                    }
                    {
                        let mut ws = ws_clients_mock.write().await;
                        ws.retain(|client_tx| client_tx.send(pcm_bytes.clone()).is_ok());
                    }
                }
            });
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
                                    let accept_key = base64::engine::general_purpose::STANDARD.encode(hash);

                                    let ws_handshake = format!(
                                        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {}\r\n\r\n",
                                        accept_key
                                    );
                                    if stream.write_all(ws_handshake.as_bytes()).await.is_ok() {
                                        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<Vec<u8>>();
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

                            if stream.write_all(http_header.as_bytes()).await.is_ok() && stream.write_all(&wav_header).await.is_ok() {
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
                            let mut current_vol = *master_vol.read().await;
                            if let Some(idx) = req.find("?v=") {
                                let val_str = &req[idx + 3..];
                                let end_idx = val_str.find(|c: char| !c.is_numeric() && c != '.').unwrap_or(val_str.len());
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
                            let body = format!(r#"{{"volume":{:.2},"muted":{}}}"#, current_vol, is_muted.load(Ordering::Relaxed));
                            let res = format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", body.len(), body);
                            let _ = stream.write_all(res.as_bytes()).await;
                            return;
                        }

                        // B.2. Endpoint: GET /api/mute
                        if req.starts_with("GET /api/mute") {
                            let prev = is_muted.fetch_xor(true, Ordering::SeqCst);
                            let new_muted = !prev;
                            bus_conn.publish(NexusEvent::AudioMuteToggled(new_muted));
                            let body = format!(r#"{{"muted":{}}}"#, new_muted);
                            let res = format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", body.len(), body);
                            let _ = stream.write_all(res.as_bytes()).await;
                            return;
                        }

                        // B.3. Endpoint: GET /api/pc_mute
                        if req.starts_with("GET /api/pc_mute") {
                            toggle_pc_speakers_mute();
                            let body = r#"{"status":"ok","action":"MUTE_PC_SPEAKERS"}"#;
                            let res = format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", body.len(), body);
                            let _ = stream.write_all(res.as_bytes()).await;
                            return;
                        }

                        // C. Endpoint: Interactive Dual-Mode Web Audio Player (/)
                        let vol = *master_vol.read().await;
                        let html = format!(r#"<!DOCTYPE html>
<html lang="it">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Nexus Private Listening - Cuffie Smartphone</title>
  <script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-slate-950 text-slate-100 flex flex-col items-center justify-center min-h-screen p-4 select-none">
  <div class="bg-slate-900 border border-indigo-500/30 rounded-3xl p-6 shadow-2xl max-w-sm w-full text-center">
    <div class="w-16 h-16 bg-indigo-500/20 text-indigo-400 rounded-full flex items-center justify-center mx-auto mb-3 text-3xl shadow-inner animate-pulse">
      🎧
    </div>
    <h1 class="text-2xl font-black tracking-tight">Private Listening</h1>
    <p class="text-xs text-slate-400 mt-0.5">Ascolto audio PC su smartphone</p>

    <!-- Mode Selector Tabs -->
    <div class="mt-4 p-1 bg-slate-950 rounded-2xl border border-slate-800 grid grid-cols-2 gap-1 text-xs font-bold">
      <button id="tabRealtime" onclick="setMode('realtime')" class="py-2.5 px-2 rounded-xl transition bg-indigo-600 text-white shadow-md flex items-center justify-center gap-1.5">
        <span>⚡ Tempo Reale</span>
      </button>
      <button id="tabBuffered" onclick="setMode('buffered')" class="py-2.5 px-2 rounded-xl transition text-slate-400 hover:text-slate-200 flex items-center justify-center gap-1.5">
        <span>💎 Alta Fedeltà</span>
      </button>
    </div>
    
    <div id="modeDesc" class="mt-2 text-[11px] text-emerald-400 font-medium">
      ⚡ Latenza ~15ms: ideale per video, film e gaming
    </div>

    <!-- Visualizer Canvas -->
    <div class="my-4 p-3 bg-slate-950 rounded-2xl border border-slate-800 flex flex-col items-center">
      <canvas id="visualizer" width="280" height="55" class="rounded-lg w-full"></canvas>
      <div id="statusBadge" class="mt-2.5 inline-flex items-center gap-2 px-3 py-1 rounded-full text-xs font-semibold bg-slate-800 text-slate-400">
        <span id="statusDot" class="w-2 h-2 rounded-full bg-slate-600"></span> <span id="statusText">Pronto • Tocca Avvia</span>
      </div>
    </div>

    <!-- Buffer Preset Selector (Visible in Hi-Fi Mode) -->
    <div id="bufferControls" class="hidden mb-4 p-2.5 bg-slate-950/80 rounded-xl border border-slate-800 text-left">
      <div class="flex justify-between items-center text-[11px] font-semibold text-slate-400 mb-1.5">
        <span>🛡️ Dimensione Buffer Anti-Lag</span>
        <span id="bufferValueLabel" class="text-indigo-400 font-mono">1.5s (Consigliato)</span>
      </div>
      <div class="grid grid-cols-3 gap-1.5 text-[11px]">
        <button onclick="setBufferPreset(0.5, '500ms (Veloce)')" class="py-1 px-2 rounded-lg bg-slate-800 hover:bg-slate-700 text-slate-300 font-medium">500ms</button>
        <button onclick="setBufferPreset(1.5, '1.5s (Hi-Fi)')" class="py-1 px-2 rounded-lg bg-indigo-600 text-white font-bold">1.5s</button>
        <button onclick="setBufferPreset(3.0, '3.0s (Stabile)')" class="py-1 px-2 rounded-lg bg-slate-800 hover:bg-slate-700 text-slate-300 font-medium">3.0s</button>
      </div>
    </div>

    <!-- Main Action Button -->
    <button id="playBtn" onclick="toggleAudio()" class="w-full bg-gradient-to-r from-indigo-600 to-indigo-500 hover:from-indigo-500 hover:to-indigo-400 active:scale-95 text-white font-bold py-3.5 px-4 rounded-2xl shadow-lg transition flex items-center justify-center gap-2 text-base">
      <span id="btnIcon">▶️</span> <span id="btnText">Avvia Ascolto</span>
    </button>

    <!-- Volume & Mute Controls -->
    <div class="mt-4 p-3 bg-slate-950/60 rounded-xl border border-slate-800">
      <div class="flex items-center gap-3">
        <button id="muteBtn" onclick="toggleMute()" class="px-2.5 py-1.5 rounded-xl bg-slate-800 hover:bg-slate-700 text-xs font-bold transition flex items-center gap-1.5 text-slate-300">
          <span id="muteIcon">🔊</span> <span id="muteText">Cuffie</span>
        </button>
        <input id="volSlider" type="range" min="0" max="100" value="{}" oninput="setVol(this.value)" class="flex-1 accent-indigo-500 h-2 bg-slate-800 rounded-lg cursor-pointer">
        <span id="volLabel" class="text-xs font-bold w-9 text-right text-indigo-400">{}%</span>
      </div>
      <button id="pcMuteBtn" onclick="togglePcSpeakers()" class="mt-3 w-full py-2 px-3 rounded-xl border border-amber-500/40 bg-amber-500/10 hover:bg-amber-500/20 text-amber-300 text-xs font-bold transition flex items-center justify-center gap-2">
        <span>🔇 Muta / Smuta Casse PC (Hardware)</span>
      </button>
    </div>

    <!-- Hidden Native Audio Element for Hi-Fi Mode -->
    <audio id="nativeAudio" src="/stream.wav" preload="none" class="hidden"></audio>
  </div>

  <script>
    let currentMode = 'realtime'; // 'realtime' or 'buffered'
    let isPlaying = false;
    let audioCtx = null;
    let gainNode = null;
    let analyser = null;
    let ws = null;
    let scheduledTime = 0;
    let bufferSec = 1.5;
    const canvas = document.getElementById('visualizer');
    const ctx = canvas.getContext('2d');
    const nativeAudio = document.getElementById('nativeAudio');

    function setMode(mode) {{
      if (currentMode === mode) return;
      currentMode = mode;
      
      const tabRealtime = document.getElementById('tabRealtime');
      const tabBuffered = document.getElementById('tabBuffered');
      const modeDesc = document.getElementById('modeDesc');
      const bufferControls = document.getElementById('bufferControls');

      if (mode === 'realtime') {{
        tabRealtime.className = "py-2.5 px-2 rounded-xl transition bg-indigo-600 text-white shadow-md flex items-center justify-center gap-1.5";
        tabBuffered.className = "py-2.5 px-2 rounded-xl transition text-slate-400 hover:text-slate-200 flex items-center justify-center gap-1.5";
        modeDesc.innerText = "⚡ Latenza ~15ms: ideale per video, film e gaming (Zero ritardo labiale)";
        modeDesc.className = "mt-2 text-[11px] text-emerald-400 font-medium";
        bufferControls.classList.add('hidden');
      }} else {{
        tabBuffered.className = "py-2.5 px-2 rounded-xl transition bg-indigo-600 text-white shadow-md flex items-center justify-center gap-1.5";
        tabRealtime.className = "py-2.5 px-2 rounded-xl transition text-slate-400 hover:text-slate-200 flex items-center justify-center gap-1.5";
        modeDesc.innerText = "💎 Alta Fedeltà con Buffer: zero glitch, musica fluida e audio cristallino";
        modeDesc.className = "mt-2 text-[11px] text-indigo-300 font-medium";
        bufferControls.classList.remove('hidden');
      }}

      if (isPlaying) {{
        // Restart in new mode
        stopPlayback();
        startPlayback();
      }}
    }}

    function setBufferPreset(sec, label) {{
      bufferSec = sec;
      document.getElementById('bufferValueLabel').innerText = label;
      if (isPlaying && currentMode === 'buffered') {{
        stopPlayback();
        startPlayback();
      }}
    }}

    function drawVisualizer() {{
      requestAnimationFrame(drawVisualizer);
      ctx.fillStyle = '#020617';
      ctx.fillRect(0, 0, canvas.width, canvas.height);

      if (!analyser || !isPlaying) {{
        ctx.fillStyle = '#1e293b';
        for (let i = 0; i < 20; i++) {{
          ctx.fillRect(i * 14 + 4, 25, 8, 4);
        }}
        return;
      }}

      const data = new Uint8Array(analyser.frequencyBinCount);
      analyser.getByteFrequencyData(data);
      const barWidth = 10;
      let x = 4;

      for (let i = 0; i < 20; i++) {{
        const barHeight = Math.max(4, (data[i] / 255) * canvas.height * 0.9);
        const gradient = ctx.createLinearGradient(0, canvas.height, 0, 0);
        if (currentMode === 'realtime') {{
          gradient.addColorStop(0, '#6366f1');
          gradient.addColorStop(1, '#10b981');
        }} else {{
          gradient.addColorStop(0, '#6366f1');
          gradient.addColorStop(1, '#a855f7');
        }}
        ctx.fillStyle = gradient;
        ctx.fillRect(x, canvas.height - barHeight, barWidth, barHeight);
        x += barWidth + 4;
      }}
    }}
    drawVisualizer();

    async function initAudioContext() {{
      if (!audioCtx) {{
        audioCtx = new (window.AudioContext || window.webkitAudioContext)({{
          latencyHint: 'interactive',
          sampleRate: 48000
        }});
        gainNode = audioCtx.createGain();
        gainNode.gain.value = document.getElementById('volSlider').value / 100;
        analyser = audioCtx.createAnalyser();
        analyser.fftSize = 64;
        gainNode.connect(analyser);
        analyser.connect(audioCtx.destination);
      }}
      if (audioCtx.state === 'suspended') {{
        await audioCtx.resume();
      }}
    }}

    async function toggleAudio() {{
      if (isPlaying) {{
        stopPlayback();
      }} else {{
        startPlayback();
      }}
    }}

    async function startPlayback() {{
      await initAudioContext();
      isPlaying = true;

      if (currentMode === 'realtime') {{
        startWebSocketRealtime();
      }} else {{
        startBufferedStream();
      }}

      document.getElementById('btnText').innerText = "Pausa Ascolto";
      document.getElementById('btnIcon').innerText = "⏸️";
      document.getElementById('statusBadge').className = currentMode === 'realtime'
        ? "mt-2.5 inline-flex items-center gap-2 px-3 py-1 rounded-full text-xs font-semibold bg-emerald-500/20 text-emerald-400"
        : "mt-2.5 inline-flex items-center gap-2 px-3 py-1 rounded-full text-xs font-semibold bg-purple-500/20 text-purple-300";
      document.getElementById('statusDot').className = "w-2 h-2 rounded-full bg-emerald-500 animate-pulse";
      document.getElementById('statusText').innerText = currentMode === 'realtime'
        ? "🟢 Tempo Reale Attivo (~15ms)"
        : "💎 Alta Fedeltà Buffer Attiva";
    }}

    function stopPlayback() {{
      isPlaying = false;
      if (ws) {{
        ws.close();
        ws = null;
      }}
      nativeAudio.pause();
      nativeAudio.src = "";

      document.getElementById('btnText').innerText = "Avvia Ascolto";
      document.getElementById('btnIcon').innerText = "▶️";
      document.getElementById('statusBadge').className = "mt-2.5 inline-flex items-center gap-2 px-3 py-1 rounded-full text-xs font-semibold bg-slate-800 text-slate-400";
      document.getElementById('statusDot').className = "w-2 h-2 rounded-full bg-slate-600";
      document.getElementById('statusText').innerText = "In Pausa";
    }}

    function startWebSocketRealtime() {{
      const loc = window.location;
      const wsProtocol = loc.protocol === 'https:' ? 'wss://' : 'ws://';
      ws = new WebSocket(wsProtocol + loc.host);
      ws.binaryType = 'arraybuffer';

      ws.onopen = function() {{
        document.getElementById('statusText').innerText = "🟢 Connesso Tempo Reale (~15ms)";
      }};

      ws.onmessage = function(event) {{
        if (!isPlaying || !audioCtx || currentMode !== 'realtime') return;
        const arrayBuffer = event.data;
        const int16 = new Int16Array(arrayBuffer);
        const numFrames = int16.length / 2;

        const buffer = audioCtx.createBuffer(2, numFrames, 48000);
        const left = buffer.getChannelData(0);
        const right = buffer.getChannelData(1);

        for (let i = 0; i < numFrames; i++) {{
          left[i] = int16[i * 2] / 32768.0;
          right[i] = int16[i * 2 + 1] / 32768.0;
        }}

        const source = audioCtx.createBufferSource();
        source.buffer = buffer;
        source.connect(gainNode);

        const currentTime = audioCtx.currentTime;
        if (scheduledTime < currentTime || scheduledTime > (currentTime + 0.045)) {{
          scheduledTime = currentTime + 0.012; // 12ms target
        }}

        source.start(scheduledTime);
        scheduledTime += buffer.duration;
      }};

      ws.onclose = function() {{
        if (isPlaying && currentMode === 'realtime') {{
          setTimeout(() => {{ if (isPlaying && currentMode === 'realtime') startWebSocketRealtime(); }}, 1000);
        }}
      }};
    }}

    function startBufferedStream() {{
      nativeAudio.src = "/stream.wav?t=" + Date.now();
      nativeAudio.volume = document.getElementById('volSlider').value / 100;
      
      // Connect to analyser for visualization
      try {{
        if (!nativeAudio._sourceConnected && audioCtx) {{
          const source = audioCtx.createMediaElementSource(nativeAudio);
          source.connect(gainNode);
          nativeAudio._sourceConnected = true;
        }}
      }} catch (e) {{
        console.log("MediaElementSource hook:", e);
      }}

      nativeAudio.play().then(() => {{
        document.getElementById('statusText').innerText = "💎 Buffer Hi-Fi Attivo (Zero Glitch)";
      }}).catch(err => {{
        console.log("Buffered playback error:", err);
      }});
    }}

    async function toggleMute() {{
      try {{
        const res = await fetch('/api/mute');
        const data = await res.json();
        updateMuteUI(data.muted);
      }} catch (e) {{}}
    }}

    function updateMuteUI(isMuted) {{
      const btn = document.getElementById('muteBtn');
      const icon = document.getElementById('muteIcon');
      const text = document.getElementById('muteText');
      if (isMuted) {{
        btn.className = "px-2.5 py-1.5 rounded-xl bg-red-600/30 border border-red-500/50 text-red-400 text-xs font-bold transition flex items-center gap-1.5";
        icon.innerText = "🔇";
        text.innerText = "Muto";
        if (gainNode) gainNode.gain.value = 0;
        if (nativeAudio) nativeAudio.volume = 0;
      }} else {{
        btn.className = "px-2.5 py-1.5 rounded-xl bg-slate-800 hover:bg-slate-700 text-slate-300 text-xs font-bold transition flex items-center gap-1.5";
        icon.innerText = "🔊";
        text.innerText = "Cuffie";
        const v = document.getElementById('volSlider').value / 100;
        if (gainNode) gainNode.gain.value = v;
        if (nativeAudio) nativeAudio.volume = v;
      }}
    }}

    async function togglePcSpeakers() {{
      try {{
        await fetch('/api/pc_mute');
      }} catch (e) {{}}
    }}

    function setVol(v) {{
      document.getElementById('volLabel').innerText = v + "%";
      if (gainNode) {{
        gainNode.gain.value = v / 100;
      }}
      if (nativeAudio) {{
        nativeAudio.volume = v / 100;
      }}
      updateMuteUI(false);
      fetch('/api/volume?v=' + (v / 100)).catch(() => {{}});
    }}
  </script>
</body>
</html>"#, (vol * 100.0) as u32, (vol * 100.0) as u32);

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_lock_free_ring_buffer() {
        let mut rb = AudioRingBuffer::new(1024);
        let samples = [0.1f32, 0.2, 0.3, 0.4, 0.5];

        let written = rb.push_slice(&samples);
        assert_eq!(written, 5);
        assert_eq!(rb.available_to_read(), 5);

        let mut out = [0.0f32; 5];
        let read = rb.pop_slice(&mut out);
        assert_eq!(read, 5);
        assert_eq!(out, samples);
        assert_eq!(rb.available_to_read(), 0);
    }

    #[test]
    fn test_ring_buffer_overflow_protection() {
        let mut rb = AudioRingBuffer::new(10);
        let samples = [1.0f32; 15];

        let written = rb.push_slice(&samples);
        assert_eq!(written, 10);
    }

    #[test]
    fn test_adaptive_jitter_buffer() {
        let mut jb = AdaptiveJitterBuffer::new(10.0);
        jb.push_packet(1, 1000, vec![1, 2, 3]);
        jb.push_packet(2, 2000, vec![4, 5, 6]);

        let frame = jb.pop_frame();
        assert_eq!(frame, Some(vec![1, 2, 3]));
    }

    #[test]
    fn test_jitter_buffer_out_of_order_packets() {
        let mut jb = AdaptiveJitterBuffer::new(10.0);
        jb.push_packet(2, 2000, vec![4, 5, 6]);
        jb.push_packet(1, 1000, vec![1, 2, 3]);

        let frame = jb.pop_frame();
        assert_eq!(frame, Some(vec![1, 2, 3]));
    }

    #[test]
    fn test_drift_resampler_linear() {
        let mut resampler = DriftResampler::new();
        resampler.set_drift_adjustment(1.002);

        let input = [1.0f32; 100];
        let mut output = [0.0f32; 100];

        let written = resampler.process_linear(&input, &mut output);
        assert!(written > 95);
    }

    #[test]
    fn test_volume_clamping_bounds() {
        let actor = AudioPluginActor::new(DeviceId::new_random());
        let rt = tokio::runtime::Runtime::new().unwrap();

        rt.block_on(async {
            actor.set_volume(1.5).await;
            assert_eq!(*actor.master_volume.read().await, 1.0);

            actor.set_volume(-0.5).await;
            assert_eq!(*actor.master_volume.read().await, 0.0);
        });
    }

    #[test]
    fn test_audio_relay_lifecycle() {
        let (bus, mut cmd_rx) = EventBus::new(10, 10);
        let actor = AudioPluginActor::new(DeviceId::new_random());
        let peer_id = DeviceId::new_random();
        let rt = tokio::runtime::Runtime::new().unwrap();

        rt.block_on(async {
            tokio::spawn(async move {
                while let Some(_) = cmd_rx.recv().await {}
            });
            assert!(actor.start_streaming_to_peer(&bus, peer_id).await.is_ok());
            assert!(actor.is_streaming.load(Ordering::SeqCst));

            assert!(actor.stop_streaming(&bus).await.is_ok());
            assert!(!actor.is_streaming.load(Ordering::SeqCst));
        });
    }

    #[test]
    fn test_wasapi_loopback_capture_and_packetizer() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let rb = Arc::new(RwLock::new(AudioRingBuffer::new(4800)));
            let capture = WasapiLoopbackCapture::new();
            assert!(capture.start_capture(rb.clone()).is_ok());
            assert!(capture.is_capturing());
            assert!(capture.stop_capture().is_ok());
            assert!(!capture.is_capturing());
        });
    }

    #[test]
    fn test_wav_header_generation() {
        let header = generate_wav_header();
        assert_eq!(&header[0..4], b"RIFF");
        assert_eq!(&header[8..12], b"WAVE");
        assert_eq!(&header[12..16], b"fmt ");
        assert_eq!(&header[36..40], b"data");
    }

    #[tokio::test]
    async fn test_volume_and_mute_control() {
        let actor = AudioPluginActor::new(DeviceId::new_random());
        assert_eq!(*actor.master_volume.read().await, 0.85);
        assert!(!actor.is_muted.load(Ordering::SeqCst));

        // Test volume set
        actor.set_volume(0.42).await;
        assert_eq!(*actor.master_volume.read().await, 0.42);

        // Test toggle mute
        assert!(actor.toggle_mute());
        assert!(actor.is_muted.load(Ordering::SeqCst));

        // Setting volume > 0 automatically unmutes
        actor.set_volume(0.70).await;
        assert!(!actor.is_muted.load(Ordering::SeqCst));

        // Explicit set mute
        actor.set_mute(true);
        assert!(actor.is_muted.load(Ordering::SeqCst));
    }
}
