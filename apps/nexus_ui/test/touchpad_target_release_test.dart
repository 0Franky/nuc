import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ui/screens/touchpad_screen.dart';
import 'package:nexus_ui/services/lan_sync_service.dart';
import 'package:nexus_ui/theme/nexus_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const first = '10000000-0000-0000-0000-000000000001';
  const second = '10000000-0000-0000-0000-000000000002';
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final lan = LanSyncService.instance;
    await lan.loadSettings();
    lan.discoveredPeers = [
      {
        'id': first,
        'name': 'First PC',
        'os': 'linux',
        'device_type': 'Desktop',
        'online': true,
      },
      {
        'id': second,
        'name': 'Second PC',
        'os': 'windows',
        'device_type': 'Desktop',
        'online': true,
      },
    ];
    lan.selectTargetDevice(first);
  });
  testWidgets('target switch releases modifiers before subsequent disposal', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: TouchpadRemoteScreen()));
    await tester.tap(find.text('Ctrl'));
    await tester.pump();
    TextButton control() => tester.widget<TextButton>(
      find.ancestor(of: find.text('Ctrl'), matching: find.byType(TextButton)),
    );
    expect(
      control().style!.backgroundColor!.resolve({}),
      NexusTheme.accentIndigo,
    );
    LanSyncService.instance.selectTargetDevice(second);
    await tester.pump();
    expect(
      control().style!.backgroundColor!.resolve({}),
      NexusTheme.surfaceCard,
    );
    expect(LanSyncService.instance.inputErrorFor(second), isNull);
    await tester.pumpWidget(const SizedBox());
    expect(LanSyncService.instance.inputErrorFor(second), isNull);
  });
  testWidgets(
    'button-up after target switch cannot release a key on the new PC',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: TouchpadRemoteScreen()));
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('CLICK SX')),
      );
      await tester.pump();
      expect(find.text('CLICK SX (TENUTO 🟢)'), findsOneWidget);
      LanSyncService.instance.selectTargetDevice(second);
      await tester.pump();
      expect(find.text('CLICK SX'), findsOneWidget);
      await gesture.up();
      await tester.pump();
      expect(LanSyncService.instance.inputErrorFor(second), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
