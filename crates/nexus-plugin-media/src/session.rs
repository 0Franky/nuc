use serde::{Deserialize, Serialize};

pub fn append_log(file_name: &str, line: &str) {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let formatted = format!("[timestamp_ms: {}] {}\n", now, line);
    let log_path = std::path::PathBuf::from("logs").join(file_name);
    if let Some(parent) = log_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
    {
        use std::io::Write;
        let _ = f.write_all(formatted.as_bytes());
    }
}

/// Active Media Playback Session on the Local Node
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct ActiveMediaSession {
    pub session_id: String,
    pub source_app: String, // e.g. "YouTube (Chrome)", "Spotify", "VLC"
    pub media_title: String,
    pub media_url: String,
    pub position_ms: u64,
    pub duration_ms: u64,
    pub is_playing: bool,
    pub last_updated_ms: u64,
}
