import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ui/screens/touchpad_screen.dart';

// B18: accumulo dello scroll a 2 dita con delta frazionari.
// Il protocollo (bridge/servizio/daemon) supporta solo dy: l'asse
// orizzontale viene verificato solo come accumulatore indipendente.
void main() {
  group('TouchpadScrollAccumulator', () {
    test('verticale: delta frazionari positivi emettono passi interi', () {
      final acc = TouchpadScrollAccumulator();
      expect(acc.add(1, 0.4), 0);
      expect(acc.add(1, 0.4), 0);
      expect(acc.add(1, 0.4), 1);
      expect(acc.residual, closeTo(0.2, 1e-9));
    });

    test('verticale: residui negativi conservati', () {
      final acc = TouchpadScrollAccumulator();
      expect(acc.add(1, -0.6), 0);
      expect(acc.add(1, -0.6), -1);
      expect(acc.residual, closeTo(-0.2, 1e-9));
      expect(acc.add(1, -2.5), -2);
      expect(acc.residual, closeTo(-0.7, 1e-9));
    });

    test('inversione di direzione azzera il residuo opposto', () {
      final acc = TouchpadScrollAccumulator();
      expect(acc.add(1, 0.7), 0);
      expect(acc.add(1, -0.5), 0);
      expect(acc.residual, closeTo(-0.5, 1e-9));
      expect(acc.add(1, -0.6), -1);
    });

    test('cambio del primo puntatore azzera il residuo', () {
      final acc = TouchpadScrollAccumulator();
      expect(acc.add(1, 0.7), 0);
      expect(acc.add(2, 0.5), 0);
      expect(acc.residual, closeTo(0.5, 1e-9));
    });

    test('reset azzera residuo e puntatore', () {
      final acc = TouchpadScrollAccumulator();
      acc.add(1, 0.9);
      acc.reset();
      expect(acc.residual, 0.0);
      expect(acc.add(1, 0.3), 0);
      expect(acc.residual, closeTo(0.3, 1e-9));
    });

    test('assi verticale e orizzontale indipendenti con delta frazionari', () {
      final y = TouchpadScrollAccumulator();
      final x = TouchpadScrollAccumulator();
      final sentY = <int>[];
      final sentX = <int>[];
      for (final d in const [(0.6, -0.3), (0.6, -0.3), (0.6, -0.5)]) {
        final sy = y.add(1, d.$1);
        final sx = x.add(1, d.$2);
        if (sy != 0) sentY.add(sy);
        if (sx != 0) sentX.add(sx);
      }
      expect(sentY, [1]);
      expect(y.residual, closeTo(0.8, 1e-9));
      expect(sentX, [-1]);
      expect(x.residual, closeTo(-0.1, 1e-9));
    });
  });
}
