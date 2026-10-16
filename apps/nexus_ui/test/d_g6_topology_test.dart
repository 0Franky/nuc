import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ui/widgets/topology_canvas.dart';

Widget _host({
  required Map<String, Offset> points,
  void Function(String, Offset)? onMove,
  ValueChanged<bool>? onDragging,
}) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: TopologyCanvas(
        points: points,
        names: {for (final id in points.keys) id: id},
        localId: 'a',
        onMove: onMove ?? (_, _) {},
        onDragging: onDragging ?? (_) {},
      ),
    ),
  ),
);

void main() {
  testWidgets('D 114: con coordinate molto distanti i nodi restano visibili e separati', (tester) async {
    await tester.pumpWidget(_host(points: const {
      'a': Offset(0, 0),
      'b': Offset(100000, 100000),
      'c': Offset(50000, 50000),
    }));
    final canvas = tester.getRect(find.byKey(const ValueKey('topology-canvas')));
    final rects = [
      for (final id in ['a', 'b', 'c'])
        tester.getRect(find.byKey(ValueKey('topology-peer-$id'))),
    ];
    for (final r in rects) {
      expect(r.size, const Size(96, 72));
      expect(canvas.inflate(0.5).contains(r.topLeft), isTrue);
      expect(canvas.inflate(0.5).contains(r.bottomRight), isTrue);
    }
    // I nodi estremi non si sovrappongono.
    expect(rects[0].overlaps(rects[1]), isFalse);
  });

  testWidgets('D 116: il pointer move aggiorna il nodo attivo e il rilascio chiama onMove', (tester) async {
    String? movedId;
    final dragging = <bool>[];
    await tester.pumpWidget(_host(
      points: const {'a': Offset(0, 0), 'b': Offset(200, 100)},
      onMove: (id, _) => movedId = id,
      onDragging: dragging.add,
    ));
    final finderA = find.byKey(const ValueKey('topology-peer-a'));
    final finderB = find.byKey(const ValueKey('topology-peer-b'));
    final startA = tester.getTopLeft(finderA);
    final startB = tester.getTopLeft(finderB);

    final gesture = await tester.startGesture(tester.getCenter(finderA));
    await tester.pump();
    await gesture.moveBy(const Offset(30, 20));
    await tester.pump();
    expect(tester.getTopLeft(finderA), startA + const Offset(30, 20));
    expect(tester.getTopLeft(finderB), startB);

    await gesture.up();
    await tester.pump();
    expect(movedId, 'a');
    expect(dragging, [true, false]);
  });

  testWidgets('D 114: con molti nodi lontani il layout resta visibile senza ammucchiarsi ai bordi', (tester) async {
    final points = <String, Offset>{
      for (var i = 0; i < 20; i++) 'n$i': Offset(i * 2000.0, 0),
    };
    await tester.pumpWidget(_host(points: points));
    final canvas = tester.getRect(find.byKey(const ValueKey('topology-canvas')));
    final xs = <double>[];
    for (var i = 0; i < 20; i++) {
      final r = tester.getRect(find.byKey(ValueKey('topology-peer-n$i')));
      expect(canvas.inflate(0.5).contains(r.topLeft), isTrue);
      expect(canvas.inflate(0.5).contains(r.bottomRight), isTrue);
      xs.add(r.left);
    }
    // Ordine preservato e nessuna posizione duplicata (niente clamp ai bordi).
    for (var i = 1; i < xs.length; i++) {
      expect(xs[i], greaterThan(xs[i - 1]));
    }
  });

  testWidgets('D 116: attivare un nodo non ricostruisce gli altri nodi ne\' la griglia', (tester) async {
    await tester.pumpWidget(_host(
      points: const {'a': Offset(0, 0), 'b': Offset(200, 100)},
    ));
    final canvasFinder = find.byKey(const ValueKey('topology-canvas'));
    final gridFinder = find
        .descendant(of: canvasFinder, matching: find.byType(CustomPaint))
        .first;
    final finderA = find.byKey(const ValueKey('topology-peer-a'));
    final finderB = find.byKey(const ValueKey('topology-peer-b'));
    final nodeB = tester.widget(finderB);
    final grid = tester.widget(gridFinder);
    final startA = tester.getTopLeft(finderA);

    final gesture = await tester.startGesture(tester.getCenter(finderA));
    await tester.pump();
    expect(identical(tester.widget(finderB), nodeB), isTrue);
    expect(identical(tester.widget(gridFinder), grid), isTrue);

    await gesture.moveBy(const Offset(25, 15));
    await tester.pump();
    expect(tester.getTopLeft(finderA), startA + const Offset(25, 15));
    expect(identical(tester.widget(finderB), nodeB), isTrue);
    expect(identical(tester.widget(gridFinder), grid), isTrue);

    await gesture.up();
    await tester.pump();
    expect(identical(tester.widget(finderB), nodeB), isTrue);
    expect(identical(tester.widget(gridFinder), grid), isTrue);
  });
}
