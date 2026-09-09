use nexus_types::ProximityMotion;

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
