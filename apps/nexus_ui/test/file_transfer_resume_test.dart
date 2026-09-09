// ignore_for_file: avoid_print
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ui/main.dart';
import 'package:nexus_ui/services/lan_sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('File Transfer Chunk Tracking, Resume & Recovery Tests', () {
    test('1. Session Tracking: Identify Missing Chunks for Incomplete File', () {
      final service = LanSyncService.instance;
      const fileId = "test_resume_file_001";

      // Simulate an incoming file session with 5 chunks
      service.testInjectIncomingSession(fileId, {
        'file_id': fileId,
        'file_name': 'report_nexus.pdf',
        'file_size': 320 * 1024,
        'total_chunks': 5,
        'chunks': <int, List<int>>{
          0: [1, 2, 3],
          1: [4, 5, 6],
          4: [7, 8, 9],
        },
      });

      // Chunks 2 and 3 are missing
      final missing = service.getMissingChunksForFile(fileId);
      expect(missing, equals([2, 3]));

      // Request file resume should execute without error
      expect(() => service.requestFileResume(fileId), returnsNormally);
    });

    testWidgets('2. UI Widget: Display Resume Action for Interrupted Transfers', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: FileTransferScreen(),
      ));
      await tester.pumpAndSettle();

      // Trigger a simulated offer so that an incoming transfer is active
      LanSyncService.instance.testInjectOffer({
        'file_id': 'incomplete_file_123',
        'file_name': 'Archivio_Importante.tar.gz',
        'file_size': 5000000,
        'sender_device': 'PC Principale',
      });
      await tester.pump();

      // Simulate partial progress (e.g. 40%)
      LanSyncService.instance.testInjectProgress({
        'file_id': 'incomplete_file_123',
        'progress': 0.4,
        'speed': '1.2 MB/s',
        'received_chunks': 30,
        'total_chunks': 75,
      });
      await tester.pump();

      // The Resume button should appear for partial transfers
      final resumeBtn = find.text('Ripristina / Recupera Chunk');
      expect(resumeBtn, findsOneWidget);

      await tester.tap(resumeBtn);
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.textContaining('Richiesta di ripristino chunk mancanti inviata'), findsOneWidget);
    });
  });
}
