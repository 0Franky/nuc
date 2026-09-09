import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ui/services/nexus_ffi_bridge.dart';

void main() {
  test('NexusFfiBridge loads DLL and gets real state', () {
    final bridge = NexusFfiBridge.instance;
    final devId = bridge.init("Test Device Node");
    expect(devId.isNotEmpty, true);
    final state = bridge.getState();
    expect(state['initialized'], true);
    expect(state['device_id'], devId);
  });
}
