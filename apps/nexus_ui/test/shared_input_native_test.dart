import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nexus_ui/services/lan_sync_service.dart';
import 'package:nexus_ui/services/shared_input_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Nexus starts and stops the real native input backend without clients',
    () async {
      SharedPreferences.setMockInitialValues({});
      final lan = LanSyncService.instance;
      lan.discoveredPeers = [];
      final config = await Directory(
        Platform.environment['NEXUS_INPUT_TEST_WORK']!,
      ).createTemp('native-input-');
      final service = SharedInputService(
        engineDirectory: Directory(
          Platform.environment['NEXUS_INPUT_TEST_ENGINE']!,
        ),
        configDirectory: config,
      );
      addTearDown(service.shutdown);
      await service.initialize(lan);
      await service.setEnabled(true);
      expect(service.error, isNull);
      expect(service.running, true);
      expect(service.enabled, true);
      final expectCapture =
          Platform.environment['NEXUS_INPUT_TEST_EXPECT_CAPTURE'] != 'disabled';
      final end = DateTime.now().add(const Duration(seconds: 8));
      while (!((!expectCapture || service.captureReady) &&
          service.emulationReady &&
          service.fingerprint != null)) {
        if (DateTime.now().isAfter(end)) fail(service.status);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(service.captureReady, expectCapture);
      expect(lan.sharedInputMetadata?['fingerprint'], service.fingerprint);
      expect(service.backendClientCount, 0);
      if (expectCapture) {
        expect(service.status, contains('nessun PC destinatario'));
      }
      service.error = 'Errore da conservare fino al riavvio';
      // Reload a real client without activating capture or sending input.
      await File('${config.path}/config.toml').writeAsString(
        'port = 4243\n[authorized_fingerprints]\n'
        '[[clients]]\nips = ["127.0.0.1"]\nport = 4244\n'
        'position = "left"\nactivate_on_startup = false\n',
        flush: true,
      );
      final reloadDeadline = DateTime.now().add(const Duration(seconds: 5));
      while (service.backendClientCount != 1 &&
          DateTime.now().isBefore(reloadDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        service.backendClientCount,
        1,
        reason: 'The running engine must apply changes from the config file',
      );
      expect(service.diagnosticReport, contains('Attivo: false'));
      expect(service.error, 'Errore da conservare fino al riavvio');
      // A disable request made during startup must not be silently discarded.
      final restarting = service.setEnabled(true);
      final disabling = service.setEnabled(false);
      await Future.wait([restarting, disabling]);
      expect(
        service.enabled,
        false,
        reason: 'The last requested state must win',
      );
      expect(service.running, false);
      expect(service.captureReady, false);
      expect(lan.sharedInputMetadata, isNull);
    },
    skip:
        !(Platform.isWindows || Platform.isLinux) ||
        Platform.environment['NEXUS_INPUT_TEST_ENGINE'] == null,
    timeout: const Timeout(Duration(seconds: 35)),
  );
}
