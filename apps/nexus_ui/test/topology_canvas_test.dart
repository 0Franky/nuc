import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ui/widgets/topology_canvas.dart';

void main() {
  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    testWidgets(
      '$kind: local and remote follow short and burst drags without page scroll',
      (tester) async {
        final points = {
          'win': Offset.zero,
          'linux': const Offset(-120, 0),
          'oppo': const Offset(120, 0),
        };
        var commits = 0;
        final scroll = ScrollController();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView(
                controller: scroll,
                children: [
                  SizedBox(
                    height: 300,
                    child: StatefulBuilder(
                      builder: (context, setState) => TopologyCanvas(
                        points: Map.of(points),
                        names: const {
                          'win': 'Win',
                          'linux': 'Linux',
                          'oppo': 'Oppo',
                        },
                        localId: 'win',
                        onDragging: (_) {},
                        onMove: (id, p) {
                          commits++;
                          setState(() => points[id] = p);
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 1000),
                ],
              ),
            ),
          ),
        );
        for (final id in ['win', 'linux', 'oppo']) {
          final node = find.byKey(ValueKey('topology-peer-$id'));
          final start = tester.getCenter(node);
          final gesture = await tester.startGesture(start, kind: kind);
          await gesture.moveBy(const Offset(3, 4));
          await tester.pump();
          expect(tester.getCenter(node) - start, const Offset(3, 4));
          // Several pointer packets before a frame must accumulate, not get lost.
          await gesture.moveBy(const Offset(2, 2));
          await gesture.moveBy(const Offset(2, 2));
          await tester.pump();
          expect(tester.getCenter(node) - start, const Offset(7, 8));
          await gesture.up();
          await tester.pump();
          expect(tester.getCenter(node) - start, const Offset(7, 8));
          expect(scroll.offset, 0);
        }
        expect(commits, 3);
        await tester.pumpWidget(const SizedBox());
        scroll.dispose();
      },
    );
  }
  testWidgets(
    'same global map keeps the same arrangement on every local identity',
    (tester) async {
      final points = {
        'win': const Offset(-120, 0),
        'oppo': Offset.zero,
        'linux': const Offset(120, 0),
      };
      Future<void> render(String local) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TopologyCanvas(
              key: ValueKey(local),
              points: points,
              names: const {},
              localId: local,
              onDragging: (_) {},
              onMove: (_, _) {},
            ),
          ),
        ),
      );
      await render('win');
      final first = {
        for (final id in points.keys)
          id: tester.getCenter(find.byKey(ValueKey('topology-peer-$id'))),
      };
      await render('oppo');
      for (final id in points.keys) {
        expect(
          tester.getCenter(find.byKey(ValueKey('topology-peer-$id'))),
          first[id],
        );
      }
    },
  );
}
