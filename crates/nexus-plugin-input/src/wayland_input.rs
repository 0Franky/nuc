//! Wayland touchpad input through the desktop RemoteDesktop portal. The portal
//! owns permission UI; a dedicated runtime keeps its session and DBus alive.
use crate::linux::WaylandEvent;
use ashpd::desktop::{
    remote_desktop::{Axis, DeviceType, KeyState, RemoteDesktop, SelectDevicesOptions},
    Session,
};
use nexus_types::{NexusError, NexusResult};
use std::{
    sync::{mpsc, Arc, Mutex, OnceLock},
    time::{Duration, Instant},
};

const PENDING: &str = "Autorizza mouse e tastiera nella finestra di condivisione sul PC Linux";
enum Status {
    Pending,
    Ready,
    Failed(String),
}
struct Request {
    event: WaylandEvent,
    deadline: Instant,
    reply: mpsc::SyncSender<Result<(), String>>,
}
struct Worker {
    sender: tokio::sync::mpsc::Sender<Request>,
    status: Arc<Mutex<Status>>,
}
static WORKER: OnceLock<Result<Worker, String>> = OnceLock::new();
fn error(message: impl Into<String>) -> NexusError {
    NexusError::Plugin {
        plugin: "input.linux.wayland",
        message: message.into(),
    }
}

fn event_budget(event: &WaylandEvent) -> NexusResult<Duration> {
    if let WaylandEvent::Text(text) = event {
        let length = text.chars().count();
        if length > 4096 { return Err(error("Il testo supera il limite di 4096 caratteri; non è stato digitato.")); }
        return Ok(Duration::from_millis((1000 + length as u64 * 10).min(30_000)));
    }
    Ok(Duration::from_secs(1))
}

pub(super) fn send(event: WaylandEvent) -> NexusResult<()> {
    let budget = event_budget(&event)?;
    let worker = WORKER
        .get_or_init(start_worker)
        .as_ref()
        .map_err(|e| error(e.clone()))?;
    match &*worker
        .status
        .lock()
        .map_err(|_| error("Stato portale non disponibile"))?
    {
        Status::Pending => return Err(error(PENDING)),
        Status::Failed(message) => return Err(error(message.clone())),
        Status::Ready => {}
    }
    let (reply, response) = mpsc::sync_channel(1);
    worker
        .sender
        .try_send(Request { event, deadline: Instant::now() + budget, reply })
        .map_err(|_| error("Portale input occupato o terminato"))?;
    response
        .recv_timeout(budget + Duration::from_secs(1))
        .map_err(|_| error("Il portale input non risponde: il testo potrebbe essere parziale. Controlla il PC prima di reinviare."))?
        .map_err(error)
}

fn start_worker() -> Result<Worker, String> {
    let (sender, mut receiver) = tokio::sync::mpsc::channel::<Request>(8);
    let status = Arc::new(Mutex::new(Status::Pending));
    let state = status.clone();
    std::thread::Builder::new().name("nexus-wayland-input".into()).spawn(move || {
        let result: Result<(), String> = (|| {
            let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|e| e.to_string())?;
            runtime.block_on(async {
                let (portal, session) = tokio::time::timeout(Duration::from_secs(120), open_session())
                    .await.map_err(|_| "Tempo scaduto per il consenso desktop".to_string())?
                    .map_err(|e| e.to_string())?;
                *state.lock().unwrap() = Status::Ready;
                while let Some(request) = receiver.recv().await {
                    let remaining = request.deadline.saturating_duration_since(Instant::now());
                    if remaining.is_zero() {
                        let _ = request.reply.send(Err("Input scaduto in coda; non è stato eseguito.".into()));
                        continue;
                    }
                    let result = tokio::time::timeout(remaining, dispatch(&portal, &session, request.event))
                        .await.map_err(|_| "Tempo scaduto durante input Wayland: il testo potrebbe essere parziale. Controlla il PC prima di reinviare.".to_string())
                        .and_then(|r| r.map_err(|e| e.to_string()));
                    let failed = result.is_err();
                    let _ = request.reply.send(result.clone());
                    if failed {
                        *state.lock().unwrap() = Status::Failed(result.clone().unwrap_err());
                        let _ = tokio::time::timeout(Duration::from_secs(2), session.close()).await;
                        return result;
                    }
                }
                let _ = session.close().await;
                Ok(())
            })
        })();
        if let Err(reason) = result {
            // Keep a denied/failed request sticky: pointer deltas must never
            // open an endless sequence of desktop permission dialogs.
            *state.lock().unwrap() = Status::Failed(format!("Input Wayland non autorizzato/disponibile: {reason}. Verifica il portale RemoteDesktop GNOME/KDE e riavvia Nexus per riprovare."));
        }
    }).map_err(|e| e.to_string())?;
    Ok(Worker { sender, status })
}

