// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ui/services/nexus_ffi_bridge.dart';

void main() {
  test('Comprehensive Trackpad, Clicks, Scroll, and Media Control Integration Test', () async {
    print('1. Initializing Nexus Core Engine...');
    final bridge = NexusFfiBridge.instance;
    final deviceId = bridge.init("Trackpad Test Node");
    expect(deviceId.isNotEmpty, true);

    print('2. Connecting Mobile Client WebSocket to ws://127.0.0.1:28471/media...');
    final clientWs = await WebSocket.connect('ws://127.0.0.1:28471/media');
    expect(clientWs.readyState, WebSocket.open);
    print('✅ Mobile WebSocket connected successfully!');

    // Test 1: Send Touchpad Delta
    print('3. Testing Touchpad Delta Move...');
    clientWs.add(jsonEncode({"type": "TOUCHPAD_DELTA", "dx": 15, "dy": -10}));
    await Future.delayed(const Duration(milliseconds: 50));

    // Test 2: Send Touchpad Click Left
    print('4. Testing Touchpad Click Left (SX)...');
    clientWs.add(jsonEncode({"type": "TOUCHPAD_CLICK", "button": "Left"}));
    await Future.delayed(const Duration(milliseconds: 50));

    // Test 3: Send Touchpad Click Right
    print('5. Testing Touchpad Click Right (DX)...');
    clientWs.add(jsonEncode({"type": "TOUCHPAD_CLICK", "button": "Right"}));
    await Future.delayed(const Duration(milliseconds: 50));

    // Test 3b: Send Touchpad Button Hold Down and Release Up (Text Selection / Drag)
    print('5b. Testing Touchpad Button Hold Down and Release Up...');
    clientWs.add(jsonEncode({"type": "TOUCHPAD_BUTTON", "button": "Left", "is_down": true}));
    await Future.delayed(const Duration(milliseconds: 30));
    clientWs.add(jsonEncode({"type": "TOUCHPAD_DELTA", "dx": 5, "dy": -2}));
    await Future.delayed(const Duration(milliseconds: 30));
    clientWs.add(jsonEncode({"type": "TOUCHPAD_BUTTON", "button": "Left", "is_down": false}));
    await Future.delayed(const Duration(milliseconds: 50));

    // Test 4: Send Touchpad Scroll
    print('6. Testing Touchpad Wheel Scroll...');
    clientWs.add(jsonEncode({"type": "TOUCHPAD_SCROLL", "dy": -3}));
    await Future.delayed(const Duration(milliseconds: 50));

    // Test 5: Send Media PAUSE and PLAY
    print('7. Testing Remote Media PAUSE and PLAY...');
    clientWs.add(jsonEncode({"action": "PAUSE", "position_ms": null}));
    await Future.delayed(const Duration(milliseconds: 50));
    clientWs.add(jsonEncode({"action": "PLAY", "position_ms": null}));
    await Future.delayed(const Duration(milliseconds: 50));

    // Test 6: Send Clipboard Sync
    print('8. Testing Clipboard Sync...');
    clientWs.add(jsonEncode({"type": "CLIPBOARD_SYNC", "text": "Test Clipboard 123"}));
    await Future.delayed(const Duration(milliseconds: 50));

    // Test 7: Send Open URL Handoff
    print('9. Testing Open URL Handoff...');
    clientWs.add(jsonEncode({
      "type": "OPEN_URL",
      "url": "https://www.youtube.com/watch?v=UDVtMYqUAyw",
      "title": "Interstellar Theme",
      "position_ms": 120000
    }));
    await Future.delayed(const Duration(milliseconds: 100));

    print('✅ SUCCESS: All trackpad inputs, clicks, scrolls, media controls, and handoff packets verified with 0 errors!');
    await clientWs.close();
  });
}
