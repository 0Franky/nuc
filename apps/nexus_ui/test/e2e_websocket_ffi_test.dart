// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ui/services/nexus_ffi_bridge.dart';

void main() {
  test('Complete End-to-End WebSocket to Flutter FFI Ingestion Test', () async {
    print('1. Initializing Nexus FFI Engine...');
    final bridge = NexusFfiBridge.instance;
    final deviceId = bridge.init("E2E Test Engine Node");
    expect(deviceId.isNotEmpty, true);

    // Initial state check
    final initialState = bridge.getState();
    expect(initialState['initialized'], true);

    // 2. Connect WebSocket client on port 28471 as Chrome Browser Extension
    print('2. Connecting WebSocket client to ws://127.0.0.1:28471/media...');
    final ws = await WebSocket.connect('ws://127.0.0.1:28471/media');
    print('✅ WebSocket Client Connected to Rust Engine on port 28471!');

    // 3. Send real YouTube playback update
    final youtubeUpdate = {
      "type": "NEXUS_MEDIA_STATE_UPDATE",
      "source_app": "YouTube (Google Chrome)",
      "media_title": "Interstellar - Stay (Hans Zimmer)",
      "media_url": "https://www.youtube.com/watch?v=UDVtMYqUAyw",
      "position_ms": 145000,
      "duration_ms": 420000,
      "is_playing": true
    };

    print('3. Sending YouTube media state update JSON over WebSocket...');
    ws.add(jsonEncode(youtubeUpdate));

    // 4. Query live state from Flutter FFI bridge with polling
    print('4. Querying live state from NexusFfiBridge.instance.getState()...');
    dynamic activeMedia;
    for (int i = 0; i < 20; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      final liveState = bridge.getState();
      activeMedia = liveState['active_media'];
      if (activeMedia != null && activeMedia['media_title'] == "Interstellar - Stay (Hans Zimmer)") {
        break;
      }
    }

    expect(activeMedia != null, true, reason: "active_media must not be null after WebSocket ingestion");
    // Verify that activeMedia has valid title and URL from live ingestion
    expect(activeMedia['media_title'] != null && (activeMedia['media_title'] as String).isNotEmpty, true);
    expect(activeMedia['media_url'] != null && (activeMedia['media_url'] as String).isNotEmpty, true);
    expect(activeMedia['is_playing'] != null, true);

    print('✅ SUCCESS: YouTube playback was ingested via WebSocket and retrieved via FFI by Flutter UI!');

    await ws.close();
  });
}
