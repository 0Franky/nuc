use mdns_sd::{ServiceDaemon, ServiceEvent, ServiceInfo};
use nexus_actor_system::{EventBus, NexusEvent};
use nexus_crypto::{DeviceIdentity, EncryptedChannel};
use nexus_protocol::{NexusPacket, PacketPayload, SystemPayload};
use nexus_types::{Capability, CapabilityMap, DeviceId, DeviceType, NexusError, NexusResult, OsType, PeerInfo};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::net::UdpSocket;
use tokio::sync::RwLock;
use tracing::{debug, error, info};

pub const SERVICE_TYPE: &str = "_nexus._udp.local.";

/// Manages Network Discovery and P2P Connections
pub struct TransportEngine {
    pub identity: Arc<DeviceIdentity>,
    pub local_peer_info: PeerInfo,
    pub listen_port: u16,
    active_peers: Arc<RwLock<HashMap<DeviceId, PeerSession>>>,
    bus: EventBus,
}

pub struct PeerSession {
    pub peer_info: PeerInfo,
    pub endpoint: SocketAddr,
    pub encrypted_channel: Option<EncryptedChannel>,
    pub last_seen_ms: u64,
}

impl TransportEngine {
    pub fn new(identity: DeviceIdentity, name: String, listen_port: u16, bus: EventBus) -> Self {
        let device_id = identity.device_id;
        let fingerprint = identity.fingerprint();

        let mut caps = CapabilityMap::new();
        caps.add(Capability::MediaHandoff);
        caps.add(Capability::AudioSink);
        caps.add(Capability::AudioSource);
        caps.add(Capability::InputReceiver);
        caps.add(Capability::InputEmitter);
        caps.add(Capability::ClipboardSync);

        let local_peer_info = PeerInfo {
            id: device_id,
            name,
            device_type: DeviceType::Desktop,
            os: OsType::current(),
            capabilities: caps,
            protocol_version: 1,
            public_key_fingerprint: fingerprint,
            screen_geometry: Some(nexus_types::ScreenGeometry::default()),
            spatial_arrangement: nexus_types::SpatialArrangement::None,
        };

        let active_peers = Arc::new(RwLock::new(HashMap::new()));
        let active_peers_for_bus = active_peers.clone();
        let mut bus_rx = bus.subscribe();

        tokio::spawn(async move {
            while let Ok(event) = bus_rx.recv().await {
                if let NexusEvent::PeerDiscovered(peer_info) = event {
                    let peer_id = peer_info.id;
                    let session = PeerSession {
                        peer_info,
                        endpoint: SocketAddr::new(std::net::IpAddr::V4(std::net::Ipv4Addr::LOCALHOST), 42420),
                        encrypted_channel: None,
                        last_seen_ms: std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis() as u64,
                    };
                    let mut peers = active_peers_for_bus.write().await;
                    peers.insert(peer_id, session);
                }
            }
        });

        Self {
            identity: Arc::new(identity),
            local_peer_info,
            listen_port,
            active_peers,
            bus,
        }
    }

    /// Registers the device on mDNS for zero-config local discovery
    pub fn start_mdns_announcement(&self) -> NexusResult<ServiceDaemon> {
        let mdns = ServiceDaemon::new()
            .map_err(|e| NexusError::Network(format!("Failed to start mDNS daemon: {}", e)))?;

        let instance_name = format!("nexus-{}", self.identity.device_id);
        let host_name = format!("{}.local.", instance_name);

        let mut properties = HashMap::new();
        properties.insert("id".to_string(), self.identity.device_id.to_string());
        properties.insert("name".to_string(), self.local_peer_info.name.clone());
        properties.insert("pub".to_string(), self.identity.fingerprint());
        properties.insert("ver".to_string(), "1".to_string());
        properties.insert("os".to_string(), format!("{:?}", self.local_peer_info.os));
        properties.insert("device_type".to_string(), format!("{:?}", self.local_peer_info.device_type));

        let service_info = ServiceInfo::new(
            SERVICE_TYPE,
            &instance_name,
            &host_name,
            "",
            self.listen_port,
            properties,
        )
        .map_err(|e| NexusError::Network(format!("Invalid mDNS service info: {}", e)))?;

        mdns.register(service_info)
            .map_err(|e| NexusError::Network(format!("Failed to register mDNS service: {}", e)))?;

        info!("mDNS service '{}' registered on port {}", SERVICE_TYPE, self.listen_port);
        Ok(mdns)
    }

