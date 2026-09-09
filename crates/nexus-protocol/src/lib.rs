use bytes::{Buf, BufMut, BytesMut};
use nexus_types::{DeviceId, NexusError, NexusResult, PeerInfo};
use serde::{Deserialize, Serialize};

/// Protocol magic header: "NX01" (4 bytes)
pub const PROTOCOL_MAGIC: [u8; 4] = [0x4E, 0x58, 0x30, 0x31];
pub const CURRENT_PROTOCOL_VERSION: u32 = 1;

/// The primary envelope for all communications across Nexus nodes
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct NexusPacket {
    pub protocol_version: u32,
    pub sequence_number: u64,
    pub sender_id: DeviceId,
    pub target_id: Option<DeviceId>,
    pub timestamp_ms: u64,
    pub payload: PacketPayload,
}

impl NexusPacket {
    pub fn new(sender_id: DeviceId, payload: PacketPayload) -> Self {
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;

        Self {
            protocol_version: CURRENT_PROTOCOL_VERSION,
            sequence_number: 0,
            sender_id,
            target_id: None,
            timestamp_ms: now_ms,
            payload,
        }
    }

    pub fn with_target(mut self, target_id: DeviceId) -> Self {
        self.target_id = Some(target_id);
        self
    }

    pub fn with_sequence(mut self, seq: u64) -> Self {
        self.sequence_number = seq;
        self
    }

    /// Encodes the packet into bytes with the magic header
    pub fn encode(&self) -> NexusResult<Vec<u8>> {
        let payload_bytes = bincode::serialize(self)
            .map_err(|e| NexusError::Protocol(format!("Packet serialization failed: {}", e)))?;

        let mut buffer = BytesMut::with_capacity(4 + 4 + payload_bytes.len());
        buffer.put_slice(&PROTOCOL_MAGIC);
        buffer.put_u32(payload_bytes.len() as u32);
        buffer.put_slice(&payload_bytes);
        Ok(buffer.to_vec())
    }

    /// Decodes a packet from raw bytes
    pub fn decode(mut bytes: &[u8]) -> NexusResult<Self> {
        if bytes.len() < 8 {
            return Err(NexusError::Protocol("Packet too short".into()));
        }

        if bytes[0..4] != PROTOCOL_MAGIC {
            return Err(NexusError::Protocol("Invalid protocol magic header".into()));
        }

        bytes.advance(4);
        let payload_len = bytes.get_u32() as usize;

        if bytes.remaining() < payload_len {
            return Err(NexusError::Protocol(format!(
                "Incomplete packet: expected {} bytes, got {}",
                payload_len,
                bytes.remaining()
            )));
        }

        let packet: NexusPacket = bincode::deserialize(&bytes[..payload_len])
            .map_err(|e| NexusError::Protocol(format!("Packet deserialization failed: {}", e)))?;

        Ok(packet)
    }
}

/// The polymorphic payload container
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum PacketPayload {
    System(SystemPayload),
    Media(MediaPayload),
    Audio(AudioPayload),
    Input(InputPayload),
    Clipboard(ClipboardPayload),
}

/// System and Control Messages
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum SystemPayload {
    Hello { peer_info: PeerInfo },
    HelloAck { peer_info: PeerInfo },
    Ping { nonce: u64 },
    Pong { nonce: u64 },
    Disconnect { reason: String },
}

