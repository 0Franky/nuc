#![cfg(target_os = "linux")]
use nexus_plugin_input::NativeInputInjector;
use std::process::Command;

#[test]
#[ignore = "Requires an isolated X11 display: xvfb-run cargo test -p nexus-plugin-input --test linux_pointer -- --ignored"]
fn relative_and_absolute_input_move_the_real_x11_pointer() {
    NativeInputInjector::inject_mouse_move_absolute(200, 200, 1024, 768).unwrap();
    NativeInputInjector::inject_mouse_move_relative(17, -9).unwrap();
    let location = Command::new("xdotool")
        .args(["getmouselocation", "--shell"])
        .output()
        .unwrap();
    assert!(location.status.success());
    let location = String::from_utf8(location.stdout).unwrap();
    assert!(location.lines().any(|line| line == "X=217"), "{location}");
    assert!(location.lines().any(|line| line == "Y=191"), "{location}");
}
