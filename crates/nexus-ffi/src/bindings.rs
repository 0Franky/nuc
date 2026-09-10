use std::ffi::CString;
use std::os::raw::c_char;
use std::sync::atomic::Ordering;
use nexus_types::DeviceId;
use serde_json::json;

use crate::state::{
    c_to_string, check_system_bluetooth_enabled, get_local_lan_ip, init_nexus_engine,
    parse_device_id, string_to_c, GLOBAL_ENGINE, GLOBAL_RUNTIME,
};

/// Initializes Nexus Core engine and returns allocated DeviceId C-string
#[no_mangle]
pub extern "C" fn nexus_init(device_name: *const c_char) -> *mut c_char {
    let name = unsafe { c_to_string(device_name) }.unwrap_or_else(|| "Nexus Flutter Node".into());
    let device_id = GLOBAL_RUNTIME.block_on(init_nexus_engine(name));
    match device_id {
        Ok(id) => string_to_c(id.to_string()),
        Err(err) => { tracing::error!("Nexus initialization failed: {err}"); std::ptr::null_mut() }
    }
}

/// Frees a C-string allocated by Rust
#[no_mangle]
pub extern "C" fn nexus_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            let _ = CString::from_raw(ptr);
        }
    }
}

/// Returns 1 if real OS Bluetooth radio is enabled/On, 0 if Off or unavailable
#[no_mangle]
pub extern "C" fn nexus_is_bluetooth_enabled() -> i32 {
    if check_system_bluetooth_enabled() {
        1
    } else {
        0
    }
}

/// Returns a JSON snapshot of the local device state (Peers, Active Media, Audio Relay, Files)
#[no_mangle]
pub extern "C" fn nexus_get_state_json() -> *mut c_char {
    GLOBAL_RUNTIME.block_on(async {
        let global = GLOBAL_ENGINE.read().await;
        if let Some(engine) = &*global {
            let media_session = engine.media_actor.get_current_session().await;
            let audio_streaming = engine.audio_actor.is_streaming.load(Ordering::Relaxed);
            let volume = *engine.audio_actor.master_volume.read().await;
            let is_muted = engine.audio_actor.is_muted.load(Ordering::Relaxed);
            let peers = engine.transport.get_discovered_peers().await;
            let clipboard_history = engine.clipboard_actor.get_history().await;
            let local_ip = get_local_lan_ip();
            let bt_enabled = check_system_bluetooth_enabled();

            let state = json!({
                "initialized": true,
                "device_id": engine.device_id.to_string(),
                "local_lan_ip": local_ip,
                "bluetooth_radio_on": bt_enabled,
                "audio_relay_active": audio_streaming,
                "audio_volume": volume,
                "audio_muted": is_muted,
                "active_media": media_session,
                "discovered_peers": peers,
                "clipboard_history": clipboard_history,
            });

            string_to_c(state.to_string())
        } else {
            let state = json!({
                "initialized": false,
                "bluetooth_radio_on": check_system_bluetooth_enabled(),
            });
            string_to_c(state.to_string())
        }
    })
}

/// Starts audio relay streaming to a target peer
#[no_mangle]
pub extern "C" fn nexus_start_audio_relay(peer_id_str: *const c_char) -> i32 {
    let peer_str = match unsafe { c_to_string(peer_id_str) } {
        Some(s) => s,
        None => return -1,
    };
    let peer_id = match parse_device_id(&peer_str) {
        Some(id) => id,
        None => return -2,
    };

    GLOBAL_RUNTIME.block_on(async {
        let global = GLOBAL_ENGINE.read().await;
        if let Some(engine) = &*global {
            match engine.audio_actor.start_streaming_to_peer(&engine.bus, peer_id).await {
                Ok(_) => 0,
                Err(_) => -3,
            }
        } else {
            -4
        }
    })
}

/// Stops audio relay streaming
#[no_mangle]
pub extern "C" fn nexus_stop_audio_relay() -> i32 {
    GLOBAL_RUNTIME.block_on(async {
        let global = GLOBAL_ENGINE.read().await;
        if let Some(engine) = &*global {
            match engine.audio_actor.stop_streaming(&engine.bus).await {
                Ok(_) => 0,
                Err(_) => -1,
            }
        } else {
            -2
        }
    })
}

