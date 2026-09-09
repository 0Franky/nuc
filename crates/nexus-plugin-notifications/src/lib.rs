use async_trait::async_trait;
use nexus_actor_system::{EventBus, NexusActor};
use nexus_types::{DeviceId, NexusResult};
use std::collections::HashSet;
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::info;

/// Windows OS Notification Capture & Forwarding Plugin
///
/// Listens for Windows toast notifications via UserNotificationListener (WinRT)
/// and broadcasts them as JSON messages to connected WebSocket clients
/// through the shared `connected_clients` channel.
#[derive(Clone)]
pub struct NotificationPluginActor {
    pub device_id: DeviceId,
    /// Shared sender list — injected from MediaPluginActor so notifications
    /// are broadcast on the same WebSocket port (28471).
    pub connected_clients: Arc<RwLock<Vec<tokio::sync::mpsc::UnboundedSender<String>>>>,
    /// Track notification IDs already forwarded to avoid duplicates
    seen_ids: Arc<RwLock<HashSet<u32>>>,
    /// Device hostname for sender_device field
    hostname: String,
}

impl NotificationPluginActor {
    pub fn new(
        device_id: DeviceId,
        connected_clients: Arc<RwLock<Vec<tokio::sync::mpsc::UnboundedSender<String>>>>,
        hostname: String,
    ) -> Self {
        Self {
            device_id,
            connected_clients,
            seen_ids: Arc::new(RwLock::new(HashSet::new())),
            hostname,
        }
    }
}

#[async_trait]
impl NexusActor for NotificationPluginActor {
    fn name(&self) -> &'static str {
        "nexus-plugin-notifications"
    }

    async fn run(&mut self, _bus: EventBus) -> NexusResult<()> {
        info!("🔔 Notification Plugin starting (Windows UserNotificationListener)...");

        #[cfg(windows)]
        {
            match self.run_windows_listener().await {
                Ok(()) => info!("Notification Plugin stopped gracefully."),
                Err(e) => {
                    tracing::error!("Notification Plugin error: {}", e);
                    return Err(nexus_types::NexusError::Internal(format!(
                        "Notification listener failed: {}",
                        e
                    )));
                }
            }
        }

        #[cfg(not(windows))]
        {
            info!("Notification Plugin: Not on Windows, notification capture unavailable. Sleeping.");
            // On non-Windows platforms, just sleep forever (no-op)
            std::future::pending::<()>().await;
        }

        Ok(())
    }
}

#[cfg(windows)]
impl NotificationPluginActor {
    async fn run_windows_listener(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        use windows::UI::Notifications::Management::{
            UserNotificationListener, UserNotificationListenerAccessStatus,
        };

        // 1. Get the current UserNotificationListener
        let listener = UserNotificationListener::Current()?;

        // 2. Request access (may prompt user in Windows Settings > Privacy > Notifications)
        // Note: windows crate 0.58 IAsyncOperation doesn't impl Future, use .get() to block
        let access = listener.RequestAccessAsync()?.get()?;

        match access {
            UserNotificationListenerAccessStatus::Allowed => {
                info!("🔔 Windows Notification Listener: Access ALLOWED. Starting polling loop.");
            }
            UserNotificationListenerAccessStatus::Denied => {
                tracing::warn!(
                    "🔔 Windows Notification Listener: Access DENIED. \
                     Please enable notification access in Windows Settings > \
                     Privacy & Security > Notifications."
                );
                // Sleep forever — user needs to grant permission manually
                std::future::pending::<()>().await;
                return Ok(());
            }
            _ => {
                tracing::warn!("🔔 Windows Notification Listener: Unspecified access status.");
                std::future::pending::<()>().await;
                return Ok(());
            }
        }

        // 3. Polling loop: check for new notifications every 2 seconds
        loop {
            if let Err(e) = self.poll_notifications(&listener).await {
                tracing::warn!("Notification poll error (will retry): {}", e);
            }
            tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;
        }
    }

