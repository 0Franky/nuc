pub mod actor;
pub mod kalman;

pub use actor::{lock_workstation, ProximityPluginActor};
pub use kalman::{KalmanRssiFilter, PresenceZone};

#[cfg(test)]
mod tests {
    use super::*;
    use nexus_types::ProximityMotion;

    #[test]
    fn test_kalman_rssi_filter_convergence() {
        let mut filter = KalmanRssiFilter::new(0.05, 1.5);

        // Feed noisy measurements centered around -50 dBm
        let samples = [-55.0, -48.0, -52.0, -49.0, -51.0, -50.0];
        let mut final_estimate = 0.0;

        for &s in &samples {
            final_estimate = filter.update(s);
        }

        assert!(
            (final_estimate - (-50.0)).abs() < 2.0,
            "Kalman filter should converge near ground truth -50 dBm, got {}",
            final_estimate
        );
    }

    #[test]
    fn test_distance_estimation() {
        let mut filter = KalmanRssiFilter::new(0.05, 1.5);
        filter.update(-59.0); // Exact 1-meter RSSI

        let d = filter.estimate_distance_meters(-59.0, 2.0);
        assert!(
            (d - 1.0).abs() < 0.1,
            "RSSI equal to TxPower at 1m must yield approx 1.0 meter, got {}",
            d
        );
    }

    #[test]
    fn test_proximity_motion_estimation() {
        let mut filter = KalmanRssiFilter::new(0.05, 1.5);

        // Approaching pattern (RSSI increasing)
        filter.update(-75.0);
        filter.update(-70.0);
        filter.update(-65.0);
        assert_eq!(filter.estimate_motion(), ProximityMotion::Approaching);

        // Moving away pattern (RSSI dropping)
        let mut filter_away = KalmanRssiFilter::new(0.05, 1.5);
        filter_away.update(-55.0);
        filter_away.update(-62.0);
        filter_away.update(-72.0);
        assert_eq!(filter_away.estimate_motion(), ProximityMotion::MovingAway);
    }

    #[test]
    fn test_kalman_filter_rejects_single_noisy_glitch() {
        let mut filter = KalmanRssiFilter::new(0.05, 2.5);

        // Steady state around -60
        for _ in 0..10 {
            filter.update(-60.0);
        }

        // Single extreme anomaly / packet drop
        let filtered = filter.update(-95.0);

        // Filter must smooth this out significantly instead of jumping immediately to -95
        assert!(
            filtered > -75.0,
            "Kalman filter must reject sudden transient drop: got {}",
            filtered
        );
    }
}
