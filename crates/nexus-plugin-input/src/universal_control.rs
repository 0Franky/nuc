use nexus_types::{DeviceId, ScreenGeometry, SpatialArrangement};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Screen Edge Hop Event for Universal Control
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SpatialEdgeHop {
    pub target_device_id: DeviceId,
    pub edge: SpatialArrangement,
    pub normalized_entry_pos: f32, // 0.0 to 1.0 along the crossed axis
}

/// Universal Control Spatial Topology Engine
#[derive(Clone, Debug)]
pub struct UniversalControlEngine {
    pub local_geometry: ScreenGeometry,
    pub peers_topology: HashMap<DeviceId, (SpatialArrangement, ScreenGeometry)>,
    pub is_controlling_remote: bool,
    pub active_remote_peer: Option<DeviceId>,
}

impl UniversalControlEngine {
    pub fn new(local_geometry: ScreenGeometry) -> Self {
        Self {
            local_geometry,
            peers_topology: HashMap::new(),
            is_controlling_remote: false,
            active_remote_peer: None,
        }
    }

    pub fn set_peer_arrangement(
        &mut self,
        peer_id: DeviceId,
        arrangement: SpatialArrangement,
        geometry: ScreenGeometry,
    ) {
        self.peers_topology.insert(peer_id, (arrangement, geometry));
    }

    /// Auto-determines peer spatial arrangement from BLE RSSI distance and device hints
    pub fn auto_determine_ble_arrangement(
        &mut self,
        peer_id: DeviceId,
        distance_meters: f32,
        is_laptop_or_desktop: bool,
        geometry: ScreenGeometry,
    ) -> SpatialArrangement {
        if distance_meters <= 1.8 {
            // In immediate desk area
            let arrangement = if is_laptop_or_desktop {
                SpatialArrangement::Left // Secondary PC / Laptop on desk left
            } else {
                SpatialArrangement::Right // Mobile phone on desk right
            };
            self.peers_topology.insert(peer_id, (arrangement, geometry));
            arrangement
        } else {
            SpatialArrangement::None
        }
    }

    /// Checks if a cursor coordinate (x, y) on the local screen has crossed a spatial boundary
    pub fn check_edge_hop(&self, cursor_x: i32, cursor_y: i32) -> Option<SpatialEdgeHop> {
        let w = self.local_geometry.width as i32;
        let h = self.local_geometry.height as i32;

        for (peer_id, (arrangement, _target_geo)) in &self.peers_topology {
            match arrangement {
                SpatialArrangement::Left if cursor_x <= 0 => {
                    let norm_y = (cursor_y as f32 / h.max(1) as f32).clamp(0.0, 1.0);
                    return Some(SpatialEdgeHop {
                        target_device_id: *peer_id,
                        edge: SpatialArrangement::Left,
                        normalized_entry_pos: norm_y,
                    });
                }
                SpatialArrangement::Right if cursor_x >= w - 1 => {
                    let norm_y = (cursor_y as f32 / h.max(1) as f32).clamp(0.0, 1.0);
                    return Some(SpatialEdgeHop {
                        target_device_id: *peer_id,
                        edge: SpatialArrangement::Right,
                        normalized_entry_pos: norm_y,
                    });
                }
                SpatialArrangement::Above if cursor_y <= 0 => {
                    let norm_x = (cursor_x as f32 / w.max(1) as f32).clamp(0.0, 1.0);
                    return Some(SpatialEdgeHop {
                        target_device_id: *peer_id,
                        edge: SpatialArrangement::Above,
                        normalized_entry_pos: norm_x,
                    });
                }
                SpatialArrangement::Below if cursor_y >= h - 1 => {
                    let norm_x = (cursor_x as f32 / w.max(1) as f32).clamp(0.0, 1.0);
                    return Some(SpatialEdgeHop {
                        target_device_id: *peer_id,
                        edge: SpatialArrangement::Below,
                        normalized_entry_pos: norm_x,
                    });
                }
                _ => {}
            }
        }
        None
    }

    /// Maps normalized entry position to target device initial coordinates
    pub fn calculate_entry_coordinates(
        edge: SpatialArrangement,
        target_geo: &ScreenGeometry,
        normalized_pos: f32,
    ) -> (i32, i32) {
        let tw = target_geo.width as i32;
        let th = target_geo.height as i32;

        match edge {
            SpatialArrangement::Left => (tw - 2, (normalized_pos * th as f32).round() as i32),
            SpatialArrangement::Right => (2, (normalized_pos * th as f32).round() as i32),
            SpatialArrangement::Above => ((normalized_pos * tw as f32).round() as i32, th - 2),
            SpatialArrangement::Below => ((normalized_pos * tw as f32).round() as i32, 2),
            SpatialArrangement::None => (tw / 2, th / 2),
        }
    }
}
