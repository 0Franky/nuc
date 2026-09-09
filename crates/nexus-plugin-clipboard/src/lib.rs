pub mod actor;
pub mod loop_guard;
pub mod parser;

pub use actor::{ClipboardHistoryItem, ClipboardPluginActor};
pub use loop_guard::ClipboardLoopGuard;
pub use parser::SmartClipboardParser;

#[cfg(test)]
mod tests {
    use super::*;
    use nexus_protocol::SmartHintType;

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

        // First time: not known, should insert and return false
        assert!(!guard.is_known_or_insert(text));

        // Second time: known, should return true (blocking ping-pong echo)
        assert!(guard.is_known_or_insert(text));
    }

    #[test]
    fn test_privacy_gate_discrimination() {
        let parser = SmartClipboardParser::new();

        // 1. Secrets & PII MUST be classified as is_secret = true
        let (is_sec, label, hint) = parser.classify_privacy("849201");
        assert!(is_sec);
        assert_eq!(label, "Codice OTP (2FA)");
        assert_eq!(hint, Some(SmartHintType::Otp2Fa));

        let (is_sec, label, hint) = parser.classify_privacy("sk-ant-api03-1234567890abcdefghijklmn");
        assert!(is_sec);
        assert_eq!(label, "Chiave API / Token");
        assert_eq!(hint, Some(SmartHintType::ApiKey));

        let (is_sec, label, hint) = parser.classify_privacy("-----BEGIN RSA PRIVATE KEY-----");
        assert!(is_sec);
        assert_eq!(label, "Chiave Privata");
        assert_eq!(hint, Some(SmartHintType::ApiKey));

        let (is_sec, label, hint) = parser.classify_privacy("IT60X0542811101000000123456");
        assert!(is_sec);
        assert_eq!(label, "Coordinate Bancarie (IBAN)");
        assert_eq!(hint, Some(SmartHintType::PiiSecret));

        let (is_sec, label, hint) = parser.classify_privacy("RSSMRA85M01H501Z");
        assert!(is_sec);
        assert_eq!(label, "Codice Fiscale (PII)");
        assert_eq!(hint, Some(SmartHintType::PiiSecret));

        let (is_sec, label, hint) = parser.classify_privacy("4532 0150 1234 5678");
        assert!(is_sec);
        assert_eq!(label, "Carta di Credito");
        assert_eq!(hint, Some(SmartHintType::CreditCard));

        // 2. Safe everyday items MUST be classified as is_secret = false
        let (is_sec, label, hint) = parser.classify_privacy("https://github.com/0Franky/nuc");
        assert!(!is_sec);
        assert_eq!(label, "Link URL");
        assert_eq!(hint, Some(SmartHintType::Url));

        let (is_sec, label, hint) = parser.classify_privacy("#4F46E5");
        assert!(!is_sec);
        assert_eq!(label, "Colore HEX");
        assert_eq!(hint, Some(SmartHintType::HexColor));

        let (is_sec, label, hint) = parser.classify_privacy("+39 340 1234567");
        assert!(!is_sec);
        assert_eq!(label, "Numero di Telefono");
        assert_eq!(hint, Some(SmartHintType::PhoneNumber));

        let (is_sec, label, hint) = parser.classify_privacy("Buongiorno, ci sentiamo dopo la riunione.");
        assert!(!is_sec);
        assert_eq!(label, "Testo Semplice");
        assert_eq!(hint, None);
    }

    #[tokio::test]
    async fn test_privacy_gate_secret_reveal_workflow() {
        use nexus_types::DeviceId;

        let dev_id = DeviceId::new_random();
        let actor = ClipboardPluginActor::new(dev_id);

        let secret_id = "test-secret-uuid-123".to_string();
        let secret_cleartext = "ghp_super_secret_github_token_xyz987".to_string();

        // 1. Store secret in local vault
        actor.store_pending_secret(secret_id.clone(), secret_cleartext.clone()).await;

        // 2. Reveal should retrieve exact cleartext
        let retrieved = actor.reveal_secret(&secret_id).await;
        assert_eq!(retrieved, Some(secret_cleartext));

        // 3. Unknown ID returns None
        let unknown = actor.reveal_secret("unknown-id").await;
        assert_eq!(unknown, None);
    }

    #[test]
    fn test_phone_and_plain_text_discrimination() {
        let parser = SmartClipboardParser::new();

        // Standard Italian mobile format
        let (is_sec, label, hint) = parser.classify_privacy("+39 333 1234567");
        assert!(!is_sec);
        assert_eq!(label, "Numero di Telefono");
        assert_eq!(hint, Some(SmartHintType::PhoneNumber));

        // Plain conversational message
        let (is_sec, label, hint) = parser.classify_privacy("Ciao come stai? Ci vediamo alle 18:00.");
        assert!(!is_sec);
        assert_eq!(label, "Testo Semplice");
        assert_eq!(hint, None);
    }

    #[test]
    fn test_loop_guard_memory_bounding() {
        let mut guard = ClipboardLoopGuard::new();

        // Insert 600 unique items to trigger the > 500 bound reset
        for i in 0..600 {
            guard.is_known_or_insert(&format!("clip-item-{}", i));
        }

        // Most recent item should still be known
        assert!(guard.is_known_or_insert("clip-item-599"));
    }
}