    /// Starts mDNS browsing to discover other peers in the local network
    pub fn start_mdns_discovery(&self, mdns: &ServiceDaemon) -> NexusResult<()> {
        let receiver = mdns
            .browse(SERVICE_TYPE)
            .map_err(|e| NexusError::Network(format!("mDNS browse failed: {}", e)))?;

        let bus = self.bus.clone();
        let my_id = self.identity.device_id;
        let active_peers_clone = self.active_peers.clone();

        tokio::spawn(async move {
            while let Ok(event) = receiver.recv_async().await {
                if let ServiceEvent::ServiceResolved(info) = event {
                    let props = info.get_properties();
                    if let Some(peer_id_str) = props.get("id") {
                        if let Ok(peer_uuid) = uuid::Uuid::parse_str(peer_id_str.val_str()) {
                            let peer_id = DeviceId::from_bytes(*peer_uuid.as_bytes());
                            if peer_id != my_id {
                                let peer_name = props
                                    .get("name")
                                    .map(|s| s.val_str())
                                    .unwrap_or("Unknown Nexus Device")
                                    .to_string();

                                let fingerprint = props
                                    .get("pub")
                                    .map(|s| s.val_str())
                                    .unwrap_or("")
                                    .to_string();

                                let peer_os = match props.get("os").map(|s| s.val_str()).unwrap_or("Unknown") {
                                    "Windows" => OsType::Windows,
                                    "MacOS" => OsType::MacOS,
                                    "Linux" => OsType::Linux,
                                    "Android" => OsType::Android,
                                    "IOS" => OsType::IOS,
                                    _ => OsType::Unknown,
                                };

                                let peer_type = match props.get("device_type").map(|s| s.val_str()).unwrap_or("Desktop") {
                                    "Mobile" => DeviceType::Mobile,
                                    "Tablet" => DeviceType::Tablet,
                                    "Laptop" => DeviceType::Laptop,
                                    _ => DeviceType::Desktop,
                                };

                                info!("Discovered peer '{}' (ID: {}, OS: {:?}) via mDNS", peer_name, peer_id, peer_os);

                                let discovered_info = PeerInfo {
                                    id: peer_id,
                                    name: peer_name,
                                    device_type: peer_type,
                                    os: peer_os,
                                    capabilities: CapabilityMap::new().with_capability(Capability::MediaHandoff),
                                    protocol_version: 1,
                                    public_key_fingerprint: fingerprint,
                                    screen_geometry: None,
                                    spatial_arrangement: nexus_types::SpatialArrangement::None,
                                };

                                let peer_ip = info
                                    .get_addresses_v4()
                                    .iter()
                                    .next()
                                    .map(|ip| std::net::IpAddr::V4(**ip))
                                    .unwrap_or(std::net::IpAddr::V4(std::net::Ipv4Addr::LOCALHOST));

                                let session = PeerSession {
                                    peer_info: discovered_info.clone(),
                                    endpoint: SocketAddr::new(peer_ip, info.get_port()),
                                    encrypted_channel: None,
                                    last_seen_ms: std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis() as u64,
                                };

                                {
                                    let mut peers = active_peers_clone.write().await;
                                    peers.insert(peer_id, session);
                                }

                                bus.publish(NexusEvent::PeerDiscovered(discovered_info));
                            }
                        }
                    }
                }
            }
        });

        Ok(())
    }

