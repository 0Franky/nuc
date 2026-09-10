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
      final expectCapture = Platform.environment['NEXUS_INPUT_TEST_EXPECT_CAPTURE'] != 'disabled';
      final end = DateTime.now().add(const Duration(seconds: 8));
      while (!((!expectCapture || service.captureReady) &&
          service.emulationReady &&
          service.fingerprint != null)) {
        if (DateTime.now().isAfter(end)) fail(service.status);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(service.captureReady, expectCapture);
      expect(lan.sharedInputMetadata?['fingerprint'], service.fingerprint);
      await service.setEnabled(false);
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
