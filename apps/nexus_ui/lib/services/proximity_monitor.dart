import 'dart:math' as math;

/// Local, single-peer BLE estimates. RSSI is a noisy signal, not a range sensor.
class ProximityMonitor {
  static const freshness = Duration(seconds: 8);
  static const departureDelay = Duration(seconds: 10);
  final List<({DateTime at, double rssi})> _samples = [];
  String? peerId;
  double? referenceRssi;
  double? filteredRssi;
  DateTime? _lastSample;
  DateTime? _farSince;
  bool _armed = false;
  bool _fired = false;

  void reset({String? peer, double? reference}) {
    peerId = peer;
    referenceRssi = reference;
    _samples.clear();
    filteredRssi = null;
    _lastSample = null;
    resetLock();
  }

  void resetLock() {
    _farSince = null;
    _armed = false;
    _fired = false;
  }

  bool isFresh(DateTime now) =>
      _lastSample != null &&
      now.difference(_lastSample!) >= Duration.zero &&
      now.difference(_lastSample!) <= freshness;

  bool add(String peer, double rssi, DateTime now) {
    if (peer != peerId || !rssi.isFinite || rssi >= 0 || rssi < -127) {
      return false;
    }
    if (_lastSample != null && now.isBefore(_lastSample!)) return false;
    if (!isFresh(now)) {
      _samples.clear();
      filteredRssi = null;
      resetLock();
    }
    _lastSample = now;
    _samples.removeWhere((sample) => now.difference(sample.at) > freshness);
    // Bound by time bins, not radio frequency: a fast advertiser must still
    // retain enough history for calibration and departure confirmation.
    final sample = (at: now, rssi: rssi);
    if (_samples.isNotEmpty && _samples.last.at.millisecondsSinceEpoch ~/ 200 == now.millisecondsSinceEpoch ~/ 200) {
      _samples[_samples.length - 1] = sample;
    } else {
      _samples.add(sample);
    }
    if (_samples.length > 48) _samples.removeAt(0);
    final sorted = _samples.map((s) => s.rssi).toList()..sort();
    // Median rejects a single large excursion from a stable radio stream.
    filteredRssi = sorted[sorted.length ~/ 2];
    return true;
  }

  bool canCalibrate(DateTime now) =>
      isFresh(now) &&
      _samples.length >= 5 &&
      _samples.last.at.difference(_samples.first.at) >=
          const Duration(seconds: 2) &&
      _samples.map((s) => s.rssi).reduce(math.max) -
              _samples.map((s) => s.rssi).reduce(math.min) <=
          8;

  double? calibrateAtOneMeter(DateTime now) {
    if (!canCalibrate(now)) return null;
    referenceRssi = filteredRssi;
    resetLock();
    return referenceRssi;
  }

  double? distance(DateTime now) {
    if (!isFresh(now) || referenceRssi == null || filteredRssi == null) {
      return null;
    }
    return math.pow(10, (referenceRssi! - filteredRssi!) / 22).toDouble();
  }

  bool shouldLock({
    required DateTime now,
    required bool enabled,
    required double threshold,
    required double returnThreshold,
  }) {
    final meters = distance(now);
    if (!enabled ||
        meters == null ||
        !threshold.isFinite ||
        threshold <= 0 ||
        !returnThreshold.isFinite ||
        returnThreshold <= 0 ||
        returnThreshold >= threshold) {
      resetLock();
      return false;
    }
    if (meters <= returnThreshold && _samples.length >= 5) {
      _armed = true;
      _fired = false;
      _farSince = null;
      return false;
    }
    final latestMeters = math.pow(10, (referenceRssi! - _samples.last.rssi) / 22);
    if (!_armed || _fired || meters <= threshold || latestMeters <= threshold) {
      _farSince = null;
      return false;
    }
    _farSince ??= now;
    if (now.difference(_farSince!) < departureDelay) return false;
    _fired = true;
    return true;
  }
}
