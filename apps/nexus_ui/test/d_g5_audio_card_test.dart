import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ui/widgets/nexus_audio_card.dart';

void main() {
  group('D-g5 audio card (8, 14)', () {
    test('14: visible texts are centralised in AudioCardStrings', () {
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
      expect(AudioCardStrings.relayPort(kAudioRelayPort), contains('$kAudioRelayPort'));
    });

    test('8: error messages shown to the user carry the failure cause', () {
      final err = Exception('boom');
      expect(AudioCardStrings.volumeSendError(err), contains('boom'));
      expect(AudioCardStrings.muteSendError(err), contains('boom'));
      expect(AudioCardStrings.pcSpeakersSendError(err), contains('boom'));
    });
  });
}
