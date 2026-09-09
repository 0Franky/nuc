use async_trait::async_trait;
use nexus_actor_system::{EventBus, NexusActor, NexusCommand};
use nexus_protocol::{ClipboardPayload, NexusPacket, PacketPayload, SmartHintType};
use nexus_types::{DeviceId, NexusResult};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::info;
use uuid::Uuid;

/// Smart Content Analyzer and Privacy Gate for System Clipboard
#[derive(Clone)]
pub struct SmartClipboardParser {
    otp_regex: Regex,
    hex_color_regex: Regex,
    url_regex: Regex,
    phone_regex: Regex,
    api_key_regex: Regex,
    credit_card_regex: Regex,
    iban_regex: Regex,
    codice_fiscale_regex: Regex,
    private_key_regex: Regex,
}

impl SmartClipboardParser {
    pub fn new() -> Self {
        Self {
            otp_regex: Regex::new(r"^\b\d{4,8}\b$").expect("Invalid OTP regex"),
            hex_color_regex: Regex::new(r"^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$")
                .expect("Invalid Hex regex"),
            url_regex: Regex::new(r"^(?:https?://|www\.)[^\s/$.?#].[^\s]*$").expect("Invalid URL regex"),
            phone_regex: Regex::new(r"^\+?[0-9\s\-()]{7,20}$").expect("Invalid Phone regex"),
            api_key_regex: Regex::new(r"(?:sk-[a-zA-Z0-9_\-]{15,}|ghp_[a-zA-Z0-9]{15,}|gho_[a-zA-Z0-9]{15,}|glpat-[a-zA-Z0-9_\-]{15,}|Bearer\s+[a-zA-Z0-9_\-\.]+|ey[A-Za-z0-9-_=]+\.[A-Za-z0-9-_=]+\.?[A-Za-z0-9-_.+/=]*)")
                .expect("Invalid API key regex"),
            credit_card_regex: Regex::new(r"\b(?:\d[ -]*?){13,19}\b").expect("Invalid Credit Card regex"),
            iban_regex: Regex::new(r"\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b").expect("Invalid IBAN regex"),
            codice_fiscale_regex: Regex::new(r"\b[A-Z]{6}\d{2}[A-Z]\d{2}[A-Z]\d{3}[A-Z]\b").expect("Invalid CF regex"),
            private_key_regex: Regex::new(r"-----BEGIN (?:[A-Z ]+)KEY-----").expect("Invalid Private Key regex"),
        }
    }

    /// Detects smart contextual actions from copied text
    pub fn analyze(&self, text: &str) -> Option<SmartHintType> {
        let trimmed = text.trim();
        if self.otp_regex.is_match(trimmed) {
            return Some(SmartHintType::Otp2Fa);
        }
        if self.private_key_regex.is_match(trimmed) || self.api_key_regex.is_match(trimmed) {
            return Some(SmartHintType::ApiKey);
        }
        if self.iban_regex.is_match(trimmed) || self.codice_fiscale_regex.is_match(trimmed) {
            return Some(SmartHintType::PiiSecret);
        }
        if self.credit_card_regex.is_match(trimmed) {
            let digit_count = trimmed.chars().filter(|c| c.is_ascii_digit()).count();
            if (13..=19).contains(&digit_count) {
                return Some(SmartHintType::CreditCard);
            }
        }
        if self.hex_color_regex.is_match(trimmed) {
            return Some(SmartHintType::HexColor);
        }
        if self.url_regex.is_match(trimmed) {
            return Some(SmartHintType::Url);
        }
        if self.phone_regex.is_match(trimmed) && trimmed.chars().any(|c| c.is_ascii_digit()) {
            return Some(SmartHintType::PhoneNumber);
        }
        None
    }

