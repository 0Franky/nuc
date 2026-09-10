// ignore_for_file: avoid_print
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ui/main.dart';
import 'package:nexus_ui/services/lan_sync_service.dart';
import 'package:nexus_ui/services/nexus_ffi_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Remote Keyboard, Macro Shortcuts & Unicode Text Typing Tests', () {
    setUp(() {
      NexusFfiBridge.instance.init("Keyboard Test Node");
    });

    test('1. Service Layer: Key, Combo, and Unicode Text Sending', () {
      final service = LanSyncService.instance;

      // Ensure methods execute without throwing
      expect(() => service.sendKeyboardKey("Esc"), returnsNormally);
      expect(() => service.sendKeyboardKey("Control", isDown: true), returnsNormally);
      expect(() => service.sendKeyboardKey("Control", isDown: false), returnsNormally);
      expect(() => service.sendKeyboardCombo(["Control", "C"]), returnsNormally);
      expect(() => service.sendKeyboardCombo(["Win", "D"]), returnsNormally);
      expect(() => service.sendTextInput("Nexus Universal Ecosystem! 🚀"), returnsNormally);
    });

    testWidgets('2. UI Widget: Key Bar Invocations and Modifier Toggling', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: TouchpadRemoteScreen(),
      ));
      await tester.pumpAndSettle();

      // Find Esc key button
      final escBtn = find.text('Esc');
      expect(escBtn, findsOneWidget);

      await tester.tap(escBtn);
      await tester.pump();

      expect(find.textContaining('Tasto Esc inviato al PC'), findsOneWidget);

      // Find Ctrl key button and toggle it
      final ctrlBtn = find.text('Ctrl');
      expect(ctrlBtn, findsOneWidget);

      await tester.tap(ctrlBtn);
      await tester.pump();

      // Tap again to release
      await tester.tap(ctrlBtn);
      await tester.pump();
    });

    testWidgets('3. UI Widget: Open Remote Keyboard Modal, Macro Chips and Text Submit', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: TouchpadRemoteScreen(),
      ));
      await tester.pumpAndSettle();

      // Find remote keyboard button ⌨️
      final keyboardBtn = find.text('⌨️');
      expect(keyboardBtn, findsOneWidget);

      await tester.tap(keyboardBtn);
      await tester.pumpAndSettle();

      // Modal should be open
      expect(find.text('Tastiera Remota & Macro PC'), findsOneWidget);
      expect(find.text('Ctrl + C'), findsOneWidget);
      expect(find.text('Ctrl + V'), findsOneWidget);
      expect(find.text('Win + D'), findsOneWidget);
      expect(find.text('Alt + Tab'), findsOneWidget);

      // Tap macro chip Ctrl + C
      final copyChip = find.text('Ctrl + C');
      await tester.tap(copyChip);
      await tester.pump();

      expect(find.textContaining('Macro eseguita: Ctrl + C'), findsOneWidget);

      // Enter text and submit
      final textField = find.byType(TextField);
      expect(textField, findsOneWidget);

      await tester.enterText(textField, 'Documento Nexus');
      await tester.pump();

      // Tap the Invia button
      final sendBtn = find.widgetWithText(FilledButton, 'Invia');
      expect(sendBtn, findsOneWidget);
      await tester.tap(sendBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // No connected backend: preserve the text and never claim it was typed.
      expect(find.text('Tastiera Remota & Macro PC'), findsOneWidget);
      expect(tester.widget<TextField>(textField).controller!.text, 'Documento Nexus');
      expect(find.textContaining('Connessione diretta'), findsOneWidget);
      expect(find.text('Digitazione confermata dal PC'), findsNothing);
    });
  });
}
