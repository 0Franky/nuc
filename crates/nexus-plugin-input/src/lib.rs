use async_trait::async_trait;
use nexus_actor_system::{EventBus, NexusActor, NexusCommand};
use nexus_protocol::{InputPayload, MouseButton, NexusPacket, PacketPayload};
use nexus_types::{DeviceId, NexusError, NexusResult, ScreenGeometry, SpatialArrangement};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

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

    pub fn set_peer_arrangement(&mut self, peer_id: DeviceId, arrangement: SpatialArrangement, geometry: ScreenGeometry) {
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
    pub fn calculate_entry_coordinates(edge: SpatialArrangement, target_geo: &ScreenGeometry, normalized_pos: f32) -> (i32, i32) {
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

/// Native Input Injector calling low-level OS APIs (Win32 SendInput / uinput)
pub struct NativeInputInjector;

impl NativeInputInjector {
    #[cfg(target_os = "windows")]
    pub fn inject_mouse_move_relative(dx: i32, dy: i32) -> NexusResult<()> {
        use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
            SendInput, INPUT, INPUT_0, INPUT_MOUSE, MOUSEEVENTF_MOVE, MOUSEINPUT,
        };

        let input = INPUT {
            r#type: INPUT_MOUSE,
            Anonymous: INPUT_0 {
                mi: MOUSEINPUT {
                    dx,
                    dy,
                    mouseData: 0,
                    dwFlags: MOUSEEVENTF_MOVE,
                    time: 0,
                    dwExtraInfo: 0,
                },
            },
        };

        unsafe {
            let sent = SendInput(1, &input, std::mem::size_of::<INPUT>() as i32);
            if sent == 1 {
                Ok(())
            } else {
                Err(NexusError::Plugin {
                    plugin: "input.injector",
                    message: "SendInput mouse move failed".into(),
                })
            }
        }
    }

    #[cfg(not(target_os = "windows"))]
    pub fn inject_mouse_move_relative(dx: i32, dy: i32) -> NexusResult<()> {
        debug!("Mock mouse move relative: ({}, {})", dx, dy);
        Ok(())
    }

    #[cfg(target_os = "windows")]
    pub fn inject_mouse_move_absolute(x: i32, y: i32, screen_width: i32, screen_height: i32) -> NexusResult<()> {
        use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
            SendInput, INPUT, INPUT_0, INPUT_MOUSE, MOUSEEVENTF_ABSOLUTE, MOUSEEVENTF_MOVE, MOUSEINPUT,
        };

        let norm_x = ((x as f32 / screen_width.max(1) as f32) * 65535.0) as i32;
        let norm_y = ((y as f32 / screen_height.max(1) as f32) * 65535.0) as i32;

        let input = INPUT {
            r#type: INPUT_MOUSE,
            Anonymous: INPUT_0 {
                mi: MOUSEINPUT {
                    dx: norm_x,
                    dy: norm_y,
                    mouseData: 0,
                    dwFlags: MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE,
                    time: 0,
                    dwExtraInfo: 0,
                },
            },
        };

        unsafe {
            let sent = SendInput(1, &input, std::mem::size_of::<INPUT>() as i32);
            if sent == 1 {
                Ok(())
            } else {
                Err(NexusError::Plugin {
                    plugin: "input.injector",
                    message: "SendInput absolute move failed".into(),
                })
            }
        }
    }

    #[cfg(not(target_os = "windows"))]
    pub fn inject_mouse_move_absolute(_x: i32, _y: i32, _w: i32, _h: i32) -> NexusResult<()> {
        Ok(())
    }

    #[cfg(target_os = "windows")]
    pub fn inject_mouse_button(button: MouseButton, is_down: bool) -> NexusResult<()> {
        use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
            SendInput, INPUT, INPUT_0, INPUT_MOUSE, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP,
            MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP, MOUSEEVENTF_RIGHTDOWN,
            MOUSEEVENTF_RIGHTUP, MOUSEINPUT,
        };

        let flags = match (button, is_down) {
            (MouseButton::Left, true) => MOUSEEVENTF_LEFTDOWN,
            (MouseButton::Left, false) => MOUSEEVENTF_LEFTUP,
            (MouseButton::Right, true) => MOUSEEVENTF_RIGHTDOWN,
            (MouseButton::Right, false) => MOUSEEVENTF_RIGHTUP,
            (MouseButton::Middle, true) => MOUSEEVENTF_MIDDLEDOWN,
            (MouseButton::Middle, false) => MOUSEEVENTF_MIDDLEUP,
        };

        let input = INPUT {
            r#type: INPUT_MOUSE,
            Anonymous: INPUT_0 {
                mi: MOUSEINPUT {
                    dx: 0,
                    dy: 0,
                    mouseData: 0,
                    dwFlags: flags,
                    time: 0,
                    dwExtraInfo: 0,
                },
            },
        };

        unsafe {
            let sent = SendInput(1, &input, std::mem::size_of::<INPUT>() as i32);
            if sent == 1 {
                Ok(())
            } else {
                Err(NexusError::Plugin {
                    plugin: "input.injector",
                    message: "SendInput button event failed".into(),
                })
            }
        }
    }

    #[cfg(target_os = "windows")]
    pub fn inject_mouse_click(button: MouseButton) -> NexusResult<()> {
        use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
            SendInput, INPUT, INPUT_0, INPUT_MOUSE, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP,
            MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP, MOUSEEVENTF_RIGHTDOWN,
            MOUSEEVENTF_RIGHTUP, MOUSEINPUT,
        };

        let (down_flag, up_flag) = match button {
            MouseButton::Left => (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP),
            MouseButton::Right => (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP),
            MouseButton::Middle => (MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP),
        };

        let input_down = INPUT {
            r#type: INPUT_MOUSE,
            Anonymous: INPUT_0 {
                mi: MOUSEINPUT {
                    dx: 0,
                    dy: 0,
                    mouseData: 0,
                    dwFlags: down_flag,
                    time: 0,
                    dwExtraInfo: 0,
                },
            },
        };

        let input_up = INPUT {
            r#type: INPUT_MOUSE,
            Anonymous: INPUT_0 {
                mi: MOUSEINPUT {
                    dx: 0,
                    dy: 0,
                    mouseData: 0,
                    dwFlags: up_flag,
                    time: 0,
                    dwExtraInfo: 0,
                },
            },
        };

        unsafe {
            let _ = SendInput(1, &input_down, std::mem::size_of::<INPUT>() as i32);
            std::thread::sleep(std::time::Duration::from_millis(20));
            let sent = SendInput(1, &input_up, std::mem::size_of::<INPUT>() as i32);
            if sent == 1 {
                Ok(())
            } else {
                Err(NexusError::Plugin {
                    plugin: "input.injector",
                    message: "SendInput mouse click failed".into(),
                })
            }
        }
    }

    #[cfg(not(target_os = "windows"))]
    pub fn inject_mouse_button(button: MouseButton, is_down: bool) -> NexusResult<()> {
        debug!("Mock mouse button: {:?} down: {}", button, is_down);
        Ok(())
    }

    #[cfg(not(target_os = "windows"))]
    pub fn inject_mouse_click(_button: MouseButton) -> NexusResult<()> {
        Ok(())
    }

    #[cfg(target_os = "windows")]
    pub fn inject_mouse_wheel(delta_y: i32) -> NexusResult<()> {
        use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
            SendInput, INPUT, INPUT_0, INPUT_MOUSE, MOUSEEVENTF_WHEEL, MOUSEINPUT,
        };

        let input = INPUT {
            r#type: INPUT_MOUSE,
            Anonymous: INPUT_0 {
                mi: MOUSEINPUT {
                    dx: 0,
                    dy: 0,
                    mouseData: (delta_y * 120) as u32,
                    dwFlags: MOUSEEVENTF_WHEEL,
                    time: 0,
                    dwExtraInfo: 0,
                },
            },
        };

        unsafe {
            let sent = SendInput(1, &input, std::mem::size_of::<INPUT>() as i32);
            if sent == 1 {
                Ok(())
            } else {
                Err(NexusError::Plugin {
                    plugin: "input.injector",
                    message: "SendInput mouse wheel failed".into(),
                })
            }
        }
    }

    #[cfg(not(target_os = "windows"))]
    pub fn inject_mouse_wheel(_delta_y: i32) -> NexusResult<()> {
        Ok(())
    }

    #[cfg(target_os = "windows")]
    pub fn inject_media_key(action: &str) -> NexusResult<()> {
        use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
            SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP,
        };

        let vk: u16 = match action.to_uppercase().as_str() {
            "PLAY" | "PAUSE" | "PLAY_PAUSE" | "TOGGLE" => 0xB3, // VK_MEDIA_PLAY_PAUSE
            "STOP" => 0xB2,                                     // VK_MEDIA_STOP
            "NEXT" | "NEXT_TRACK" => 0xB0,                      // VK_MEDIA_NEXT_TRACK
            "PREV" | "PREV_TRACK" => 0xB1,                      // VK_MEDIA_PREV_TRACK
            "MUTE" => 0xAD,                                     // VK_VOLUME_MUTE
            "VOL_DOWN" => 0xAE,                                 // VK_VOLUME_DOWN
            "VOL_UP" => 0xAF,                                   // VK_VOLUME_UP
            _ => 0xB3,
        };

        let mut inputs = [
            INPUT {
                r#type: INPUT_KEYBOARD,
                Anonymous: INPUT_0 {
                    ki: KEYBDINPUT {
                        wVk: vk,
                        wScan: 0,
                        dwFlags: 0,
                        time: 0,
                        dwExtraInfo: 0,
                    },
                },
            },
            INPUT {
                r#type: INPUT_KEYBOARD,
                Anonymous: INPUT_0 {
                    ki: KEYBDINPUT {
                        wVk: vk,
                        wScan: 0,
                        dwFlags: KEYEVENTF_KEYUP,
                        time: 0,
                        dwExtraInfo: 0,
                    },
                },
            },
        ];

        unsafe {
            SendInput(2, inputs.as_mut_ptr(), std::mem::size_of::<INPUT>() as i32);
        }
        Ok(())
    }

    #[cfg(target_os = "windows")]
    pub fn key_to_vk(key: &str) -> u16 {
        match key.to_uppercase().trim() {
            "ESC" | "ESCAPE" => 0x1B,
            "TAB" => 0x09,
            "CTRL" | "CONTROL" | "LCTRL" => 0x11,
            "RCTRL" => 0xA3,
            "ALT" | "MENU" | "LALT" => 0x12,
            "RALT" => 0xA5,
            "WIN" | "WINDOWS" | "LWIN" | "START" => 0x5B,
            "RWIN" => 0x5C,
            "ENTER" | "RETURN" => 0x0D,
            "BACK" | "BACKSPACE" => 0x08,
            "SPACE" => 0x20,
            "DEL" | "DELETE" => 0x2E,
            "INSERT" => 0x2D,
            "HOME" => 0x24,
            "END" => 0x23,
            "PAGEUP" | "PGUP" => 0x21,
            "PAGEDOWN" | "PGDN" => 0x22,
            "UP" | "ARROWUP" => 0x26,
            "DOWN" | "ARROWDOWN" => 0x28,
            "LEFT" | "ARROWLEFT" => 0x25,
            "RIGHT" | "ARROWRIGHT" => 0x27,
            "CAPSLOCK" | "CAPS" => 0x14,
            "PRINTSCREEN" | "PRTSC" | "SNAPSHOT" => 0x2C,
            "A" => 0x41, "B" => 0x42, "C" => 0x43, "D" => 0x44, "E" => 0x45,
            "F" => 0x46, "G" => 0x47, "H" => 0x48, "I" => 0x49, "J" => 0x4A,
            "K" => 0x4B, "L" => 0x4C, "M" => 0x4D, "N" => 0x4E, "O" => 0x4F,
            "P" => 0x50, "Q" => 0x51, "R" => 0x52, "S" => 0x53, "T" => 0x54,
            "U" => 0x55, "V" => 0x56, "W" => 0x57, "X" => 0x58, "Y" => 0x59,
            "Z" => 0x5A,
            "0" => 0x30, "1" => 0x31, "2" => 0x32, "3" => 0x33, "4" => 0x34,
            "5" => 0x35, "6" => 0x36, "7" => 0x37, "8" => 0x38, "9" => 0x39,
            "F1" => 0x70, "F2" => 0x71, "F3" => 0x72, "F4" => 0x73,
            "F5" => 0x74, "F6" => 0x75, "F7" => 0x76, "F8" => 0x77,
            "F9" => 0x78, "F10" => 0x79, "F11" => 0x7A, "F12" => 0x7B,
            _ => 0,
        }
    }

    #[cfg(target_os = "windows")]
    pub fn inject_keyboard_key(key: &str, is_down: Option<bool>) -> NexusResult<()> {
        use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
            SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP,
        };

        let vk = Self::key_to_vk(key);
        if vk == 0 {
            return Err(NexusError::Plugin {
                plugin: "input.injector",
                message: format!("Unknown virtual key: {}", key),
            });
        }

        match is_down {
            Some(true) => {
                let mut input = INPUT {
                    r#type: INPUT_KEYBOARD,
                    Anonymous: INPUT_0 {
                        ki: KEYBDINPUT {
                            wVk: vk,
                            wScan: 0,
                            dwFlags: 0,
                            time: 0,
                            dwExtraInfo: 0,
                        },
                    },
                };
                unsafe { SendInput(1, &mut input, std::mem::size_of::<INPUT>() as i32); }
            }
            Some(false) => {
                let mut input = INPUT {
                    r#type: INPUT_KEYBOARD,
                    Anonymous: INPUT_0 {
                        ki: KEYBDINPUT {
                            wVk: vk,
                            wScan: 0,
                            dwFlags: KEYEVENTF_KEYUP,
                            time: 0,
                            dwExtraInfo: 0,
                        },
                    },
                };
                unsafe { SendInput(1, &mut input, std::mem::size_of::<INPUT>() as i32); }
            }
            None => {
                let mut inputs = [
                    INPUT {
                        r#type: INPUT_KEYBOARD,
                        Anonymous: INPUT_0 {
                            ki: KEYBDINPUT {
                                wVk: vk,
                                wScan: 0,
                                dwFlags: 0,
                                time: 0,
                                dwExtraInfo: 0,
                            },
                        },
                    },
                    INPUT {
                        r#type: INPUT_KEYBOARD,
                        Anonymous: INPUT_0 {
                            ki: KEYBDINPUT {
                                wVk: vk,
                                wScan: 0,
                                dwFlags: KEYEVENTF_KEYUP,
                                time: 0,
                                dwExtraInfo: 0,
                            },
                        },
                    },
                ];
                unsafe { SendInput(2, inputs.as_mut_ptr(), std::mem::size_of::<INPUT>() as i32); }
            }
        }
        Ok(())
    }

    #[cfg(target_os = "windows")]
    pub fn inject_keyboard_combo(keys: &[&str]) -> NexusResult<()> {
        use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
            SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP,
        };

        if keys.is_empty() {
            return Ok(());
        }

        let mut vks = Vec::new();
        for k in keys {
            let vk = Self::key_to_vk(k);
            if vk != 0 {
                vks.push(vk);
            }
        }

        for &vk in &vks {
            let mut input = INPUT {
                r#type: INPUT_KEYBOARD,
                Anonymous: INPUT_0 {
                    ki: KEYBDINPUT {
                        wVk: vk,
                        wScan: 0,
                        dwFlags: 0,
                        time: 0,
                        dwExtraInfo: 0,
                    },
                },
            };
            unsafe { SendInput(1, &mut input, std::mem::size_of::<INPUT>() as i32); }
        }

        std::thread::sleep(std::time::Duration::from_millis(20));

        for &vk in vks.iter().rev() {
            let mut input = INPUT {
                r#type: INPUT_KEYBOARD,
                Anonymous: INPUT_0 {
                    ki: KEYBDINPUT {
                        wVk: vk,
                        wScan: 0,
                        dwFlags: KEYEVENTF_KEYUP,
                        time: 0,
                        dwExtraInfo: 0,
                    },
                },
            };
            unsafe { SendInput(1, &mut input, std::mem::size_of::<INPUT>() as i32); }
        }

        Ok(())
    }

    #[cfg(target_os = "windows")]
    pub fn inject_unicode_text(text: &str) -> NexusResult<()> {
        use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
            SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP, KEYEVENTF_UNICODE,
        };

        for ch in text.encode_utf16() {
            let mut inputs = [
                INPUT {
                    r#type: INPUT_KEYBOARD,
                    Anonymous: INPUT_0 {
                        ki: KEYBDINPUT {
                            wVk: 0,
                            wScan: ch,
                            dwFlags: KEYEVENTF_UNICODE,
                            time: 0,
                            dwExtraInfo: 0,
                        },
                    },
                },
                INPUT {
                    r#type: INPUT_KEYBOARD,
                    Anonymous: INPUT_0 {
                        ki: KEYBDINPUT {
                            wVk: 0,
                            wScan: ch,
                            dwFlags: KEYEVENTF_UNICODE | KEYEVENTF_KEYUP,
                            time: 0,
                            dwExtraInfo: 0,
                        },
                    },
                },
            ];
            unsafe {
                SendInput(2, inputs.as_mut_ptr(), std::mem::size_of::<INPUT>() as i32);
            }
        }

        Ok(())
    }

    #[cfg(not(target_os = "windows"))]
    pub fn inject_media_key(_action: &str) -> NexusResult<()> {
        Ok(())
    }

    #[cfg(not(target_os = "windows"))]
    pub fn inject_keyboard_key(_key: &str, _is_down: Option<bool>) -> NexusResult<()> {
        Ok(())
    }

    #[cfg(not(target_os = "windows"))]
    pub fn inject_keyboard_combo(_keys: &[&str]) -> NexusResult<()> {
        Ok(())
    }

    #[cfg(not(target_os = "windows"))]
    pub fn inject_unicode_text(_text: &str) -> NexusResult<()> {
        Ok(())
    }
}

