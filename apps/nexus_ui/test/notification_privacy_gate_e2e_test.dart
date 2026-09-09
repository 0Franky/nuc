// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ui/services/lan_sync_service.dart';

void main() {
  group('Zero-Trust Notification Privacy Gate & Multi-Device Separation Tests', () {
    final service = LanSyncService.instance;

    setUp(() {
      service.clearNotifications();
    });

    test('1. Secret Censoring: OTP, IBAN, and Token Detection in Notification Body', () {
      // Test 1: OTP in notification
      service.sendNotification(
        title: "Banca Intesa",
        body: "Il tuo codice OTP di sicurezza è 748291. Scade tra 5 minuti.",
        appName: "Banca Online",
      );

      expect(service.notifications.isNotEmpty, true);
      final notifOtp = service.notifications.first;
      expect(notifOtp.title, "Banca Intesa");
      expect(notifOtp.hasSecret, true);
      expect(notifOtp.isRevealed, false);
      expect(notifOtp.currentBody.contains("748291"), false);
      expect(notifOtp.currentBody.contains("••••••"), true);
      expect(notifOtp.currentBody.contains("[Codice OTP]"), true);

      // Test 2: IBAN in notification
      service.sendNotification(
        title: "Bonifico Ricevuto",
        body: "Ricevuto accredito su IT60X0542811101000000123456 di € 500,00",
        appName: "Finanze",
      );

      final notifIban = service.notifications.first;
      expect(notifIban.hasSecret, true);
      expect(notifIban.isRevealed, false);
      expect(notifIban.currentBody.contains("IT60X0542811101000000123456"), false);
      expect(notifIban.currentBody.contains("[IBAN]"), true);

      // Test 3: Safe text without secrets
      service.sendNotification(
        title: "Telegram",
        body: "Marco: Ciao, ci vediamo alle 19 per la riunione?",
        appName: "Telegram",
      );

      final notifSafe = service.notifications.first;
      expect(notifSafe.hasSecret, false);
      expect(notifSafe.isRevealed, true);
      expect(notifSafe.currentBody, "Marco: Ciao, ci vediamo alle 19 per la riunione?");
    });

    test('2. Bidirectional Secure Reveal Flow (E2EE Zero-Trust)', () {
      // Receiver receives a masked notification from remote device
      final remoteNotif = NexusNotification(
        id: "notif_remote_9988",
        title: "Google Security",
        rawBody: "", // Secret is not transmitted in plaintext
        currentBody: "Codice di verifica 2FA: [CODICE PROTETTO: ******]",
        appName: "Google",
        senderDevice: "Smartphone Android",
        senderDeviceId: "nexus-android",
        timestamp: DateTime.now(),
        hasSecret: true,
        secretCategory: "Codice OTP (2FA)",
        isRevealed: false,
      );

      service.handleNotificationForTesting(remoteNotif);
      expect(service.notifications.length, 1);
      expect(service.notifications.first.isRevealed, false);

      // Simulate remote device responding with the unmasked secret via secure channel
      service.handleNotificationRevealResponseForTesting("notif_remote_9988", "Codice di verifica 2FA: 981245");

      final revealedNotif = service.notifications.first;
      expect(revealedNotif.isRevealed, true);
      expect(revealedNotif.currentBody, "Codice di verifica 2FA: 981245");
    });

    test('3. Multi-Device Separation and Device Filtering', () {
      // Simulate notifications coming from multiple distinct devices
      final notifPc = NexusNotification(
        id: "n_pc_1",
        title: "Windows Update",
        rawBody: "Riavvio programmato per aggiornamento di sicurezza",
        currentBody: "Riavvio programmato per aggiornamento di sicurezza",
        appName: "Sistema",
        senderDevice: "PC Principale (Windows 11)",
        senderDeviceId: "nexus-pc",
        timestamp: DateTime.now(),
        hasSecret: false,
        isRevealed: true,
      );

      final notifPhone = NexusNotification(
        id: "n_phone_1",
        title: "WhatsApp",
        rawBody: "Messaggio da Laura",
        currentBody: "Messaggio da Laura",
        appName: "WhatsApp",
        senderDevice: "Smartphone Android",
        senderDeviceId: "nexus-android",
        timestamp: DateTime.now(),
        hasSecret: false,
        isRevealed: true,
      );

      final notifLaptop = NexusNotification(
        id: "n_laptop_1",
        title: "Slack",
        rawBody: "Nuovo messaggio sul canale dev",
        currentBody: "Nuovo messaggio sul canale dev",
        appName: "Slack",
        senderDevice: "PC Laptop",
        senderDeviceId: "nexus-laptop",
        timestamp: DateTime.now(),
        hasSecret: false,
        isRevealed: true,
      );

      service.handleNotificationForTesting(notifPc);
      service.handleNotificationForTesting(notifPhone);
      service.handleNotificationForTesting(notifLaptop);

      expect(service.notifications.length, 3);

      // Filter "Tutti"
      final all = service.notifications;
      expect(all.length, 3);

      // Filter "PC Principale"
      final pcOnly = service.notifications.where((n) => n.senderDevice.contains("PC Principale")).toList();
      expect(pcOnly.length, 1);
      expect(pcOnly.first.appName, "Sistema");

      // Filter "Smartphone Android"
      final phoneOnly = service.notifications.where((n) => n.senderDevice.contains("Smartphone Android")).toList();
      expect(phoneOnly.length, 1);
      expect(phoneOnly.first.appName, "WhatsApp");

      // Filter "PC Laptop"
      final laptopOnly = service.notifications.where((n) => n.senderDevice.contains("Laptop")).toList();
      expect(laptopOnly.length, 1);
      expect(laptopOnly.first.appName, "Slack");
    });
  });
}
