use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fmt;
use uuid::Uuid;

/// Unique Identifier for a Device in the Nexus Ecosystem
#[derive(Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct DeviceId(pub Uuid);

impl DeviceId {
    /// Generates a new random DeviceId (UUIDv4)
    pub fn new_random() -> Self {
        Self(Uuid::new_v4())
    }

    /// Creates a DeviceId from raw bytes (16 bytes)
    pub fn from_bytes(bytes: [u8; 16]) -> Self {
        Self(Uuid::from_bytes(bytes))
    }

    pub fn as_bytes(&self) -> &[u8; 16] {
        self.0.as_bytes()
    }
}

impl fmt::Display for DeviceId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl fmt::Debug for DeviceId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "DeviceId({})", self.0)
    }
}

impl Default for DeviceId {
    fn default() -> Self {
        Self::new_random()
    }
}

/// Device Physical Form Factor
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum DeviceType {
    Desktop,
    Laptop,
    Mobile,
    Tablet,
    BrowserExtension,
    HeadlessServer,
}

/// Operating System Type
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum OsType {
    Windows,
    MacOS,
    Linux,
    Android,
    IOS,
    Browser,
    Unknown,
}

impl OsType {
    pub fn current() -> Self {
        #[cfg(target_os = "windows")]
        return OsType::Windows;
        #[cfg(target_os = "macos")]
        return OsType::MacOS;
        #[cfg(target_os = "linux")]
        return OsType::Linux;
        #[cfg(target_os = "android")]
        return OsType::Android;
        #[cfg(target_os = "ios")]
        return OsType::IOS;
        #[cfg(not(any(
            target_os = "windows",
            target_os = "macos",
            target_os = "linux",
            target_os = "android",
            target_os = "ios"
        )))]
        return OsType::Unknown;
    }
}

/// Capabilities supported and offered by a Nexus Node
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Capability {
    MediaHandoff,
    AudioSource,
    AudioSink,
    InputReceiver,
    InputEmitter,
    ClipboardSync,
    FileStream,
    SensorBridge,
    ProximityTracker,
}

impl Capability {
    pub fn as_str(&self) -> &'static str {
        match self {
            Capability::MediaHandoff => "media.handoff",
            Capability::AudioSource => "audio.source",
            Capability::AudioSink => "audio.sink",
            Capability::InputReceiver => "input.receiver",
            Capability::InputEmitter => "input.emitter",
            Capability::ClipboardSync => "clipboard.sync",
            Capability::FileStream => "file.stream",
            Capability::SensorBridge => "sensor.bridge",
            Capability::ProximityTracker => "proximity.tracker",
        }
    }
}

/// Set of capabilities offered by a device
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CapabilityMap {
    capabilities: HashSet<Capability>,
}

impl CapabilityMap {
    pub fn new() -> Self {
        Self {
            capabilities: HashSet::new(),
        }
    }

    pub fn with_capability(mut self, cap: Capability) -> Self {
        self.capabilities.insert(cap);
        self
    }

    pub fn add(&mut self, cap: Capability) {
        self.capabilities.insert(cap);
    }

    pub fn has(&self, cap: Capability) -> bool {
        self.capabilities.contains(&cap)
    }

    pub fn iter(&self) -> impl Iterator<Item = &Capability> {
        self.capabilities.iter()
    }
}

/// Geometry and Display Resolution of a Device Screen
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct ScreenGeometry {
    pub width: u32,
    pub height: u32,
    pub scale_factor: f32,
}

impl Default for ScreenGeometry {
    fn default() -> Self {
        Self {
            width: 1920,
            height: 1080,
            scale_factor: 1.0,
        }
    }
}

/// Relative Spatial Position in Universal Control Workspace
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum SpatialArrangement {
    None,
    Left,
    Right,
    Above,
    Below,
}

impl Default for SpatialArrangement {
    fn default() -> Self {
        SpatialArrangement::None
    }
}

/// Motion State of a peer relative to local workstation
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ProximityMotion {
    Stationary,
    Approaching,
    MovingAway,
}

impl Default for ProximityMotion {
    fn default() -> Self {
        ProximityMotion::Stationary
    }
}

/// Information describing a peer device
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PeerInfo {
    pub id: DeviceId,
    pub name: String,
    pub device_type: DeviceType,
    pub os: OsType,
    pub capabilities: CapabilityMap,
    pub protocol_version: u32,
    pub public_key_fingerprint: String,
    pub screen_geometry: Option<ScreenGeometry>,
    pub spatial_arrangement: SpatialArrangement,
}

/// Standard error type for all Nexus subsystems
#[derive(thiserror::Error, Debug)]
pub enum NexusError {
    #[error("Network I/O error: {0}")]
    Network(String),

    #[error("Cryptography error: {0}")]
    Crypto(String),

    #[error("Protocol error: {0}")]
    Protocol(String),

    #[error("Plugin error in '{plugin}': {message}")]
    Plugin {
        plugin: &'static str,
        message: String,
    },

    #[error("Permission denied for action: {0}")]
    PermissionDenied(String),

    #[error("Operation timed out after {0} ms")]
    Timeout(u64),

    #[error("Internal system error: {0}")]
    Internal(String),
}

pub type NexusResult<T> = Result<T, NexusError>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_device_id_generation_and_string() {
        let id1 = DeviceId::new_random();
        let id2 = DeviceId::new_random();
        assert_ne!(id1, id2);
        assert_eq!(id1.to_string().len(), 36);
    }

    #[test]
    fn test_capability_map() {
        let mut map = CapabilityMap::new();
        map.add(Capability::MediaHandoff);
        map.add(Capability::AudioSink);

        assert!(map.has(Capability::MediaHandoff));
        assert!(map.has(Capability::AudioSink));
        assert!(!map.has(Capability::InputReceiver));
    }

    #[test]
    fn test_peer_info_serialization() {
        let peer = PeerInfo {
            id: DeviceId::new_random(),
            name: "Work PC".to_string(),
            device_type: DeviceType::Desktop,
            os: OsType::Windows,
            capabilities: CapabilityMap::new().with_capability(Capability::MediaHandoff),
            protocol_version: 1,
            public_key_fingerprint: "a1b2c3d4".to_string(),
            screen_geometry: Some(ScreenGeometry::default()),
            spatial_arrangement: SpatialArrangement::Right,
        };

        let json = serde_json::to_string(&peer).expect("Serialization failed");
        let decoded: PeerInfo = serde_json::from_str(&json).expect("Deserialization failed");
        assert_eq!(peer.id, decoded.id);
        assert_eq!(peer.name, decoded.name);
        assert_eq!(peer.spatial_arrangement, decoded.spatial_arrangement);
        assert!(decoded.capabilities.has(Capability::MediaHandoff));
    }
}
