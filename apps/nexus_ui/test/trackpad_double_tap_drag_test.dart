// ignore_for_file: avoid_print
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ui/main.dart';
import 'package:nexus_ui/services/nexus_ffi_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Trackpad Double-Tap + Drag & Two-Finger Right Click Tests', () {
    setUp(() {
      NexusFfiBridge.instance.init("Trackpad Test Node");
    });

    testWidgets('1. Double-Tap + Drag activates Left Down state and visual feedback', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: TouchpadRemoteScreen(),
      ));
      await tester.pumpAndSettle();

      // Find the trackpad surface Listener
      final trackpadFinder = find.byType(Listener).first;
      expect(trackpadFinder, findsOneWidget);

      final gestureLocation = tester.getCenter(trackpadFinder);

      // --- First Tap ---
      final pointer1 = await tester.startGesture(gestureLocation, pointer: 1);
      await tester.pump(const Duration(milliseconds: 50));
      await pointer1.up();
      await tester.pump(const Duration(milliseconds: 100)); // Tap interval within 480ms

      // Banner should NOT be visible yet
      expect(find.textContaining('SELEZIONE TESTO / DRAG ATTIVO'), findsNothing);

      // --- Second Tap and Hold (Double-Tap to Drag) ---
      final pointer2 = await tester.startGesture(gestureLocation + const Offset(5, 5), pointer: 2);
      await tester.pump(); // rebuild with state change

      // Now Double-Tap Drag is ACTIVE: Left Click is held DOWN
      expect(find.textContaining('SELEZIONE TESTO / DRAG ATTIVO'), findsOneWidget);

      // Move finger to select text / drag
      await pointer2.moveBy(const Offset(30, 20));
      await tester.pump();
      expect(find.textContaining('SELEZIONE TESTO / DRAG ATTIVO'), findsOneWidget);

      // Release finger: ends drag and releases Left Click
      await pointer2.up();
      await tester.pump();

      // Banner disappears
      expect(find.textContaining('SELEZIONE TESTO / DRAG ATTIVO'), findsNothing);
    });

    testWidgets('2. Two-Finger Tap triggers Right Click', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: TouchpadRemoteScreen(),
      ));
      await tester.pumpAndSettle();

      final trackpadFinder = find.byType(Listener).first;
      final center = tester.getCenter(trackpadFinder);

      // Start 2 pointers simultaneously
      final finger1 = await tester.startGesture(center + const Offset(-30, 0), pointer: 10);
      final finger2 = await tester.startGesture(center + const Offset(30, 0), pointer: 11);
      await tester.pump(const Duration(milliseconds: 60));

      // Lift both fingers quickly (< 450ms)
      await finger1.up();
      await finger2.up();
      await tester.pump();

      // SnackBar for Right Click should be shown
      expect(find.textContaining('Click Destro (Tap a 2 dita) inviato al PC!'), findsOneWidget);
    });
  });
}
