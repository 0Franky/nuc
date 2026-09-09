import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ui/services/lan_sync_service.dart';
import 'package:nexus_ui/services/nexus_ffi_bridge.dart';
import 'package:nexus_ui/screens/spatial_topology_screen.dart';
import 'package:nexus_ui/screens/dashboard_screen.dart';
import 'package:nexus_ui/screens/settings_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('1. Hardware Radio Check via FFI matches real OS radio state', () {
    final isBtEnabled = NexusFfiBridge.instance.isBluetoothEnabled();
    expect(isBtEnabled, isA<bool>());
    // ignore: avoid_print
    print('Verified real OS Bluetooth radio enabled: $isBtEnabled');

    LanSyncService.instance.checkBluetoothHardwareStatus();
    expect(LanSyncService.instance.isBleHardwareAvailable, equals(isBtEnabled));

    if (!isBtEnabled) {
      expect(LanSyncService.instance.bleSpatialAutoDetect, isFalse);
      expect(LanSyncService.instance.estimatedDistanceMeters, isNull);
      expect(LanSyncService.instance.proximityMotion, isNull);
    }
  });

  testWidgets('2. SpatialTopologyScreen displays warning and disables switch when Bluetooth is OFF', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    LanSyncService.instance.isBleHardwareAvailable = false;
    LanSyncService.instance.bleSpatialAutoDetect = false;
    LanSyncService.instance.estimatedDistanceMeters = null;

    await tester.pumpWidget(
      const MaterialApp(
        home: SpatialTopologyScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Bluetooth disattivato sul dispositivo'), findsOneWidget);
    expect(find.byIcon(Icons.bluetooth_disabled_rounded), findsWidgets);
    expect(find.text('RADIO OFF'), findsOneWidget);
    expect(find.textContaining('1.2 m'), findsNothing);

    final switchFinder = find.byType(Switch).first;
    final Switch switchWidget = tester.widget(switchFinder);
    expect(switchWidget.onChanged, isNull);
  });

  testWidgets('3. DashboardScreen quick tile shows Bluetooth OFF or BLE Standby when not active', (tester) async {
    LanSyncService.instance.isBleHardwareAvailable = false;
    LanSyncService.instance.estimatedDistanceMeters = null;

    await tester.pumpWidget(
      const MaterialApp(
        home: DashboardScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Bluetooth OFF'), findsOneWidget);
    expect(find.textContaining('1.2m'), findsNothing);
  });

  testWidgets('4. SettingsScreen disables BLE auto-detect switch when Bluetooth is OFF', (tester) async {
    LanSyncService.instance.isBleHardwareAvailable = false;
    LanSyncService.instance.bleSpatialAutoDetect = false;

    await tester.pumpWidget(
      const MaterialApp(
        home: SettingsScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Bluetooth spento sul dispositivo'), findsOneWidget);
  });
}