    async fn poll_notifications(
        &self,
        listener: &windows::UI::Notifications::Management::UserNotificationListener,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        use windows::UI::Notifications::NotificationKinds;

        // Phase 1: Extract all data synchronously from WinRT COM objects (not Send)
        // into plain Rust types, so no COM objects are held across .await points.
        let extracted = {
            let notifications = listener
                .GetNotificationsAsync(NotificationKinds::Toast)?
                .get()?;

            let count = notifications.Size()?;
            let mut items: Vec<(u32, String, String, String)> = Vec::new();

            for i in 0..count {
                let user_notif = notifications.GetAt(i)?;
                let notif_id = user_notif.Id()?;

                // Extract app name
                let app_name = match user_notif.AppInfo() {
                    Ok(app_info) => match app_info.DisplayInfo() {
                        Ok(display_info) => match display_info.DisplayName() {
                            Ok(name) => name.to_string(),
                            Err(_) => "Sconosciuta".to_string(),
                        },
                        Err(_) => "Sconosciuta".to_string(),
                    },
                    Err(_) => "Sconosciuta".to_string(),
                };

                // Skip self-notifications from Nexus
                let app_lower = app_name.to_lowercase();
                if app_lower.contains("nexus") || app_lower.contains("continuity") {
                    continue;
                }

                let (title, body) = self.extract_notification_text(&user_notif);

                if title.is_empty() && body.is_empty() {
                    continue;
                }

                items.push((notif_id, app_name, title, body));
            }
            items
            // All COM objects (notifications, user_notif, etc.) are dropped here
        };

        // Phase 2: Process extracted data with async operations (safe to .await)
        for (notif_id, app_name, title, body) in extracted {
            // Skip already-seen notifications
            {
                let seen = self.seen_ids.read().await;
                if seen.contains(&notif_id) {
                    continue;
                }
            }

            // Mark as seen
            {
                let mut seen = self.seen_ids.write().await;
                seen.insert(notif_id);

                // Prune old IDs to prevent unbounded growth (keep last 500)
                if seen.len() > 500 {
                    let to_remove: Vec<u32> = seen.iter().take(seen.len() - 400).copied().collect();
                    for id in to_remove {
                        seen.remove(&id);
                    }
                }
            }

            let now = chrono_now_iso8601();
            let notif_json = serde_json::json!({
                "type": "NOTIFICATION_SYNC",
                "id": format!("win-notif-{}", notif_id),
                "title": title,
                "body": body,
                "app_name": app_name,
                "sender_device": self.hostname,
                "sender_device_id": format!("{}", self.device_id),
                "timestamp": now,
                "has_secret": false,
                "secret_category": "",
                "category": "osNotification",
            });

            if let Ok(msg_str) = serde_json::to_string(&notif_json) {
                let mut clients = self.connected_clients.write().await;
                clients.retain(|c| c.send(msg_str.clone()).is_ok());
                info!(
                    "🔔 Forwarded Windows notification: [{}] {} - {}",
                    app_name,
                    title,
                    if body.len() > 60 {
                        format!("{}...", &body[..60])
                    } else {
                        body.clone()
                    }
                );
            }
        }

        Ok(())
    }

    fn extract_notification_text(
        &self,
        user_notif: &windows::UI::Notifications::UserNotification,
    ) -> (String, String) {
        let mut title = String::new();
        let mut body = String::new();

        if let Ok(notification) = user_notif.Notification() {
            if let Ok(visual) = notification.Visual() {
                // Try to get the ToastGeneric binding
                if let Ok(bindings) = visual.Bindings() {
                    if let Ok(count) = bindings.Size() {
                        for i in 0..count {
                            if let Ok(binding) = bindings.GetAt(i) {
                                if let Ok(text_elements) = binding.GetTextElements() {
                                    if let Ok(text_count) = text_elements.Size() {
                                        if text_count > 0 {
                                            if let Ok(text0) = text_elements.GetAt(0) {
                                                if let Ok(t) = text0.Text() {
                                                    title = t.to_string();
                                                }
                                            }
                                        }
                                        if text_count > 1 {
                                            if let Ok(text1) = text_elements.GetAt(1) {
                                                if let Ok(t) = text1.Text() {
                                                    body = t.to_string();
                                                }
                                            }
                                        }
                                        // Concatenate additional text lines into body
                                        for j in 2..text_count {
                                            if let Ok(text_j) = text_elements.GetAt(j) {
                                                if let Ok(t) = text_j.Text() {
                                                    let line = t.to_string();
                                                    if !line.is_empty() {
                                                        if !body.is_empty() {
                                                            body.push('\n');
                                                        }
                                                        body.push_str(&line);
                                                    }
                                                }
                                            }
                                        }
                                        if !title.is_empty() {
                                            break; // Got text from the first binding that has content
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        (title, body)
    }
}

/// Simple ISO8601 timestamp without chrono dependency
fn chrono_now_iso8601() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let secs = now.as_secs();
    // Convert to rough datetime (not perfectly accurate but good enough for notification IDs)
    let days = secs / 86400;
    let time_of_day = secs % 86400;
    let hours = time_of_day / 3600;
    let minutes = (time_of_day % 3600) / 60;
    let seconds = time_of_day % 60;
    let millis = now.subsec_millis();

    // Approximate year/month/day from days since epoch (1970-01-01)
    // Good enough for notification timestamps
    let (year, month, day) = days_to_ymd(days);

    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
        year, month, day, hours, minutes, seconds, millis
    )
}

fn days_to_ymd(days_since_epoch: u64) -> (u64, u64, u64) {
    // Simplified algorithm for Gregorian calendar
    let mut y = 1970;
    let mut remaining = days_since_epoch;

    loop {
        let days_in_year = if is_leap(y) { 366 } else { 365 };
        if remaining < days_in_year {
            break;
        }
        remaining -= days_in_year;
        y += 1;
    }

    let month_days: [u64; 12] = if is_leap(y) {
        [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    } else {
        [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    };

    let mut m = 1;
    for &md in &month_days {
        if remaining < md {
            break;
        }
        remaining -= md;
        m += 1;
    }

    (y, m, remaining + 1)
}

fn is_leap(y: u64) -> bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_iso8601_format() {
        let ts = chrono_now_iso8601();
        assert!(ts.contains('T'));
        assert!(ts.ends_with('Z'));
        // Should look like: 2026-09-08T19:03:12.123Z
        assert!(ts.len() >= 20);
    }

    #[test]
    fn test_days_to_ymd() {
        // 2026-09-08 is day 20704 since epoch (approx)
        let (y, m, d) = days_to_ymd(0);
        assert_eq!(y, 1970);
        assert_eq!(m, 1);
        assert_eq!(d, 1);
    }
}
