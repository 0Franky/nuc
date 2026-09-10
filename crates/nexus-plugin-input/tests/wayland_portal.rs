#![cfg(target_os = "linux")]
use nexus_plugin_input::NativeInputInjector;
use std::time::{Duration, Instant};

#[test]
#[ignore = "Runs without a desktop bus; explicitly run this dedicated integration test"]
fn missing_portal_reports_failure_without_blocking_or_retrying_dialogs() {
    // A deliberately unreachable, private address: never access the user's bus.
    std::env::set_var(
        "DBUS_SESSION_BUS_ADDRESS",
        "unix:path=/nonexistent/nexus-test-session-bus",
    );
    std::env::set_var("XDG_SESSION_TYPE", "wayland");
    std::env::set_var("WAYLAND_DISPLAY", "nexus-test-no-compositor");
    let start = Instant::now();
    let first = NativeInputInjector::inject_mouse_move_relative(1, 1)
        .unwrap_err()
        .to_string();
    assert!(start.elapsed() < Duration::from_secs(1));
    assert!(
        first.contains("Autorizza") || first.contains("non autorizzato/disponibile"),
        "{first}"
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    let failure = loop {
        let result = NativeInputInjector::inject_mouse_move_relative(1, 1)
            .unwrap_err()
            .to_string();
        if result.contains("non autorizzato/disponibile") {
            break result;
        }
        assert!(
            Instant::now() < deadline,
            "portal failure not surfaced: {result}"
        );
        std::thread::sleep(Duration::from_millis(20));
    };
    for _ in 0..10 {
        assert_eq!(
            NativeInputInjector::inject_mouse_move_relative(1, 1)
                .unwrap_err()
                .to_string(),
            failure
        );
    }
}