/// Adjusts master volume (0.0 to 1.0)
#[no_mangle]
pub extern "C" fn nexus_set_master_volume(volume: f32) -> i32 {
    GLOBAL_RUNTIME.block_on(async {
        let global = GLOBAL_ENGINE.read().await;
        if let Some(engine) = &*global {
            engine.audio_actor.set_volume(volume).await;
            0
        } else {
            -1
        }
    })
}

/// Toggles audio mute on private listening relay
#[no_mangle]
pub extern "C" fn nexus_toggle_audio_mute() -> i32 {
    GLOBAL_RUNTIME.block_on(async {
        let global = GLOBAL_ENGINE.read().await;
        if let Some(engine) = &*global {
            let is_muted = engine.audio_actor.toggle_mute();
            engine.bus.publish(nexus_actor_system::NexusEvent::AudioMuteToggled(is_muted));
            if is_muted { 1 } else { 0 }
        } else {
            -1
        }
    })
}

/// Sends a media control command ("PLAY", "PAUSE", "SEEK") to browser extensions
#[no_mangle]
pub extern "C" fn nexus_send_media_control(action_str: *const c_char, position_ms: i64) -> i32 {
    let action = match unsafe { c_to_string(action_str) } {
        Some(s) => s,
        None => return -1,
    };

    let pos = if position_ms >= 0 {
        Some(position_ms as u64)
    } else {
        None
    };

    GLOBAL_RUNTIME.block_on(async {
        let global = GLOBAL_ENGINE.read().await;
        if let Some(engine) = &*global {
            engine.media_actor.send_remote_command(action, pos).await;
            0
        } else {
            -2
        }
    })
}

/// Emits a relative mouse move event from the trackpad
#[no_mangle]
pub extern "C" fn nexus_send_touchpad_delta(peer_id_str: *const c_char, dx: i16, dy: i16) -> i32 {
    let peer_str = match unsafe { c_to_string(peer_id_str) } {
        Some(s) => s,
        None => return -1,
    };
    let peer_id = match parse_device_id(&peer_str) {
        Some(id) => id,
        None => return -2,
    };

    GLOBAL_RUNTIME.block_on(async {
        let global = GLOBAL_ENGINE.read().await;
        if let Some(engine) = &*global {
            match engine.input_actor.emit_mouse_move(&engine.bus, peer_id, dx, dy).await {
                Ok(_) => 0,
                Err(_) => -3,
            }
        } else {
            -4
        }
    })
}

/// Emits a mouse button event (down or up) for holding mouse buttons and drag-selection
#[no_mangle]
pub extern "C" fn nexus_send_touchpad_button(button_str: *const c_char, is_down: i32) -> i32 {
    let btn_str = match unsafe { c_to_string(button_str) } {
        Some(s) => s,
        None => return -1,
    };
    let btn = if btn_str.eq_ignore_ascii_case("right") {
        nexus_protocol::MouseButton::Right
    } else if btn_str.eq_ignore_ascii_case("middle") {
        nexus_protocol::MouseButton::Middle
    } else {
        nexus_protocol::MouseButton::Left
    };
    let _ = nexus_plugin_input::NativeInputInjector::inject_mouse_button(btn, is_down != 0);
    0
}

/// Synchronizes a clipboard snippet to peers E2EE
#[no_mangle]
pub extern "C" fn nexus_sync_clipboard(text: *const c_char, target_peer_str: *const c_char) -> i32 {
    let content = match unsafe { c_to_string(text) } {
        Some(s) => s,
        None => return -1,
    };
    let target_peer = unsafe { c_to_string(target_peer_str) }.and_then(|s| parse_device_id(&s));

    GLOBAL_RUNTIME.block_on(async {
        let global = GLOBAL_ENGINE.read().await;
        if let Some(engine) = &*global {
            match engine.clipboard_actor.on_local_clipboard_changed(&engine.bus, &content, target_peer).await {
                Ok(_) => 0,
                Err(_) => -2,
            }
        } else {
            -3
        }
    })
}

