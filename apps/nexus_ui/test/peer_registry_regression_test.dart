import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ui/services/lan_sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final lan = LanSyncService.instance;
  setUp(() {
    lan.deviceId = 'local-device';
    lan.discoveredPeers = [];
    lan.selectedTargetDeviceId = null;
  });

  test('relayed announcements cannot replace another stable device on the same route', () {
    lan.registerOrUpdatePeer(id: 'linux-pc', name: 'Linux Studio', ip: '192.0.2.10');
    lan.selectTargetDevice('linux-pc');
    lan.registerOrUpdatePeer(id: 'phone', name: 'Phone', ip: '192.0.2.10');
    expect(lan.discoveredPeers.map((p) => p['id']), ['linux-pc', 'phone']);
    expect(lan.selectedTargetPeer?['name'], 'Linux Studio');
  });

  test('canonical identity replaces provisional identity and keeps selection', () {
    lan.registerOrUpdatePeer(id: 'peer-nexus-192.0.2.10', name: 'Dispositivo (192.0.2.10)', ip: '192.0.2.10');
    lan.registerOrUpdatePeer(id: 'linux-pc', name: 'Linux Studio', ip: '192.0.2.10');
    expect(lan.discoveredPeers.length, 1);
    expect(lan.selectedTargetDeviceId, 'linux-pc');
  });

  test('partial metadata does not erase the device name', () {
    lan.registerOrUpdatePeer(id: 'linux-pc', name: 'Linux Studio', ip: '192.0.2.10');
    lan.registerOrUpdatePeer(id: 'linux-pc', name: '', spatialPosition: 'Left');
    expect(lan.discoveredPeers.single['name'], 'Linux Studio');
  });

  test('missing selected device cannot silently redirect to another PC', () {
    lan.registerOrUpdatePeer(id: 'windows-pc', name: 'Windows Studio');
    lan.selectTargetDevice('linux-pc');
    expect(lan.selectedTargetPeer, isNull);
    expect(lan.touchpadTargetId, 'linux-pc');
  });
  test('touchpad uses a desktop even when a mobile target was selected elsewhere', () {
    lan.registerOrUpdatePeer(id: 'phone', name: 'Phone', os: 'android', deviceType: 'Mobile');
    lan.registerOrUpdatePeer(id: 'linux-pc', name: 'Studio', os: 'linux', deviceType: 'Desktop');
    lan.selectTargetDevice('phone');
    expect(lan.touchpadTargetId, 'linux-pc');
  });
  test('discovery cannot overwrite an authoritative custom name', () {
    lan.registerOrUpdatePeer(id: 'linux-pc', name: 'Custom Name', namePriority: 2);
    lan.registerOrUpdatePeer(id: 'linux-pc', name: 'Stale Name', namePriority: 0);
    expect(lan.discoveredPeers.single['name'], 'Custom Name');
  });

  test('discovery before direct connection merges an existing canonical peer and its placeholder', () {
    lan.registerOrUpdatePeer(id: 'linux-pc', name: 'Linux Studio');
    lan.registerOrUpdatePeer(id: 'peer-nexus-192.0.2.10', name: 'Connecting', ip: '192.0.2.10');
    lan.selectTargetDevice('peer-nexus-192.0.2.10');
    lan.registerOrUpdatePeer(id: 'linux-pc', name: 'Linux Studio', ip: '192.0.2.10');
    expect(lan.discoveredPeers.length, 1);
    expect(lan.selectedTargetDeviceId, 'linux-pc');
  });

}
