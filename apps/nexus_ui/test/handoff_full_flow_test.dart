// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ui/services/nexus_ffi_bridge.dart';

void main() {
  test('Complete Mobile Handoff Flow with Automatic PC Pause Test', () async {
    print('1. Initializing Nexus FFI Engine for PC...');
    final bridge = NexusFfiBridge.instance;
    final deviceId = bridge.init("PC Core Test Node");
    expect(deviceId.isNotEmpty, true);

    print('2. Connecting Browser Extension WebSocket to ws://127.0.0.1:28471/media...');
    final extensionWs = await WebSocket.connect('ws://127.0.0.1:28471/media');
    print('✅ Browser Extension connected!');

    final receivedExtensionCommands = <String>[];
    final pauseCompleter = Completer<void>();

    extensionWs.listen((data) {
      final text = data.toString();
      print('📥 Browser Extension received from Daemon: $text');
      try {
        final parsed = jsonDecode(text);
        if (parsed['action'] != null) {
          final action = parsed['action'] as String;
          receivedExtensionCommands.add(action);
          if (action == "PAUSE" && !pauseCompleter.isCompleted) {
            pauseCompleter.complete();
          }
        }
      } catch (_) {}
    });

    // 3. Browser extension emits active video playback state
    print('3. Browser extension starts playing YouTube video...');
    final youtubeUpdate = {
      "type": "NEXUS_MEDIA_STATE_UPDATE",
      "source_app": "YouTube (Chrome)",
      "media_title": "Interstellar Main Theme Live",
      "media_url": "https://www.youtube.com/watch?v=UDVtMYqUAyw",
      "position_ms": 142000,
      "duration_ms": 600000,
      "is_playing": true
    };
    extensionWs.add(jsonEncode(youtubeUpdate));
    await Future.delayed(const Duration(milliseconds: 250));

    // 4. Mobile Client connects via LAN WebSocket
    print('4. Simulating Mobile Client connecting over LAN WebSocket...');
    final mobileWs = await WebSocket.connect('ws://127.0.0.1:28471/media');
    final announceMsg = {
      "type": "PEER_ANNOUNCE",
      "name": "Smartphone Android (OnePlus)",
      "id": "00000000-0000-0000-0000-000000000002",
      "ip": "192.168.1.42"
    };
    mobileWs.add(jsonEncode(announceMsg));
    await Future.delayed(const Duration(milliseconds: 200));

    // 5. Mobile user accepts handoff / opens video on phone
    // When mobile triggers handoff, it sends PAUSE command to PC!
    print('5. Mobile user opens video on phone -> mobile sends PAUSE to PC...');
    final mobilePauseCmd = {
      "action": "PAUSE",
      "position_ms": null
    };
    mobileWs.add(jsonEncode(mobilePauseCmd));

    // 6. Assert that Browser Extension on PC receives PAUSE command
    await pauseCompleter.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => throw TimeoutException('Browser extension did not receive PAUSE command'),
    );

    expect(receivedExtensionCommands.contains("PAUSE"), true,
        reason: "PC Browser Extension MUST receive PAUSE when mobile accepts handoff");

    print('✅ SUCCESS: Mobile Handoff correctly pauses PC video playback via LAN!');

    await mobileWs.close();
    await extensionWs.close();
  });
}
