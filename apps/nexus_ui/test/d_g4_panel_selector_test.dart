import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ui/services/lan_sync_service.dart';
import 'package:nexus_ui/widgets/shared_input_panel.dart';
import 'package:nexus_ui/widgets/target_device_selector.dart';

void main() {
  group('fix D #93 setupInstructions', () {
    test('usa la topologia reale dei PC', () {
      final text = SharedInputPanel.setupInstructions(
        localName: 'PC-Locale',
        peers: {'a': 'Laptop-A', 'b': 'Desk-B', 'c': 'Senza-Pos'},
        offsets: {'a': const Offset(1, 0), 'b': const Offset(0, -1)},
      );
      expect(text, contains('Topologia attuale rispetto a PC-Locale'));
      expect(text, contains('Laptop-A'));
      expect(text, contains('Desk-B'));
      expect(text, contains('per Laptop-A usa il bordo'));
      expect(text, isNot(contains('Senza-Pos')));
    });

    test('lati diversi producono istruzioni diverse', () {
      String build(Offset o) => SharedInputPanel.setupInstructions(
            localName: 'L',
            peers: {'a': 'A'},
            offsets: {'a': o},
          );
      expect(build(const Offset(1, 0)), isNot(build(const Offset(-1, 0))));
      expect(build(const Offset(0, 1)), isNot(build(const Offset(1, 0))));
    });

    test('senza posizioni non inventa una disposizione', () {
      final text = SharedInputPanel.setupInstructions(
        localName: 'L',
        peers: {'a': 'A'},
        offsets: {},
      );
      expect(text, isNot(contains('Topologia attuale')));
      expect(text, isNot(contains('per A usa il bordo')));
    });
  });

  group('fix D #97/#105 TargetDeviceSelector', () {
    tearDown(() {
      LanSyncService.instance.discoveredPeers = [];
    });

    Future<void> pumpSelector(WidgetTester tester, {String? selected}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TargetDeviceSelector(
              filterType: 'Desktop',
              selectedDeviceId: selected,
              updateGlobalTarget: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    final peers = <Map<String, dynamic>>[
      {
        'id': 'pc-1',
        'name': 'PC-Uno',
        'device_type': 'Desktop',
        'os': 'Windows',
        'online': true,
      },
      {
        'id': 'ph-1',
        'name': 'Telefono-Nascosto',
        'device_type': 'Mobile',
        'os': 'Android',
        'online': true,
      },
    ];

    testWidgets('#97 segnala il target escluso dal filtro', (tester) async {
      LanSyncService.instance.discoveredPeers = peers;
      await pumpSelector(tester, selected: 'ph-1');
      expect(find.text('PC-Uno'), findsOneWidget);
      expect(find.textContaining('Telefono-Nascosto'), findsWidgets);
    });

    testWidgets('#97 nessun avviso se il target e\' visibile', (tester) async {
      LanSyncService.instance.discoveredPeers = peers;
      await pumpSelector(tester, selected: 'pc-1');
      expect(find.textContaining('Telefono-Nascosto'), findsNothing);
    });

    testWidgets('#105 scroll orizzontale con Scrollbar e controller', (tester) async {
      LanSyncService.instance.discoveredPeers = [
        for (var i = 0; i < 12; i++)
          {
            'id': 'pc-$i',
            'name': 'PC-Lungo-Nome-$i',
            'device_type': 'Desktop',
            'os': 'Windows',
            'online': true,
          },
      ];
      await pumpSelector(tester, selected: 'pc-0');
      final bar = find.byKey(const ValueKey('d105-selector-scrollbar'));
      expect(bar, findsOneWidget);
      final scrollbar = tester.widget<Scrollbar>(bar);
      expect(scrollbar.controller, isNotNull);
      expect(scrollbar.thumbVisibility, isTrue);
      expect(tester.takeException(), isNull);
    });
  });
}