async fn open_session() -> Result<(RemoteDesktop, Session<RemoteDesktop>), String> {
    let portal = RemoteDesktop::new().await.map_err(|e| e.to_string())?;
    let session = portal
        .create_session(Default::default())
        .await
        .map_err(|e| e.to_string())?;
    portal
        .select_devices(
            &session,
            SelectDevicesOptions::default().set_devices(DeviceType::Pointer | DeviceType::Keyboard),
        )
        .await
        .map_err(|e| e.to_string())?
        .response()
        .map_err(|e| e.to_string())?;
    let selected = portal
        .start(&session, None, Default::default())
        .await
        .map_err(|e| e.to_string())?
        .response()
        .map_err(|e| e.to_string())?;
    if !selected
        .devices()
        .contains(DeviceType::Pointer | DeviceType::Keyboard)
    {
        let _ = session.close().await;
        return Err("Il desktop non ha autorizzato sia mouse sia tastiera".into());
    }
    Ok((portal, session))
}

fn key_state(down: bool) -> KeyState {
    if down {
        KeyState::Pressed
    } else {
        KeyState::Released
    }
}
async fn key(
    portal: &RemoteDesktop,
    session: &Session<RemoteDesktop>,
    code: u16,
    down: bool,
) -> ashpd::Result<()> {
    portal
        .notify_keyboard_keycode(
            session,
            i32::from(code),
            key_state(down),
            Default::default(),
        )
        .await
}
async fn dispatch(
    portal: &RemoteDesktop,
    session: &Session<RemoteDesktop>,
    event: WaylandEvent,
) -> ashpd::Result<()> {
    match event {
        WaylandEvent::Motion(x, y) => {
            portal
                .notify_pointer_motion(session, f64::from(x), f64::from(y), Default::default())
                .await?
        }
        WaylandEvent::Button(button, down) => {
            if down != Some(false) {
                portal
                    .notify_pointer_button(session, button, KeyState::Pressed, Default::default())
                    .await?;
            }
            if down != Some(true) {
                portal
                    .notify_pointer_button(session, button, KeyState::Released, Default::default())
                    .await?;
            }
        }
        WaylandEvent::Scroll(steps) => {
            portal
                .notify_pointer_axis_discrete(session, Axis::Vertical, steps, Default::default())
                .await?
        }
        WaylandEvent::Key(code, down) => {
            if down != Some(false) {
                key(portal, session, code, true).await?;
            }
            if down != Some(true) {
                key(portal, session, code, false).await?;
            }
        }
        WaylandEvent::Combo(codes) => {
            for &code in &codes {
                key(portal, session, code, true).await?;
            }
            for &code in codes.iter().rev() {
                key(portal, session, code, false).await?;
            }
        }
        WaylandEvent::Text(text) => {
            for ch in text.chars() {
                let sym = match ch {
                    '\n' => 0xff0d,
                    '\t' => 0xff09,
                    _ if (ch as u32) < 0x100 => ch as i32,
                    _ => (ch as i32) | 0x01000000,
                };
                portal
                    .notify_keyboard_keysym(session, sym, KeyState::Pressed, Default::default())
                    .await?;
                portal
                    .notify_keyboard_keysym(session, sym, KeyState::Released, Default::default())
                    .await?;
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod budget_tests {
    use super::*;
    #[test]
    fn long_text_has_a_bounded_budget_and_oversize_is_rejected_before_input() {
        assert_eq!(event_budget(&WaylandEvent::Motion(1, 1)).unwrap(), Duration::from_secs(1));
        assert_eq!(event_budget(&WaylandEvent::Text("a".repeat(1000))).unwrap(), Duration::from_secs(11));
        assert_eq!(event_budget(&WaylandEvent::Text("à".repeat(4096))).unwrap(), Duration::from_secs(30));
        assert!(event_budget(&WaylandEvent::Text("a".repeat(4097))).is_err());
    }
}
