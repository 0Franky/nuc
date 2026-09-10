import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nexus_ui/screens/spatial_topology_screen.dart';
import 'package:nexus_ui/services/lan_sync_service.dart';

void main() {
  testWidgets('button activates persistent automatic topology synchronization', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final lan = LanSyncService.instance;
    lan.discoveredPeers = [{'id':'linux','name':'Linux','os':'linux','device_type':'Desktop','online':false}];
    lan.customDeviceOffsets['linux'] = const Offset(0, 190);
    await tester.pumpWidget(const MaterialApp(home: SpatialTopologyScreen()));
    final canvas = tester.getRect(find.byKey(const ValueKey('topology-canvas')));
    final node = tester.getRect(find.byKey(const ValueKey('topology-peer-linux')));
    expect(canvas.contains(node.topLeft), true);
    expect(canvas.contains(node.bottomRight), true);
    final local = find.byKey(ValueKey('topology-peer-${lan.deviceId}'));
    expect(local, findsOneWidget, reason: 'The local device must also be draggable');
    final before = tester.getCenter(local);
    final gesture = await tester.startGesture(before);
    await gesture.moveBy(const Offset(5, 0));
    await tester.pump();
    expect(tester.getCenter(local).dx - before.dx, closeTo(5, 0.1));
    await gesture.up();
    await tester.pump();
    expect(tester.getCenter(local).dx - before.dx, closeTo(5, 0.1));
    final button = find.widgetWithText(FilledButton, 'Sincronizza topologia con gli altri dispositivi');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(lan.topologySyncEnabled, true);
    expect(find.textContaining('Sincronizzazione automatica attiva'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('shared_topology_v1'), contains('linux'));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