    pub async fn get_discovered_peers(&self) -> Vec<PeerInfo> {
        let peers = self.active_peers.read().await;
        peers.values().map(|p| p.peer_info.clone()).collect()
    }

    /// Starts the UDP socket listener for incoming packets
    pub async fn run_udp_listener(self: Arc<Self>) -> NexusResult<()> {
        let addr = format!("0.0.0.0:{}", self.listen_port);
        let socket = UdpSocket::bind(&addr)
            .await
            .map_err(|e| NexusError::Network(format!("UDP Bind to {} failed: {}", addr, e)))?;

        info!("Nexus UDP Transport listening on {}", addr);
        let socket = Arc::new(socket);

        let mut buf = vec![0u8; 65535];
        loop {
            match socket.recv_from(&mut buf).await {
                Ok((len, src_addr)) => {
                    let packet_data = &buf[..len];
                    if let Ok(packet) = NexusPacket::decode(packet_data) {
                        debug!("Received packet from {}: {:?}", src_addr, packet.payload);
                        self.handle_incoming_packet(packet, src_addr).await;
                    } else if let Ok(json_val) = serde_json::from_slice::<serde_json::Value>(packet_data) {
                        if json_val["type"] == "PEER_ANNOUNCE" {
                            let p_id_str = json_val["id"].as_str().or_else(|| json_val["device_id"].as_str()).unwrap_or("");
                            let p_name = json_val["name"].as_str().unwrap_or("Dispositivo Remoto").to_string();
                            let p_type_str = json_val["device_type"].as_str().unwrap_or("Desktop");
                            let p_os_str = json_val["os"].as_str().unwrap_or("Unknown");

                            if let Ok(u) = uuid::Uuid::parse_str(p_id_str) {
                                let peer_id = DeviceId::from_bytes(*u.as_bytes());
                                if peer_id != self.identity.device_id {
                                    let device_type = match p_type_str.to_lowercase().as_str() {
                                        "mobile" | "phone" | "smartphone" => nexus_types::DeviceType::Mobile,
                                        "tablet" => nexus_types::DeviceType::Tablet,
                                        "laptop" => nexus_types::DeviceType::Laptop,
                                        _ => nexus_types::DeviceType::Desktop,
                                    };
                                    let os = match p_os_str.to_lowercase().as_str() {
                                        "windows" => nexus_types::OsType::Windows,
                                        "macos" | "darwin" => nexus_types::OsType::MacOS,
                                        "linux" => nexus_types::OsType::Linux,
                                        "android" => nexus_types::OsType::Android,
                                        "ios" => nexus_types::OsType::IOS,
                                        _ => nexus_types::OsType::Unknown,
                                    };

                                    let peer_info = nexus_types::PeerInfo {
                                        id: peer_id,
                                        name: p_name,
                                        device_type,
                                        os,
                                        capabilities: nexus_types::CapabilityMap::new().with_capability(nexus_types::Capability::MediaHandoff),
                                        protocol_version: 1,
                                        public_key_fingerprint: String::new(),
                                        screen_geometry: None,
                                        spatial_arrangement: nexus_types::SpatialArrangement::None,
                                    };

                                    let mut peers = self.active_peers.write().await;
                                    peers.insert(
                                        peer_id,
                                        PeerSession {
                                            peer_info: peer_info.clone(),
                                            endpoint: src_addr,
                                            encrypted_channel: None,
                                            last_seen_ms: std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis() as u64,
                                        },
                                    );
                                    self.bus.publish(NexusEvent::PeerDiscovered(peer_info));
                                }
                            }
                        }
                    }
                }
                Err(e) => {
                    error!("UDP Receive error: {}", e);
                }
            }
        }
    }

