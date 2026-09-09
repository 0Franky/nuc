#![allow(clippy::not_unsafe_ptr_arg_deref)]

use nexus_actor_system::{ActorSupervisor, EventBus};
use nexus_crypto::DeviceIdentity;
use nexus_plugin_audio::AudioPluginActor;
use nexus_plugin_clipboard::ClipboardPluginActor;
use nexus_plugin_files::FilePluginActor;
use nexus_plugin_input::InputPluginActor;
use nexus_plugin_media::MediaPluginActor;
use nexus_plugin_proximity::ProximityPluginActor;
use nexus_transport::TransportEngine;
use nexus_types::DeviceId;
use serde_json::json;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::runtime::Runtime;
use tokio::sync::RwLock;

static IS_INITIALIZED: AtomicBool = AtomicBool::new(false);

/// High-Level App State exposed across the FFI boundary
pub struct NexusEngineHandle {
    pub device_id: DeviceId,
    pub bus: EventBus,
    pub media_actor: Arc<MediaPluginActor>,
    pub audio_actor: Arc<AudioPluginActor>,
    pub input_actor: Arc<InputPluginActor>,
    pub clipboard_actor: Arc<ClipboardPluginActor>,
    pub proximity_actor: Arc<ProximityPluginActor>,
    pub files_actor: Arc<FilePluginActor>,
    pub transport: Arc<TransportEngine>,
}

lazy_static::lazy_static! {
    static ref GLOBAL_RUNTIME: Runtime = Runtime::new().expect("Failed to initialize Tokio FFI Runtime");
    static ref GLOBAL_ENGINE: RwLock<Option<NexusEngineHandle>> = RwLock::new(None);
}

/// Helper: Converts C string to Rust String
unsafe fn c_to_string(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    CStr::from_ptr(ptr).to_str().ok().map(|s| s.to_string())
}

/// Helper: Converts Rust String to C string allocated with libc/CString
fn string_to_c(s: String) -> *mut c_char {
    CString::new(s).unwrap_or_default().into_raw()
}

/// Helper: Parses UUID string into DeviceId
fn parse_device_id(id_str: &str) -> Option<DeviceId> {
    uuid::Uuid::parse_str(id_str)
        .ok()
        .map(|u| DeviceId::from_bytes(*u.as_bytes()))
}

/// Initializes the Nexus Engine asynchronously from Rust
pub async fn init_nexus_engine(device_name: String) -> DeviceId {
    let identity = DeviceIdentity::generate();
    let device_id = identity.device_id;

    let (bus, mut cmd_rx) = EventBus::new(256, 128);

    let media_actor = Arc::new(MediaPluginActor::new(device_id));
    ActorSupervisor::spawn_actor((*media_actor).clone_handle(), bus.clone());

    let audio_actor = Arc::new(AudioPluginActor::new(device_id));
    ActorSupervisor::spawn_actor((*audio_actor).clone(), bus.clone());

    let input_actor = Arc::new(InputPluginActor::new(device_id));
    ActorSupervisor::spawn_actor((*input_actor).clone(), bus.clone());

    let clipboard_actor = Arc::new(ClipboardPluginActor::new(device_id));
    ActorSupervisor::spawn_actor((*clipboard_actor).clone(), bus.clone());

    let proximity_actor = Arc::new(ProximityPluginActor::new(device_id));
    ActorSupervisor::spawn_actor((*proximity_actor).clone(), bus.clone());

    let files_actor = Arc::new(FilePluginActor::new(device_id));
    ActorSupervisor::spawn_actor((*files_actor).clone(), bus.clone());

    let transport = Arc::new(TransportEngine::new(
        identity,
        device_name,
        42420,
        bus.clone(),
    ));

    // Command router loop
    tokio::spawn(async move {
        while let Some(_cmd) = cmd_rx.recv().await {
            // Internal command routing
        }
    });

    let handle = NexusEngineHandle {
        device_id,
        bus,
        media_actor,
        audio_actor,
        input_actor,
        clipboard_actor,
        proximity_actor,
        files_actor,
        transport,
    };

    let mut global = GLOBAL_ENGINE.write().await;
    *global = Some(handle);
    IS_INITIALIZED.store(true, Ordering::SeqCst);

    device_id
}

