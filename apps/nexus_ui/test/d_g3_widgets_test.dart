import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ui/widgets/nexus_pill.dart';
import 'package:nexus_ui/widgets/nexus_segmented_control.dart';
import 'package:nexus_ui/widgets/proximity_lock_switch.dart';

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  group('#60 NexusPill', () {
    testWidgets('statica: nessun InkWell', (tester) async {
      await tester.pumpWidget(_wrap(const NexusPill(label: 'A')));
      expect(find.byType(InkWell), findsNothing);
    });

    testWidgets('cliccabile: area >= 48 px, tap e Semantics button',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _wrap(NexusPill(label: 'A', onTap: () => taps++)),
      );
      expect(find.byType(InkWell), findsOneWidget);
      final size = tester.getSize(find.byType(GestureDetector).first);
      expect(size.height, greaterThanOrEqualTo(NexusPill.minTapTarget));
      expect(size.width, greaterThanOrEqualTo(NexusPill.minTapTarget));
      await tester.tap(find.text('A'));
      expect(taps, greaterThanOrEqualTo(1));
      final handle = tester.ensureSemantics();
      expect(
        tester.getSemantics(find.text('A')),
        matchesSemantics(
          isButton: true,
          label: 'A',
          hasTapAction: true,
          isFocusable: true,
          hasFocusAction: true,
        ),
      );
      handle.dispose();
    });
  });

  group('#65 NexusSegmentedControl', () {
    testWidgets('InkWell per segmento, 48 px, niente notifica su selezionato',
        (tester) async {
      final changes = <int>[];
      await tester.pumpWidget(_wrap(SizedBox(
        width: 300,
        child: NexusSegmentedControl<int>(
          segments: const {0: 'Uno', 1: 'Due'},
          selectedValue: 0,
          onValueChanged: changes.add,
        ),
      )));
      expect(find.byType(InkWell), findsNWidgets(2));
      final h = tester.getSize(find.byType(InkWell).first).height;
      expect(h, greaterThanOrEqualTo(NexusSegmentedControl.minTapTarget));
      await tester.tap(find.text('Uno'));
      await tester.tap(find.text('Due'));
      expect(changes, [1]);
    });

    testWidgets('non vincolato in larghezza: nessun errore di layout',
        (tester) async {
      await tester.pumpWidget(_wrap(SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: NexusSegmentedControl<int>(
          segments: const {0: 'Uno', 1: 'Due'},
          selectedValue: 1,
          onValueChanged: (_) {},
        ),
      )));
      expect(tester.takeException(), isNull);
    });
  });

  group('#73 ProximityLockStrings', () {
    test('testi centralizzati e sostituibili', () {
      const def = ProximityLockStrings();
      expect(def.title, isNotEmpty);
      expect(def.saveError, isNotEmpty);
      const custom = ProximityLockStrings(title: 'Lock on walk-away');
      expect(custom.title, 'Lock on walk-away');
      expect(custom.notReady, def.notReady);
    });
  });
}
