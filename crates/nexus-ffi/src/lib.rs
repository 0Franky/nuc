#![allow(clippy::not_unsafe_ptr_arg_deref)]

pub mod bindings;
pub mod ble;
pub mod state;

pub use bindings::*;
pub use state::{
    check_system_bluetooth_enabled, init_nexus_engine, NexusEngineHandle, GLOBAL_ENGINE,
    GLOBAL_RUNTIME, IS_INITIALIZED,
};

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::{CStr, CString};
    use std::sync::atomic::Ordering;
    static TEST_MUTEX: std::sync::Mutex<()> = std::sync::Mutex::new(());

    #[tokio::test]
    async fn test_ffi_engine_init() {
        let _guard = TEST_MUTEX.lock().unwrap();
        let device_id = init_nexus_engine("Nexus Phone Test".into()).await.unwrap();
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
        let res_ptr =
            nexus_offer_file_transfer(file_name.as_ptr(), target_peer.as_ptr(), 128000);
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
                engine
                    .media_actor
                    .update_local_playback(
                        &engine.bus,
                        "YouTube (Chrome)".into(),
                        "Inception Soundtrack (Hans Zimmer)".into(),
                        "https://youtube.com/watch?v=inception".into(),
                        124000,
                        450000,
                        true,
                    )
                    .await;
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