/// Classifies clipboard content into safe vs secret/PII
#[no_mangle]
pub extern "C" fn nexus_classify_clipboard(text: *const c_char) -> *mut c_char {
    let content = match unsafe { c_to_string(text) } {
        Some(s) => s,
        None => return string_to_c("{\"error\":\"Invalid text\"}".into()),
    };

    GLOBAL_RUNTIME.block_on(async {
        let global = GLOBAL_ENGINE.read().await;
        if let Some(engine) = &*global {
            let (is_secret, label, hint) = engine.clipboard_actor.parser.classify_privacy(&content);
            let res = json!({
                "is_secret": is_secret,
                "label": label,
                "hint_type": hint.map(|h| format!("{:?}", h)),
            });
            string_to_c(res.to_string())
        } else {
            let parser = nexus_plugin_clipboard::SmartClipboardParser::new();
            let (is_secret, label, hint) = parser.classify_privacy(&content);
            let res = json!({
                "is_secret": is_secret,
                "label": label,
                "hint_type": hint.map(|h| format!("{:?}", h)),
            });
            string_to_c(res.to_string())
        }
    })
}

/// Sets whether the Zero-Trust Clipboard Privacy Gate is enabled
#[no_mangle]
pub extern "C" fn nexus_set_clipboard_privacy_gate(enabled: i32) -> i32 {
    GLOBAL_RUNTIME.block_on(async {
        let global = GLOBAL_ENGINE.read().await;
        if let Some(engine) = &*global {
            engine.clipboard_actor.set_privacy_gate_enabled(enabled != 0).await;
            0
        } else {
            -1
        }
    })
}

/// Reveals a stored secret given its entry ID
#[no_mangle]
pub extern "C" fn nexus_reveal_clipboard_secret(entry_id_str: *const c_char) -> *mut c_char {
    let entry_id = match unsafe { c_to_string(entry_id_str) } {
        Some(s) => s,
        None => return string_to_c("{\"error\":\"Invalid ID\"}".into()),
    };

    GLOBAL_RUNTIME.block_on(async {
        let global = GLOBAL_ENGINE.read().await;
        if let Some(engine) = &*global {
            if let Some(cleartext) = engine.clipboard_actor.reveal_secret(&entry_id).await {
                let res = json!({
                    "entry_id": entry_id,
                    "revealed": true,
                    "text": cleartext,
                });
                string_to_c(res.to_string())
            } else {
                let res = json!({
                    "entry_id": entry_id,
                    "revealed": false,
                    "error": "Secret not found or expired",
                });
                string_to_c(res.to_string())
            }
        } else {
            string_to_c("{\"error\":\"Engine not initialized\"}".into())
        }
    })
}

/// Creates a new P2P file transfer offer and returns JSON with file_id and chunk count
#[no_mangle]
pub extern "C" fn nexus_offer_file_transfer(
    file_name: *const c_char,
    target_peer_str: *const c_char,
    file_bytes_len: u64,
) -> *mut c_char {
    let name = match unsafe { c_to_string(file_name) } {
        Some(s) => s,
        None => return string_to_c("{\"error\":\"Invalid filename\"}".into()),
    };
    let target_peer = match unsafe { c_to_string(target_peer_str) }.and_then(|s| parse_device_id(&s)) {
        Some(p) => p,
        None => DeviceId::new_random(),
    };

    GLOBAL_RUNTIME.block_on(async {
        let global = GLOBAL_ENGINE.read().await;
        if let Some(engine) = &*global {
            let path = std::path::Path::new(&name);
            let file_data = if path.exists() && path.is_file() {
                std::fs::read(path).unwrap_or_default()
            } else {
                vec![0u8; file_bytes_len as usize]
            };
            let actual_name = path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or(&name)
                .to_string();

            let (meta, chunks) = engine.files_actor.create_offer(actual_name, &file_data, target_peer).await;

            let res = json!({
                "file_id": meta.file_id.to_string(),
                "file_name": meta.file_name,
                "file_size": meta.file_size,
                "total_chunks": meta.total_chunks,
                "chunks_prepared": chunks.len(),
            });

            string_to_c(res.to_string())
        } else {
            string_to_c("{\"error\":\"Engine not initialized\"}".into())
        }
    })
}
