//! Persistent X11 XTest connection for pointer events. No shell commands or
//! desktop-global Xlib state; failures invalidate the connection for retry.
use nexus_types::{NexusError, NexusResult};
use std::sync::Mutex;
use x11rb::{
    connection::Connection,
    protocol::{
        xproto::{BUTTON_PRESS_EVENT, BUTTON_RELEASE_EVENT, MOTION_NOTIFY_EVENT},
        xtest::ConnectionExt as _,
    },
    rust_connection::RustConnection,
};

static CONNECTION: Mutex<Option<RustConnection>> = Mutex::new(None);
fn error(message: impl std::fmt::Display) -> NexusError {
    NexusError::Plugin {
        plugin: "input.linux.x11",
        message: format!("Input X11: {message}"),
    }
}

fn event(kind: u8, detail: u8, x: i16, y: i16) -> NexusResult<()> {
    let mut slot = CONNECTION
        .lock()
        .map_err(|_| error("connessione non disponibile"))?;
    if slot.is_none() {
        let (conn, _) = x11rb::connect(None).map_err(|e| {
            error(format!(
                "impossibile aprire DISPLAY nella sessione desktop: {e}"
            ))
        })?;
        conn.xtest_get_version(2, 2)
            .map_err(error)?
            .reply()
            .map_err(error)?;
        *slot = Some(conn);
    }
    let conn = slot.as_ref().unwrap();
    // Checked request confirms that the X server accepted the event. This also
    // flushes the request immediately instead of buffering tiny pointer deltas.
    let result = (|| {
        conn.xtest_fake_input(kind, detail, x11rb::CURRENT_TIME, x11rb::NONE, x, y, 0)
            .map_err(error)?
            .check()
            .map_err(error)?;
        conn.flush().map_err(error)
    })();
    if result.is_err() {
        *slot = None;
    }
    result
}

pub(super) fn move_pointer(x: i32, y: i32, relative: bool) -> NexusResult<()> {
    let x = i16::try_from(x).map_err(|_| error("coordinata X fuori intervallo X11"))?;
    let y = i16::try_from(y).map_err(|_| error("coordinata Y fuori intervallo X11"))?;
    event(MOTION_NOTIFY_EVENT, u8::from(relative), x, y)
}

pub(super) fn button(button: u8, down: bool) -> NexusResult<()> {
    event(
        if down {
            BUTTON_PRESS_EVENT
        } else {
            BUTTON_RELEASE_EVENT
        },
        button,
        0,
        0,
    )
}
