use async_trait::async_trait;
use nexus_actor_system::{EventBus, NexusActor, NexusEvent};
use nexus_types::{DeviceId, ProximityMotion};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::info;

use crate::kalman::{KalmanRssiFilter, PresenceZone};

/// Proximity Plugin Actor
#[derive(Clone)]
pub struct ProximityPluginActor {
    pub device_id: DeviceId,
    filters: Arc<RwLock<HashMap<DeviceId, (KalmanRssiFilter, PresenceZone, ProximityMotion)>>>,
    auto_lock_enabled: Arc<AtomicBool>,
}

impl ProximityPluginActor {
    pub fn new(device_id: DeviceId) -> Self {
        Self {
            device_id,
            filters: Arc::new(RwLock::new(HashMap::new())),
            auto_lock_enabled: Arc::new(AtomicBool::new(false)),
        }
    }

    /// Local consent is volatile and off until the application loads its policy.
    pub fn set_auto_lock_enabled(&self, enabled: bool) {
        self.auto_lock_enabled.store(enabled, Ordering::SeqCst);
    }

    pub fn auto_lock_enabled(&self) -> bool {
        self.auto_lock_enabled.load(Ordering::SeqCst)
    }

    /// The OS action is executed only after local consent has been checked.
    /// None means consent denied; Some reports the operating system result.
    pub fn lock_if_enabled(&self, lock: impl FnOnce() -> bool) -> Option<bool> {
        self.auto_lock_enabled().then(lock)
    }

    /// Feeds an incoming BLE RSSI packet into the Kalman filter
    pub async fn process_ble_sample(
        &self,
        bus: &EventBus,
        peer_id: DeviceId,
        raw_rssi: f32,
        calibrated_tx_power: f32,
    ) -> (f32, PresenceZone, ProximityMotion) {
        let mut filters = self.filters.write().await;
        let entry = filters
            .entry(peer_id)
            .or_insert_with(|| (KalmanRssiFilter::default(), PresenceZone::Near, ProximityMotion::Stationary));

        let _filtered_rssi = entry.0.update(raw_rssi);
        let distance_m = entry.0.estimate_distance_meters(calibrated_tx_power, 2.2);
        let motion = entry.0.estimate_motion();

        let new_zone = if distance_m < 1.5 {
            PresenceZone::Immediate
        } else if distance_m < 3.5 {
            PresenceZone::Near
        } else {
            PresenceZone::Far
        };

        let prev_zone = entry.1;
        let prev_motion = entry.2;
        entry.1 = new_zone;
        entry.2 = motion;

        if prev_zone != new_zone {
            info!(
                "Peer {} proximity changed: {:?} -> {:?} (Est: {:.2}m, Motion: {:?})",
                peer_id, prev_zone, new_zone, distance_m, motion
            );
            bus.publish(NexusEvent::ProximityChanged {
                peer_id,
                estimated_meters: distance_m,
                is_near: new_zone != PresenceZone::Far,
            });

            // Zones describe signal telemetry only. The application owns the
            // selected peer, calibration, distance threshold and dwell policy.

        }

        if prev_motion != motion {
            info!("Peer {} motion trend changed: {:?} -> {:?}", peer_id, prev_motion, motion);
            bus.publish(NexusEvent::ProximityMotionChanged {
                peer_id,
                motion,
                distance_m,
            });
        }

        (distance_m, new_zone, motion)
    }
}

#[cfg(target_os = "windows")]
pub fn lock_workstation() -> bool {
    use windows_sys::Win32::System::Shutdown::LockWorkStation;
    unsafe { LockWorkStation() != 0 }
}

#[cfg(target_os = "linux")]
pub fn lock_workstation() -> bool {
    let res = std::process::Command::new("loginctl")
        .arg("lock-session")
        .status();
    if let Ok(status) = res {
        if status.success() {
            return true;
        }
    }
    let res = std::process::Command::new("xdg-screensaver")
        .arg("lock")
        .status();
    res.map(|s| s.success()).unwrap_or(false)
}

#[cfg(target_os = "macos")]
pub fn lock_workstation() -> bool {
    let res = std::process::Command::new("pmset")
        .arg("displaysleepnow")
        .status();
    res.map(|s| s.success()).unwrap_or(false)
}

#[cfg(all(not(target_os = "windows"), not(target_os = "linux"), not(target_os = "macos")))]
pub fn lock_workstation() -> bool {
    false
}

#[async_trait]
impl NexusActor for ProximityPluginActor {
    fn name(&self) -> &'static str {
        "nexus-plugin-proximity"
    }

    async fn run(&mut self, _bus: EventBus) -> nexus_types::NexusResult<()> {
        tokio::time::sleep(tokio::time::Duration::from_secs(3600 * 24)).await;
        Ok(())
    }
}
