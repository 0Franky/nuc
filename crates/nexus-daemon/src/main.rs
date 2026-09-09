use nexus_actor_system::{ActorSupervisor, EventBus, NexusEvent};
use nexus_crypto::DeviceIdentity;
use nexus_plugin_audio::AudioPluginActor;
use nexus_plugin_clipboard::ClipboardPluginActor;
use nexus_plugin_files::FilePluginActor;
use nexus_plugin_input::InputPluginActor;
use nexus_plugin_media::MediaPluginActor;
use nexus_plugin_notifications::NotificationPluginActor;
use nexus_plugin_proximity::ProximityPluginActor;
use nexus_transport::TransportEngine;
use std::sync::Arc;
use tracing::{info, Level};
use tracing_subscriber::FmtSubscriber;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // 1. Initialize Structured Logging
    let subscriber = FmtSubscriber::builder()
        .with_max_level(Level::INFO)
        .finish();
    tracing::subscriber::set_global_default(subscriber)
        .expect("Setting default tracing subscriber failed");

    info!("=================================================");
    info!("   Nexus Universal Continuity Daemon v0.1.0      ");
    info!("   (Windows, macOS, Linux, Android, iOS Core)   ");
    info!("=================================================");

    // 2. Cryptographic Identity
    let identity = DeviceIdentity::generate();
    let device_id = identity.device_id;
    let fingerprint = identity.fingerprint();
    let hostname = whoami_hostname();

    info!("Device ID:    {}", device_id);
    info!("Fingerprint:  {}", fingerprint);
    info!("Device Name:  {}", hostname);
    nexus_plugin_media::append_log("nexus_daemon.log", &format!("Daemon started. Device: {} ({})", hostname, device_id));

    // 3. In-Process Event Bus & Command Channel
    let (bus, mut command_rx) = EventBus::new(256, 128);

    // 4. Spawn Plugin Actors
    let media_actor = MediaPluginActor::new(device_id);
    let shared_ws_clients = media_actor.shared_clients(); // Extract before spawn consumes it
    ActorSupervisor::spawn_actor(media_actor, bus.clone());

    let audio_actor = AudioPluginActor::new(device_id);
    ActorSupervisor::spawn_actor(audio_actor, bus.clone());

    let input_actor = InputPluginActor::new(device_id);
    ActorSupervisor::spawn_actor(input_actor, bus.clone());

    let clipboard_actor = ClipboardPluginActor::new(device_id);
    ActorSupervisor::spawn_actor(clipboard_actor, bus.clone());

    let proximity_actor = ProximityPluginActor::new(device_id);
    ActorSupervisor::spawn_actor(proximity_actor, bus.clone());

    let files_actor = FilePluginActor::new(device_id);
    ActorSupervisor::spawn_actor(files_actor, bus.clone());

    let notification_actor = NotificationPluginActor::new(
        device_id,
        shared_ws_clients,
        hostname.clone(),
    );
    ActorSupervisor::spawn_actor(notification_actor, bus.clone());

    info!("Media, Audio, Input, Clipboard, Proximity, Files & Notifications Actors initialized in background.");

    // 5. Initialize P2P Transport & mDNS Discovery
    let listen_port = 42420;
    let transport = Arc::new(TransportEngine::new(
        identity,
        hostname,
        listen_port,
        bus.clone(),
    ));

    // Start mDNS advertisement and local peer browsing
    match transport.start_mdns_announcement() {
        Ok(mdns) => {
            if let Err(e) = transport.start_mdns_discovery(&mdns) {
                tracing::warn!("Failed to start mDNS browsing: {}", e);
            }
        }
        Err(e) => {
            tracing::warn!("mDNS announcement unavailable: {}", e);
        }
    }

    // 6. Spawn Command Processor
    tokio::spawn(async move {
        while let Some(cmd) = command_rx.recv().await {
            info!("Daemon received internal command: {:?}", cmd);
        }
    });

    // 7. Event Monitor Loop (Logs incoming peer activity)
    let mut event_sub = bus.subscribe();
    tokio::spawn(async move {
        while let Ok(event) = event_sub.recv().await {
            match event {
                NexusEvent::PeerDiscovered(peer) => {
                    info!("🟢 Discovered Peer: '{}' ({})", peer.name, peer.id);
                }
                NexusEvent::PeerConnected(peer_id) => {
                    info!("🔗 Connected with Peer: {}", peer_id);
                }
                NexusEvent::HandoffOffered { media_title, position_ms, .. } => {
                    info!("📺 Media Handoff Available: '{}' at {}ms", media_title, position_ms);
                }
                _ => {}
            }
        }
    });

    // 8. Start Background UDP Transport Loop in a separate task
    let transport_clone = transport.clone();
    tokio::spawn(async move {
        if let Err(e) = transport_clone.run_udp_listener().await {
            tracing::error!("UDP Listener error: {}", e);
        }
    });

    info!("Nexus Daemon successfully running. Listening on UDP 42420 and WebSocket 28471.");
    // Keep daemon running continuously in background
    std::future::pending::<()>().await;

    Ok(())
}

fn whoami_hostname() -> String {
    std::env::var("COMPUTERNAME")
        .or_else(|_| std::env::var("HOSTNAME"))
        .unwrap_or_else(|_| "Nexus Desktop".to_string())
}
