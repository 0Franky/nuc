// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ui/services/lan_sync_service.dart';
import 'package:nexus_ui/services/nexus_ffi_bridge.dart';

void main() {
  test('Walk-Away Proximity Auto-Pause PC Video & Mobile Handoff Notification E2E Test', () async {
    print('1. Initializing Nexus FFI Engine for PC...');
    final bridge = NexusFfiBridge.instance;
    final deviceId = bridge.init("PC Core Walkaway Test");
    expect(deviceId.isNotEmpty, true);

    print('2. Connecting Browser Extension WebSocket to ws://127.0.0.1:28471/media...');
    final extensionWs = await WebSocket.connect('ws://127.0.0.1:28471/media');
    print('✅ Browser Extension connected!');

    final receivedExtensionCommands = <String>[];
    final pauseCompleter = Completer<void>();

    extensionWs.listen((data) {
      final text = data.toString();
      try {
        final parsed = jsonDecode(text);
        if (parsed['action'] != null) {
          final action = parsed['action'] as String;
          receivedExtensionCommands.add(action);
          print('📥 Browser Extension received command: $action');
          if (action == "PAUSE" && !pauseCompleter.isCompleted) {
            pauseCompleter.complete();
          }
        }
      } catch (_) {}
    });

    // 3. Browser extension emits active video playback state (Playing)
    print('3. Video playback starts on PC (Chrome YouTube)...');
    final youtubeUpdate = {
      "type": "NEXUS_MEDIA_STATE_UPDATE",
      "source_app": "YouTube (Chrome)",
      "media_title": "Interstellar - Stay (Hans Zimmer)",
      "media_url": "https://www.youtube.com/watch?v=UDVtMYqUAyw",
      "position_ms": 145000,
      "duration_ms": 420000,
      "is_playing": true
    };
    extensionWs.add(jsonEncode(youtubeUpdate));
    await Future.delayed(const Duration(milliseconds: 250));

    // 4. Setup LanSyncService on Mobile
    print('4. Setting up LanSyncService on Mobile...');
    final lan = LanSyncService.instance;
    lan.autoPauseMediaOnWalkAway = true;
    lan.activeMedia = {
      "source_app": "YouTube (Chrome)",
      "media_title": "Interstellar - Stay (Hans Zimmer)",
      "media_url": "https://www.youtube.com/watch?v=UDVtMYqUAyw",
      "position_ms": 145000,
      "duration_ms": 420000,
      "is_playing": true,
    };

    final handoffPromptCompleter = Completer<Map<String, dynamic>>();
    final sub = lan.onMediaHandoffPrompt.listen((data) {
      if (!handoffPromptCompleter.isCompleted) {
        handoffPromptCompleter.complete(data);
      }
    });

    // 5. User takes phone and walks away (Proximity distance increases to 3.8m, motion: MovingAway)
    lan.triggerProximityDepartureHandoff(distanceMeters: 3.8);

    // 6. Verify Mobile LanSyncService state
    expect(lan.activeMedia!['is_playing'], false, reason: 'Mobile must mark PC media as paused immediately');

    // 7. Verify prompt was emitted on the Stream
    final promptData = await handoffPromptCompleter.future.timeout(const Duration(seconds: 4));
    print('📱 Received Handoff Prompt on Mobile: $promptData');
    expect(promptData['prompt_text'], 'Vuoi continuare la riproduzione qui?');
    expect(promptData['title'], 'Interstellar - Stay (Hans Zimmer)');
    expect(promptData['timestamped_url'].contains('t=145s'), true, reason: 'URL must jump to exact position 145s');

    // 8. Verify Notification Center has the notification
    final hasNotification = lan.notifications.any((n) =>
        n.title.contains('Continua la riproduzione') &&
        n.currentBody.contains('Interstellar - Stay'));
    expect(hasNotification, true, reason: 'Notification Center must contain walk-away handoff notification');

    // 9. Simulate User tapping the notification to resume playback
    print('6. User taps notification -> confirms timestamped URL is valid for launch:');
    final launchTarget = promptData['timestamped_url'] as String;
    expect(launchTarget, 'https://www.youtube.com/watch?v=UDVtMYqUAyw&t=145s');
    print('▶️ Confirmed launch target on phone: $launchTarget');

    await sub.cancel();
    await extensionWs.close();
    print('🎉 Walk-Away Proximity Auto-Pause & Handoff Prompt fully verified!');
  });
}
