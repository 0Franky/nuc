use nexus_protocol::MouseButton;
use nexus_types::{NexusError, NexusResult};

pub(crate) struct LinuxInputInjector;

#[derive(Debug, PartialEq)]
enum Backend {
    X11,
    Wayland,
}

fn backend(session: &str, wayland_display: &str, display: &str) -> NexusResult<Backend> {
    if session.eq_ignore_ascii_case("wayland") || !wayland_display.is_empty() {
        Ok(Backend::Wayland)
    } else if !display.is_empty() {
        Ok(Backend::X11)
    } else {
        Err(error(
            "Nessuna sessione grafica. Avvia Nexus nella sessione desktop Linux.",
        ))
    }
}

fn error(message: impl Into<String>) -> NexusError {
    NexusError::Plugin {
        plugin: "input.linux",
        message: message.into(),
    }
}

fn run(program: &str, args: &[&str]) -> NexusResult<()> {
    let output = std::process::Command::new(program)
        .args(args)
        .output()
        .map_err(|e| {
            error(format!(
                "{program} non disponibile: {e}. Per i comandi tastiera X11 installa xdotool."
            ))
        })?;
    if output.status.success() {
        return Ok(());
    }
    // Do not include arguments: keyboard text may contain private data.
    Err(error(format!(
        "{program} ha rifiutato l'input ({}). Verifica accesso alla sessione grafica desktop. {}",
        output.status,
        String::from_utf8_lossy(&output.stderr).trim()
    )))
}

#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
impl LinuxInputInjector {
    fn backend() -> NexusResult<Backend> {
        backend(
            &std::env::var("XDG_SESSION_TYPE").unwrap_or_default(),
            &std::env::var("WAYLAND_DISPLAY").unwrap_or_default(),
            &std::env::var("DISPLAY").unwrap_or_default(),
        )
    }

    pub fn inject_mouse_move_relative(dx: i32, dy: i32) -> NexusResult<()> {
        if dx == 0 && dy == 0 {
            return Ok(());
        }
        match Self::backend()? {
            Backend::X11 => x11_pointer_move(dx, dy, true),
            Backend::Wayland => wayland(WaylandEvent::Motion(dx, dy)),
        }
    }

    pub fn inject_mouse_move_absolute(x: i32, y: i32, _w: i32, _h: i32) -> NexusResult<()> {
        match Self::backend()? {
            Backend::X11 => x11_pointer_move(x, y, false),
            Backend::Wayland => Err(error("Posizione assoluta Wayland richiede un flusso schermo autorizzato; usa il touchpad relativo.")),
        }
    }

    fn buttons(button: MouseButton) -> (u8, u8) {
        match button {
            MouseButton::Left => (1, 0),
            MouseButton::Right => (3, 1),
            MouseButton::Middle => (2, 2),
        }
    }

    pub fn inject_mouse_button(button: MouseButton, is_down: bool) -> NexusResult<()> {
        let (xbutton, ybutton) = Self::buttons(button);
        match Self::backend()? {
            Backend::X11 => x11_pointer_button(xbutton, is_down),
            Backend::Wayland => wayland(WaylandEvent::Button(
                272 + i32::from(ybutton),
                Some(is_down),
            )),
        }
    }

    pub fn inject_mouse_click(button: MouseButton) -> NexusResult<()> {
        let (xbutton, ybutton) = Self::buttons(button);
        match Self::backend()? {
            Backend::X11 => {
                x11_pointer_button(xbutton, true)?;
                x11_pointer_button(xbutton, false)
            }
            Backend::Wayland => wayland(WaylandEvent::Button(272 + i32::from(ybutton), None)),
        }
    }

    pub fn inject_mouse_wheel(delta_y: i32) -> NexusResult<()> {
        if delta_y == 0 {
            return Ok(());
        }
        let delta = delta_y.clamp(-10, 10);
        match Self::backend()? {
            Backend::X11 => {
                let button = if delta > 0 { 4 } else { 5 };
                for _ in 0..delta.abs() {
                    x11_pointer_button(button, true)?;
                    x11_pointer_button(button, false)?;
                }
                Ok(())
            }
            Backend::Wayland => wayland(WaylandEvent::Scroll(-delta)),
        }
    }

