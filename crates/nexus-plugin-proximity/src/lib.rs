use async_trait::async_trait;
use nexus_actor_system::{EventBus, NexusActor, NexusEvent};
use nexus_types::{DeviceId, ProximityMotion};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::info;

/// 1D Kalman Filter for Smoothing Noisy BLE RSSI Measurements and Velocity Estimation
#[derive(Clone, Debug)]
pub struct KalmanRssiFilter {
    pub process_noise_q: f32,
    pub measurement_noise_r: f32,
    pub state_x: f32,       // Estimated filtered RSSI
    pub error_cov_p: f32,   // Estimation error covariance
    pub is_initialized: bool,
    pub history: Vec<f32>,  // Recent filtered RSSI window
}

impl KalmanRssiFilter {
    pub fn new(q: f32, r: f32) -> Self {
        Self {
            process_noise_q: q,
            measurement_noise_r: r,
            state_x: -60.0,
            error_cov_p: 1.0,
            is_initialized: false,
            history: Vec::with_capacity(8),
        }
    }

    /// Updates the filter with a new raw RSSI sample
    pub fn update(&mut self, raw_rssi: f32) -> f32 {
        if !self.is_initialized {
            self.state_x = raw_rssi;
            self.is_initialized = true;
            self.history.push(raw_rssi);
            return self.state_x;
        }

        // 1. Time Update (Predict)
        let p_pred = self.error_cov_p + self.process_noise_q;

        // 2. Measurement Update (Correct)
        let kalman_gain = p_pred / (p_pred + self.measurement_noise_r);
        self.state_x = self.state_x + kalman_gain * (raw_rssi - self.state_x);
        self.error_cov_p = (1.0 - kalman_gain) * p_pred;

        if self.history.len() >= 6 {
            self.history.remove(0);
        }
        self.history.push(self.state_x);

        self.state_x
    }

    /// Calculates the motion trend (Approaching, MovingAway, Stationary)
    pub fn estimate_motion(&self) -> ProximityMotion {
        if self.history.len() < 3 {
            return ProximityMotion::Stationary;
        }
        let oldest = self.history[0];
        let newest = *self.history.last().unwrap_or(&oldest);
        let delta = newest - oldest;

        if delta > 2.0 {
            // Signal getting significantly stronger -> Approaching
            ProximityMotion::Approaching
        } else if delta < -2.0 {
            // Signal getting significantly weaker -> Moving Away
            ProximityMotion::MovingAway
        } else {
            ProximityMotion::Stationary
        }
    }

    /// Converts filtered RSSI to estimated distance in meters
    pub fn estimate_distance_meters(&self, tx_power_at_1m: f32, path_loss_exponent: f32) -> f32 {
        let ratio = (tx_power_at_1m - self.state_x) / (10.0 * path_loss_exponent);
        10.0f32.powf(ratio)
    }
}

impl Default for KalmanRssiFilter {
    fn default() -> Self {
        Self::new(0.08, 2.5)
    }
}

/// Distance Zone
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PresenceZone {
    Immediate, // < 1.5 meters (at desk)
    Near,      // 1.5 - 3.5 meters (in room)
    Far,       // > 4.0 meters (walked away)
}

/// Proximity Plugin Actor
#[derive(Clone)]
pub struct ProximityPluginActor {
    pub device_id: DeviceId,
    filters: Arc<RwLock<HashMap<DeviceId, (KalmanRssiFilter, PresenceZone, ProximityMotion)>>>,
    pub auto_lock_enabled: Arc<RwLock<bool>>,
}

impl ProximityPluginActor {
    pub fn new(device_id: DeviceId) -> Self {
        Self {
            device_id,
            filters: Arc::new(RwLock::new(HashMap::new())),
            auto_lock_enabled: Arc::new(RwLock::new(true)),
        }
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

            // If user walked away into Far zone and auto-lock is enabled
            if new_zone == PresenceZone::Far && *self.auto_lock_enabled.read().await {
                info!("Triggering Walk-Away Auto-Lock for workstation...");
                lock_workstation();
            }
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
    // Only lock physical Windows session if explicitly enabled in production via env var
    if std::env::var("NEXUS_ENABLE_REAL_SCREEN_LOCK").unwrap_or_default() == "1" {
        use windows_sys::Win32::System::Shutdown::LockWorkStation;
        unsafe { LockWorkStation() != 0 }
    } else {
        tracing::info!("🔒 [SIMULATED] LockWorkStation called (real screen lock neutralized for developer safety).");
        true
    }
}

#[cfg(not(target_os = "windows"))]
pub fn lock_workstation() -> bool {
    true
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_kalman_rssi_filter_convergence() {
        let mut filter = KalmanRssiFilter::new(0.05, 1.5);

        // Feed noisy measurements centered around -50 dBm
        let samples = [-55.0, -48.0, -52.0, -49.0, -51.0, -50.0];
        let mut final_estimate = 0.0;

        for &s in &samples {
            final_estimate = filter.update(s);
        }

        // Filtered estimate should be very close to -50 dBm
        assert!((final_estimate - (-50.0)).abs() < 2.0);
    }

    #[test]
    fn test_distance_estimation() {
        let mut filter = KalmanRssiFilter::default();
        filter.update(-59.0); // Exactly 1 meter if TxPower is -59
        let distance = filter.estimate_distance_meters(-59.0, 2.0);
        assert!((distance - 1.0).abs() < 0.1);
    }

    #[test]
    fn test_kalman_filter_rejects_single_noisy_glitch() {
        let mut filter = KalmanRssiFilter::new(0.02, 3.0);

        // Stabilize at -50 dBm
        for _ in 0..10 {
            filter.update(-50.0);
        }

        // Single extreme outlier glitch (-95 dBm)
        let filtered_glitch = filter.update(-95.0);

        // Filter MUST smooth out the spike rather than jumping straight to -95
        assert!(filtered_glitch > -65.0, "Kalman filter must suppress single-sample spike");
    }

    #[test]
    fn test_proximity_motion_estimation() {
        let mut filter = KalmanRssiFilter::new(0.1, 1.0);

        // 1. Simulate approaching (RSSI increases from -80 to -45)
        for &s in &[-80.0, -72.0, -65.0, -55.0, -45.0] {
            filter.update(s);
        }
        assert_eq!(filter.estimate_motion(), ProximityMotion::Approaching);

        // 2. Simulate moving away (RSSI decreases from -45 to -85)
        for &s in &[-55.0, -68.0, -75.0, -85.0, -90.0] {
            filter.update(s);
        }
        assert_eq!(filter.estimate_motion(), ProximityMotion::MovingAway);
    }
}
