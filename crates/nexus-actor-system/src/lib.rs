use async_trait::async_trait;
use futures::FutureExt;
use nexus_protocol::NexusPacket;
use nexus_types::{DeviceId, NexusError, NexusResult, PeerInfo};
use std::panic::AssertUnwindSafe;
use tokio::sync::{broadcast, mpsc};
use tracing::{error, info};

/// System-Wide Broadcast Events (Pub/Sub)
#[derive(Clone, Debug)]
pub enum NexusEvent {
    // Discovery & Network Events
    PeerDiscovered(PeerInfo),
    PeerConnected(DeviceId),
    PeerDisconnected(DeviceId),

    // Media Handoff Events
    LocalPlaybackChanged {
        source_app: String,
        media_title: String,
        media_url: Option<String>,
        position_ms: u64,
        is_playing: bool,
    },
    HandoffOffered {
        from_peer: DeviceId,
        session_id: String,
        media_title: String,
        media_url: String,
        position_ms: u64,
    },
    HandoffAccepted {
        from_peer: DeviceId,
        session_id: String,
        start_position_ms: u64,
    },

    // Audio Relay Events
    AudioStreamingActive(bool),
    AudioVolumeChanged(f32),
    AudioMuteToggled(bool),

    // Proximity Events
    ProximityChanged {
        peer_id: DeviceId,
        estimated_meters: f32,
        is_near: bool,
    },
    ProximityMotionChanged {
        peer_id: DeviceId,
        motion: nexus_types::ProximityMotion,
        distance_m: f32,
    },
}

/// Commands targeted to specific actors
#[derive(Debug)]
pub enum NexusCommand {
    SendPacket {
        target: DeviceId,
        packet: NexusPacket,
    },
    BroadcastPacket {
        packet: NexusPacket,
    },
    TriggerMediaHandoff {
        target_peer: DeviceId,
        session_id: String,
    },
    StartAudioRelay {
        target_peer: DeviceId,
    },
    StopAudioRelay,
}

/// Central In-Process Event Bus for Zero-Latency Inter-Actor Messaging
#[derive(Clone)]
pub struct EventBus {
    event_tx: broadcast::Sender<NexusEvent>,
    command_tx: mpsc::Sender<NexusCommand>,
}

impl EventBus {
    pub fn new(broadcast_capacity: usize, command_capacity: usize) -> (Self, mpsc::Receiver<NexusCommand>) {
        let (event_tx, _) = broadcast::channel(broadcast_capacity);
        let (command_tx, command_rx) = mpsc::channel(command_capacity);

        let bus = Self {
            event_tx,
            command_tx,
        };

        (bus, command_rx)
    }

    /// Publishes a system event to all subscribing actors
    pub fn publish(&self, event: NexusEvent) {
        let _ = self.event_tx.send(event);
    }

    /// Subscribes to the broadcast event feed
    pub fn subscribe(&self) -> broadcast::Receiver<NexusEvent> {
        self.event_tx.subscribe()
    }

    /// Sends a direct command to the command handler
    pub async fn send_command(&self, command: NexusCommand) -> NexusResult<()> {
        self.command_tx
            .send(command)
            .await
            .map_err(|_| NexusError::Internal("Command channel closed".into()))
    }
}

/// Trait implemented by every modular Actor in the Nexus system
#[async_trait]
pub trait NexusActor: Send + Sync + 'static {
    fn name(&self) -> &'static str;
    async fn run(&mut self, bus: EventBus) -> NexusResult<()>;
}

/// Actor Supervisor: Runs actor tasks in the background with panic resilience
pub struct ActorSupervisor;

