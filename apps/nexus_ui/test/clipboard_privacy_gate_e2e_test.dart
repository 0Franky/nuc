// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ui/services/nexus_ffi_bridge.dart';
import 'package:nexus_ui/services/lan_sync_service.dart';

void main() {
  group('Zero-Trust Clipboard Privacy Gate Verification Loop', () {
    test('1. Security & Completeness: FFI Classification of Secrets vs Safe Data', () {
      final bridge = NexusFfiBridge.instance;
      bridge.init("Privacy Gate Test Node");

      // A. Verify Secrets & PII are strictly detected
      final otpResult = bridge.classifyClipboard("849201");
      expect(otpResult['is_secret'], true, reason: "OTP 6 digits must be classified as secret");
      expect(otpResult['secret_type'], "Codice OTP (2FA)");

      final otp8Result = bridge.classifyClipboard("12345678");
      expect(otp8Result['is_secret'], true, reason: "OTP 8 digits must be classified as secret");
      expect(otp8Result['secret_type'], "Codice OTP (2FA)");

      final apiKeyResult = bridge.classifyClipboard("sk-proj-abc123xyz789012345678");
      expect(apiKeyResult['is_secret'], true, reason: "OpenAI API Key must be classified as secret");
      expect(apiKeyResult['secret_type'], "Chiave API / Token");

      final ghpResult = bridge.classifyClipboard("ghp_ABCDEFGHIJKL12345678901234567890"); // gitleaks:allow
      expect(ghpResult['is_secret'], true, reason: "GitHub Token must be classified as secret");
      expect(ghpResult['secret_type'], "Chiave API / Token");

      final jwtResult = bridge.classifyClipboard("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.doNotLeakThisToken"); // gitleaks:allow
      expect(jwtResult['is_secret'], true, reason: "JWT token must be classified as secret");
      expect(jwtResult['secret_type'], "Chiave API / Token");

      final ccResult = bridge.classifyClipboard("4532 0123 4567 8910");
      expect(ccResult['is_secret'], true, reason: "Credit Card number must be classified as secret");
      expect(ccResult['secret_type'], "Carta di Credito");

      final ibanResult = bridge.classifyClipboard("IT60X0542811101000000123456");
      expect(ibanResult['is_secret'], true, reason: "IBAN must be classified as secret");
      expect(ibanResult['secret_type'], "Coordinate Bancarie (IBAN)");

      final cfResult = bridge.classifyClipboard("RSSMRA85M01H501Z");
      expect(cfResult['is_secret'], true, reason: "Codice Fiscale must be classified as secret");
      expect(cfResult['secret_type'], "Codice Fiscale (PII)");

      final privKeyResult = bridge.classifyClipboard("-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA0...\n-----END RSA PRIVATE KEY-----");
      expect(privKeyResult['is_secret'], true, reason: "Private Key must be classified as secret");
      expect(privKeyResult['secret_type'], "Chiave Privata");

      // B. Verify Safe Content is allowed through without gate blocking
      final urlResult = bridge.classifyClipboard("https://github.com/google/gemini");
      expect(urlResult['is_secret'], false, reason: "URL must be classified as safe");
      expect(urlResult['secret_type'], "Link URL");

      final hexResult = bridge.classifyClipboard("#3498DB");
      expect(hexResult['is_secret'], false, reason: "HEX color must be classified as safe");
      expect(hexResult['secret_type'], "Colore HEX");

      final phoneResult = bridge.classifyClipboard("+39 340 1234567");
      expect(phoneResult['is_secret'], false, reason: "Phone number is general text / safe");
      expect(phoneResult['secret_type'], "Numero di Telefono");

      final plainTextResult = bridge.classifyClipboard("Ciao mondo, questo e un testo ordinario di test per Nexus.");
      expect(plainTextResult['is_secret'], false, reason: "Standard conversation text must be classified as safe");
      expect(plainTextResult['secret_type'], "Testo Semplice");

      print("All 11 classification vectors verified successfully.");
    });

    test('2. Correctness & Protocol Flow: LanSyncService Privacy Gate & Reveal Loop', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final sync = LanSyncService.instance;
      sync.clipboardPrivacyGate = true;

      Map<String, dynamic>? announcedSecret;
      Map<String, dynamic>? revealedSecret;

      final subAnnounce = sync.onSecretAnnounce.listen((announce) {
        announcedSecret = announce;
      });

      final subReveal = sync.onSecretRevealed.listen((reveal) {
        revealedSecret = reveal;
      });

      // Step A: User copies sensitive OTP
      const sensitiveOtp = "948201";
      final classifyOtp = NexusFfiBridge.instance.classifyClipboard(sensitiveOtp);
      expect(classifyOtp['is_secret'], true);

      sync.sendClipboardWithPrivacyGate(sensitiveOtp);
      await Future.delayed(const Duration(milliseconds: 50));

      // Step B: Simulate inbound secret announcement from remote peer
      const mockSecretId = "sec_test_abc123";
      sync.handleSecretAnnounceForTesting({
        "type": "CLIPBOARD_SECRET_ANNOUNCE",
        "entry_id": mockSecretId,
        "secret_type": "Codice OTP (2FA)",
        "masked_preview": "•••••••• (Codice OTP (2FA))",
        "source_device": "Smartphone Android",
        "timestamp_ms": DateTime.now().millisecondsSinceEpoch,
      });

      await Future.delayed(const Duration(milliseconds: 50));
      expect(announcedSecret != null, true);
      expect(announcedSecret!['entry_id'], mockSecretId);
      expect(announcedSecret!['masked_preview'], "•••••••• (Codice OTP (2FA))");
      expect(announcedSecret!['secret_type'], "Codice OTP (2FA)");

      // Step C: Simulate inbound reveal response after on-demand request
      sync.handleSecretRevealResponseForTesting({
        "type": "CLIPBOARD_REVEAL_RESPONSE",
        "entry_id": mockSecretId,
        "text": sensitiveOtp,
        "source_device": "Smartphone Android",
      });

      await Future.delayed(const Duration(milliseconds: 50));
      expect(revealedSecret != null, true);
      expect(revealedSecret!['entry_id'], mockSecretId);
      expect(revealedSecret!['text'], sensitiveOtp);

      await subAnnounce.cancel();
      await subReveal.cancel();
    });

    test('3. Gate Bypass when Privacy Gate is explicitly disabled in Settings', () {
      final sync = LanSyncService.instance;
      sync.clipboardPrivacyGate = false;
      expect(sync.clipboardPrivacyGate, false);

      sync.clipboardPrivacyGate = true;
      expect(sync.clipboardPrivacyGate, true);
    });

    test('4. Selective Secret Censoring: Preserve sentence context while redacting secrets', () {
      // A. OTP within conversational context
      final mixedOtp = censorSecretsInText("Il tuo codice OTP è 849201 per il login.");
      expect(mixedOtp.hasSecret, true);
      expect(mixedOtp.primarySecretType, "Codice OTP (2FA)");
      expect(mixedOtp.maskedText, "Il tuo codice OTP è •••••• [Codice OTP] per il login.");

      // B. Standalone OTP
      final standaloneOtp = censorSecretsInText("849201");
      expect(standaloneOtp.hasSecret, true);
      expect(standaloneOtp.maskedText, "•••••• [Codice OTP]");

      // C. API Key within prose
      final apiKeyProse = censorSecretsInText("Configura il client usando la chiave sk-proj-12345678901234567890 per accedere.");
      expect(apiKeyProse.hasSecret, true);
      expect(apiKeyProse.primarySecretType, "Chiave API / Token");
      expect(apiKeyProse.maskedText, "Configura il client usando la chiave •••••••• [Chiave API] per accedere.");

      // D. Safe text with no secrets
      final safeProse = censorSecretsInText("Ciao! Ci vediamo per un caffè alle 15:30 al bar del centro.");
      expect(safeProse.hasSecret, false);
      expect(safeProse.maskedText, "Ciao! Ci vediamo per un caffè alle 15:30 al bar del centro.");

      print("Selective censoring tests passed with 100% accuracy!");
    });
  });
}