/// Input Plugin Actor: Handles incoming touch/keyboard/gyro streams and injects into OS
#[derive(Clone)]
pub struct InputPluginActor {
    pub device_id: DeviceId,
    pub ballistics: TouchpadBallistics,
    pub gyro_filter: GyroLaserFilter,
    pub universal_control: UniversalControlEngine,
}

impl InputPluginActor {
    pub fn new(device_id: DeviceId) -> Self {
        Self {
            device_id,
            ballistics: TouchpadBallistics::default(),
            gyro_filter: GyroLaserFilter::default(),
            universal_control: UniversalControlEngine::new(ScreenGeometry::default()),
        }
    }

    /// Emits a mouse move event to a remote target peer
    pub async fn emit_mouse_move(&self, bus: &EventBus, target_peer: DeviceId, dx: i16, dy: i16) -> NexusResult<()> {
        let payload = PacketPayload::Input(InputPayload::MouseMoveRelative { dx, dy });
        let packet = NexusPacket::new(self.device_id, payload).with_target(target_peer);

        bus.send_command(NexusCommand::SendPacket {
            target: target_peer,
            packet,
        })
        .await?;

        Ok(())
    }

    /// Processes an incoming input payload from a remote peer
    pub fn handle_remote_input(&mut self, payload: InputPayload) -> NexusResult<()> {
        match payload {
            InputPayload::MouseMoveRelative { dx, dy } => {
                let (scaled_dx, scaled_dy) = self.ballistics.calculate_delta(dx as f32, dy as f32);
                NativeInputInjector::inject_mouse_move_relative(scaled_dx, scaled_dy)?;
            }
            InputPayload::MouseButton { button, is_down } => {
                NativeInputInjector::inject_mouse_button(button, is_down)?;
            }
            InputPayload::GyroLaserPointer { pitch_delta, yaw_delta } => {
                let (smooth_x, smooth_y) = self.gyro_filter.update(pitch_delta, yaw_delta);
                let dx = (smooth_x * 20.0).round() as i32;
                let dy = (smooth_y * 20.0).round() as i32;
                NativeInputInjector::inject_mouse_move_relative(dx, dy)?;
            }
            _ => {}
        }
        Ok(())
    }
}

