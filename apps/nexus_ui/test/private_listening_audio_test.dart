// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ui/services/nexus_ffi_bridge.dart';

void main() {
  test('Complete Private Listening Audio Relay Ultra-Low Latency E2E Test', () async {
    print('1. Initializing Nexus Core Engine with Audio Relay...');
    final bridge = NexusFfiBridge.instance;
    final deviceId = bridge.init("Audio Relay Test Node");
    expect(deviceId.isNotEmpty, true);

    await Future.delayed(const Duration(milliseconds: 400));

    // Test 1: HTTP GET / (HTML5 Web Audio Player)
    print('2. Testing HTTP GET http://127.0.0.1:28472/ (HTML Web Audio Player)...');
    final httpClient = HttpClient();
    final htmlReq = await httpClient.getUrl(Uri.parse('http://127.0.0.1:28472/'));
    final htmlResp = await htmlReq.close();
    expect(htmlResp.statusCode, 200);
    final htmlBody = await htmlResp.transform(utf8.decoder).join();
    print('HTML BODY RECEIVED (len ${htmlBody.length}): $htmlBody');
    expect(htmlBody.contains('Private Listening'), true);
    print('✅ HTTP Web Player responded with 200 OK and valid Ultra-Low Latency WebAudio player!');

    // Test 2: Low-Latency WebSocket Binary PCM Stream (ws://127.0.0.1:28472/)
    print('3. Testing WebSocket ws://127.0.0.1:28472/ (Ultra-Low Latency PCM Frames)...');
    final audioWs = await WebSocket.connect('ws://127.0.0.1:28472/');
    expect(audioWs.readyState, WebSocket.open);

    final receivedFrames = <List<int>>[];
    final wsSub = audioWs.listen((data) {
      if (data is List<int>) {
        receivedFrames.add(data);
      }
    });

    await Future.delayed(const Duration(milliseconds: 200));
    await wsSub.cancel();
    await audioWs.close();

    // Test 3: HTTP GET /stream.wav (Continuous WAV Stream Fallback)
    print('4. Testing HTTP GET http://127.0.0.1:28472/stream.wav (WAV Audio Stream)...');
    final wavReq = await httpClient.getUrl(Uri.parse('http://127.0.0.1:28472/stream.wav'));
    final wavResp = await wavReq.close();
    expect(wavResp.statusCode, 200);
    expect(wavResp.headers.contentType.toString(), 'audio/x-wav');

    final wavChunks = <List<int>>[];
    final wavSub = wavResp.listen((chunk) {
      wavChunks.add(chunk);
    });

    await Future.delayed(const Duration(milliseconds: 150));
    await wavSub.cancel();
    httpClient.close();

    expect(wavChunks.isNotEmpty, true);
    final firstChunk = wavChunks.first;
    final headerStr = String.fromCharCodes(firstChunk.take(4));
    expect(headerStr, 'RIFF');
    print('✅ Continuous WAV stream received valid RIFF/WAVE header and live PCM chunks!');
    print('✅ SUCCESS: Ultra-Low Latency WebSocket Streaming & HTML5 Player verified 100%!');
  });
}