    pub fn inject_media_key(action: &str) -> NexusResult<()> {
        let command = match action.to_uppercase().as_str() {
            "PLAY" => "play",
            "PAUSE" => "pause",
            "PLAY_PAUSE" | "TOGGLE" => "play-pause",
            "STOP" => "stop",
            "NEXT" | "NEXT_TRACK" => "next",
            "PREV" | "PREV_TRACK" => "previous",
            _ => return Err(error("Comando media non supportato")),
        };
        run("playerctl", &[command])
    }

    pub fn linux_key_name(key: &str) -> &'static str {
        match key.to_uppercase().trim() {
            "ESC" | "ESCAPE" => "Escape",
            "TAB" => "Tab",
            "CTRL" | "CONTROL" | "LCTRL" => "Control_L",
            "RCTRL" => "Control_R",
            "ALT" | "MENU" | "LALT" => "Alt_L",
            "RALT" => "Alt_R",
            "WIN" | "WINDOWS" | "LWIN" | "START" => "Super_L",
            "RWIN" => "Super_R",
            "ENTER" | "RETURN" => "Return",
            "BACK" | "BACKSPACE" => "BackSpace",
            "SPACE" => "space",
            "DEL" | "DELETE" => "Delete",
            "INSERT" => "Insert",
            "HOME" => "Home",
            "END" => "End",
            "PAGEUP" | "PGUP" => "Prior",
            "PAGEDOWN" | "PGDN" => "Next",
            "UP" | "ARROWUP" => "Up",
            "DOWN" | "ARROWDOWN" => "Down",
            "LEFT" | "ARROWLEFT" => "Left",
            "RIGHT" | "ARROWRIGHT" => "Right",
            "F1" => "F1",
            "F2" => "F2",
            "F3" => "F3",
            "F4" => "F4",
            "F5" => "F5",
            "F6" => "F6",
            "F7" => "F7",
            "F8" => "F8",
            "F9" => "F9",
            "F10" => "F10",
            "F11" => "F11",
            "F12" => "F12",
            _ => "",
        }
    }

    fn key_code(key: &str) -> NexusResult<u16> {
        let code = match key.to_uppercase().trim() {
            "ESC" | "ESCAPE" => 1,
            "TAB" => 15,
            "ENTER" | "RETURN" => 28,
            "CTRL" | "CONTROL" | "LCTRL" => 29,
            "RCTRL" => 97,
            "SHIFT" | "LSHIFT" => 42,
            "RSHIFT" => 54,
            "ALT" | "MENU" | "LALT" => 56,
            "RALT" => 100,
            "WIN" | "WINDOWS" | "LWIN" | "START" => 125,
            "RWIN" => 126,
            "SPACE" => 57,
            "BACK" | "BACKSPACE" => 14,
            "DEL" | "DELETE" => 111,
            "INSERT" => 110,
            "HOME" => 102,
            "END" => 107,
            "PAGEUP" | "PGUP" => 104,
            "PAGEDOWN" | "PGDN" => 109,
            "UP" | "ARROWUP" => 103,
            "DOWN" | "ARROWDOWN" => 108,
            "LEFT" | "ARROWLEFT" => 105,
            "RIGHT" | "ARROWRIGHT" => 106,
            "F1" => 59,
            "F2" => 60,
            "F3" => 61,
            "F4" => 62,
            "F5" => 63,
            "F6" => 64,
            "F7" => 65,
            "F8" => 66,
            "F9" => 67,
            "F10" => 68,
            "F11" => 87,
            "F12" => 88,
            "A" => 30,
            "B" => 48,
            "C" => 46,
            "D" => 32,
            "E" => 18,
            "F" => 33,
            "G" => 34,
            "H" => 35,
            "I" => 23,
            "J" => 36,
            "K" => 37,
            "L" => 38,
            "M" => 50,
            "N" => 49,
            "O" => 24,
            "P" => 25,
            "Q" => 16,
            "R" => 19,
            "S" => 31,
            "T" => 20,
            "U" => 22,
            "V" => 47,
            "W" => 17,
            "X" => 45,
            "Y" => 21,
            "Z" => 44,
            "1" => 2,
            "2" => 3,
            "3" => 4,
            "4" => 5,
            "5" => 6,
            "6" => 7,
            "7" => 8,
            "8" => 9,
            "9" => 10,
            "0" => 11,
            _ => return Err(error("Tasto non supportato dal backend Wayland")),
        };
        Ok(code)
    }

    pub fn inject_keyboard_key(key: &str, is_down: Option<bool>) -> NexusResult<()> {
        match Self::backend()? {
            Backend::X11 => {
                let mapped = Self::linux_key_name(key);
                run(
                    "xdotool",
                    &[
                        match is_down {
                            Some(true) => "keydown",
                            Some(false) => "keyup",
                            None => "key",
                        },
                        "--",
                        if mapped.is_empty() { key } else { mapped },
                    ],
                )
            }
            Backend::Wayland => {
                let code = Self::key_code(key)?;
                wayland(WaylandEvent::Key(code, is_down))
            }
        }
    }

    pub fn inject_keyboard_combo(keys: &[&str]) -> NexusResult<()> {
        if keys.is_empty() {
            return Ok(());
        }
        match Self::backend()? {
            Backend::X11 => {
                let keys: Vec<&str> = keys
                    .iter()
                    .map(|k| {
                        let mapped = Self::linux_key_name(k);
                        if mapped.is_empty() {
                            *k
                        } else {
                            mapped
                        }
                    })
                    .collect();
                run("xdotool", &["key", "--", &keys.join("+")])
            }
            Backend::Wayland => {
                let codes: Vec<u16> = keys
                    .iter()
                    .map(|k| Self::key_code(k))
                    .collect::<NexusResult<_>>()?;
                wayland(WaylandEvent::Combo(codes))
            }
        }
    }

    pub fn inject_unicode_text(text: &str) -> NexusResult<()> {
        if text.is_empty() {
            return Ok(());
        }
        match Self::backend()? {
            Backend::X11 => run("xdotool", &["type", "--delay", "0", "--clearmodifiers", "--", text]),
            Backend::Wayland => wayland(WaylandEvent::Text(text.to_owned())),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn wayland_must_not_use_xwayland_even_when_display_is_set() {
        assert_eq!(
            backend("wayland", "wayland-0", ":0").unwrap(),
            Backend::Wayland
        );
        assert_eq!(backend("", "wayland-0", ":0").unwrap(), Backend::Wayland);
        assert_eq!(backend("x11", "", ":0").unwrap(), Backend::X11);
        assert!(backend("", "", "").is_err());
    }
    #[test]
    fn unavailable_linux_backend_reports_failure() {
        assert!(run("nexus-nonexistent-input-backend", &[]).is_err());
        #[cfg(target_os = "windows")]
        assert!(LinuxInputInjector::inject_mouse_move_relative(1, 1).is_err());
    }
    #[test]
    fn zero_scroll_and_zero_motion_are_noops() {
        assert!(LinuxInputInjector::inject_mouse_wheel(0).is_ok());
        assert!(LinuxInputInjector::inject_mouse_move_relative(0, 0).is_ok());
    }
    #[test]
    fn unsupported_keys_do_not_inject_a_different_key() {
        assert_eq!(LinuxInputInjector::key_code("CTRL").unwrap(), 29);
        assert_eq!(LinuxInputInjector::key_code("C").unwrap(), 46);
        assert!(LinuxInputInjector::key_code("unknown").is_err());
    }
    #[test]
    #[cfg(target_os = "linux")]
    fn failed_command_exit_is_reported() {
        assert!(run("false", &[]).is_err());
    }
}

#[cfg(target_os = "linux")]
fn x11_pointer_move(x: i32, y: i32, relative: bool) -> NexusResult<()> {
    crate::x11_pointer::move_pointer(x, y, relative)
}
#[cfg(target_os = "linux")]
fn x11_pointer_button(button: u8, down: bool) -> NexusResult<()> {
    crate::x11_pointer::button(button, down)
}
#[cfg(not(target_os = "linux"))]
fn x11_pointer_move(_: i32, _: i32, _: bool) -> NexusResult<()> {
    Err(error("X11 disponibile solo su Linux"))
}
#[cfg(not(target_os = "linux"))]
fn x11_pointer_button(_: u8, _: bool) -> NexusResult<()> {
    Err(error("X11 disponibile solo su Linux"))
}

#[derive(Debug)]
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub(super) enum WaylandEvent {
    Motion(i32, i32),
    Button(i32, Option<bool>),
    Scroll(i32),
    Key(u16, Option<bool>),
    Combo(Vec<u16>),
    Text(String),
}
fn wayland(event: WaylandEvent) -> NexusResult<()> {
    #[cfg(target_os = "linux")]
    {
        crate::wayland_input::send(event)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = event;
        Err(error("Wayland disponibile solo su Linux"))
    }
}
