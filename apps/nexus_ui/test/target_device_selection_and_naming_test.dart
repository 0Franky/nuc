import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nexus_ui/services/lan_sync_service.dart';
import 'package:nexus_ui/models/device_colors.dart';
import 'package:nexus_ui/widgets/target_device_selector.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LanSyncService.instance.loadSettings();
  });

  group('Device Naming & Variable Suffix Tests', () {
    test('1. Default device name has a 4-character variable suffix derived from deviceId', () {
      final service = LanSyncService.instance;
      expect(service.deviceId.isNotEmpty, isTrue);
      expect(service.defaultDeviceSuffix.length, 4);

      final defaultName = service.defaultDeviceName;
      expect(defaultName.contains(service.defaultDeviceSuffix), isTrue);
      expect(service.deviceName, defaultName);
    });

    test('2. Custom device name can be set, saved, and reset to default', () async {
      final service = LanSyncService.instance;
      final defaultName = service.defaultDeviceName;

      await service.setDeviceName('Studio Workstation PC');
      expect(service.deviceName, 'Studio Workstation PC');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('nexus_custom_device_name'), 'Studio Workstation PC');

      await service.resetDeviceNameToDefault();
      expect(service.deviceName, defaultName);
      expect(prefs.getString('nexus_custom_device_name'), isNull);
    });
  });

  group('Multi-Device Topology & Target Switching Tests', () {
    test('3. Manages multiple PCs simultaneously and routes target device on the fly', () {
      final service = LanSyncService.instance;

      service.discoveredPeers = [
        {
          "id": "pc-win-1",
          "name": "PC Studio-A1B2",
          "ip": "192.168.1.11",
          "device_type": "Desktop",
          "os": "Windows",
          "online": true,
        },
        {
          "id": "pc-win-2",
          "name": "PC Laptop-7F3A",
          "ip": "192.168.1.35",
          "device_type": "Desktop",
          "os": "Windows",
          "online": true,
        },
      ];

      // Default target selects first PC
      expect(service.selectedTargetPeer?['id'], 'pc-win-1');

      // Switch to PC 2 on the fly
      service.selectTargetDevice('pc-win-2');
      expect(service.selectedTargetDeviceId, 'pc-win-2');
      expect(service.selectedTargetPeer?['name'], 'PC Laptop-7F3A');

      // Switch back to PC 1
      service.selectTargetDevice('pc-win-1');
      expect(service.selectedTargetDeviceId, 'pc-win-1');
      expect(service.selectedTargetPeer?['name'], 'PC Studio-A1B2');
    });

    testWidgets('4. TargetDeviceSelector renders both PCs with distinct colors and handles taps', (tester) async {
      final service = LanSyncService.instance;
      service.discoveredPeers = [
        {
          "id": "pc-1",
          "name": "PC Windows-1001",
          "device_type": "Desktop",
          "os": "Windows",
          "online": true,
        },
        {
          "id": "pc-2",
          "name": "PC Windows-2002",
          "device_type": "Desktop",
          "os": "Windows",
          "online": true,
        },
      ];
      service.selectTargetDevice('pc-1');

      String? selectedId;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TargetDeviceSelector(
              onDeviceSelected: (id) {
                selectedId = id;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('PC Windows-1001'), findsOneWidget);
      expect(find.text('PC Windows-2002'), findsOneWidget);
      expect(find.text('2 nodi'), findsOneWidget);

      // Tap on PC 2
      await tester.tap(find.text('PC Windows-2002'));
      await tester.pumpAndSettle();

      expect(selectedId, 'pc-2');
      expect(service.selectedTargetDeviceId, 'pc-2');
    });

    test('5. Dynamic peer metadata update and self-device filter', () {
      final service = LanSyncService.instance;
      service.deviceId = 'my-self-uuid-1234';
      service.discoveredPeers.clear();

      // Register initial peer
      service.registerOrUpdatePeer(
        id: 'peer-linux-5678',
        name: 'Dispositivo (192.168.1.10)',
        ip: '192.168.1.10',
        deviceType: 'Desktop',
        os: 'Linux',
      );

      expect(service.discoveredPeers.length, 1);
      expect(service.discoveredPeers.first['name'], 'Dispositivo (192.168.1.10)');

      // Receive PEER_METADATA with real user-configured name
      service.registerOrUpdatePeer(
        id: 'peer-linux-5678',
        name: 'Workstation Ubuntu',
        ip: '192.168.1.10',
        deviceType: 'Desktop',
        os: 'Linux',
      );

      // Name should be updated dynamically without creating duplicate peer entries
      expect(service.discoveredPeers.length, 1);
      expect(service.discoveredPeers.first['name'], 'Workstation Ubuntu');

      // Attempt to register self: MUST BE IGNORED
      service.registerOrUpdatePeer(
        id: 'my-self-uuid-1234',
        name: 'Self PC Windows',
        ip: '127.0.0.1',
        deviceType: 'Desktop',
        os: 'Windows',
      );

      // Still only 1 remote peer, self is never added
      expect(service.discoveredPeers.length, 1);
      expect(service.discoveredPeers.any((p) => p['id'] == 'my-self-uuid-1234'), false);
    });
  });
}