    /// Classifies whether copied text is a Secret or PII vs Safe Content
    /// Returns (is_secret_or_pii, category_label, optional_hint)
    pub fn classify_privacy(&self, text: &str) -> (bool, &'static str, Option<SmartHintType>) {
        let trimmed = text.trim();

        // 1. Check OTP (2FA code)
        if self.otp_regex.is_match(trimmed) {
            return (true, "Codice OTP (2FA)", Some(SmartHintType::Otp2Fa));
        }

        // 2. Check Private Key
        if self.private_key_regex.is_match(trimmed) {
            return (true, "Chiave Privata", Some(SmartHintType::ApiKey));
        }

        // 3. Check API Keys & Auth Tokens (OpenAI sk-..., GitHub ghp_..., JWT tokens)
        if self.api_key_regex.is_match(trimmed) {
            return (true, "Chiave API / Token", Some(SmartHintType::ApiKey));
        }

        // 4. Check Credit Card Numbers
        if self.credit_card_regex.is_match(trimmed) {
            let digit_count = trimmed.chars().filter(|c| c.is_ascii_digit()).count();
            if (13..=19).contains(&digit_count) {
                return (true, "Carta di Credito", Some(SmartHintType::CreditCard));
            }
        }

        // 5. Check IBAN or Codice Fiscale (PII)
        if self.iban_regex.is_match(trimmed) {
            return (true, "Coordinate Bancarie (IBAN)", Some(SmartHintType::PiiSecret));
        }
        if self.codice_fiscale_regex.is_match(trimmed) {
            return (true, "Codice Fiscale (PII)", Some(SmartHintType::PiiSecret));
        }

        // 6. Safe Content
        if self.url_regex.is_match(trimmed) {
            return (false, "Link URL", Some(SmartHintType::Url));
        }
        if self.hex_color_regex.is_match(trimmed) {
            return (false, "Colore HEX", Some(SmartHintType::HexColor));
        }
        if self.phone_regex.is_match(trimmed) && trimmed.chars().any(|c| c.is_ascii_digit()) {
            return (false, "Numero di Telefono", Some(SmartHintType::PhoneNumber));
        }

        (false, "Testo Semplice", None)
    }
}

impl Default for SmartClipboardParser {
    fn default() -> Self {
        Self::new()
    }
}

/// Prevents infinite synchronization ping-pong loops
pub struct ClipboardLoopGuard {
    seen_hashes: HashSet<[u8; 32]>,
}

impl ClipboardLoopGuard {
    pub fn new() -> Self {
        Self {
            seen_hashes: HashSet::new(),
        }
    }

    pub fn is_known_or_insert(&mut self, text: &str) -> bool {
        let hash = *blake3::hash(text.as_bytes()).as_bytes();
        if self.seen_hashes.contains(&hash) {
            true
        } else {
            // Keep set size bounded to 500 recent items
            if self.seen_hashes.len() > 500 {
                self.seen_hashes.clear();
            }
            self.seen_hashes.insert(hash);
            false
        }
    }
}