#[async_trait]
impl NexusActor for InputPluginActor {
    fn name(&self) -> &'static str {
        "nexus-plugin-input"
    }

    async fn run(&mut self, _bus: EventBus) -> NexusResult<()> {
        // Keeps actor loop alive
        tokio::time::sleep(tokio::time::Duration::from_secs(3600 * 24)).await;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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

        // EMA smoothing must prevent abrupt stop
        assert!(p1 > 0.0);
        assert!(p2 > 0.0, "Filter must smooth delta over time");
    }

    #[test]
    fn test_spatial_edge_hop_transition() {
        let local_geo = ScreenGeometry { width: 1920, height: 1080, scale_factor: 1.0 };
        let mut engine = UniversalControlEngine::new(local_geo);

        let target_id = DeviceId::new_random();
        let target_geo = ScreenGeometry { width: 2560, height: 1440, scale_factor: 1.25 };

        // Position target device to the Left
        engine.set_peer_arrangement(target_id, SpatialArrangement::Left, target_geo);

        // Cursor at x = 0 (left edge boundary)
        let hop = engine.check_edge_hop(0, 540);
        assert!(hop.is_some());
        let hop_event = hop.unwrap();
        assert_eq!(hop_event.target_device_id, target_id);
        assert_eq!(hop_event.edge, SpatialArrangement::Left);
        assert!((hop_event.normalized_entry_pos - 0.5).abs() < 0.01);

        // Calculate entry coordinate on target device: should enter at rightmost edge (x = 2558)
        let (entry_x, entry_y) = UniversalControlEngine::calculate_entry_coordinates(
            SpatialArrangement::Left,
            &target_geo,
            hop_event.normalized_entry_pos,
        );
        assert_eq!(entry_x, 2558);
        assert_eq!(entry_y, 720); // 50% height of 1440
    }

    #[test]
    fn test_spatial_edge_hop_right() {
        let local_geo = ScreenGeometry { width: 1920, height: 1080, scale_factor: 1.0 };
        let mut engine = UniversalControlEngine::new(local_geo);

        let target_id = DeviceId::new_random();
        let target_geo = ScreenGeometry { width: 1920, height: 1080, scale_factor: 1.0 };

        // Position target device to the Right
        engine.set_peer_arrangement(target_id, SpatialArrangement::Right, target_geo);

        // Cursor at x = 1919 (right edge boundary)
        let hop = engine.check_edge_hop(1919, 270);
        assert!(hop.is_some());
        let hop_event = hop.unwrap();
        assert_eq!(hop_event.edge, SpatialArrangement::Right);

        // Entry coord on right display should be x = 2
        let (entry_x, entry_y) = UniversalControlEngine::calculate_entry_coordinates(
            SpatialArrangement::Right,
            &target_geo,
            hop_event.normalized_entry_pos,
        );
        assert_eq!(entry_x, 2);
        assert_eq!(entry_y, 270);
    }

    #[test]
    fn test_auto_determine_ble_arrangement() {
        let local_geo = ScreenGeometry { width: 1920, height: 1080, scale_factor: 1.0 };
        let mut engine = UniversalControlEngine::new(local_geo);

        let laptop_id = DeviceId::new_random();
        let phone_id = DeviceId::new_random();
        let target_geo = ScreenGeometry { width: 1920, height: 1080, scale_factor: 1.0 };

        // Laptop at 0.8m (Desk Area) -> auto Left
        let laptop_arr = engine.auto_determine_ble_arrangement(laptop_id, 0.8, true, target_geo);
        assert_eq!(laptop_arr, SpatialArrangement::Left);

        // Phone at 0.5m (Desk Area) -> auto Right
        let phone_arr = engine.auto_determine_ble_arrangement(phone_id, 0.5, false, target_geo);
        assert_eq!(phone_arr, SpatialArrangement::Right);

        // Device far away at 3.5m -> None
        let far_id = DeviceId::new_random();
        let far_arr = engine.auto_determine_ble_arrangement(far_id, 3.5, true, target_geo);
        assert_eq!(far_arr, SpatialArrangement::None);
    }

    #[test]
    fn test_keyboard_injection_and_combos() {
        // Test key VK mappings
        assert_eq!(NativeInputInjector::key_to_vk("Esc"), 0x1B);
        assert_eq!(NativeInputInjector::key_to_vk("Tab"), 0x09);
        assert_eq!(NativeInputInjector::key_to_vk("Ctrl"), 0x11);
        assert_eq!(NativeInputInjector::key_to_vk("Alt"), 0x12);
        assert_eq!(NativeInputInjector::key_to_vk("Win"), 0x5B);
        assert_eq!(NativeInputInjector::key_to_vk("Enter"), 0x0D);
        assert_eq!(NativeInputInjector::key_to_vk("Backspace"), 0x08);

        // Test key injection doesn't panic
        assert!(NativeInputInjector::inject_keyboard_key("Esc", None).is_ok());
        assert!(NativeInputInjector::inject_keyboard_key("Tab", Some(true)).is_ok());
        assert!(NativeInputInjector::inject_keyboard_key("Tab", Some(false)).is_ok());

        // Test combo injection
        assert!(NativeInputInjector::inject_keyboard_combo(&["Ctrl", "C"]).is_ok());
        assert!(NativeInputInjector::inject_keyboard_combo(&["Win", "D"]).is_ok());

        // Test unicode text injection
        assert!(NativeInputInjector::inject_unicode_text("Hello Nexus! 🚀").is_ok());
    }
}
