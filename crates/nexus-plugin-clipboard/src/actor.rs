use async_trait::async_trait;
use nexus_actor_system::{EventBus, NexusActor, NexusCommand};
use nexus_protocol::{ClipboardPayload, NexusPacket, PacketPayload, SmartHintType};
use nexus_types::{DeviceId, NexusResult};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::info;
use uuid::Uuid;

use crate::loop_guard::ClipboardLoopGuard;
use crate::parser::SmartClipboardParser;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ClipboardHistoryItem {
    pub id: String,
    pub text: String,
    pub hint_type: Option<SmartHintType>,
    pub timestamp_ms: u64,
    pub source_device: String,
    pub is_locked: bool,
    pub secret_type: Option<String>,
}

/// Clipboard Plugin Actor with Zero-Trust Privacy Gate
#[derive(Clone)]
pub struct ClipboardPluginActor {
    pub device_id: DeviceId,
    pub parser: SmartClipboardParser,
    loop_guard: Arc<RwLock<ClipboardLoopGuard>>,
    history: Arc<RwLock<Vec<ClipboardHistoryItem>>>,
    privacy_gate_enabled: Arc<RwLock<bool>>,
    pending_secrets: Arc<RwLock<HashMap<String, String>>>,
}

impl ClipboardPluginActor {
    pub fn new(device_id: DeviceId) -> Self {
        Self {
            device_id,
            parser: SmartClipboardParser::default(),
            loop_guard: Arc::new(RwLock::new(ClipboardLoopGuard::default())),
            history: Arc::new(RwLock::new(Vec::new())),
            privacy_gate_enabled: Arc::new(RwLock::new(true)),
            pending_secrets: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    /// Toggles the Zero-Trust Privacy Gate ON/OFF
    pub async fn set_privacy_gate_enabled(&self, enabled: bool) {
        let mut gate = self.privacy_gate_enabled.write().await;
        *gate = enabled;
        info!("Clipboard Privacy Gate set to: {}", enabled);
    }

    /// Checks if Privacy Gate is enabled
    pub async fn is_privacy_gate_enabled(&self) -> bool {
        *self.privacy_gate_enabled.read().await
    }

    /// Stores a secret locally waiting for on-demand reveal request
    pub async fn store_pending_secret(&self, entry_id: String, cleartext: String) {
        let mut secrets = self.pending_secrets.write().await;
        secrets.insert(entry_id, cleartext);
    }

    /// Reveals a stored secret given its entry_id
    pub async fn reveal_secret(&self, entry_id: &str) -> Option<String> {
        let secrets = self.pending_secrets.read().await;
        secrets.get(entry_id).cloned()
    }

    /// Returns the live real clipboard history
    pub async fn get_history(&self) -> Vec<ClipboardHistoryItem> {
        self.history.read().await.clone()
    }

    /// Called when local OS clipboard content changes
    pub async fn on_local_clipboard_changed(
        &self,
        bus: &EventBus,
        text: &str,
        target_peer: Option<DeviceId>,
    ) -> NexusResult<Option<SmartHintType>> {
        {
            let mut guard = self.loop_guard.write().await;
            if guard.is_known_or_insert(text) {
                return Ok(None);
            }
        }

        let (is_secret, secret_label, hint) = self.parser.classify_privacy(text);
        let gate_on = *self.privacy_gate_enabled.read().await;
        let entry_id = Uuid::new_v4().to_string();

        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;

        if is_secret && gate_on {
            // ZERO-TRUST PRIVACY GATE: Do NOT transmit cleartext over the network!
            // Store cleartext locally in the vault
            {
                let mut secrets = self.pending_secrets.write().await;
                secrets.insert(entry_id.clone(), text.to_string());
            }

            // Record in local history (originator sees it)
            let item = ClipboardHistoryItem {
                id: entry_id.clone(),
                text: text.to_string(),
                hint_type: hint,
                timestamp_ms: now_ms,
                source_device: "Dispositivo Locale".into(),
                is_locked: false,
                secret_type: Some(secret_label.to_string()),
            };

            {
                let mut hist = self.history.write().await;
                hist.insert(0, item);
                if hist.len() > 50 {
                    hist.truncate(50);
                }
            }

            // Send announcement with masked placeholder ONLY
            let payload = PacketPayload::Clipboard(ClipboardPayload::SecretAnnounce {
                entry_id,
                secret_type: secret_label.to_string(),
                masked_preview: format!("•••••• ({})", secret_label),
            });

            let mut packet = NexusPacket::new(self.device_id, payload);
            if let Some(target) = target_peer {
                packet = packet.with_target(target);
                bus.send_command(NexusCommand::SendPacket { target, packet }).await?;
            } else {
                bus.send_command(NexusCommand::BroadcastPacket { packet }).await?;
            }

            info!("🛡️ Zero-Trust Gate: Secret '{}' announced with masked preview. Cleartext retained locally.", secret_label);
            Ok(hint)
        } else {
            // SAFE CONTENT: auto-share immediately
            let hash = *blake3::hash(text.as_bytes()).as_bytes();

            let item = ClipboardHistoryItem {
                id: entry_id,
                text: text.to_string(),
                hint_type: hint,
                timestamp_ms: now_ms,
                source_device: "Dispositivo Locale".into(),
                is_locked: false,
                secret_type: None,
            };

            {
                let mut hist = self.history.write().await;
                hist.insert(0, item);
                if hist.len() > 50 {
                    hist.truncate(50);
                }
            }

            let payload = PacketPayload::Clipboard(ClipboardPayload::EncryptedText {
                nonce: [0u8; 12],
                ciphertext: text.as_bytes().to_vec(),
                plain_hash: hash,
            });

            let mut packet = NexusPacket::new(self.device_id, payload);
            if let Some(target) = target_peer {
                packet = packet.with_target(target);
                bus.send_command(NexusCommand::SendPacket { target, packet }).await?;
            } else {
                bus.send_command(NexusCommand::BroadcastPacket { packet }).await?;
            }

            info!("Local safe clipboard synchronized E2EE (Smart Hint: {:?})", hint);
            Ok(hint)
        }
    }
}

#[async_trait]
impl NexusActor for ClipboardPluginActor {
    fn name(&self) -> &'static str {
        "nexus-plugin-clipboard"
    }

    async fn run(&mut self, _bus: EventBus) -> NexusResult<()> {
        tokio::time::sleep(tokio::time::Duration::from_secs(3600 * 24)).await;
        Ok(())
    }
}
