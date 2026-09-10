import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nexus_ui/widgets/shared_input_panel.dart';
import 'package:nexus_ui/services/shared_input_service.dart';

void main() {
  final fingerprint = List.filled(32, 'ab').join(':');
  Map<String, dynamic> peer(String id, String ip) => {
    'id': id,
    'ip': ip,
    'os': 'linux',
    'online': true,
    'shared_input': {'fingerprint': fingerprint, 'port': 4243},
  };
  test('discovery alone never authorizes physical input', () {
    final config = SharedInputService.configuration(
      [peer('pc', '192.0.2.1')],
      {},
      {'pc': 'left'},
    );
    expect(config, isNot(contains('[[clients]]')));
  });
  test('approved live peer uses its address and configured edge', () {
    final config = SharedInputService.configuration(
      [peer('pc', '192.0.2.1')],
      {'pc': fingerprint},
      {'pc': 'right'},
    );
    expect(config, contains('ips = ["192.0.2.1"]'));
    expect(config, contains('position = "right"'));
    expect(config, contains('KeyLeftMeta'));
    expect(config, isNot(contains(r'\n')));
  });
  test('changed identity, offline peer and missing topology disable edges', () {
    for (final p in [
      peer('pc', '192.0.2.1')..['online'] = false,
      peer('pc', '127.0.0.1'),
    ]) {
      expect(
        SharedInputService.configuration([p], {'pc': fingerprint}, {
          'pc': 'left',
        }),
        isNot(contains('[[clients]]')),
      );
    }
    expect(
      SharedInputService.configuration(
        [peer('pc', '192.0.2.1')],
        {'pc': 'old'},
        {'pc': 'left'},
      ),
      isNot(contains('[[clients]]')),
    );
    expect(
      SharedInputService.configuration(
        [peer('pc', '192.0.2.1')],
        {'pc': fingerprint},
        {},
      ),
      isNot(contains('[[clients]]')),
    );
  });
  test('ambiguous same-edge topology cannot silently choose a device', () {
    expect(
      () => SharedInputService.configuration(
        [peer('a', '192.0.2.1'), peer('b', '192.0.2.2')],
        {'a': fingerprint, 'b': fingerprint},
        {'a': 'left', 'b': 'left'},
      ),
      throwsStateError,
    );
  });
  test('position maps reciprocal canvas offsets', () {
    expect(SharedInputService.position(-120, 20), 'left');
    expect(SharedInputService.position(120, -20), 'right');
    expect(SharedInputService.position(5, -90), 'top');
    expect(SharedInputService.position(-5, 90), 'bottom');
  });
  testWidgets('saved offline consent can be revoked even with sharing off', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final input = SharedInputService.instance;
    input.enabled = false;
    input.trusted['absent-pc'] = fingerprint;
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: SharedInputPanel())),
      ),
    );
    expect(find.text('Revoca'), findsOneWidget);
    await tester.tap(find.text('Revoca'));
    await tester.pumpAndSettle();
    expect(input.trusted.containsKey('absent-pc'), false);
  });
}