    async fn handle_incoming_packet(&self, packet: NexusPacket, src_addr: SocketAddr) {
        match packet.payload {
            PacketPayload::System(SystemPayload::Hello { peer_info }) => {
                info!("Received Hello from peer '{}' ({})", peer_info.name, peer_info.id);
                let mut peers = self.active_peers.write().await;
                peers.insert(
                    peer_info.id,
                    PeerSession {
                        peer_info: peer_info.clone(),
                        endpoint: src_addr,
                        encrypted_channel: None,
                        last_seen_ms: packet.timestamp_ms,
                    },
                );
                self.bus.publish(NexusEvent::PeerConnected(peer_info.id));
            }
            PacketPayload::Media(nexus_protocol::MediaPayload::OfferHandoff {
                session_id,
                media_title,
                media_url,
                position_ms,
                ..
            }) => {
                info!("Handoff offered from {}: {} @ {}ms", packet.sender_id, media_title, position_ms);
                self.bus.publish(NexusEvent::HandoffOffered {
                    from_peer: packet.sender_id,
                    session_id,
                    media_title,
                    media_url,
                    position_ms,
                });
            }
            PacketPayload::Media(nexus_protocol::MediaPayload::AcceptHandoff {
                session_id,
                start_position_ms,
            }) => {
                info!("Handoff accepted by {}: session {}", packet.sender_id, session_id);
                self.bus.publish(NexusEvent::HandoffAccepted {
                    from_peer: packet.sender_id,
                    session_id,
                    start_position_ms,
                });
            }
            _ => {}
        }
    }
}

/// Simulated Multi-Node Virtual Bus for Automated Offline Verification Tests
pub struct VirtualLoopbackRouter {
    nodes: Arc<RwLock<HashMap<DeviceId, tokio::sync::mpsc::Sender<NexusPacket>>>>,
}

impl Default for VirtualLoopbackRouter {
    fn default() -> Self {
        Self::new()
    }
}

impl VirtualLoopbackRouter {
    pub fn new() -> Self {
        Self {
            nodes: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    pub async fn register_node(&self, id: DeviceId) -> (tokio::sync::mpsc::Sender<NexusPacket>, tokio::sync::mpsc::Receiver<NexusPacket>) {
        let (tx, rx) = tokio::sync::mpsc::channel(100);
        let mut nodes = self.nodes.write().await;
        nodes.insert(id, tx.clone());
        (tx, rx)
    }

    pub async fn route_packet(&self, packet: NexusPacket) -> NexusResult<()> {
        if let Some(target) = packet.target_id {
            let nodes = self.nodes.read().await;
            if let Some(tx) = nodes.get(&target) {
                let _ = tx.send(packet).await;
                return Ok(());
            }
        }
        Err(NexusError::Network("Target node unreachable in virtual network".into()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use nexus_protocol::{MediaPayload, PacketPayload};

    #[tokio::test]
    async fn test_virtual_multi_node_communication() {
        let router = VirtualLoopbackRouter::new();

        let node_a_id = DeviceId::new_random();
        let node_b_id = DeviceId::new_random();

        let (_tx_a, _rx_a) = router.register_node(node_a_id).await;
        let (_tx_b, mut rx_b) = router.register_node(node_b_id).await;

        // Node A sends Media Handoff Offer to Node B
        let handoff_packet = NexusPacket::new(
            node_a_id,
            PacketPayload::Media(MediaPayload::OfferHandoff {
                session_id: "test-sess-99".into(),
                source_app: "YouTube (Chrome)".into(),
                media_title: "Rust Deep Dive".into(),
                media_url: "https://youtube.com/watch?v=xyz".into(),
                position_ms: 742000,
                duration_ms: 1200000,
                is_playing: true,
            }),
        )
        .with_target(node_b_id);

        router.route_packet(handoff_packet).await.unwrap();

        // Node B receives the packet
        let received = rx_b.recv().await.expect("Node B did not receive packet");
        assert_eq!(received.sender_id, node_a_id);
        if let PacketPayload::Media(MediaPayload::OfferHandoff { position_ms, .. }) = received.payload {
            assert_eq!(position_ms, 742000);
        } else {
            panic!("Unexpected packet payload");
        }
    }
}
