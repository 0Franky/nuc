/// Ballistic Acceleration Model for Trackpad Input
#[derive(Clone, Debug)]
pub struct TouchpadBallistics {
    pub base_speed: f32,
    pub acceleration_factor: f32,
    pub max_multiplier: f32,
}

impl Default for TouchpadBallistics {
    fn default() -> Self {
        Self {
            base_speed: 1.0,
            acceleration_factor: 0.05,
            max_multiplier: 3.5,
        }
    }
}

impl TouchpadBallistics {
    /// Calculates accelerated relative mouse delta (dx, dy)
    pub fn calculate_delta(&self, raw_dx: f32, raw_dy: f32) -> (i32, i32) {
        let magnitude = (raw_dx * raw_dx + raw_dy * raw_dy).sqrt();
        let multiplier = (1.0 + magnitude * self.acceleration_factor)
            .min(self.max_multiplier)
            * self.base_speed;

        let final_dx = (raw_dx * multiplier).round() as i32;
        let final_dy = (raw_dy * multiplier).round() as i32;
        (final_dx, final_dy)
    }
}

/// Dynamic EMA Low-Pass Filter for Smoothing Gyroscope Laser Movements
#[derive(Clone, Debug)]
pub struct GyroLaserFilter {
    pub alpha: f32,
    pub last_pitch: f32,
    pub last_yaw: f32,
}

impl Default for GyroLaserFilter {
    fn default() -> Self {
        Self {
            alpha: 0.35,
            last_pitch: 0.0,
            last_yaw: 0.0,
        }
    }
}

impl GyroLaserFilter {
    pub fn update(&mut self, pitch_delta: f32, yaw_delta: f32) -> (f32, f32) {
        self.last_pitch = self.alpha * pitch_delta + (1.0 - self.alpha) * self.last_pitch;
        self.last_yaw = self.alpha * yaw_delta + (1.0 - self.alpha) * self.last_yaw;
        (self.last_pitch, self.last_yaw)
    }
}
