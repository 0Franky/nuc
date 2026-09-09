use nexus_protocol::SmartHintType;
use regex::Regex;

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
