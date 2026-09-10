import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nexus_ui/services/lan_sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final lan = LanSyncService.instance;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    lan.discoveredPeers.clear();
    lan.bleSpatialAutoDetect = false;
    lan.autoPauseMediaOnWalkAway = false;
    lan.wakeOnApproach = false;
    lan.estimatedDistanceMeters = null;
    lan.liveRssi = null;
  });
  test('fresh settings never opt into workstation locking', () async {
    await lan.loadSettings();
    expect(lan.autoLockOnWalkAway, isFalse);
  });
  test(
    'legacy default-on preference is not migrated as explicit consent',
    () async {
      SharedPreferences.setMockInitialValues({'autoLockOnWalkAway': true});
      await lan.loadSettings();
      expect(lan.autoLockOnWalkAway, isFalse);
    },
  );
  test('explicit opt-in persists and disabling survives restart', () async {
    await lan.setAutoLockOnWalkAway(true);
    await lan.loadSettings();
    expect(lan.autoLockOnWalkAway, isTrue);
    await lan.setAutoLockOnWalkAway(false);
    await lan.loadSettings();
    expect(lan.autoLockOnWalkAway, isFalse);
  });
  test('a BLE service marker without a known UUID is insufficient', () {
    lan.handleIncomingBleRssi(-59, address: 'rotating-address', isNexus: true);
    expect(lan.discoveredPeers, isEmpty);
    expect(lan.estimatedDistanceMeters, isNull);
  });
  test('unidentified Bluetooth advertisements never become connected peers or distance', () {
    lan.autoLockOnWalkAway = false;
    for (var i = 0; i < 100; i++) {
      lan.handleIncomingBleRssi(
        -71,
        address: 'unknown-radio-$i',
        isNexus: false,
      );
    }
    expect(lan.discoveredPeers, isEmpty);
    expect(lan.estimatedDistanceMeters, isNull);
    expect(lan.liveRssi, isNull);
  });
  test('legacy radio addresses are not revived as LAN peers or topology nodes', () async {
    SharedPreferences.setMockInitialValues({
      'nexus_device_id': 'local',
      'shared_input_topology': '{"AA:BB:CC:DD:EE:FF":[100,0],"real-pc":[-100,0]}',
      'shared_topology_v1': '{"schema":1,"revision":1,"author":"local","points":{"local":[0,0],"real-pc":[-100,0],"AA:BB:CC:DD:EE:FF":[100,0]}}',
    });
    await lan.loadSettings();
    lan.registerOrUpdatePeer(id: 'AA:BB:CC:DD:EE:FF', name: 'Peer BLE (old)');
    expect(lan.discoveredPeers, isEmpty);
    expect(lan.topologyPoints.containsKey('AA:BB:CC:DD:EE:FF'), isFalse);
    expect(lan.topologyPoints.containsKey('real-pc'), isTrue);
  });

  test('identified samples use only the chosen peer and never move topology', () async {
    await lan.loadSettings();
    lan.isBleHardwareAvailable = true;
    lan.bleSpatialAutoDetect = true;
    lan.registerOrUpdatePeer(id: 'phone', name: 'Phone', os: 'android');
    lan.customDeviceOffsets['phone'] = const Offset(-150, 30);
    await lan.setProximityPeer('phone');
    lan.proximity.referenceRssi = -59;
    lan.handleIncomingBleRssi(-59, peerId: 'phone', isNexus: true);
    expect(lan.estimatedDistanceMeters, closeTo(1, 0.001));
    lan.handleIncomingBleRssi(-100, peerId: 'stranger', isNexus: true);
    expect(lan.estimatedDistanceMeters, closeTo(1, 0.001));
    expect(lan.customDeviceOffsets['phone'], const Offset(-150, 30));
    lan.setBleSpatialAutoDetect(false);
    expect(lan.estimatedDistanceMeters, isNull);
    lan.handleIncomingBleRssi(-59, peerId: 'phone', isNexus: true);
    expect(lan.estimatedDistanceMeters, isNull);
  });

}
