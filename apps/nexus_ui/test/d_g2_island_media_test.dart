import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ui/widgets/nexus_media_card.dart';

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  group('D-g2 media card', () {
    testWidgets('55: position is formatted as h:mm:ss beyond one hour',
        (tester) async {
      await tester.pumpWidget(_wrap(const NexusMediaCard(media: {
        'media_title': 'Long video',
        'source_app': 'Browser',
        'position_ms': 3725000,
        'duration_ms': 7200000,
        'is_playing': false,
      })));
      await tester.pump();
      expect(find.text('Long video'), findsOneWidget);
      expect(find.textContaining('1:02:05'), findsWidgets);
      expect(find.textContaining('2:00:00'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('55: unknown duration (0) is not shown', (tester) async {
      await tester.pumpWidget(_wrap(const NexusMediaCard(media: {
        'media_title': 'Live',
        'position_ms': 65000,
        'duration_ms': 0,
        'is_playing': false,
      })));
      await tester.pump();
      expect(find.textContaining('1:05'), findsWidgets);
      expect(find.textContaining('/ 0:00'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('48: playing card advances position locally', (tester) async {
      await tester.pumpWidget(_wrap(const NexusMediaCard(media: {
        'media_title': 'Playing',
        'position_ms': 10000,
        'duration_ms': 600000,
        'is_playing': true,
      })));
      await tester.pump();
      expect(find.textContaining('0:10'), findsWidgets);
      await tester.pump(const Duration(seconds: 2));
      expect(find.textContaining('0:10'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
