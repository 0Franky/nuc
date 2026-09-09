#[cfg(target_os = "windows")]
pub fn set_windows_master_volume(volume: f32) {
    use windows::Win32::Media::Audio::Endpoints::IAudioEndpointVolume;
    use windows::Win32::Media::Audio::{
        eMultimedia, eRender, IMMDeviceEnumerator, MMDeviceEnumerator,
    };
    use windows::Win32::System::Com::{
        CoCreateInstance, CoInitializeEx, CLSCTX_ALL, COINIT_MULTITHREADED,
    };

    let clamped = volume.clamp(0.0, 1.0);
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        if let Ok(enumerator) =
            CoCreateInstance::<_, IMMDeviceEnumerator>(&MMDeviceEnumerator, None, CLSCTX_ALL)
        {
            if let Ok(device) = enumerator.GetDefaultAudioEndpoint(eRender, eMultimedia) {
                if let Ok(endpoint_volume) =
                    device.Activate::<IAudioEndpointVolume>(CLSCTX_ALL, None)
                {
                    let _ = endpoint_volume.SetMasterVolumeLevelScalar(clamped, std::ptr::null());
                    if clamped > 0.0 {
                        let _ = endpoint_volume.SetMute(false, std::ptr::null());
                    }
                    tracing::info!(
                        "🔊 Windows OS Master Volume adjusted to: {:.0}%",
                        clamped * 100.0
                    );
                }
            }
        }
    }
}

#[cfg(target_os = "linux")]
pub fn set_windows_master_volume(volume: f32) {
    let clamped = volume.clamp(0.0, 1.0);
    let pct = (clamped * 100.0).round() as u32;
    let pactl_res = std::process::Command::new("pactl")
        .args(["set-sink-volume", "@DEFAULT_SINK@", &format!("{}%", pct)])
        .status();
    if pactl_res.is_err() || !pactl_res.as_ref().unwrap().success() {
        let _ = std::process::Command::new("amixer")
            .args(["sset", "Master", &format!("{}%", pct)])
            .status();
    }
    tracing::info!("🔊 Linux OS Master Volume adjusted to: {}%", pct);
}

#[cfg(all(not(target_os = "windows"), not(target_os = "linux")))]
pub fn set_windows_master_volume(_volume: f32) {}

#[cfg(target_os = "windows")]
pub fn toggle_pc_speakers_mute() {
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
        SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP,
    };
    let mut inputs = [
        INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT {
                    wVk: 0xAD, // VK_VOLUME_MUTE
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
                    wVk: 0xAD,
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

#[cfg(target_os = "linux")]
pub fn toggle_pc_speakers_mute() {
    let pactl_res = std::process::Command::new("pactl")
        .args(["set-sink-mute", "@DEFAULT_SINK@", "toggle"])
        .status();
    if pactl_res.is_err() || !pactl_res.as_ref().unwrap().success() {
        let _ = std::process::Command::new("amixer")
            .args(["sset", "Master", "toggle"])
            .status();
    }
    tracing::info!("🔇 Linux PC speaker mute toggled");
}

#[cfg(all(not(target_os = "windows"), not(target_os = "linux")))]
pub fn toggle_pc_speakers_mute() {}
