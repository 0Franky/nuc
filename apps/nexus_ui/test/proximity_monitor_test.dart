import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_ui/services/proximity_monitor.dart';

void main() {
  late ProximityMonitor monitor;
  var now = DateTime(2026);
  void sample(double rssi, {bool enabled = true, int seconds = 1}) {
    now = now.add(Duration(seconds: seconds));
    monitor.add('phone', rssi, now);
  }

  bool lock({bool enabled = true}) => monitor.shouldLock(
    now: now,
    enabled: enabled,
    threshold: 6,
    returnThreshold: 1.2,
  );
  setUp(() {
    now = DateTime(2026);
    monitor = ProximityMonitor()..reset(peer: 'phone', reference: -59);
  });

  test('other radios cannot contaminate the selected peer filter', () {
    sample(-59);
    expect(monitor.add('other-phone', -100, now), isFalse);
    expect(monitor.distance(now), closeTo(1, 0.001));
  });
  test('no uncalibrated distance is presented as meters', () {
    monitor.reset(peer: 'phone');
    for (var i = 0; i < 6; i++) {
      sample(-71);
    }
    expect(monitor.distance(now), isNull);
    expect(lock(), isFalse);
    expect(monitor.calibrateAtOneMeter(now), -71);
    expect(monitor.distance(now), closeTo(1, 0.001));
  });
  test('a stable 3.6m estimate never crosses the 6m lock threshold', () {
    for (var i = 0; i < 6; i++) {
      sample(-59);
      lock();
    }
    for (var i = 0; i < 60; i++) {
      sample(-71.24);
      expect(lock(), isFalse);
    }
    expect(monitor.distance(now), closeTo(3.6, 0.05));
  });
  test('one distant RSSI spike cannot lock', () {
    for (var i = 0; i < 6; i++) {
      sample(-59);
      lock();
    }
    sample(-110);
    expect(lock(), isFalse);
    expect(monitor.distance(now), closeTo(1, 0.001));
  });
  test('sustained departure locks once, rearmed only by a near return', () {
    for (var i = 0; i < 6; i++) {
      sample(-59);
      lock();
    }
    var count = 0;
    for (var i = 0; i < 50; i++) {
      sample(-85);
      if (lock()) count++;
    }
    expect(count, 1);
    for (var i = 0; i < 15; i++) {
      sample(-59);
      expect(lock(), isFalse);
    }
    for (var i = 0; i < 30; i++) {
      sample(-85);
      if (lock()) count++;
    }
    expect(count, 2);
  });
  test('start already far never arms, even with consent', () {
    for (var i = 0; i < 40; i++) {
      sample(-85);
      expect(lock(), isFalse);
    }
  });
  test('disabled flag never locks regardless of distance', () {
    for (var i = 0; i < 6; i++) {
      sample(-59);
      lock(enabled: false);
    }
    for (var i = 0; i < 40; i++) {
      sample(-100);
      expect(lock(enabled: false), isFalse);
    }
  });
  test('signal loss invalidates reading and cancels departure', () {
    for (var i = 0; i < 6; i++) {
      sample(-59);
      lock();
    }
    sample(-85);
    now = now.add(const Duration(seconds: 9));
    expect(monitor.distance(now), isNull);
    expect(lock(), isFalse);
    for (var i = 0; i < 30; i++) {
      sample(-85);
      expect(lock(), isFalse);
    }
  });
  test('calibration rejects unstable or too few samples', () {
    sample(-59);
    expect(monitor.calibrateAtOneMeter(now), isNull);
    for (var i = 0; i < 6; i++) {
      sample(i.isEven ? -59 : -90);
    }
    expect(monitor.calibrateAtOneMeter(now), isNull);
  });
  test('invalid RSSI and timestamps do not create distances', () {
    monitor.reset(peer: 'phone');
    for (final rssi in [double.nan, double.infinity, 0.0, -128.0]) {
      expect(monitor.add('phone', rssi, now), isFalse);
    }
    expect(monitor.distance(now), isNull);
  });
  test('20Hz advertisements retain enough time for calibration', () {
    monitor.reset(peer: 'phone');
    for (var i = 0; i < 100; i++) {
      now = now.add(const Duration(milliseconds: 50));
      monitor.add('phone', -65, now);
    }
    expect(monitor.canCalibrate(now), isTrue);
    expect(monitor.calibrateAtOneMeter(now), -65);
  });
  test('a recent near sample in a batch cancels an elapsed departure', () {
    for (var i = 0; i < 6; i++) { sample(-59); lock(); }
    for (var i = 0; i < 10; i++) { sample(-85); expect(lock(), isFalse); }
    for (var i = 0; i < 6; i++) { sample(-85); }
    sample(-59);
    expect(lock(), isFalse);
  });

}
