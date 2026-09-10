#![cfg(target_os = "linux")]
use nexus_plugin_input::NativeInputInjector;
use nexus_protocol::MouseButton;
use x11rb::{
    connection::Connection,
    protocol::xproto::{ConnectionExt, KeyButMask},
};

#[test]
#[ignore = "Requires an isolated X11 display: xvfb-run cargo test -p nexus-plugin-input --test linux_pointer -- --ignored"]
fn native_pointer_works_without_external_input_commands() {
    // This integration-test process owns its environment and private display.
    // No xdotool/ydotool can be launched, even if installed on the test host.
    let old_path = std::env::var_os("PATH");
    struct RestorePath(Option<std::ffi::OsString>);
    impl Drop for RestorePath {
        fn drop(&mut self) {
            match &self.0 {
                Some(value) => std::env::set_var("PATH", value),
                None => std::env::remove_var("PATH"),
            }
        }
    }
    let _restore = RestorePath(old_path);
    std::env::set_var("PATH", "");
    let (observer, screen) = x11rb::connect(None).unwrap();
    let root = observer.setup().roots[screen].root;
    NativeInputInjector::inject_mouse_move_absolute(200, 200, 1024, 768).unwrap();
    NativeInputInjector::inject_mouse_move_relative(17, -9).unwrap();
    let position = observer.query_pointer(root).unwrap().reply().unwrap();
    assert_eq!((position.root_x, position.root_y), (217, 191));
    NativeInputInjector::inject_mouse_button(MouseButton::Left, true).unwrap();
    let pressed = observer.query_pointer(root).unwrap().reply().unwrap();
    NativeInputInjector::inject_mouse_button(MouseButton::Left, false).unwrap();
    let released = observer.query_pointer(root).unwrap().reply().unwrap();
    assert!(pressed.mask.contains(KeyButMask::BUTTON1));
    assert!(!released.mask.contains(KeyButMask::BUTTON1));
    NativeInputInjector::inject_mouse_click(MouseButton::Right).unwrap();
    NativeInputInjector::inject_mouse_wheel(-3).unwrap();
    let final_state = observer.query_pointer(root).unwrap().reply().unwrap();
    assert!(!final_state.mask.contains(KeyButMask::BUTTON3));
    assert!(!final_state.mask.contains(KeyButMask::BUTTON5));
}
