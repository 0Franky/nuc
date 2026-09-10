import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nexus_ui/services/lan_sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'moving self preserves remote world positions and persists reciprocal input offsets',
    () async {
      SharedPreferences.setMockInitialValues({'nexus_device_id': 'win'});
      final lan = LanSyncService.instance;
      await lan.loadSettings();
      lan.discoveredPeers = [
        {'id': 'linux', 'name': 'Linux'},
      ];
      lan.customDeviceOffsets['linux'] = const Offset(120, 0);
      lan.moveTopologyDevice('win', const Offset(20, 30));
      expect(lan.topologyPoints['linux'], const Offset(120, 0));
      expect(lan.customDeviceOffsets['linux'], const Offset(100, -30));
      await lan.synchronizeTopology();
      lan.moveTopologyDevice('win', const Offset(40, 50));
      expect(lan.topologyPoints['linux'], const Offset(120, 0));
      expect(lan.customDeviceOffsets['linux'], const Offset(80, -50));
      await lan.synchronizeTopology();
      await lan.loadSettings();
      expect(lan.topologyPoints['win'], const Offset(40, 50));
      expect(lan.topologyPoints['linux'], const Offset(120, 0));
    },
  );
}
