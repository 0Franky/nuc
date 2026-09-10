import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ui/services/nexus_ffi_bridge.dart';

void main() {
  test('native router forwards versioned topology unchanged between sockets', () async {
    NexusFfiBridge.instance.init('Topology router test');
    final a = await WebSocket.connect('ws://127.0.0.1:28471/media');
    WebSocket? b;
    try {
      b = await WebSocket.connect('ws://127.0.0.1:28471/media');
      final received = Completer<Map<String,dynamic>>();
      final packet = {'type':'TOPOLOGY_SYNC', 'sender_device_id':'isolated-test-sender',
        'topology': {'schema':1,'revision':1,'author':'isolated-test-sender',
          'points': {'isolated-test-sender':[0,0],'isolated-test-receiver':[120,0]}}};
      b.listen((data) {
        final message = jsonDecode(data as String) as Map<String,dynamic>;
        if (message['type'] == 'TOPOLOGY_SYNC' && message['sender_device_id'] == 'isolated-test-sender' && !received.isCompleted) received.complete(message);
      });
      a.add(jsonEncode(packet));
      expect(await received.future.timeout(const Duration(seconds:3)), packet);
    } finally {
      await a.close();
      await b?.close();
    }
  });
}