/// Media Continuity & Handoff Messages
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum MediaPayload {
    /// Offer to handoff playback to a peer
    OfferHandoff {
        session_id: String,
        source_app: String,
        media_title: String,
        media_url: String,
        position_ms: u64,
        duration_ms: u64,
        is_playing: bool,
    },
    /// Peer accepts the handoff offer
    AcceptHandoff {
        session_id: String,
        start_position_ms: u64,
    },
    /// Source acknowledges handoff and confirms pause
    AckHandoff {
        session_id: String,
        paused_at_position_ms: u64,
    },
    /// Periodic playback state update for Now-Playing synchronization
    PlaybackStateUpdate {
        source_app: String,
        media_title: String,
        media_url: Option<String>,
        position_ms: u64,
        duration_ms: u64,
        is_playing: bool,
    },
    /// Remote Control Commands
    RemoteControl {
        session_id: String,
        command: MediaCommand,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum MediaCommand {
    Play,
    Pause,
    TogglePlayPause,
    NextTrack,
    PreviousTrack,
    SeekRelative { delta_ms: i64 },
    SeekAbsolute { position_ms: u64 },
}

/// Real-time Audio Streaming Payloads
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum AudioPayload {
    /// A single low-latency Opus audio frame
    AudioFrame {
        sequence: u32,
        timestamp_us: u64,
        channels: u8,
        sample_rate: u32,
        opus_data: Vec<u8>,
    },
    /// Stream control (Start, Stop, Mute, Volume)
    StreamControl {
        is_streaming: bool,
        master_volume: f32, // 0.0 to 1.0
    },
}

/// Real-time Input Injection Payloads
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum InputPayload {
    MouseMoveRelative {
        dx: i16,
        dy: i16,
    },
    MouseButton {
        button: MouseButton,
        is_down: bool,
    },
    MouseScroll {
        delta_x: i16,
        delta_y: i16,
    },
    KeyEvent {
        keycode: u32,
        modifiers: u8,
        is_down: bool,
    },
    GyroLaserPointer {
        pitch_delta: f32,
        yaw_delta: f32,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum MouseButton {
    Left,
    Right,
    Middle,
}

/// E2EE Encrypted Clipboard Payloads
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum ClipboardPayload {
    EncryptedText {
        nonce: [u8; 12],
        ciphertext: Vec<u8>,
        plain_hash: [u8; 32],
    },
    SmartActionHint {
        hint_type: SmartHintType,
        preview: String,
    },
    SecretAnnounce {
        entry_id: String,
        secret_type: String,
        masked_preview: String,
    },
    RevealRequest {
        entry_id: String,
        requesting_device: String,
    },
    RevealResponse {
        entry_id: String,
        nonce: [u8; 12],
        ciphertext: Vec<u8>,
        secret_type: String,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum SmartHintType {
    Otp2Fa,
    Url,
    HexColor,
    PhoneNumber,
    ApiKey,
    CreditCard,
    PiiSecret,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_packet_encode_decode_roundtrip() {
        let sender_id = DeviceId::new_random();
        let target_id = DeviceId::new_random();

        let payload = PacketPayload::Media(MediaPayload::OfferHandoff {
            session_id: "sess-1234".into(),
            source_app: "YouTube (Chrome)".into(),
            media_title: "Rust for Beginners".into(),
            media_url: "https://youtube.com/watch?v=123".into(),
            position_ms: 862000,
            duration_ms: 1800000,
            is_playing: true,
        });

        let packet = NexusPacket::new(sender_id, payload)
            .with_target(target_id)
            .with_sequence(42);

        let encoded = packet.encode().expect("Failed to encode packet");
        let decoded = NexusPacket::decode(&encoded).expect("Failed to decode packet");

        assert_eq!(packet.protocol_version, decoded.protocol_version);
        assert_eq!(packet.sequence_number, decoded.sequence_number);
        assert_eq!(packet.sender_id, decoded.sender_id);
        assert_eq!(packet.target_id, decoded.target_id);
        assert_eq!(packet.payload, decoded.payload);
    }

    #[test]
    fn test_audio_datagram_packet() {
        let sender = DeviceId::new_random();
        let opus_mock_bytes = vec![0xAB, 0xCD, 0xEF, 0x01, 0x02];

        let payload = PacketPayload::Audio(AudioPayload::AudioFrame {
            sequence: 1001,
            timestamp_us: 50000,
            channels: 2,
            sample_rate: 48000,
            opus_data: opus_mock_bytes.clone(),
        });

        let packet = NexusPacket::new(sender, payload);
        let encoded = packet.encode().unwrap();
        let decoded = NexusPacket::decode(&encoded).unwrap();

        match decoded.payload {
            PacketPayload::Audio(AudioPayload::AudioFrame { opus_data, .. }) => {
                assert_eq!(opus_data, opus_mock_bytes);
            }
            _ => panic!("Unexpected payload type"),
        }
    }

    #[test]
    fn test_reject_invalid_magic_header() {
        let sender = DeviceId::new_random();
        let payload = PacketPayload::System(SystemPayload::Ping { nonce: 12345 });
        let packet = NexusPacket::new(sender, payload);
        let mut encoded = packet.encode().unwrap();

        // Corrupt magic header (NX01 -> XX01)
        encoded[0] = b'X';
        encoded[1] = b'X';

        let result = NexusPacket::decode(&encoded);
        assert!(result.is_err(), "Packet with invalid magic header must be rejected");
    }

    #[test]
    fn test_reject_truncated_and_garbage_data() {
        // Empty bytes
        assert!(NexusPacket::decode(&[]).is_err());
        // Sub-4 bytes header
        assert!(NexusPacket::decode(b"NX").is_err());
        // Valid header but truncated body
        assert!(NexusPacket::decode(&[b'N', b'X', b'0', b'1', 0xFF, 0x00]).is_err());

        // Garbage bytes injection (fuzz-style)
        let random_garbage = vec![0xDE, 0xAD, 0xBE, 0xEF, 0x12, 0x34, 0x56, 0x78];
        assert!(NexusPacket::decode(&random_garbage).is_err());
    }
}
