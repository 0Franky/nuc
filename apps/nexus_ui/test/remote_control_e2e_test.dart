// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ui/services/nexus_ffi_bridge.dart';

void main() {
  test('Remote Play/Pause Control Bidirectional End-to-End Test', () async {
    print('1. Initializing Nexus FFI Engine...');
    final bridge = NexusFfiBridge.instance;
    final deviceId = bridge.init("Remote Control Node");
    expect(deviceId.isNotEmpty, true);

    print('2. Connecting Browser Extension WebSocket to ws://127.0.0.1:28471/media...');
    final extensionWs = await WebSocket.connect('ws://127.0.0.1:28471/media');
    print('✅ Browser Extension connected to port 28471!');

    final pauseCompleter = Completer<void>();
    final playCompleter = Completer<void>();

    extensionWs.listen((data) {
      final text = data.toString();
      print('📥 Browser Extension received from Daemon: $text');
      try {
        final parsed = jsonDecode(text);
        if (parsed['action'] == 'PAUSE' && !pauseCompleter.isCompleted) {
          pauseCompleter.complete();
        }
        if (parsed['action'] == 'PLAY' && !playCompleter.isCompleted) {
          playCompleter.complete();
        }
      } catch (_) {}
    });

    // 3. Send initial playback update from browser extension
    final youtubeUpdate = {
      "type": "NEXUS_MEDIA_STATE_UPDATE",
      "source_app": "YouTube (Chrome)",
      "media_title": "Interstellar Theme",
      "media_url": "https://www.youtube.com/watch?v=UDVtMYqUAyw",
      "position_ms": 60000,
      "duration_ms": 300000,
      "is_playing": true
    };
    extensionWs.add(jsonEncode(youtubeUpdate));
    await Future.delayed(const Duration(milliseconds: 250));

    // 4. Flutter UI sends PAUSE command via FFI
    print('4. Flutter UI calls sendMediaControl("PAUSE")...');
    final pauseRes = bridge.sendMediaControl("PAUSE");
    expect(pauseRes, 0);

    await pauseCompleter.future.timeout(const Duration(seconds: 3));

    // 5. Flutter UI sends PLAY command via FFI
    print('5. Flutter UI calls sendMediaControl("PLAY")...');
    final playRes = bridge.sendMediaControl("PLAY");
    expect(playRes, 0);

    await playCompleter.future.timeout(const Duration(seconds: 3));

    print('✅ SUCCESS: Remote Play and Pause commands transmitted from Flutter UI -> FFI -> Daemon -> Browser Extension!');

    await extensionWs.close();
  });
}
