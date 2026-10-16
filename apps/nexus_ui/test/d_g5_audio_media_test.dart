import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ui/widgets/nexus_audio_card.dart';
import 'package:nexus_ui/widgets/nexus_media_card.dart';

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  group('D-g5 media card routing (48)', () {
    final calls = <(bool, String?)>[];

    setUp(() {
      calls.clear();
      debugMediaPlayPauseSender = (bool play, {String? targetPeerId}) {
        calls.add((play, targetPeerId));
        return 0;
      };
    });

    tearDown(() => debugMediaPlayPauseSender = null);

    test('48: empty or null target falls back to local FFI', () {
      expect(resolveMediaTargetPeerId(null), isNull);
      expect(resolveMediaTargetPeerId(''), isNull);
      expect(resolveMediaTargetPeerId('peer-1'), 'peer-1');
    });

    test('48: routeMediaPlayPause is the single routing point', () {
      routeMediaPlayPause(true, targetPeerId: 'peer-1');
      routeMediaPlayPause(false, targetPeerId: '');
      routeMediaPlayPause(false);
      expect(calls, [(true, 'peer-1'), (false, null), (false, null)]);
    });

    testWidgets('48: pause button goes through routeMediaPlayPause',
        (tester) async {
      await tester.pumpWidget(_wrap(const NexusMediaCard(media: {
        'media_title': 'Video',
        'source_app': 'Browser',
        'position_ms': 1000,
        'duration_ms': 60000,
        'is_playing': true,
      })));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.pause_rounded));
      await tester.pump();
      expect(calls.length, 1);
      expect(calls.single.$1, isFalse);
    });
  });

  group('D-g5 audio card strings (14)', () {
    test('14: visible texts are centralised and non-empty', () {
      const texts = [
        AudioCardStrings.cardTitle,
        AudioCardStrings.cardSubtitle,
        AudioCardStrings.relayDisabled,
        AudioCardStrings.relayWaiting,
        AudioCardStrings.sourceSelectorTitle,
        AudioCardStrings.unmuteTooltip,
        AudioCardStrings.muteTooltip,
        AudioCardStrings.openWebPlayer,
        AudioCardStrings.ipUnavailable,
        AudioCardStrings.unmutePcSpeakers,
        AudioCardStrings.mutePcSpeakers,
        AudioCardStrings.pcSpeakersMuted,
        AudioCardStrings.pcSpeakersUnmuted,
        AudioCardStrings.dialogTitle,
        AudioCardStrings.dialogBody,
        AudioCardStrings.browserOpenFailed,
        AudioCardStrings.openInBrowser,
        AudioCardStrings.close,
      ];
      for (final t in texts) {
        expect(t.trim(), isNotEmpty);
      }
    });
  });
}
