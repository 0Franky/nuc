class SecretCensorResult {
  final bool hasSecret;
  final String maskedText;
  final String primarySecretType;

  SecretCensorResult({
    required this.hasSecret,
    required this.maskedText,
    required this.primarySecretType,
  });
}

/// Selectively censors sensitive tokens (OTP, API keys, private keys, credit cards, PII)
/// within a text while preserving the surrounding prose and message context.
SecretCensorResult censorSecretsInText(String input) {
  String masked = input;
  bool detected = false;
  String primaryType = 'Segreto';

  // 1. Private keys (PEM / RSA / EC)
  final privateKeyRegex = RegExp(
    r'-----BEGIN (?:[A-Z ]+)KEY-----[\s\S]*?-----END (?:[A-Z ]+)KEY-----|-----BEGIN (?:[A-Z ]+)KEY-----',
  );
  if (privateKeyRegex.hasMatch(masked)) {
    detected = true;
    primaryType = 'Chiave Privata';
    masked = masked.replaceAll(privateKeyRegex, '•••••••• [Chiave Privata]');
  }

  // 2. API Keys & Bearer / JWT tokens
  final apiKeyRegex = RegExp(
    r'(?:sk-[a-zA-Z0-9_\-]{15,}|ghp_[a-zA-Z0-9]{15,}|gho_[a-zA-Z0-9]{15,}|glpat-[a-zA-Z0-9_\-]{15,}|Bearer\s+[a-zA-Z0-9_\-\.]+|ey[A-Za-z0-9-_=]+\.[A-Za-z0-9-_=]+\.?[A-Za-z0-9-_.+/=]*)',
  );
  if (apiKeyRegex.hasMatch(masked)) {
    detected = true;
    if (primaryType == 'Segreto') primaryType = 'Chiave API / Token';
    masked = masked.replaceAll(apiKeyRegex, '•••••••• [Chiave API]');
  }

  // 3. IBAN
  final ibanRegex = RegExp(r'\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b');
  if (ibanRegex.hasMatch(masked)) {
    detected = true;
    if (primaryType == 'Segreto') primaryType = 'Coordinate Bancarie (IBAN)';
    masked = masked.replaceAll(ibanRegex, '•••••••• [IBAN]');
  }

  // 4. Codice Fiscale (Italian Fiscal Code - PII)
  final cfRegex = RegExp(r'\b[A-Z]{6}\d{2}[A-Z]\d{2}[A-Z]\d{3}[A-Z]\b');
  if (cfRegex.hasMatch(masked)) {
    detected = true;
    if (primaryType == 'Segreto') primaryType = 'Codice Fiscale (PII)';
    masked = masked.replaceAll(cfRegex, '•••••••• [Codice Fiscale]');
  }

  // 5. Credit Cards
  final ccCandidateRegex = RegExp(r'\b(?:\d[ -]*?){13,19}\b');
  masked = masked.replaceAllMapped(ccCandidateRegex, (m) {
    final matched = m.group(0)!;
    final digitsOnly = matched.replaceAll(RegExp(r'[^0-9]'), '');
    if (digitsOnly.length >= 13 && digitsOnly.length <= 19) {
      detected = true;
      if (primaryType == 'Segreto') primaryType = 'Carta di Credito';
      return '•••••••• [Carta di Credito]';
    }
    return matched;
  });

  // 6. OTP (2FA code: 4-8 digits standalone or contextual)
  final trimmed = input.trim();
  if (RegExp(r'^\b\d{4,8}\b$').hasMatch(trimmed)) {
    detected = true;
    primaryType = 'Codice OTP (2FA)';
    masked = '•••••• [Codice OTP]';
  } else {
    // Check if the text mentions 2FA / OTP keywords
    final hasOtpKeyword = RegExp(
      r'\b(?:otp|codice|code|token|2fa|pin|verifica|autenticazione)\b',
      caseSensitive: false,
    ).hasMatch(masked);

    if (hasOtpKeyword) {
      final otpPattern = RegExp(r'\b\d{4,8}\b');
      if (otpPattern.hasMatch(masked)) {
        detected = true;
        if (primaryType == 'Segreto') primaryType = 'Codice OTP (2FA)';
        masked = masked.replaceAll(otpPattern, '•••••• [Codice OTP]');
      }
    }
  }

  return SecretCensorResult(
    hasSecret: detected,
    maskedText: masked,
    primarySecretType: primaryType,
  );
}