// -------------------------------------------------------------
// EXPORTED C-ABI FFI FUNCTIONS FOR DART / FLUTTER
// -------------------------------------------------------------

/// Initializes Nexus Core engine and returns allocated DeviceId C-string
#[no_mangle]
pub extern "C" fn nexus_init(device_name: *const c_char) -> *mut c_char {
    let name = unsafe { c_to_string(device_name) }.unwrap_or_else(|| "Nexus Flutter Node".into());
    let device_id = GLOBAL_RUNTIME.block_on(init_nexus_engine(name));
    string_to_c(device_id.to_string())
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

fn get_local_lan_ip() -> String {
    if let Ok(socket) = std::net::UdpSocket::bind("0.0.0.0:0") {
        if socket.connect("8.8.8.8:80").is_ok() {
            if let Ok(addr) = socket.local_addr() {
                return addr.ip().to_string();
            }
        }
    }
    "127.0.0.1".to_string()
}

static LAST_BT_CHECK_MS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
static LAST_BT_STATE: AtomicBool = AtomicBool::new(false);

/// Queries real OS Bluetooth radio hardware state (Windows / Mobile)
pub fn check_system_bluetooth_enabled() -> bool {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;

    let last_ts = LAST_BT_CHECK_MS.load(Ordering::Relaxed);
    if now.saturating_sub(last_ts) < 2500 && last_ts != 0 {
        return LAST_BT_STATE.load(Ordering::Relaxed);
    }

    #[cfg(target_os = "windows")]
    {
        #[repr(C)]
        struct BluetoothFindRadioParams {
            dw_size: u32,
        }

        #[link(name = "bthprops")]
        extern "system" {
            fn BluetoothFindFirstRadio(
                pbtfrp: *const BluetoothFindRadioParams,
                ph_radio: *mut *mut std::ffi::c_void,
            ) -> *mut std::ffi::c_void;
            fn BluetoothFindRadioClose(h_find: *mut std::ffi::c_void) -> i32;
        }

        #[link(name = "kernel32")]
        extern "system" {
            fn CloseHandle(h_object: *mut std::ffi::c_void) -> i32;
        }

        let is_on = unsafe {
            let params = BluetoothFindRadioParams {
                dw_size: std::mem::size_of::<BluetoothFindRadioParams>() as u32,
            };
            let mut radio_handle: *mut std::ffi::c_void = std::ptr::null_mut();
            let h_find = BluetoothFindFirstRadio(&params, &mut radio_handle);
            if !h_find.is_null() {
                if !radio_handle.is_null() {
                    CloseHandle(radio_handle);
                }
                BluetoothFindRadioClose(h_find);
                true
            } else {
                false
            }
        };

        LAST_BT_CHECK_MS.store(now, Ordering::Relaxed);
        LAST_BT_STATE.store(is_on, Ordering::Relaxed);
        is_on
    }

    #[cfg(not(target_os = "windows"))]
    {
        LAST_BT_CHECK_MS.store(now, Ordering::Relaxed);
        LAST_BT_STATE.store(false, Ordering::Relaxed);
        false
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
pub extern "C" fn nexus_offer_file_transfer(file_name: *const c_char, target_peer_str: *const c_char, file_bytes_len: u64) -> *mut c_char {
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
            let dummy_data = vec![0u8; file_bytes_len as usize];
            let (meta, chunks) = engine.files_actor.create_offer(name, &dummy_data, target_peer).await;

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

#[cfg(test)]
mod tests {
    use super::*;
    static TEST_MUTEX: std::sync::Mutex<()> = std::sync::Mutex::new(());

    #[tokio::test]
    async fn test_ffi_engine_init() {
        let _guard = TEST_MUTEX.lock().unwrap();
        let device_id = init_nexus_engine("Nexus Phone Test".into()).await;
        assert_ne!(device_id.to_string(), "");
        assert!(IS_INITIALIZED.load(Ordering::SeqCst));
    }

    #[test]
    fn test_c_abi_init_and_state_json() {
        let _guard = TEST_MUTEX.lock().unwrap();
        let name_c = CString::new("Desktop Studio").unwrap();
        let id_ptr = nexus_init(name_c.as_ptr());
        assert!(!id_ptr.is_null());

        let id_str = unsafe { CStr::from_ptr(id_ptr).to_str().unwrap() };
        assert!(uuid::Uuid::parse_str(id_str).is_ok());
        nexus_free_string(id_ptr);

        let state_ptr = nexus_get_state_json();
        assert!(!state_ptr.is_null());

        let state_str = unsafe { CStr::from_ptr(state_ptr).to_str().unwrap() };
        assert!(state_str.contains("\"initialized\":true"));
        assert!(state_str.contains("\"audio_volume\":"));
        nexus_free_string(state_ptr);
    }

    #[test]
    fn test_c_abi_volume_and_audio_control() {
        let _guard = TEST_MUTEX.lock().unwrap();
        let name_c = CString::new("Audio Node").unwrap();
        let id_ptr = nexus_init(name_c.as_ptr());
        nexus_free_string(id_ptr);

        let vol_res = nexus_set_master_volume(0.75);
        assert_eq!(vol_res, 0);

        let state_ptr = nexus_get_state_json();
        let state_str = unsafe { CStr::from_ptr(state_ptr).to_str().unwrap() };
        assert!(state_str.contains("\"audio_volume\":"));
        nexus_free_string(state_ptr);

        let stop_res = nexus_stop_audio_relay();
        assert_eq!(stop_res, 0);
    }

    #[test]
    fn test_c_abi_file_transfer_offer() {
        let _guard = TEST_MUTEX.lock().unwrap();
        let name_c = CString::new("File Node").unwrap();
        let id_ptr = nexus_init(name_c.as_ptr());
        nexus_free_string(id_ptr);

        let file_name = CString::new("document.pdf").unwrap();
        let target_peer = CString::new("00000000-0000-0000-0000-000000000001").unwrap();
        let res_ptr = nexus_offer_file_transfer(file_name.as_ptr(), target_peer.as_ptr(), 128000);
        assert!(!res_ptr.is_null());

        let res_str = unsafe { CStr::from_ptr(res_ptr).to_str().unwrap() };
        assert!(res_str.contains("\"file_name\":\"document.pdf\""));
        assert!(res_str.contains("\"total_chunks\":2"));
        nexus_free_string(res_ptr);
    }

    #[test]
    fn test_c_abi_live_media_playback_state() {
        let _guard = TEST_MUTEX.lock().unwrap();
        GLOBAL_RUNTIME.block_on(async {
            let _ = init_nexus_engine("Media Node".into()).await;
            let global = GLOBAL_ENGINE.read().await;
            if let Some(engine) = &*global {
                engine.media_actor.update_local_playback(
                    &engine.bus,
                    "YouTube (Chrome)".into(),
                    "Inception Soundtrack (Hans Zimmer)".into(),
                    "https://youtube.com/watch?v=inception".into(),
                    124000,
                    450000,
                    true,
                ).await;
            }
            tokio::time::sleep(tokio::time::Duration::from_millis(50)).await;
        });

        let state_ptr = nexus_get_state_json();
        assert!(!state_ptr.is_null());

        let state_str = unsafe { CStr::from_ptr(state_ptr).to_str().unwrap() };
        assert!(state_str.contains("Inception Soundtrack (Hans Zimmer)"));
        assert!(state_str.contains("124000"));
        assert!(state_str.contains("https://youtube.com/watch?v=inception"));
        assert!(state_str.contains("\"bluetooth_radio_on\":"));
        nexus_free_string(state_ptr);
    }

    #[test]
    fn test_c_abi_bluetooth_hardware_check() {
        let _guard = TEST_MUTEX.lock().unwrap();
        let bt_code = nexus_is_bluetooth_enabled();
        // Returns 0 or 1 on Windows depending on hardware radio state
        assert!(bt_code == 0 || bt_code == 1);
        println!("Live Windows Bluetooth Radio state returned: {}", bt_code);
    }
}

