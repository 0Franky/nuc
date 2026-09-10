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
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use tokio::runtime::Runtime;
use tokio::sync::RwLock;

pub static IS_INITIALIZED: AtomicBool = AtomicBool::new(false);
static LAST_BT_CHECK_MS: AtomicU64 = AtomicU64::new(0);
static LAST_BT_STATE: AtomicBool = AtomicBool::new(false);

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
    pub static ref GLOBAL_RUNTIME: Runtime = Runtime::new().expect("Failed to initialize Tokio FFI Runtime");
    pub static ref GLOBAL_ENGINE: RwLock<Option<NexusEngineHandle>> = RwLock::new(None);
}

/// Helper: Converts C string to Rust String
pub unsafe fn c_to_string(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    CStr::from_ptr(ptr).to_str().ok().map(|s| s.to_string())
}

/// Helper: Converts Rust String to C string allocated with libc/CString
pub fn string_to_c(s: String) -> *mut c_char {
    CString::new(s).unwrap_or_default().into_raw()
}

/// Helper: Parses UUID string into DeviceId
pub fn parse_device_id(id_str: &str) -> Option<DeviceId> {
    uuid::Uuid::parse_str(id_str)
        .ok()
        .map(|u| DeviceId::from_bytes(*u.as_bytes()))
}

pub fn get_local_lan_ip() -> String {
    if let Ok(socket) = std::net::UdpSocket::bind("0.0.0.0:0") {
        if socket.connect("8.8.8.8:80").is_ok() {
            if let Ok(addr) = socket.local_addr() {
                return addr.ip().to_string();
            }
        }
    }
    "127.0.0.1".to_string()
}

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

/// Initializes the Nexus Engine asynchronously from Rust
pub async fn init_nexus_engine(device_name: String) -> nexus_types::NexusResult<DeviceId> {
    let mut engine_guard = GLOBAL_ENGINE.write().await;
    if let Some(engine) = engine_guard.as_ref() { return Ok(engine.device_id); }
    let identity = DeviceIdentity::load_or_create().map_err(|e| nexus_types::NexusError::Crypto(format!("Identity storage: {e}")))?;
    let device_id = identity.device_id;

    let (bus, mut cmd_rx) = EventBus::new(256, 128);

    let media_actor = Arc::new(MediaPluginActor::new(device_id).with_device_name(device_name.clone()));
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


    *engine_guard = Some(handle);
    IS_INITIALIZED.store(true, Ordering::SeqCst);

    Ok(device_id)
}
