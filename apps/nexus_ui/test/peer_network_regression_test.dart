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


  });
}
