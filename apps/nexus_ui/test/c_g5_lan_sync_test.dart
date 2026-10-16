import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ui/services/lan_sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('C g5 lan_sync', () {
    test('#42 OPEN_URL whitelist accepts only http/https with host', () {
      expect(LanSyncService.isAllowedRemoteUrl('https://example.com/a'), isTrue);
      expect(LanSyncService.isAllowedRemoteUrl('HTTP://example.com'), isTrue);
      expect(LanSyncService.isAllowedRemoteUrl('intent://scan/#Intent;end'), isFalse);
      expect(LanSyncService.isAllowedRemoteUrl('tel:123456'), isFalse);
      expect(LanSyncService.isAllowedRemoteUrl('file:///etc/passwd'), isFalse);
      expect(LanSyncService.isAllowedRemoteUrl('javascript:alert(1)'), isFalse);
      expect(LanSyncService.isAllowedRemoteUrl('https://'), isFalse);
      expect(LanSyncService.isAllowedRemoteUrl(''), isFalse);
    });

    test('#48 idle incoming sessions expire after TTL', () {
      final service = LanSyncService.instance;
      final now = DateTime(2026, 10, 1, 12);
      service.testInjectIncomingSession('g5_stale', {
        'file_id': 'g5_stale',
        'last_activity': now.subtract(const Duration(minutes: 11)),
      });
      service.testInjectIncomingSession('g5_fresh', {
        'file_id': 'g5_fresh',
        'last_activity': now.subtract(const Duration(minutes: 1)),
      });
      service.testInjectIncomingSession('g5_no_ts', {'file_id': 'g5_no_ts'});

      final removed = service.testPruneStaleIncomingFiles(now);

      expect(removed, greaterThanOrEqualTo(2));
      expect(service.testHasIncomingSession('g5_stale'), isFalse);
      expect(service.testHasIncomingSession('g5_no_ts'), isFalse);
      expect(service.testHasIncomingSession('g5_fresh'), isTrue);
    });
  });
}