impl ActorSupervisor {
    pub fn spawn_actor<A: NexusActor>(mut actor: A, bus: EventBus) {
        let name = actor.name();
        info!("Spawning actor '{}'", name);

        tokio::spawn(async move {
            loop {
                let bus_clone = bus.clone();
                let result = AssertUnwindSafe(actor.run(bus_clone)).catch_unwind().await;

                match result {
                    Ok(Ok(())) => {
                        info!("Actor '{}' completed gracefully", name);
                        break;
                    }
                    Ok(Err(err)) => {
                        error!("Actor '{}' failed with error: {}. Restarting in 1s...", name, err);
                        tokio::time::sleep(tokio::time::Duration::from_secs(1)).await;
                    }
                    Err(_panic_payload) => {
                        error!("Actor '{}' panicked! Panic isolated. Auto-recovering in 1s...", name);
                        tokio::time::sleep(tokio::time::Duration::from_secs(1)).await;
                    }
                }
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct MockMediaActor {
        received_handoff_count: usize,
    }

    #[async_trait]
    impl NexusActor for MockMediaActor {
        fn name(&self) -> &'static str {
            "mock_media_actor"
        }

        async fn run(&mut self, bus: EventBus) -> NexusResult<()> {
            let mut sub = bus.subscribe();
            while let Ok(event) = sub.recv().await {
                if let NexusEvent::HandoffOffered { .. } = event {
                    self.received_handoff_count += 1;
                    if self.received_handoff_count >= 1 {
                        break;
                    }
                }
            }
            Ok(())
        }
    }

    #[tokio::test]
    async fn test_event_bus_pub_sub() {
        let (bus, _rx) = EventBus::new(100, 100);
        let mut sub = bus.subscribe();

        let event = NexusEvent::PeerConnected(DeviceId::new_random());
        bus.publish(event);

        match sub.recv().await {
            Ok(NexusEvent::PeerConnected(_)) => {}
            _ => panic!("Expected PeerConnected event"),
        }
    }

    #[tokio::test]
    async fn test_actor_lifecycle() {
        let (bus, _rx) = EventBus::new(100, 100);
        let actor = MockMediaActor {
            received_handoff_count: 0,
        };

        ActorSupervisor::spawn_actor(actor, bus.clone());

        // Publish handoff event
        bus.publish(NexusEvent::HandoffOffered {
            from_peer: DeviceId::new_random(),
            session_id: "s1".into(),
            media_title: "Video 1".into(),
            media_url: "https://youtube.com".into(),
            position_ms: 1000,
        });

        tokio::time::sleep(tokio::time::Duration::from_millis(50)).await;
    }

    struct PanickingActor {
        panic_triggered: bool,
    }

    #[async_trait]
    impl NexusActor for PanickingActor {
        fn name(&self) -> &'static str {
            "panicking_actor"
        }

        async fn run(&mut self, _bus: EventBus) -> NexusResult<()> {
            if !self.panic_triggered {
                self.panic_triggered = true;
                panic!("Deliberate simulated hardware crash!");
            }
            tokio::time::sleep(tokio::time::Duration::from_secs(10)).await;
            Ok(())
        }
    }

    #[tokio::test]
    async fn test_actor_panic_isolation() {
        let (bus, _rx) = EventBus::new(100, 100);
        let actor = PanickingActor { panic_triggered: false };

        // Spawning panicking actor under supervisor MUST NOT crash the process
        ActorSupervisor::spawn_actor(actor, bus.clone());

        tokio::time::sleep(tokio::time::Duration::from_millis(50)).await;

        // Verify EventBus remains 100% operational
        let mut sub = bus.subscribe();
        bus.publish(NexusEvent::AudioStreamingActive(true));

        match sub.recv().await {
            Ok(NexusEvent::AudioStreamingActive(true)) => {}
            _ => panic!("EventBus must remain healthy after actor panic"),
        }
    }

    #[tokio::test]
    async fn test_high_concurrency_event_throughput() {
        let (bus, _rx) = EventBus::new(1000, 1000);
        let mut sub1 = bus.subscribe();
        let mut sub2 = bus.subscribe();

        let event_count = 500;
        let bus_pub = bus.clone();

        tokio::spawn(async move {
            for _ in 0..event_count {
                bus_pub.publish(NexusEvent::AudioStreamingActive(true));
            }
        });

        let mut received1 = 0;
        let mut received2 = 0;

        for _ in 0..event_count {
            if let Ok(NexusEvent::AudioStreamingActive(_)) = sub1.recv().await {
                received1 += 1;
            }
            if let Ok(NexusEvent::AudioStreamingActive(_)) = sub2.recv().await {
                received2 += 1;
            }
        }

        assert_eq!(received1, event_count);
        assert_eq!(received2, event_count);
    }
}
