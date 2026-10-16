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
    // Only PRIVATE keys (PUBLIC keys and certificates are not secrets). A BEGIN
    // without its matching END is masked up to the end of the text, so a
    // truncated key body never stays in clear.
    r'-----BEGIN ((?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?)-----[\s\S]*?(?:-----END \1-----|$)',
  );
  if (privateKeyRegex.hasMatch(masked)) {
    detected = true;
    primaryType = 'Chiave Privata';
    masked = masked.replaceAll(privateKeyRegex, '•••••••• [Chiave Privata]');
  }

  // 2. API Keys & Bearer / JWT tokens
  final apiKeyRegex = RegExp(
    r'(?:sk-[a-zA-Z0-9_\-]{15,}|ghp_[a-zA-Z0-9]{15,}|gho_[a-zA-Z0-9]{15,}|glpat-[a-zA-Z0-9_\-]{15,}|Bearer\s+[a-zA-Z0-9_\-\.]+|\beyJ[A-Za-z0-9_\-=]+\.[A-Za-z0-9_\-=]+\.[A-Za-z0-9_\-=+/]*)',
  );
  if (apiKeyRegex.hasMatch(masked)) {
    detected = true;
    if (primaryType == 'Segreto') primaryType = 'Chiave API / Token';
    masked = masked.replaceAll(apiKeyRegex, '•••••••• [Chiave API]');
  }

  // 3. IBAN
  // Accepts lowercase and the usual groups of 4 separated by spaces; every
  // candidate is validated with the ISO 13616 mod-97 checksum.
  final ibanRegex = RegExp(
    r'\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,4})?\b',
    caseSensitive: false,
  );
  masked = masked.replaceAllMapped(ibanRegex, (m) {
    final parts = m.group(0)!.split(' ');
    for (var n = parts.length; n >= 1; n--) {
      if (_isValidIban(parts.take(n).join().toUpperCase())) {
        detected = true;
        if (primaryType == 'Segreto') primaryType = 'Coordinate Bancarie (IBAN)';
        final rest = parts.skip(n).join(' ');
        return rest.isEmpty ? '•••••••• [IBAN]' : '•••••••• [IBAN] $rest';
      }
    }
    return m.group(0)!;
  });

  // 4. Codice Fiscale (Italian Fiscal Code - PII)
  final cfRegex = RegExp(
    // Digit positions also accept the omocodia letters (L M N P Q R S T U V).
    r'\b[A-Z]{6}[\dLMNP-V]{2}[A-Z][\dLMNP-V]{2}[A-Z][\dLMNP-V]{3}[A-Z]\b',
    caseSensitive: false,
  );
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
    if (digitsOnly.length >= 13 &&
        digitsOnly.length <= 19 &&
        _passesLuhn(digitsOnly)) {
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
    // Mask only 4-8 digit numbers close to a 2FA / OTP keyword (same line, no
    // other number or mask label in between), not every number in the text
    // (years, order numbers, quantities).
    const otpKeyword =
        r'\b(?:otp|codice|code|token|2fa|pin|verifica|autenticazione)\b';
    const otpGap = r'[^\d\n\[\]]{0,30}?';
    final otpAfterKeyword = RegExp(
      '($otpKeyword$otpGap)' r'\b(\d{4,8})\b',
      caseSensitive: false,
    );
    final otpBeforeKeyword = RegExp(
      r'\b(\d{4,8})\b' '(?=$otpGap$otpKeyword)',
      caseSensitive: false,
    );
    var otpFound = false;
    masked = masked.replaceAllMapped(otpAfterKeyword, (m) {
      otpFound = true;
      return '${m.group(1)}•••••• [Codice OTP]';
    });
    masked = masked.replaceAllMapped(otpBeforeKeyword, (m) {
      otpFound = true;
      return '•••••• [Codice OTP]';
    });
    if (otpFound) {
      detected = true;
      if (primaryType == 'Segreto') primaryType = 'Codice OTP (2FA)';
    }
  }

  return SecretCensorResult(
    hasSecret: detected,
    maskedText: masked,
    primarySecretType: primaryType,
  );
}

/// Luhn checksum: tells real card numbers apart from other long digit runs.
bool _passesLuhn(String digits) {
  var sum = 0;
  var doubleIt = false;
  for (var i = digits.length - 1; i >= 0; i--) {
    var d = digits.codeUnitAt(i) - 48;
    if (doubleIt) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
    doubleIt = !doubleIt;
  }
  return sum % 10 == 0;
}

/// ISO 13616 IBAN check (length 15-34, mod 97 == 1). Expects uppercase, no spaces.
bool _isValidIban(String iban) {
  if (iban.length < 15 || iban.length > 34) return false;
  if (!RegExp(r'^[A-Z]{2}\d{2}[A-Z0-9]+$').hasMatch(iban)) return false;
  final rearranged = iban.substring(4) + iban.substring(0, 4);
  var remainder = 0;
  for (final unit in rearranged.codeUnits) {
    final value = unit >= 65 ? unit - 55 : unit - 48;
    remainder =
        (value > 9 ? remainder * 100 + value : remainder * 10 + value) % 97;
  }
  return remainder == 1;
}
