pub mod actor;
pub mod ballistics;
pub mod injector;
pub mod universal_control;

pub use actor::InputPluginActor;
pub use ballistics::{GyroLaserFilter, TouchpadBallistics};
pub use injector::NativeInputInjector;
pub use universal_control::{SpatialEdgeHop, UniversalControlEngine};

#[cfg(test)]
mod tests {
    use super::*;
    use nexus_protocol::MouseButton;
    use nexus_types::{DeviceId, ScreenGeometry, SpatialArrangement};

    #[test]
    fn test_touchpad_ballistics() {
        let ballistics = TouchpadBallistics::default();

        // Slow movement (1px) -> multiplier near 1.0
        let (dx_slow, _) = ballistics.calculate_delta(1.0, 0.0);
        assert_eq!(dx_slow, 1);

        // Fast flick (50px) -> accelerated multiplier applied
        let (dx_fast, _) = ballistics.calculate_delta(50.0, 0.0);
        assert!(dx_fast > 100, "Fast flick must produce accelerated delta");
    }

    #[test]
    fn test_gyro_laser_filter_smoothing() {
        let mut filter = GyroLaserFilter::default();

        // Feed noisy jitter
        let (p1, _) = filter.update(10.0, 0.0);
        let (p2, _) = filter.update(0.0, 0.0);

        assert!(p1 < 10.0, "Filter must smooth sudden impulse");
        assert!(p2 > 0.0, "Filter must retain residual motion for fluid deceleration");
    }

    #[test]
    fn test_spatial_edge_hop_transition() {
        let mut engine = UniversalControlEngine::new(ScreenGeometry {
            width: 1920,
            height: 1080,
            scale_factor: 1.0,
        });

        let target_peer = DeviceId::new_random();
        let target_geo = ScreenGeometry {
            width: 1920,
            height: 1080,
            scale_factor: 1.0,
        };
        engine.set_peer_arrangement(target_peer, SpatialArrangement::Left, target_geo);

        // Cursor at (100, 500) -> inside local screen
        assert_eq!(engine.check_edge_hop(100, 500), None);

        // Cursor reaches x=0 -> edge hop to Left peer
        let hop = engine.check_edge_hop(0, 540).expect("Must trigger edge hop");
        assert_eq!(hop.target_device_id, target_peer);
        assert_eq!(hop.edge, SpatialArrangement::Left);

        let (entry_x, entry_y) = UniversalControlEngine::calculate_entry_coordinates(
            hop.edge,
            &target_geo,
            hop.normalized_entry_pos,
        );
        assert_eq!(entry_x, 1918); // Right boundary of left screen
        assert_eq!(entry_y, 540);
    }

    #[test]
    fn test_spatial_edge_hop_right() {
        let mut engine = UniversalControlEngine::new(ScreenGeometry {
            width: 1920,
            height: 1080,
            scale_factor: 1.0,
        });

        let target_peer = DeviceId::new_random();
        let target_geo = ScreenGeometry {
            width: 1080,
            height: 2400,
            scale_factor: 2.0,
        };
        engine.set_peer_arrangement(target_peer, SpatialArrangement::Right, target_geo);

        let hop = engine.check_edge_hop(1920, 1080).expect("Must trigger edge hop right");
        assert_eq!(hop.edge, SpatialArrangement::Right);

        let (entry_x, entry_y) = UniversalControlEngine::calculate_entry_coordinates(
            hop.edge,
            &target_geo,
            hop.normalized_entry_pos,
        );
        assert_eq!(entry_x, 2);
        assert_eq!(entry_y, 2400);
    }

    #[test]
    fn test_auto_determine_ble_arrangement() {
        let mut engine = UniversalControlEngine::new(ScreenGeometry::default());
        let phone_id = DeviceId::new_random();
        let pc_id = DeviceId::new_random();

        // Phone at 0.8m -> Right
        let phone_arr = engine.auto_determine_ble_arrangement(
            phone_id,
            0.8,
            false,
            ScreenGeometry::default(),
        );
        assert_eq!(phone_arr, SpatialArrangement::Right);

        // Laptop at 1.2m -> Left
        let pc_arr = engine.auto_determine_ble_arrangement(
            pc_id,
            1.2,
            true,
            ScreenGeometry::default(),
        );
        assert_eq!(pc_arr, SpatialArrangement::Left);

        // Out of desk area (> 1.8m) -> None
        let distant_id = DeviceId::new_random();
        let dist_arr = engine.auto_determine_ble_arrangement(
            distant_id,
            2.5,
            true,
            ScreenGeometry::default(),
        );
        assert_eq!(dist_arr, SpatialArrangement::None);
    }

    #[test]
    fn test_keyboard_injection_and_combos() {
        // Test key conversion
        assert_eq!(NativeInputInjector::key_to_vk("ENTER"), 0x0D);
        assert_eq!(NativeInputInjector::key_to_vk("TAB"), 0x09);
        assert_eq!(NativeInputInjector::key_to_vk("A"), 0x41);
        assert_eq!(NativeInputInjector::key_to_vk("F5"), 0x74);

        // Test non-crashing injection calls
        let _ = NativeInputInjector::inject_mouse_button(MouseButton::Left, true);
        let _ = NativeInputInjector::inject_mouse_button(MouseButton::Left, false);
        let _ = NativeInputInjector::inject_media_key("PLAY");
    }
}
