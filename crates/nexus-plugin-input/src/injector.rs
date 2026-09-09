use nexus_protocol::MouseButton;
use nexus_types::{NexusError, NexusResult};
#[allow(unused_imports)]
use tracing::debug;

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
    pub fn inject_mouse_move_absolute(
        x: i32,
        y: i32,
        screen_width: i32,
        screen_height: i32,
    ) -> NexusResult<()> {
        use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
            SendInput, INPUT, INPUT_0, INPUT_MOUSE, MOUSEEVENTF_ABSOLUTE, MOUSEEVENTF_MOVE,
            MOUSEINPUT,
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
            "A" => 0x41,
            "B" => 0x42,
            "C" => 0x43,
            "D" => 0x44,
            "E" => 0x45,
            "F" => 0x46,
            "G" => 0x47,
            "H" => 0x48,
            "I" => 0x49,
            "J" => 0x4A,
            "K" => 0x4B,
            "L" => 0x4C,
            "M" => 0x4D,
            "N" => 0x4E,
            "O" => 0x4F,
            "P" => 0x50,
            "Q" => 0x51,
            "R" => 0x52,
            "S" => 0x53,
            "T" => 0x54,
            "U" => 0x55,
            "V" => 0x56,
            "W" => 0x57,
            "X" => 0x58,
            "Y" => 0x59,
            "Z" => 0x5A,
            "0" => 0x30,
            "1" => 0x31,
            "2" => 0x32,
            "3" => 0x33,
            "4" => 0x34,
            "5" => 0x35,
            "6" => 0x36,
            "7" => 0x37,
            "8" => 0x38,
            "9" => 0x39,
            "F1" => 0x70,
            "F2" => 0x71,
            "F3" => 0x72,
            "F4" => 0x73,
            "F5" => 0x74,
            "F6" => 0x75,
            "F7" => 0x76,
            "F8" => 0x77,
            "F9" => 0x78,
            "F10" => 0x79,
            "F11" => 0x7A,
            "F12" => 0x7B,
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
                unsafe {
                    SendInput(1, &mut input, std::mem::size_of::<INPUT>() as i32);
                }
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
                unsafe {
                    SendInput(1, &mut input, std::mem::size_of::<INPUT>() as i32);
                }
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
                unsafe {
                    SendInput(2, inputs.as_mut_ptr(), std::mem::size_of::<INPUT>() as i32);
                }
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
            unsafe {
                SendInput(1, &mut input, std::mem::size_of::<INPUT>() as i32);
            }
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
            unsafe {
                SendInput(1, &mut input, std::mem::size_of::<INPUT>() as i32);
            }
        }

        Ok(())
    }

    #[cfg(target_os = "windows")]
    pub fn inject_unicode_text(text: &str) -> NexusResult<()> {
        use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
            SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP,
            KEYEVENTF_UNICODE,
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
