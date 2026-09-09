// ignore_for_file: avoid_print
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ui/main.dart';
import 'package:nexus_ui/services/lan_sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Spatial Topology Draggable Squares & Universal Control Tests', () {
    setUp(() {
      LanSyncService.instance.spatialPosition = "Right";
      LanSyncService.instance.bleSpatialAutoDetect = false;
      LanSyncService.instance.discoveredPeers = [
        {
          "id": "test-peer-01",
          "name": "Dispositivo Remoto",
          "device_type": "Mobile",
          "os": "Android",
          "online": true,
        }
      ];
      LanSyncService.instance.selectTargetDevice("test-peer-01");
    });

    testWidgets('1. Renders Host Device and Discovered Peer on canvas', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: SpatialTopologyScreen(),
      ));
      await tester.pumpAndSettle();

      // Verify Host Device and Peer are displayed with real dynamic names
      expect(find.text(LanSyncService.instance.deviceName), findsOneWidget);
      expect(find.text('Dispositivo Remoto'), findsWidgets);

      // Verify explanatory text for Right position
      expect(
        find.textContaining('bordo DESTRO'),
        findsOneWidget,
      );
    });

    testWidgets('2. Swapping position updates spatial topology to Left', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: SpatialTopologyScreen(),
      ));
      await tester.pumpAndSettle();

      // Find the swap button
      final swapButton = find.byTooltip('Inverti Sinistra / Destra');
      expect(swapButton, findsOneWidget);

      await tester.tap(swapButton);
      await tester.pumpAndSettle();

      // Verified updated orientation
      expect(
        find.textContaining('bordo SINISTRO'),
        findsOneWidget,
      );
      expect(LanSyncService.instance.spatialPosition.toLowerCase(), 'left');
    });

    testWidgets('3. Drop target or direct selection updates to Above / Below', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: SpatialTopologyScreen(),
      ));
      await tester.pumpAndSettle();

      // Scroll until 'In Alto' is visible, then tap
      final aboveTarget = find.textContaining('In Alto').first;
      expect(aboveTarget, findsOneWidget);
      await tester.ensureVisible(aboveTarget);
      await tester.pumpAndSettle();

      await tester.tap(aboveTarget);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('bordo SUPERIORE'),
        findsOneWidget,
      );
      expect(LanSyncService.instance.spatialPosition.toLowerCase(), 'above');
    });

    testWidgets('4. When no peers connected, shows clean listening banner and zero fake nodes', (tester) async {
      LanSyncService.instance.discoveredPeers = [];
      LanSyncService.instance.selectedTargetDeviceId = null;
      await tester.pumpWidget(const MaterialApp(
        home: SpatialTopologyScreen(),
      ));
      await tester.pumpAndSettle();

      expect(
        find.text('In ascolto LAN... Accendi Nexus su un altro dispositivo per disporre gli schermi'),
        findsOneWidget,
      );
      expect(find.text('PC Principale'), findsNothing);
      expect(find.text('Telefono (Tu)'), findsNothing);
    });
  });
}