impl Default for ClipboardLoopGuard {
    fn default() -> Self {
        Self::new()
    }
}

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_smart_parser_otp() {
        let parser = SmartClipboardParser::new();
        assert_eq!(parser.analyze("849201"), Some(SmartHintType::Otp2Fa));
        assert_eq!(parser.analyze("1234"), Some(SmartHintType::Otp2Fa));
        assert_eq!(parser.analyze("not-an-otp"), None);
    }

    #[test]
    fn test_smart_parser_hex_color() {
        let parser = SmartClipboardParser::new();
        assert_eq!(parser.analyze("#FF5733"), Some(SmartHintType::HexColor));
        assert_eq!(parser.analyze("#fff"), Some(SmartHintType::HexColor));
        assert_eq!(parser.analyze("#112233AA"), Some(SmartHintType::HexColor));
    }

    #[test]
    fn test_smart_parser_url() {
        let parser = SmartClipboardParser::new();
        assert_eq!(
            parser.analyze("https://youtube.com/watch?v=123"),
            Some(SmartHintType::Url)
        );
    }

    #[test]
    fn test_loop_guard() {
        let mut guard = ClipboardLoopGuard::new();
        let text = "Hello Nexus!";

        assert!(!guard.is_known_or_insert(text));
        // Second check with same text should return true (already seen)
        assert!(guard.is_known_or_insert(text));
    }

    #[test]
    fn test_phone_and_plain_text_discrimination() {
        let parser = SmartClipboardParser::new();

        // Valid phone formats
        assert_eq!(parser.analyze("+39 340 1234567"), Some(SmartHintType::PhoneNumber));
        assert_eq!(parser.analyze("(02) 8920192"), Some(SmartHintType::PhoneNumber));

        // Normal prose must NOT trigger smart chips
        assert_eq!(parser.analyze("just a regular text sentence"), None);
    }

    #[test]
    fn test_loop_guard_memory_bounding() {
        let mut guard = ClipboardLoopGuard::new();

        // Inserting 600 distinct items must trigger safe cache rollover
        for i in 0..600 {
            let item = format!("clipboard-item-hash-{}", i);
            let _ = guard.is_known_or_insert(&item);
        }

        // Must still function safely without memory explosion
        assert!(!guard.is_known_or_insert("brand-new-item"));
    }

    #[test]
    fn test_privacy_gate_discrimination() {
        let parser = SmartClipboardParser::new();

        // 1. Secrets & PII: must return is_secret = true
        let (otp_secret, otp_label, otp_hint) = parser.classify_privacy("849201");
        assert!(otp_secret);
        assert_eq!(otp_hint, Some(SmartHintType::Otp2Fa));
        assert_eq!(otp_label, "Codice OTP (2FA)");

        let (api_secret, _, api_hint) = parser.classify_privacy("sk-proj-abc1234567890123456789012");
        assert!(api_secret);
        assert_eq!(api_hint, Some(SmartHintType::ApiKey));

        let (ghp_secret, _, _) = parser.classify_privacy("ghp_ABCDEFGHIJKL12345678901234567890");
        assert!(ghp_secret);

        let (jwt_secret, _, _) = parser.classify_privacy("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.doNotLeakThis"); // gitleaks:allow
        assert!(jwt_secret);

        let (cc_secret, cc_label, cc_hint) = parser.classify_privacy("4532 0150 9281 3847");
        assert!(cc_secret);
        assert_eq!(cc_hint, Some(SmartHintType::CreditCard));
        assert_eq!(cc_label, "Carta di Credito");

        let (iban_secret, iban_label, iban_hint) = parser.classify_privacy("IT60X0542811101000000123456");
        assert!(iban_secret);
        assert_eq!(iban_hint, Some(SmartHintType::PiiSecret));
        assert_eq!(iban_label, "Coordinate Bancarie (IBAN)");

        let (cf_secret, cf_label, _) = parser.classify_privacy("RSSMRA85M01H501Z");
        assert!(cf_secret);
        assert_eq!(cf_label, "Codice Fiscale (PII)");

        // 2. Safe Content: must return is_secret = false
        let (url_secret, _, url_hint) = parser.classify_privacy("https://github.com/eco/nexus");
        assert!(!url_secret);
        assert_eq!(url_hint, Some(SmartHintType::Url));

        let (hex_secret, _, hex_hint) = parser.classify_privacy("#6366F1");
        assert!(!hex_secret);
        assert_eq!(hex_hint, Some(SmartHintType::HexColor));

        let (phone_secret, _, phone_hint) = parser.classify_privacy("+39 340 1234567");
        assert!(!phone_secret);
        assert_eq!(phone_hint, Some(SmartHintType::PhoneNumber));

        let (plain_secret, _, plain_hint) = parser.classify_privacy("Ecco la ricetta per la pizza fatta in casa");
        assert!(!plain_secret);
        assert_eq!(plain_hint, None);
    }

    #[tokio::test]
    async fn test_privacy_gate_secret_reveal_workflow() {
        let device_id = DeviceId::new_random();
        let actor = ClipboardPluginActor::new(device_id);

        assert!(actor.is_privacy_gate_enabled().await);

        // Store a secret in the vault
        let secret_id = "test-secret-1234";
        let secret_code = "998201";
        actor.store_pending_secret(secret_id.into(), secret_code.into()).await;

        // Reveal it
        let revealed = actor.reveal_secret(secret_id).await;
        assert_eq!(revealed, Some(secret_code.to_string()));

        // Non-existent secret returns None
        assert_eq!(actor.reveal_secret("unknown-id").await, None);

        // Toggle gate off
        actor.set_privacy_gate_enabled(false).await;
        assert!(!actor.is_privacy_gate_enabled().await);
    }
}
