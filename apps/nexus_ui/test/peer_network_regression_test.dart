import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nexus_ui/services/lan_sync_service.dart';

Future<void> until(bool Function() ready) async {
  final end = DateTime.now().add(const Duration(seconds: 3));
  while (!ready()) {
    if (DateTime.now().isAfter(end)) fail('Peer state did not converge');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  test('real sockets preserve host and relayed peers and send to the requested identity', () async {
    final lan = LanSyncService.instance;
    lan.deviceId = 'this-client';
    lan.discoveredPeers = [];
    lan.selectedTargetDeviceId = null;
    final server = await HttpServer.bind('127.0.0.2', 0);
    final connected = Completer<WebSocket>();
    final received = <Map<String, dynamic>>[];
    final subscription = server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((data) => received.add(jsonDecode(data as String) as Map<String, dynamic>));
      connected.complete(socket);
      socket.add(jsonEncode({'type':'PEER_ANNOUNCE','is_host':true,'id':'linux-host','name':'Linux Studio','os':'linux','device_type':'Desktop'}));
    });
    await lan.connectToPeer('127.0.0.2', port: server.port);
    final remote = await connected.future;
    addTearDown(() async {
      await remote.close();
      await until(() => !lan.isConnected);
      await subscription.cancel();
      await server.close(force: true);
    });
    await until(() => lan.discoveredPeers.any((p) => p['id'] == 'linux-host'));
    remote.add(jsonEncode({'type':'PEER_ANNOUNCE','id':'phone','name':'Phone','os':'android','device_type':'Mobile'}));
    await until(() => lan.discoveredPeers.length == 2);
    expect(lan.discoveredPeers.map((p) => p['id']), ['linux-host','phone']);
    expect(lan.selectedTargetDeviceId, 'linux-host');
    var textCompleted = false;
    final failedText = lan.sendTextInputConfirmed('Kept until ACK', targetPeerId: 'linux-host')
        .then((result) { textCompleted = true; return result; });
    await until(() => received.any((m) => m['type'] == 'KEYBOARD_TEXT'));
    final failedRequest = received.lastWhere((m) => m['type'] == 'KEYBOARD_TEXT')['request_id'];
    remote.add(jsonEncode({'type':'INPUT_STATUS','device_id':'linux-host','ok':false,
      'request_id':'unrelated', 'message':'unrelated ACK'}));
    await until(() => lan.inputError == 'unrelated ACK');
    expect(textCompleted, isFalse);
    remote.add(jsonEncode({'type':'INPUT_STATUS','device_id':'linux-host','ok':false,
      'request_id':failedRequest, 'message':'Authorize the Wayland portal'}));
    expect(await failedText, 'Authorize the Wayland portal');
    final successfulText = lan.sendTextInputConfirmed('Confirmed text', targetPeerId: 'linux-host');
    await until(() => received.where((m) => m['type'] == 'KEYBOARD_TEXT').length == 2);
    final goodRequest = received.lastWhere((m) => m['type'] == 'KEYBOARD_TEXT')['request_id'];
    remote.add(jsonEncode({'type':'INPUT_STATUS','device_id':'linux-host','ok':true,
      'request_id':goodRequest}));
    expect(await successfulText, isNull);

    lan.sendTouchpadDelta(7, -4, targetPeerId: 'linux-host');
    await until(() => received.any((m) => m['type'] == 'TOUCHPAD_DELTA'));
    expect(received.last['target_device_id'], 'linux-host');
    lan.sendTouchpadDelta(1, 1, targetPeerId: 'phone');
    expect(lan.inputErrorFor('phone'), contains('Connessione diretta'));
    lan.sendOpenUrl('https://example.com/', 'Example', 0, targetPeerId: 'phone');
    await until(() => received.any((m) => m['type'] == 'OPEN_URL'));
    expect(received.last['target_device_id'], 'phone');
    remote.add(jsonEncode({'type':'PEER_METADATA','id':'linux-host','name':'Custom Name'}));
    await until(() => lan.targetDeviceDisplayName == 'Custom Name');
    remote.add(jsonEncode({'type':'PEER_ANNOUNCE','metadata_source':'discovery','id':'linux-host','name':'Stale Name'}));
    remote.add(jsonEncode({'type':'INPUT_STATUS','device_id':'linux-host','ok':false,'message':'Backend unavailable'}));
    await until(() => lan.inputError == 'Backend unavailable');
    expect(lan.targetDeviceDisplayName, 'Custom Name');
    expect(lan.discoveredPeers.length, 2);
    remote.add(jsonEncode({'type':'PEER_DISCONNECTED','id':'phone'}));
    await until(() => lan.discoveredPeers.last['online'] == false);
    expect(lan.socketForDevice('phone'), isNull);
    // A discovery announcement is not proof of an active data connection.
    remote.add(jsonEncode({'type':'PEER_ANNOUNCE','metadata_source':'discovery','id':'phone','name':'Old Phone'}));
    remote.add(jsonEncode({'type':'INPUT_STATUS','device_id':'linux-host','ok':true}));
    await until(() => lan.inputError == null);
    expect(lan.discoveredPeers.last['online'], false);
    expect(lan.discoveredPeers.last['name'], 'Phone');
    remote.add(jsonEncode({'type':'PEER_METADATA','id':'linux-host','shared_input': {'fingerprint':'test-fingerprint','port':4243}}));
    await until(() => lan.discoveredPeers.first['shared_input'] != null);
    remote.add(jsonEncode({'type':'SPATIAL_ARRANGEMENT','sender_device_id':'linux-host','peer_id':'this-client','offset_x':120,'offset_y':0}));
    await until(() => lan.customDeviceOffsets['linux-host']?.dx == -120);
    expect(lan.discoveredPeers.length, 2);
    await lan.synchronizeTopology();
    await until(() => received.any((m) => m['type'] == 'TOPOLOGY_SYNC'));
    final first = received.lastWhere((m) => m['type'] == 'TOPOLOGY_SYNC');
    expect(first['topology']['points']['this-client'], [0, 0]);
    expect(first['topology']['points']['linux-host'], [-120, 0]);
    final changed = {'type':'TOPOLOGY_SYNC','sender_device_id':'linux-host',
      'topology': {'schema':1,'revision':2,'author':'linux-host',
        'points': {'this-client':[100,50],'linux-host':[300,50],'phone':[300,150]}}};
    remote.add(jsonEncode(changed));
    await until(() => lan.customDeviceOffsets['linux-host']?.dx == 200);
    expect(lan.customDeviceOffsets['phone']?.dy, 100);
    // Replay and old pairwise traffic cannot revert the shared layout.
    remote.add(jsonEncode(first));
    remote.add(jsonEncode({'type':'SPATIAL_ARRANGEMENT','sender_device_id':'linux-host',
      'peer_id':'this-client','offset_x':999,'offset_y':0}));
    remote.add(jsonEncode({'type':'INPUT_STATUS','device_id':'linux-host','ok':false,'message':'barrier'}));
    await until(() => lan.inputError == 'barrier');
    expect(lan.customDeviceOffsets['linux-host']?.dx, 200);
    await until(() => received.where((m) => m['type'] == 'TOPOLOGY_SYNC').length == 2);
    final prefs = await SharedPreferences.getInstance();
    await until(() => prefs.getString('shared_topology_v1')?.contains('300') == true);
    await remote.close();
    await until(() => !lan.isConnected);
    final retryServer = await HttpServer.bind('127.0.0.2', 0);
    final caughtUp = Completer<Map<String, dynamic>>();
    WebSocket? retrySocket;
    final retrySubscription = retryServer.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      retrySocket = socket;
      socket.listen((data) {
        final packet = jsonDecode(data as String) as Map<String, dynamic>;
        if (packet['type'] == 'TOPOLOGY_SYNC' && !caughtUp.isCompleted) caughtUp.complete(packet);
      });
      socket.add(jsonEncode({'type':'PEER_ANNOUNCE','is_host':true,'id':'linux-host','name':'Linux'}));
    });
    try {
      await lan.connectToPeer('127.0.0.2', port: retryServer.port);
      final snapshot = await caughtUp.future.timeout(const Duration(seconds: 3));
      expect(snapshot['topology']['revision'], 2);
      expect(snapshot['topology']['points']['phone'], [300,150]);
    } finally {
      await retrySocket?.close();
      await until(() => !lan.isConnected);
      await retrySubscription.cancel();
      await retryServer.close(force: true);
    }

  });
}
