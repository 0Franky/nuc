import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ui/services/shared_topology.dart';

void main() {
  final initial = SharedTopology(1, 'win', {
    'win': Offset.zero,
    'linux': const Offset(120, 0),
    'phone': const Offset(0, 90),
  });
  test('three machines project the same map around their own origin', () {
    expect(initial.relativeTo('linux')['win'], const Offset(-120, 0));
    expect(initial.relativeTo('phone')['linux'], const Offset(120, -90));
    final moved = initial.move('linux', 'phone', const Offset(0, 90));
    expect(moved.relativeTo('win')['phone'], const Offset(120, 90));
    expect(moved.relativeTo('phone')['linux'], const Offset(0, -90));
  });
  test('concurrent snapshots converge regardless of delivery order', () {
    final a = initial.move('win', 'linux', const Offset(-120, 0));
    final b = initial.move('linux', 'win', const Offset(0, -90));
    SharedTopology reduce(List<SharedTopology> packets) {
      var value = initial;
      for (final p in packets) {
        if (p.newerThan(value)) value = p;
      }
      return value;
    }

    expect(reduce([a, b, a, initial]).toJson(), reduce([b, a, b]).toJson());
    expect(a.newerThan(a), false);
  });
  test('persistence retains coordinates and conflict revision', () {
    final restored = SharedTopology.parse(
      jsonDecode(jsonEncode(initial.toJson())),
    )!;
    expect(restored.toJson(), initial.toJson());
    expect(restored.move('linux', 'win', const Offset(90, 0)).revision, 2);
  });
  test('reject malformed, nonfinite, oversized and unversioned payloads', () {
    for (final bad in [
      null,
      {},
      {...initial.toJson(), 'schema': 2},
      {...initial.toJson(), 'revision': -1},
      {
        ...initial.toJson(),
        'points': {
          'win': [double.nan, 0],
        },
      },
      {
        ...initial.toJson(),
        'points': {
          'win': [1000001, 0],
        },
      },
      {
        ...initial.toJson(),
        'points': {
          'other': [0, 0],
        },
      },
    ]) {
      expect(SharedTopology.parse(bad), isNull);
    }
  });
}
