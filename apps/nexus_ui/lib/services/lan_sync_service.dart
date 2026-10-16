import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'logger_service.dart';
import 'shared_topology.dart';
import 'proximity_monitor.dart';
import 'nexus_ffi_bridge.dart';
import '../models/models.dart';

export '../models/models.dart';

/// #51: minimal SHA-256 (FIPS 180-4), used as the file transfer digest.
/// Inline because `crypto` is not a dependency of the app (no pubspec change).
@visibleForTesting
String lanSyncSha256Hex(List<int> data) {
  const k = <int>[
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];
  final h = <int>[0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
  final bitLen = data.length * 8;
  final padLen = ((data.length + 9 + 63) ~/ 64) * 64;
  final msg = Uint8List(padLen);
  msg.setRange(0, data.length, data);
  msg[data.length] = 0x80;
  final bd = ByteData.sublistView(msg);
  bd.setUint32(padLen - 8, (bitLen >> 32) & 0xffffffff);
  bd.setUint32(padLen - 4, bitLen & 0xffffffff);
  final w = Uint32List(64);
  int rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;
  for (var off = 0; off < padLen; off += 64) {
    for (var t = 0; t < 16; t++) {
      w[t] = bd.getUint32(off + t * 4);
    }
    for (var t = 16; t < 64; t++) {
      final s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3);
      final s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10);
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & 0xffffffff;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var t = 0; t < 64; t++) {
      final bigS1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      final ch = (e & f) ^ ((~e) & g);
      final t1 = (hh + bigS1 + ch + k[t] + w[t]) & 0xffffffff;
      final bigS0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (bigS0 + maj) & 0xffffffff;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xffffffff;
    }
    h[0] = (h[0] + a) & 0xffffffff;
    h[1] = (h[1] + b) & 0xffffffff;
    h[2] = (h[2] + c) & 0xffffffff;
    h[3] = (h[3] + d) & 0xffffffff;
    h[4] = (h[4] + e) & 0xffffffff;
    h[5] = (h[5] + f) & 0xffffffff;
    h[6] = (h[6] + g) & 0xffffffff;
    h[7] = (h[7] + hh) & 0xffffffff;
  }
  return h.map((v) => v.toRadixString(16).padLeft(8, '0')).join();
}

class LanSyncService extends ChangeNotifier {
  static final LanSyncService instance = LanSyncService._();

  WebSocket? _ws;
  final Map<String, WebSocket> _peerSockets = {};
  /// Single chunk size shared by file streaming and resume.
  static const int _fileChunkSize = 64 * 1024;
  final Set<String> _localIps = {};
  final Set<String> _connectingIps = {};
  // #64: per-IP connect backoff after failures.
  final Map<String, DateTime> _peerNextAttempt = {};
  final Map<String, int> _peerBackoffSeconds = {};
  final Map<String, String> _socketPeerIds = {};
  final Map<String, Set<String>> _peerRoutes = {};
  Timer? _discoveryTimer;
  Timer? _keepAliveTimer;
  // #39: ultimo frame ricevuto per socket (ip), usato per chiudere i peer muti.
  final Map<String, DateTime> _lastFrameAt = {};
  // #39: timestamp of the last PONG received on each peer socket (keyed by IP).
  final Map<String, DateTime> _lastPongAt = {};
  static const Duration _peerSilenceTimeout = Duration(seconds: 35);
  // #40: dimensione massima di un frame WebSocket in ingresso.
  static const int _maxWsFrameChars = 8 * 1024 * 1024;
  bool _isSearching = false;

  static String _generateInitUuid() {
    final r = math.Random.secure();
    final rawHex = List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
    return '${rawHex.substring(0,8)}-${rawHex.substring(8,12)}-4${rawHex.substring(13,16)}-a${rawHex.substring(17,20)}-${rawHex.substring(20,32)}';
  }

  String deviceId = _generateInitUuid();
  String _customDeviceName = "";
  String? selectedTargetDeviceId;

  String? pcIp;
  String get pcName => targetDeviceDisplayName;
  Map<String, dynamic>? activeMedia;
  List<Map<String, dynamic>> discoveredPeers = [];
  bool isConnected = false;
  final Map<String, String> _inputErrors = {};
  final Map<String, ({String target, Completer<String?> reply})> _pendingText = {};
  int _textRequestSequence = 0;
  String? get inputError => _inputErrors[selectedTargetDeviceId ?? deviceId];
  String? inputErrorFor(String id) => _inputErrors[id];

  static bool isDesktopPeer(Map<String, dynamic> peer) {
    final type = (peer['device_type'] as String? ?? '').toLowerCase();
    final os = (peer['os'] as String? ?? '').toLowerCase();
    return type == 'desktop' || type == 'laptop' || ['windows', 'linux', 'macos'].contains(os);
  }

  String get touchpadTargetId {
    final selected = selectedTargetPeer;
    // #4: an ID that is no longer in discoveredPeers is used only if it still has an open socket.
    if (selected == null && selectedTargetDeviceId != null &&
        socketForDevice(selectedTargetDeviceId) != null) {
      return selectedTargetDeviceId!;
    }
    if (selected != null && isDesktopPeer(selected)) return selected['id'] as String;
    for (final peer in discoveredPeers) {
      if (isDesktopPeer(peer) && peer['online'] != false) return peer['id'] as String;
    }
    return 'unavailable-desktop';
  }


  void _setInputError(String id, String? error) {
    if (_inputErrors[id] == error) return;
    if (error == null) { _inputErrors.remove(id); } else { _inputErrors[id] = error; }
    notifyListeners();
  }

  bool _sendInput(Map<String, dynamic> message, String? targetId) {
    final id = targetId == null || targetId.isEmpty ? selectedTargetDeviceId ?? deviceId : targetId;
    // #2: usa la destinazione risolta (id), non il targetId grezzo che puo' essere null/vuoto.
    final socket = socketForDevice(id);
    if (socket == null) {
      final noTarget = (targetId == null || targetId.isEmpty) && selectedTargetDeviceId == null;
      _setInputError(id, noTarget
          ? 'Nessun PC di destinazione selezionato o connesso.'
          : 'Connessione diretta al PC non disponibile. Attendi la connessione o seleziona un altro PC.');
      return false;
    }
    final text = message['text'];
    if (message['type'] == 'KEYBOARD_TEXT' && text is String && text.runes.length > 4096) {
      _setInputError(id, 'Invia al massimo 4096 caratteri per volta.');
      return false;
    }
    try { socket.add(_encodeForDevice(message, targetId)); }
    catch (_) { _setInputError(id, 'Invio input non riuscito: connessione interrotta.'); return false; }
    return true;
  }


  String get defaultDeviceSuffix {
    final clean = deviceId.replaceAll('-', '');
    return (clean.length >= 4 ? clean.substring(0, 4) : "0001").toUpperCase();
  }

  String get defaultDeviceName {
    final prefix = Platform.isAndroid
        ? "Smartphone Android"
        : (Platform.isWindows
            ? "PC Windows"
            : (Platform.isMacOS
                ? "Mac"
                : (Platform.isIOS ? "iPhone" : "PC Linux")));
    return "$prefix-$defaultDeviceSuffix";
  }

  String get deviceName => _customDeviceName.isNotEmpty ? _customDeviceName : defaultDeviceName;

  Future<void> setDeviceName(String newName) async {
    var cleaned = newName.replaceAll(_peerControlChars, '').trim();
    if (cleaned.length > 64) cleaned = cleaned.substring(0, 64).trim();
    _customDeviceName = cleaned;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_customDeviceName.isEmpty) {
        await prefs.remove('nexus_custom_device_name');
      } else {
        await prefs.setString('nexus_custom_device_name', _customDeviceName);
      }
    } catch (e) {
      NexusLogger.log("LAN_SYNC", "Failed to persist device name: $e");
    }
    broadcastDeviceMetadata();
  }

  Future<void> resetDeviceNameToDefault() async {
    await setDeviceName("");
  }

  void selectTargetDevice(String id) {
    if (selectedTargetDeviceId != id) {
      selectedTargetDeviceId = id;
      NexusLogger.log("ROUTING", "Switched active target device to: $id");
      notifyListeners();
    }
  }

  static final RegExp _legacyBleMacPattern = RegExp(r'^(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$');

  static bool _legacyBleIdentity(String id) =>
      _legacyBleMacPattern.hasMatch(id) ||
      id == 'auto-ble-peer' || id.startsWith('Peer BLE (');

  SharedTopology? _cleanLegacyBleTopology(SharedTopology? topology) {
    if (topology == null || !topology.points.keys.any(_legacyBleIdentity)) return topology;
    final points = Map<String, Offset>.from(topology.points)..removeWhere((id, _) => _legacyBleIdentity(id));
    if (points.isEmpty || !points.containsKey(topology.author)) return null;
    // #8: keep the original author (it is guaranteed to be present at this point).
    return SharedTopology(topology.revision + 1, topology.author, points);
  }

  static const int _maxTrackedPeers = 64;
  static const int _maxKnownPeerIds = 256;
  static final RegExp _peerControlChars = RegExp(r'[\x00-\x1F\x7F]');

  static String? _clampPeerField(String? value, int maxLength) {
    if (value == null) return null;
    final cleaned = value.replaceAll(_peerControlChars, '').trim();
    return cleaned.length > maxLength ? cleaned.substring(0, maxLength) : cleaned;
  }

  void registerOrUpdatePeer({
    required String id,
    required String name,
    String? ip,
    String? deviceType,
    String? os,
    String? spatialPosition,
    int namePriority = 1,
    bool discoveryOnly = false,
    Map<String, dynamic>? sharedInput,
    bool updateSharedInput = false,
  }) {
    if (id.isEmpty || id.length > 128 || _peerControlChars.hasMatch(id)) return;
    if (id == deviceId || _legacyBleIdentity(id)) return;
    name = _clampPeerField(name, 64) ?? '';
    ip = _clampPeerField(ip, 64);
    deviceType = _clampPeerField(deviceType, 32);
    os = _clampPeerField(os, 64);
    spatialPosition = _clampPeerField(spatialPosition, 32);
    if (ip != null && _localIps.contains(ip)) return;
    if (!_knownPeerIds.contains(id) && _knownPeerIds.length >= _maxKnownPeerIds) {
      NexusLogger.log("LAN_SYNC", "Peer registry full: ignoring new peer id");
      return;
    }
    _knownPeerIds.add(id);
    final online = !discoveryOnly || socketForDevice(id) != null;

    // An IP is a route, not an identity: a router can announce several peers.
    var existingIndex = discoveredPeers.indexWhere((p) => p['id'] == id);
    if (existingIndex < 0 && ip != null && ip.isNotEmpty) {
      existingIndex = discoveredPeers.indexWhere((p) =>
          p['id'] == 'peer-nexus-$ip' && p['ip'] == ip);
    }
    if (existingIndex >= 0) {
      final existing = discoveredPeers[existingIndex];
      if (selectedTargetDeviceId == existing['id']) selectedTargetDeviceId = id;
      existing['id'] = id;
      if (name.trim().isNotEmpty && namePriority >= (existing['name_priority'] as int? ?? 0)) {
        existing['name'] = name.trim();
        existing['name_priority'] = namePriority;
      }
      if (ip != null && ip.isNotEmpty) existing['ip'] = ip;
      if (deviceType != null && deviceType.isNotEmpty) existing['device_type'] = deviceType;
      if (os != null && os.isNotEmpty) existing['os'] = os;
      if (spatialPosition != null && spatialPosition.isNotEmpty) existing['spatial_position'] = spatialPosition;
      existing['online'] = online;
    } else {
      final fallbackType = (name.toLowerCase().contains("phone") ||
              name.toLowerCase().contains("smartphone") ||
              name.toLowerCase().contains("android") ||
              name.toLowerCase().contains("iphone"))
          ? "Mobile"
          : "Desktop";
      if (discoveredPeers.length >= _maxTrackedPeers) {
        final evictIndex = discoveredPeers.indexWhere((p) =>
            p['online'] != true && p['id'] != selectedTargetDeviceId);
        if (evictIndex < 0) {
          NexusLogger.log("LAN_SYNC", "Too many discovered peers: ignoring new peer");
          return;
        }
        discoveredPeers.removeAt(evictIndex);
      }
      discoveredPeers.add({
        "id": id,
        "name": name.trim().isEmpty ? "Dispositivo ${id.substring(0, math.min(4, id.length))}" : name.trim(),
        "ip": ip,
        "online": online,
        "name_priority": namePriority,
        "device_type": deviceType ?? fallbackType,
        "os": os ?? "Unknown",
        "spatial_position": spatialPosition ?? "Center",
      });
    }
    if (ip != null && id != 'peer-nexus-$ip') {
      final provisionalId = 'peer-nexus-$ip';
      if (selectedTargetDeviceId == provisionalId) selectedTargetDeviceId = id;
      discoveredPeers.removeWhere((peer) => peer['id'] == provisionalId);
    }
    if (updateSharedInput) {
      for (final peer in discoveredPeers) {
        if (peer['id'] == id) peer['shared_input'] = sharedInput;
      }
    }
    if (selectedTargetDeviceId == null && discoveredPeers.isNotEmpty) {
      selectedTargetDeviceId = discoveredPeers.first['id'] as String?;
    }
    notifyListeners();
  }

  Map<String, dynamic>? get selectedTargetPeer {
    if (discoveredPeers.isEmpty) return null;
    if (selectedTargetDeviceId != null) {
      for (final peer in discoveredPeers) {
        if (peer['id'] == selectedTargetDeviceId) return peer;
      }
      return null;
    }
    return discoveredPeers.firstWhere(
      (p) => p['device_type'] == 'Desktop' || (p['os'] as String?)?.toLowerCase() == 'windows',
      orElse: () => discoveredPeers.first,
    );
  }

  String get targetDeviceDisplayName {
    final peer = selectedTargetPeer;
    if (peer != null) {
      final name = peer['name'] as String?;
      if (name != null && name.isNotEmpty) return name;
    }
    return "PC";
  }

  WebSocket? get targetSocket {
    final id = selectedTargetPeer?['id'] as String?;
    if (id != null) return socketForDevice(id);
    // Local engine commands are valid only when no remote target was selected.
    return selectedTargetDeviceId == null ? _peerSockets['127.0.0.1'] : null;
  }

  WebSocket? socketForDevice(String? targetId) {
    if (targetId == null || targetId.isEmpty) return targetSocket;
    for (final entry in _socketPeerIds.entries) {
      if (entry.value != targetId) continue;
      final socket = _peerSockets[entry.key];
      // #7: a socket that is closing/closed must not count as a live route.
      if (socket != null && socket.readyState == WebSocket.open) return socket;
    }
    for (final route in _peerRoutes[targetId] ?? <String>{}) {
      final socket = _peerSockets[route];
      if (socket != null && socket.readyState == WebSocket.open) return socket;
    }
    return null;
  }

  String _encodeForDevice(Map<String, dynamic> message, String? targetId) {
    final id = targetId == null || targetId.isEmpty ? selectedTargetDeviceId : targetId;
    return jsonEncode({...message, 'target_device_id': ?id});
  }

  Future<void> adoptNativeIdentity(String id) async {
    final previousId = deviceId;
    deviceId = id;
    final topology = _sharedTopology;
    if (topology != null && previousId != id) {
      // #9: always drop the previous point, so no ghost remains when both ids exist.
      if (topology.points.containsKey(previousId)) {
        final points = {...topology.points};
        final previousPoint = points.remove(previousId)!;
        points.putIfAbsent(id, () => previousPoint);
        _sharedTopology = SharedTopology(topology.revision + 1, id, points);
      }
      _projectTopology();
      try {
        await _saveTopology();
      } catch (e) {
        NexusLogger.log("LAN_SYNC", "Failed to save topology after identity change: $e");
      }
      _broadcastTopology();
    }
    discoveredPeers.removeWhere((peer) => peer['id'] == id);
    if (selectedTargetDeviceId == id) selectedTargetDeviceId = null;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('nexus_device_id', id);
    } catch (e) {
      NexusLogger.log("LAN_SYNC", "Failed to persist native device id: $e");
    }
  }

  void broadcastDeviceMetadata() {
    final meta = {
      "type": "PEER_METADATA",
      "id": deviceId,
      "device_id": deviceId,
      "name": deviceName,
      "device_type": deviceType,
      "os": Platform.operatingSystem,
      "spatial_position": spatialPosition,
      "shared_input": sharedInputMetadata,
    };
    final encoded = jsonEncode(meta);
    // #10: log failures and close the broken socket; its onDone handler then
    // removes it from _peerSockets, _socketPeerIds and _peerRoutes.
    for (final entry in _peerSockets.entries.toList()) {
      try {
        entry.value.add(encoded);
      } catch (e) {
        NexusLogger.log("LAN_SYNC", "PEER_METADATA send to ${entry.key} failed: $e");
        entry.value.close().catchError((_) {});
      }
    }
    if (_ws != null && !_peerSockets.containsValue(_ws)) {
      try {
        _ws!.add(encoded);
      } catch (e) {
        NexusLogger.log("LAN_SYNC", "PEER_METADATA send on primary socket failed: $e");
      }
    }
    notifyListeners();
  }

  // Spatial & Proximity State (Strictly Real Hardware)
  String spatialPosition = "Left"; // Cell is to the left of the PC
  String deviceType = Platform.isAndroid || Platform.isIOS ? "Mobile" : "Desktop";
  String? proximityMotion; // Null until real live signal received
  double? estimatedDistanceMeters; // Null until real BLE distance measured
  int? liveRssi;
  bool autoLockOnWalkAway = false;
  final proximity = ProximityMonitor();
  String? proximityPeerId;
  final Map<String, double> _proximityCalibration = {};
  int _lastBleSequence = -1;
  bool? _bleMonitoringApplied;
  String bleScanStatus = "disabled";
  String? bleScanError;
  String? proximityLockError;
  bool autoPauseMediaOnWalkAway = true;
  bool wakeOnApproach = true;
  bool universalControlActive = false;
  Map<String, dynamic>? sharedInputMetadata;
  bool bleSpatialAutoDetect = true; // Active by default when Bluetooth is available
  bool isBleHardwareAvailable = false; // Real OS radio check (Windows Radio / Mobile Adapter)
  String lastAutoDeterminedPosition = "Left";

  // Dynamic Freeform Multi-Device Coordinates: offset relative to PC center (0.0, 0.0)
  final Map<String, Offset> customDeviceOffsets = {
    'self': const Offset(-120.0, 0.0),
  };

  Offset _planeOrigin = Offset.zero;
  Map<String, Offset> get topologyPoints {
    final origin = _sharedTopology?.points[deviceId] ?? _planeOrigin;
    return {
      ...?_sharedTopology?.points,
      deviceId: origin,
      for (final id in discoveredPeers.map((peer) => peer['id']).whereType<String>())
        if (id != deviceId)
          id: _sharedTopology?.points[id] ?? origin + getDeviceOffset(id),
    };
  }

  void moveTopologyDevice(String id, Offset position) {
    final points = topologyPoints;
    if (!points.containsKey(id)) return;
    points[id] = position;
    final origin = points[deviceId]!;
    final next = SharedTopology((_sharedTopology?.revision ?? 0) + 1, deviceId, points);
    if (SharedTopology.parse(next.toJson()) == null) return;
    _planeOrigin = origin;
    if (_sharedTopology != null) {
      _sharedTopology = next;
      _projectTopology();
      _broadcastTopology();
    } else {
      customDeviceOffsets..clear()..addAll(next.relativeTo(deviceId));
    }
    final target = selectedTargetDeviceId;
    if (target != null && customDeviceOffsets.containsKey(target)) {
      updateDeviceOffset(target, customDeviceOffsets[target]!, syncNetwork: false);
    }
    unawaited(_saveTopology());
    notifyListeners();
  }

  SharedTopology? _sharedTopology;
  bool get topologySyncEnabled => _sharedTopology != null;
  Future<void> _topologySave = Future<void>.value();

  void _broadcastTopology() {
    final topology = _sharedTopology;
    if (topology == null) return;
    final payload = jsonEncode({'type': 'TOPOLOGY_SYNC',
      'sender_device_id': deviceId, 'topology': topology.toJson()});
    final sockets = _peerSockets.values.toSet();
    final ws = _ws;
    if (ws != null) sockets.add(ws);
    for (final socket in sockets) {
      if (socket.readyState != WebSocket.open) continue;
      try {
        socket.add(payload);
      } catch (e) {
        // Il socket puo' chiudersi tra il controllo e l'invio: la pulizia
        // avviene negli handler onDone/onError, qui non si interrompe il ciclo.
        NexusLogger.log("LAN_SYNC", "TOPOLOGY_SYNC send failed: $e");
      }
    }
  }

  void _projectTopology() {
    final relative = _sharedTopology?.relativeTo(deviceId);
    if (relative == null || !_sharedTopology!.points.containsKey(deviceId)) return;
    customDeviceOffsets..clear()..addAll(relative);
    final target = selectedTargetDeviceId;
    if (target != null && relative.containsKey(target)) {
      updateDeviceOffset(target, relative[target]!, syncNetwork: false);
    }
  }

  Future<void> synchronizeTopology() async {
    final previous = _sharedTopology;
    final origin = previous?.points[deviceId] ?? _planeOrigin;
    final points = <String, Offset>{...?previous?.points, deviceId: origin};
    for (final id in discoveredPeers.map((peer) => peer['id']).whereType<String>()) {
      // Conserva le posizioni gia' condivise da altri dispositivi.
      if (id != deviceId && !points.containsKey(id)) points[id] = origin + getDeviceOffset(id);
    }
    final next = SharedTopology((previous?.revision ?? 0) + 1, deviceId, points);
    if (SharedTopology.parse(next.toJson()) == null) {
      throw StateError('Topologia non valida o troppi dispositivi');
    }
    _sharedTopology = next;
    _projectTopology();
    await _saveTopology();
    _broadcastTopology();
    notifyListeners();
  }

  void updateDeviceOffset(String id, Offset offset, {bool syncNetwork = true}) {
    final targetPeer = (id == 'self' || id.isEmpty) ? (selectedTargetDeviceId ?? '') : id;
    SharedTopology? nextTopology;
    if (syncNetwork && _sharedTopology != null && targetPeer.isNotEmpty) {
      // #12b: move() valida l'input e può lanciare StateError/ArgumentError;
      // in quel caso lo stato locale non viene toccato.
      final SharedTopology moved;
      try {
        moved = _sharedTopology!.move(deviceId, targetPeer, offset);
      } on StateError catch (e) {
        NexusLogger.log('TOPOLOGY', 'Topology move for $targetPeer rejected: $e');
        return;
      } on ArgumentError catch (e) {
        NexusLogger.log('TOPOLOGY', 'Topology move for $targetPeer rejected: $e');
        return;
      }
      // Valida prima di mutare lo stato locale.
      if (SharedTopology.parse(moved.toJson()) == null) {
        NexusLogger.log('TOPOLOGY', 'Invalid topology move for $targetPeer ignored');
        return;
      }
      nextTopology = moved;
    }
    customDeviceOffsets[id] = offset;
    // Derive macro quadrant relative to center
    if (offset.dx.abs() > offset.dy.abs()) {
      spatialPosition = offset.dx >= 0 ? "Right" : "Left";
    } else {
      spatialPosition = offset.dy >= 0 ? "Below" : "Above";
    }
    if (syncNetwork) {
      if (nextTopology != null) {
        _sharedTopology = nextTopology;
        _projectTopology();
        _broadcastTopology();
      } else if (targetPeer.isEmpty) {
        NexusLogger.log('TOPOLOGY', 'No target peer: spatial arrangement not sent');
      } else {
        sendSpatialArrangement(targetPeer, spatialPosition, customOffset: offset);
      }
      unawaited(_saveTopology());
      notifyListeners();
    }
  }

  Future<void> _saveTopology() {
    final planeOrigin = jsonEncode([_planeOrigin.dx, _planeOrigin.dy]);
    final local = jsonEncode(customDeviceOffsets.map((id, offset) => MapEntry(id, [offset.dx, offset.dy])));
    final shared = _sharedTopology == null ? null : jsonEncode(_sharedTopology!.toJson());
    _topologySave = _topologySave.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('shared_input_topology', local);
      await prefs.setString('topology_plane_origin', planeOrigin);
      if (shared != null) await prefs.setString('shared_topology_v1', shared);
    }).catchError((Object e) {
      NexusLogger.log('TOPOLOGY', 'Persistence failed: $e');
    });
    return _topologySave;
  }

  Offset getDeviceOffset(String id) {
    if (customDeviceOffsets.containsKey(id)) {
      return customDeviceOffsets[id]!;
    }
    // Default position based on spatialPosition
    switch (spatialPosition.toLowerCase()) {
      case 'right':
        return const Offset(120.0, 0.0);
      case 'above':
        return const Offset(0.0, -90.0);
      case 'below':
        return const Offset(0.0, 90.0);
      case 'left':
      default:
        return const Offset(-120.0, 0.0);
    }
  }

  // Configurable BLE Proximity Distance Thresholds (User Configurable)
  double walkAwayThresholdMeters = 2.2; // Default requested: 2.2m
  double returnThresholdMeters = 1.2;
  double autoLockThresholdMeters = 3.0;

  // #15: formato ammesso per l'ID dispositivo letto dalle preferenze.
  static final RegExp _validDeviceIdPattern = RegExp(r'^[A-Za-z0-9._:-]{1,128}$');

  // #17: soglia letta dalle preferenze, con fallback se assente, del tipo sbagliato o non valida.
  static double _loadThreshold(SharedPreferences prefs, String key, double fallback) {
    try {
      final v = prefs.getDouble(key);
      if (v != null && v.isFinite && v > 0) return v;
    } catch (_) {}
    return fallback;
  }

  Future<void> loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedId = prefs.getString('nexus_device_id');
      if (savedId != null && _validDeviceIdPattern.hasMatch(savedId)) {
        deviceId = savedId;
      } else {
        if (savedId != null && savedId.isNotEmpty) {
          NexusLogger.log("SETTINGS", "Stored device id has an invalid format: regenerating");
        }
        deviceId = _generateInitUuid();
        await prefs.setString('nexus_device_id', deviceId);
      }
      try {
        final planeOrigin = jsonDecode(prefs.getString('topology_plane_origin') ?? '[0,0]');
        if (planeOrigin is List && planeOrigin.length == 2 && planeOrigin.every((v) => v is num && v.isFinite)) {
          _planeOrigin = Offset((planeOrigin[0] as num).toDouble(), (planeOrigin[1] as num).toDouble());
        }
      } catch (e) {
        NexusLogger.log("SETTINGS", "Ignoring invalid topology_plane_origin: $e");
      }
      try {
        final topology = jsonDecode(prefs.getString('shared_input_topology') ?? '{}');
        if (topology is Map) {
          for (final entry in topology.entries) {
            final key = entry.key;
            final value = entry.value;
            if (key is String && value is List && value.length == 2 && value.every((v) => v is num && v.isFinite)) {
              customDeviceOffsets[key] = Offset((value[0] as num).toDouble(), (value[1] as num).toDouble());
            }
          }
        }
      } catch (e) {
        NexusLogger.log("SETTINGS", "Ignoring invalid shared_input_topology: $e");
      }
      try {
        _sharedTopology = _cleanLegacyBleTopology(SharedTopology.parse(jsonDecode(prefs.getString('shared_topology_v1') ?? 'null')));
      } catch (e) {
        NexusLogger.log("SETTINGS", "Ignoring invalid shared_topology_v1: $e");
      }
      customDeviceOffsets.removeWhere((id, _) => _legacyBleIdentity(id));
      _projectTopology();
      _customDeviceName = prefs.getString('nexus_custom_device_name') ?? "";

      walkAwayThresholdMeters = _loadThreshold(prefs, 'proximity_walk_away_threshold', 2.2);
      returnThresholdMeters = _loadThreshold(prefs, 'proximity_return_threshold', 1.2);
      autoLockThresholdMeters = _loadThreshold(prefs, 'proximity_autolock_threshold', 3.0);
      if (!(returnThresholdMeters < walkAwayThresholdMeters && returnThresholdMeters < autoLockThresholdMeters)) {
        NexusLogger.log("SETTINGS", "Inconsistent proximity thresholds: restoring defaults");
        walkAwayThresholdMeters = 2.2;
        returnThresholdMeters = 1.2;
        autoLockThresholdMeters = 3.0;
      }
      // The old key was enabled by default: it cannot establish explicit consent.
      autoLockOnWalkAway = prefs.getBool('proximity_lock_opt_in_v2') ?? false;
      proximityPeerId = prefs.getString('proximity_peer_v2');
      _proximityCalibration.clear();
      dynamic calibration;
      try {
        calibration = jsonDecode(prefs.getString('proximity_calibration_v2') ?? '{}');
      } catch (e) {
        NexusLogger.log("SETTINGS", "Ignoring invalid proximity_calibration_v2: $e");
      }
      if (calibration is Map) {
        for (final entry in calibration.entries) {
          if (entry.key is String && entry.value is num &&
              entry.value.isFinite && entry.value < 0 && entry.value >= -127) {
            _proximityCalibration[entry.key as String] = (entry.value as num).toDouble();
          }
        }
      }
      proximity.reset(peer: proximityPeerId, reference: _proximityCalibration[proximityPeerId]);
      NexusFfiBridge.instance.setProximityLockEnabled(autoLockOnWalkAway);
      autoPauseMediaOnWalkAway = prefs.getBool('autoPauseMediaOnWalkAway') ?? true;
      wakeOnApproach = prefs.getBool('wakeOnApproach') ?? true;
      bleSpatialAutoDetect = prefs.getBool('bleSpatialAutoDetect') ?? true;
      NexusLogger.log("SETTINGS", "Settings loaded: deviceName=$deviceName (ID: $deviceId), walkAway=${walkAwayThresholdMeters}m, return=${returnThresholdMeters}m, lock=${autoLockThresholdMeters}m");
    } catch (e) {
      NexusLogger.log("SETTINGS", "Error loading settings: $e");
    }
  }

  Future<void> setWalkAwayThreshold(double meters) async {
    if (!meters.isFinite || meters <= 0 || meters <= returnThresholdMeters) return;
    proximity.resetLock();
    walkAwayThresholdMeters = meters;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('proximity_walk_away_threshold', meters);
    } catch (e) {
      NexusLogger.log("SETTINGS", "Error saving proximity_walk_away_threshold: $e");
    }
  }

  Future<void> setReturnThreshold(double meters) async {
    if (!meters.isFinite || meters <= 0 || meters >= autoLockThresholdMeters) return;
    proximity.resetLock();
    returnThresholdMeters = meters;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('proximity_return_threshold', meters);
    } catch (e) {
      NexusLogger.log("SETTINGS", "Error saving proximity_return_threshold: $e");
    }
  }

  Future<void> setAutoLockThreshold(double meters) async {
    if (!meters.isFinite || meters <= returnThresholdMeters) return;
    proximity.resetLock();
    autoLockThresholdMeters = meters;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('proximity_autolock_threshold', meters);
    } catch (e) {
      NexusLogger.log("SETTINGS", "Error saving proximity_autolock_threshold: $e");
    }
  }

  Future<void> saveSettingBool(String key, bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (e) {
      NexusLogger.log("SETTINGS", "Error saving $key: $e");
    }
    notifyListeners();
  }

  final Set<String> _knownPeerIds = {};

  double currentVolume = 0.85;
  bool isAudioMuted = false;

  // Operational Feature Flags (Zero Mock)
  bool clipboardSyncEnabled = true;
  bool mediaHandoffEnabled = true;
  bool audioRelayEnabled = true;
  bool fileTransferEnabled = true;

  final _openUrlController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onOpenUrl => _openUrlController.stream;

  final _mediaHandoffPromptController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onMediaHandoffPrompt => _mediaHandoffPromptController.stream;

  final _clipboardController = StreamController<String>.broadcast();
  Stream<String> get onClipboardSync => _clipboardController.stream;

  bool clipboardPrivacyGate = true;
  final Map<String, String> _pendingLocalSecrets = {};
  // #44: reveal requests we actually sent; unsolicited REVEAL_RESPONSEs are dropped.
  final Set<String> _pendingClipboardRevealRequests = {};
  final Set<String> _pendingNotificationRevealRequests = {};

  final _secretAnnounceController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onSecretAnnounce => _secretAnnounceController.stream;

  final _secretRevealedController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onSecretRevealed => _secretRevealedController.stream;

  final _fileOfferController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onFileOffer => _fileOfferController.stream;

  final _fileProgressController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onFileProgress => _fileProgressController.stream;

  final _fileReceivedController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onFileReceived => _fileReceivedController.stream;

  final Map<String, Map<String, dynamic>> _incomingFiles = {};
  // #22: bounded cache of outgoing files (used only by FILE_RESUME_REQUEST):
  // limited number of entries, total size and lifetime; oldest entries are evicted first.
  static const int _outgoingCacheMaxEntries = 4;
  static const int _outgoingCacheMaxBytes = 64 * 1024 * 1024;
  static const Duration _outgoingCacheTtl = Duration(minutes: 10);
  final Map<String, List<int>> _outgoingFileCache = {};
  final Map<String, DateTime> _outgoingFileCacheTimes = {};
  // #53: destination socket each cached file was sent to; resume is served only to that socket.
  final Map<String, Object?> _outgoingFileCachePeers = {};

  void _purgeOutgoingFileCache() {
    final now = DateTime.now();
    final expired = _outgoingFileCacheTimes.entries
        .where((e) => now.difference(e.value) > _outgoingCacheTtl)
        .map((e) => e.key)
        .toList();
    for (final id in expired) {
      _outgoingFileCache.remove(id);
      _outgoingFileCacheTimes.remove(id);
      _outgoingFileCachePeers.remove(id);
    }
  }

  void _cacheOutgoingFile(String fileId, List<int> bytes, {required Object? peer}) {
    _purgeOutgoingFileCache();
    _outgoingFileCache.remove(fileId);
    _outgoingFileCacheTimes.remove(fileId);
    _outgoingFileCachePeers.remove(fileId);
    if (bytes.length > _outgoingCacheMaxBytes) {
      NexusLogger.log("FILE_TRANSFER", "File $fileId too large to cache for resume (${bytes.length} bytes)");
      return;
    }
    int total = _outgoingFileCache.values.fold(0, (s, b) => s + b.length);
    while (_outgoingFileCache.isNotEmpty &&
        (_outgoingFileCache.length >= _outgoingCacheMaxEntries || total + bytes.length > _outgoingCacheMaxBytes)) {
      final oldest = _outgoingFileCache.keys.first;
      total -= _outgoingFileCache.remove(oldest)?.length ?? 0;
      _outgoingFileCacheTimes.remove(oldest);
      _outgoingFileCachePeers.remove(oldest);
    }
    _outgoingFileCache[fileId] = bytes;
    _outgoingFileCacheTimes[fileId] = DateTime.now();
    _outgoingFileCachePeers[fileId] = peer;
  }

  List<int>? _getCachedOutgoingFile(String fileId, {required Object? requester}) {
    _purgeOutgoingFileCache();
    // #53: only the socket the file was offered to may pull it again.
    final bound = _outgoingFileCachePeers[fileId];
    if (bound == null || requester == null || !identical(bound, requester)) return null;
    return _outgoingFileCache[fileId];
  }

  final _topologyController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onTopologyChanged => _topologyController.stream;

  final _proximityController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onProximityUpdate => _proximityController.stream;

  // #23: notifications are a bounded list (newest first) and pending secrets expire.
  static const int _maxNotifications = 200;
  static const int _maxPendingNotificationSecrets = 50;
  static const Duration _pendingNotificationSecretTtl = Duration(minutes: 10);
  final List<NexusNotification> notifications = [];
  final Map<String, String> _pendingLocalNotificationSecrets = {};

  void _insertNotification(NexusNotification notif) {
    notifications.insert(0, notif);
    if (notifications.length > _maxNotifications) {
      notifications.removeRange(_maxNotifications, notifications.length);
    }
  }

  void _storePendingNotificationSecret(String id, String body) {
    while (_pendingLocalNotificationSecrets.length >= _maxPendingNotificationSecrets) {
      _pendingLocalNotificationSecrets.remove(_pendingLocalNotificationSecrets.keys.first);
    }
    _pendingLocalNotificationSecrets[id] = body;
    Timer(_pendingNotificationSecretTtl, () => _pendingLocalNotificationSecrets.remove(id));
  }
  final _notificationController = StreamController<NexusNotification>.broadcast();
  Stream<NexusNotification> get onNotificationReceived => _notificationController.stream;
  final _notificationRevealedController = StreamController<String>.broadcast();
  Stream<String> get onNotificationRevealed => _notificationRevealedController.stream;

  Timer? _clipboardWatcherTimer;
  String? _lastSeenClipboardText;

  Timer? _btWatcherTimer;

  RawDatagramSocket? _udpListenerSocket;

  LanSyncService._();

  // #19/#23: il singleton vive normalmente per l'intero processo; dispose()
  // rilascia comunque controller, timer e socket se viene chiamato (es. test).
  @override
  void dispose() {
    _discoveryTimer?.cancel();
    _keepAliveTimer?.cancel();
    _clipboardWatcherTimer?.cancel();
    _btWatcherTimer?.cancel();
    _udpListenerSocket?.close();
    _udpListenerSocket = null;
    final sockets = <WebSocket>{
      ?_ws,
      ..._peerSockets.values,
    };
    for (final s in sockets) {
      unawaited(s.close().catchError((Object e) {
        debugPrint('[LanSync] dispose: close socket fallita: $e');
      }));
    }
    _ws = null;
    _peerSockets.clear();
    _outgoingFileCache.clear();
    _pendingLocalNotificationSecrets.clear();
    notifications.clear();
    final controllers = <StreamController<dynamic>>[
      _openUrlController,
      _mediaHandoffPromptController,
      _clipboardController,
      _secretAnnounceController,
      _secretRevealedController,
      _fileOfferController,
      _fileProgressController,
      _fileReceivedController,
      _topologyController,
      _proximityController,
      _notificationController,
      _notificationRevealedController,
    ];
    for (final c in controllers) {
      unawaited(c.close());
    }
    _started = false;
    super.dispose();
  }

  bool _started = false;

  // #25: limiti difensivi per i beacon UDP non autenticati.
  static const int _udpBeaconMaxBytes = 1024;
  static const Duration _udpBeaconMinInterval = Duration(milliseconds: 500);
  static const int _udpBeaconMaxSources = 64;
  static final RegExp _udpBeaconControlChars = RegExp(r'[\x00-\x1F\x7F]');
  final Map<String, DateTime> _udpBeaconLastSeen = {};

  static String? _udpBeaconString(dynamic value, int maxLen) {
    if (value is! String) return null;
    final v = value.trim().replaceAll(_udpBeaconControlChars, '');
    if (v.isEmpty) return null;
    return v.length > maxLen ? v.substring(0, maxLen) : v;
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    // #24: se l'avvio fallisce, _started torna false cosi' start() puo' essere ritentato.
    try {
      await loadSettings();
      _setupNativeBleChannel();
      _startUdpBeaconListener();
      _startPeriodicDiscovery();
      _startClipboardWatcher();
      _startBluetoothHardwareWatcher();
    } catch (e) {
      _started = false;
      NexusLogger.log("LAN_SYNC", "Avvio del servizio fallito: $e");
      rethrow;
    }
  }

  // #26: il listener UDP si riavvia con backoff esponenziale limitato (1s..60s).
  int _udpBeaconRestartAttempt = 0;
  static const int _udpBeaconRestartMaxDelaySec = 60;

  void _scheduleUdpBeaconRestart(RawDatagramSocket? socket) {
    if (!_started || !identical(_udpListenerSocket, socket)) return;
    final attempt = _udpBeaconRestartAttempt;
    if (_udpBeaconRestartAttempt < 6) _udpBeaconRestartAttempt++;
    final delaySec = math.min(1 << attempt, _udpBeaconRestartMaxDelaySec);
    NexusLogger.log("LAN_SYNC", "UDP Beacon listener restart in ${delaySec}s (tentativo ${attempt + 1})");
    Future.delayed(Duration(seconds: delaySec), () {
      if (_started && identical(_udpListenerSocket, socket)) {
        _startUdpBeaconListener();
      }
    });
  }

  Future<void> _startUdpBeaconListener() async {
    try {
      _udpListenerSocket?.close();
      _udpListenerSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        42420,
        reuseAddress: true,
        reusePort: !Platform.isWindows,
      );
      _udpListenerSocket!.broadcastEnabled = true;
      final socket = _udpListenerSocket!;
      socket.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final dg = _udpListenerSocket?.receive();
          if (dg != null) {
            // #25: scarta datagrammi troppo grandi e applica un rate limit per IP.
            if (dg.data.length > _udpBeaconMaxBytes) return;
            final senderIp = dg.address.address;
            final now = DateTime.now();
            final last = _udpBeaconLastSeen[senderIp];
            if (last != null && now.difference(last) < _udpBeaconMinInterval) return;
            if (last == null && _udpBeaconLastSeen.length >= _udpBeaconMaxSources) {
              _udpBeaconLastSeen.removeWhere(
                  (_, t) => now.difference(t) > const Duration(minutes: 5));
              if (_udpBeaconLastSeen.length >= _udpBeaconMaxSources) return;
            }
            _udpBeaconLastSeen[senderIp] = now;
            _udpBeaconRestartAttempt = 0;
            try {
              final text = utf8.decode(dg.data);
              final json = jsonDecode(text);
              if (json is Map && json['type'] == 'PEER_ANNOUNCE') {
                final pId = _udpBeaconString(json['id'], 128) ??
                    _udpBeaconString(json['device_id'], 128) ??
                    '';
                final pName = _udpBeaconString(json['name'], 64) ?? 'Dispositivo Remoto';
                final pType = _udpBeaconString(json['device_type'], 32);
                final pOs = _udpBeaconString(json['os'], 32);
                final pPos = _udpBeaconString(json['spatial_position'], 32);

                if (pId.isNotEmpty && pId != deviceId && !_localIps.contains(senderIp)) {
                  registerOrUpdatePeer(
                    id: pId,
                    name: pName,
                    ip: senderIp,
                    deviceType: pType,
                    os: pOs,
                    spatialPosition: pPos,
                    namePriority: 0,
                    discoveryOnly: true,
                  );
                  if (!_peerSockets.containsKey(senderIp)) {
                    connectToPeer(senderIp);
                  }
                }
              }
            } catch (e) {
              NexusLogger.log("LAN_SYNC", "UDP beacon malformato da $senderIp scartato: $e");
            }
          }
        }
      }, onError: (Object e) {
        NexusLogger.log("LAN_SYNC", "UDP Beacon listener error: $e");
      }, onDone: () {
        NexusLogger.log("LAN_SYNC", "UDP Beacon listener closed");
        _scheduleUdpBeaconRestart(socket);
      });
      NexusLogger.log("LAN_SYNC", "UDP Beacon listener active on port 42420");
    } catch (e) {
      NexusLogger.log("LAN_SYNC", "UDP Beacon listener bind warning (non-fatal): $e");
      _scheduleUdpBeaconRestart(_udpListenerSocket);
    }
  }

  void _setupNativeBleChannel() {
    if (Platform.isAndroid) {
      _hardwareChannel.setMethodCallHandler((call) async {
        if (call.method == 'onBleRssiSample') {
          final rawArgs = call.arguments;
          final args = rawArgs is Map ? rawArgs : null;
          final rawRssi = args?['rssi'];
          final rssi = rawRssi is num ? rawRssi.toDouble() : null;
          final rawAddr = args?['address'];
          final addr = rawAddr is String ? rawAddr : '';
          final rawName = args?['name'];
          final name = rawName is String ? rawName : '';
          final rawIsNexus = args?['is_nexus'];
          final isNexus = rawIsNexus is bool ? rawIsNexus : false;
          final rawPeerId = args?['peer_id'];
          final peerId = rawPeerId is String ? rawPeerId : null;
          if (rssi != null) {
            handleIncomingBleRssi(rssi, address: addr, name: name, isNexus: isNexus, peerId: peerId);
          }
        } else if (call.method == 'onRemoteMediaAction') {
          final rawAction = call.arguments;
          final action = rawAction is String ? rawAction : '';
          NexusLogger.log("MEDIA_REMOTE", "Received lockscreen remote media action: $action");
          if (action == 'TOGGLE_PLAY_PAUSE') {
            final isCurrentlyPlaying = activeMedia != null &&
                (activeMedia!['is_playing'] == true || activeMedia!['status'] == 'playing');
            final nextCmd = isCurrentlyPlaying ? "PAUSE" : "PLAY";
            sendCommand(nextCmd);
            if (activeMedia != null) {
              // Optimistic toggle; the next PC state update will reconcile it.
              activeMedia!['is_playing'] = !isCurrentlyPlaying;
              notifyListeners();
              _updateLockScreenMediaNotification();
            }
          } else if (action == 'PREV') {
            sendCommand("SEEK", positionMs: 0);
          } else if (action == 'NEXT') {
            sendCommand("NEXT");
          }
        }
      });
      _pushTargetPeerBluetooth();
    }
  }

  static final RegExp _btMacPattern = RegExp(r'^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$');

  /// Sends the configured Bluetooth target (from settings) to the native side.
  /// No hardcoded device: if nothing valid is configured, nothing is sent.
  Future<void> _pushTargetPeerBluetooth() async {
    if (!Platform.isAndroid) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final mac = prefs.getString('target_peer_bt_mac')?.trim() ?? '';
      final name = prefs.getString('target_peer_bt_name')?.trim() ?? '';
      if (!_btMacPattern.hasMatch(mac)) {
        NexusLogger.log("LAN_SYNC", "No valid target peer Bluetooth MAC configured; skipping setTargetPeerBluetooth");
        return;
      }
      await _hardwareChannel.invokeMethod('setTargetPeerBluetooth', {
        'mac': mac.toUpperCase(),
        'name': name.length > 64 ? name.substring(0, 64) : name,
      });
    } catch (e) {
      NexusLogger.log("LAN_SYNC", "setTargetPeerBluetooth failed: $e");
    }
  }

  /// Persists the Bluetooth target of the associated peer and forwards it to native.
  Future<void> setTargetPeerBluetooth({required String mac, String name = ''}) async {
    final m = mac.trim();
    if (!_btMacPattern.hasMatch(m)) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('target_peer_bt_mac', m.toUpperCase());
      await prefs.setString('target_peer_bt_name', name.trim());
    } catch (e) {
      NexusLogger.log("LAN_SYNC", "Saving target peer Bluetooth failed: $e");
      return;
    }
    await _pushTargetPeerBluetooth();
  }

  Future<void> _updateLockScreenMediaNotification() async {
    if (!Platform.isAndroid) return;
    if (activeMedia == null) {
      try {
        await _hardwareChannel.invokeMethod('clearMediaRemoteNotification');
      } catch (e) {
        NexusLogger.log("MEDIA_REMOTE", "Failed to clear Android lockscreen notification: $e");
      }
      return;
    }

    final title = activeMedia!['media_title'] as String? ?? '';
    if (title.isEmpty) {
      try {
        await _hardwareChannel.invokeMethod('clearMediaRemoteNotification');
      } catch (e) {
        NexusLogger.log("MEDIA_REMOTE", "Failed to clear Android lockscreen notification: $e");
      }
      return;
    }

    final sourceApp = activeMedia!['source_app'] as String? ?? 'Browser PC';
    final isPlaying = activeMedia!['is_playing'] == true || activeMedia!['status'] == 'playing';
    final posMs = (activeMedia!['position_ms'] as num?)?.toInt() ?? 0;
    final durMs = (activeMedia!['duration_ms'] as num?)?.toInt() ?? 0;

    try {
      await _hardwareChannel.invokeMethod('showMediaRemoteNotification', {
        'title': title,
        'source_app': sourceApp,
        'is_playing': isPlaying,
        'position_ms': posMs,
        'duration_ms': durMs,
      });
    } catch (e) {
      NexusLogger.log("MEDIA_REMOTE", "Failed to update Android lockscreen notification: $e");
    }
  }

  void _startBluetoothHardwareWatcher() {
    checkBluetoothHardwareStatus();
    _btWatcherTimer?.cancel();
    _btWatcherTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      checkBluetoothHardwareStatus();
      pollBleObservations();
    });
  }

  static const _hardwareChannel = MethodChannel('com.nexus.continuity/hardware');

  /// Guard against overlapping executions of [checkBluetoothHardwareStatus].
  bool _btCheckInFlight = false;

  /// Real OS-level radio hardware detection (no mocks, no simulations)
  Future<void> checkBluetoothHardwareStatus() async {
    if (_btCheckInFlight) return;
    _btCheckInFlight = true;
    try {
      bool isEnabled = false;
      if (Platform.isWindows || Platform.isLinux) {
        try {
          isEnabled = NexusFfiBridge.instance.isBluetoothEnabled();
        } catch (e) {
          NexusLogger.log("BLUETOOTH_HW", "Error checking desktop Bluetooth via FFI: $e");
          isEnabled = false;
        }
      } else if (Platform.isAndroid) {
        try {
          final res = await _hardwareChannel.invokeMethod<bool>('isBluetoothEnabled');
          isEnabled = res ?? false;
        } catch (e) {
          NexusLogger.log("BLUETOOTH_HW", "Error checking Android Bluetooth: $e");
          isEnabled = false;
        }
      }
      // macOS / iOS: no native detection available yet, radio reported as unavailable.

      if (isBleHardwareAvailable != isEnabled) {
        isBleHardwareAvailable = isEnabled;

        NexusLogger.log("BLUETOOTH_HW", "Real OS Bluetooth radio hardware updated: isEnabled=$isEnabled");
        if (!isEnabled) {
          estimatedDistanceMeters = null;
          liveRssi = null;
          proximityMotion = null;
        }
        notifyListeners();
      }
      _applyBleMonitoring();
    } finally {
      _btCheckInFlight = false;
    }
  }

  Future<void> openBluetoothSettings() async {
    if (Platform.isAndroid) {
      try {
        await _hardwareChannel.invokeMethod('openBluetoothSettings');
      } catch (_) {}
    }
  }

  bool _clipboardTickInFlight = false;
  bool _clipboardBaselineTaken = false;
  String? _lastClipboardWatcherError;

  void _startClipboardWatcher() {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) return;

    _clipboardWatcherTimer?.cancel();
    _clipboardBaselineTaken = false;
    _clipboardWatcherTimer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      if (_clipboardTickInFlight) return;
      _clipboardTickInFlight = true;
      try {
        if (!clipboardSyncEnabled) return;
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        final current = data?.text;
        if (!_clipboardBaselineTaken) {
          // First read: take the pre-existing clipboard as baseline, never send it.
          _clipboardBaselineTaken = true;
          _lastSeenClipboardText ??= current;
          return;
        }
        if (current != null && current.trim().isNotEmpty && current != _lastSeenClipboardText) {
          _lastSeenClipboardText = current;
          NexusLogger.log("CLIPBOARD_WATCHER", "OS clipboard change detected (${current.length} chars)");
          sendClipboardWithPrivacyGate(current);
        }
        _lastClipboardWatcherError = null;
      } catch (e) {
        final msg = e.toString();
        if (msg != _lastClipboardWatcherError) {
          _lastClipboardWatcherError = msg;
          NexusLogger.log("CLIPBOARD_WATCHER", "Clipboard read failed: $msg");
        }
      } finally {
        _clipboardTickInFlight = false;
      }
    });
  }

  void _startPeriodicDiscovery() {
    _discoverAndConnect();
    _discoveryTimer?.cancel();
    _discoveryTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!_isSearching) {
        _discoverAndConnect();
      }
    });
  }

  // Discovery throttling state (review C #33, #36).
  DateTime? _nextLocalhostAttempt;
  int _localhostBackoffSeconds = 4;
  DateTime? _lastSubnetSweep;
  static const Duration _sweepIntervalIdle = Duration(seconds: 60);
  static const Duration _sweepIntervalConnected = Duration(minutes: 5);

  /// Returns the /24 prefix ("a.b.c.") of a private IPv4 address
  /// (10/8, 172.16/12, 192.168/16, excluding libvirt 192.168.122/24), otherwise null.
  static String? _privateSubnetPrefix(String address) {
    final parts = address.split('.');
    if (parts.length != 4) return null;
    final octets = parts.map(int.tryParse).toList();
    if (octets.any((o) => o == null || o < 0 || o > 255)) return null;
    final a = octets[0]!;
    final b = octets[1]!;
    final isPrivate = a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168 && octets[2] != 122);
    if (!isPrivate) return null;
    return '${parts[0]}.${parts[1]}.${parts[2]}.';
  }

  Future<void> _discoverAndConnect() async {
    if (_isSearching) return;
    _isSearching = true;

    try {
      // 1. Resolve local private subnets and rebuild the set of local IPs
      final subnetPrefixes = <String>[];
      try {
        final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
        final currentIps = <String>{};
        for (final iface in interfaces) {
          final ifaceName = iface.name.toLowerCase();
          // Filter out virtual bridges/adapters (libvirt, docker, virtualbox, vmware, tun/tap)
          if (ifaceName.startsWith("virbr") ||
              ifaceName.startsWith("docker") ||
              ifaceName.startsWith("vbox") ||
              ifaceName.startsWith("veth") ||
              ifaceName.startsWith("br-") ||
              ifaceName.startsWith("vmnet") ||
              ifaceName.startsWith("tun") ||
              ifaceName.startsWith("tap")) {
            continue;
          }

          for (final addr in iface.addresses) {
            if (!addr.isLoopback) {
              currentIps.add(addr.address);
              final prefix = _privateSubnetPrefix(addr.address);
              if (prefix != null && !subnetPrefixes.contains(prefix)) {
                subnetPrefixes.add(prefix);
              }
            }
          }
        }
        // Replace, do not accumulate: IPs of a previous network must not stay "local".
        _localIps
          ..clear()
          ..addAll(currentIps);
      } catch (e) {
        NexusLogger.log("LAN_SYNC", "Network interface listing failed: $e");
      }

      // 0. Local desktop node: only when not connected, with exponential backoff
      if (!Platform.isAndroid && !Platform.isIOS && !_peerSockets.containsKey('127.0.0.1')) {
        final attemptNow = DateTime.now();
        if (_nextLocalhostAttempt == null || !attemptNow.isBefore(_nextLocalhostAttempt!)) {
          try {
            await connectToPeer('127.0.0.1');
          } catch (e) {
            NexusLogger.log("LAN_SYNC", "Localhost connect failed: $e");
          }
          if (_peerSockets.containsKey('127.0.0.1')) {
            _localhostBackoffSeconds = 4;
            _nextLocalhostAttempt = null;
          } else {
            _nextLocalhostAttempt = DateTime.now().add(Duration(seconds: _localhostBackoffSeconds));
            _localhostBackoffSeconds = _localhostBackoffSeconds >= 60 ? 60 : _localhostBackoffSeconds * 2;
          }
        }
      }

      // 2. UDP broadcast beacon on port 42420.
      // Note: the beacon is not PII-free: it carries deviceName and the stable deviceId,
      // which receiving peers use to identify this node (PEER_ANNOUNCE handler).
      RawDatagramSocket? rawSocket;
      try {
        rawSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        rawSocket.broadcastEnabled = true;
        final beaconData = utf8.encode(jsonEncode({
          "type": "PEER_ANNOUNCE",
          "id": deviceId,
          "device_id": deviceId,
          "name": deviceName,
          "device_type": deviceType,
          "os": Platform.operatingSystem,
          "spatial_position": spatialPosition,
        }));
        rawSocket.send(beaconData, InternetAddress("255.255.255.255"), 42420);
        for (final prefix in subnetPrefixes) {
          rawSocket.send(beaconData, InternetAddress("${prefix}255"), 42420);
        }
      } catch (e) {
        NexusLogger.log("LAN_SYNC", "Beacon send failed: $e");
      } finally {
        rawSocket?.close();
      }

      // 3. TCP sweep of the local /24 subnets (254 probes each): throttled, no hardcoded hosts
      final hasRemotePeer = _peerSockets.keys.any((ip) => ip != '127.0.0.1' && ip != 'localhost');
      final sweepInterval = hasRemotePeer ? _sweepIntervalConnected : _sweepIntervalIdle;
      final sweepNow = DateTime.now();
      final sweepDue = _lastSubnetSweep == null || sweepNow.difference(_lastSubnetSweep!) >= sweepInterval;
      if (!sweepDue || subnetPrefixes.isEmpty) return;
      _lastSubnetSweep = sweepNow;

      final candidateIps = <String>[];
      for (final prefix in subnetPrefixes) {
        for (int i = 1; i <= 254; i++) {
          candidateIps.add('$prefix$i');
        }
      }

      // Parallel probe for all responding nodes on port 28471
      final foundIps = <String>[];
      for (int i = 0; i < candidateIps.length; i += 25) {
        final batch = candidateIps.sublist(i, (i + 25 > candidateIps.length) ? candidateIps.length : i + 25);
        final probes = batch.map((ip) async {
          if (_peerSockets.containsKey(ip) || _localIps.contains(ip)) return null;
          try {
            final socket = await Socket.connect(ip, 28471, timeout: const Duration(milliseconds: 800));
            socket.destroy();
            return ip;
          } catch (_) {
            return null;
          }
        });

        final results = await Future.wait(probes);
        final found = results.whereType<String>().toList();
        foundIps.addAll(found);
      }

      await Future.wait(foundIps.map((ip) => connectToPeer(ip)));
    } catch (e) {
      NexusLogger.log("LAN_SYNC", "Discovery scan error: $e");
    } finally {
      _isSearching = false;
    }
  }

  Future<void> connectToPeer(String ip, {int port = 28471}) async {
    final nextAttempt = _peerNextAttempt[ip];
    if (nextAttempt != null && DateTime.now().isBefore(nextAttempt)) return;
    if (_peerSockets.containsKey(ip) || !_connectingIps.add(ip)) return;
    try {
      final wsUrl = 'ws://$ip:$port/media';
      NexusLogger.log("LAN_SYNC", "Connecting to node at $wsUrl...");
      final ws = await WebSocket.connect(wsUrl).timeout(const Duration(seconds: 3));
      _ws = ws;
      _peerSockets[ip] = ws;
      _peerNextAttempt.remove(ip);
      _peerBackoffSeconds.remove(ip);
      pcIp = ip;
      isConnected = true;

      final peerId = "peer-nexus-$ip";
      final isLocalLoopback = (ip == '127.0.0.1' || ip == 'localhost');
      final isOwnIp = _localIps.contains(ip);

      if (!isLocalLoopback && !isOwnIp) {
        final existingIndex = discoveredPeers.indexWhere((p) => p['ip'] == ip || p['id'] == peerId);
        if (existingIndex >= 0) {
          discoveredPeers[existingIndex]['ip'] = ip;
        } else {
          final peerName = "Dispositivo ($ip)";
          final peerEntry = {
            "id": peerId,
            "name": peerName,
            "ip": ip,
            "online": false,
            "device_type": "Desktop",
            "os": "Unknown",
            "spatial_position": "Center",
          };
          discoveredPeers.add(peerEntry);
          selectedTargetDeviceId ??= peerId;
        }
        notifyListeners();
      }

      NexusLogger.log("LAN_SYNC", "Connected successfully to node at $ip! Active sockets: ${_peerSockets.length}");

      // Announce this node with minimal metadata (NO PII)
      final announce = {
        "type": "PEER_ANNOUNCE",
        "id": deviceId,
        "device_id": deviceId,
        "name": deviceName,
        "ip": ip,
        "device_type": deviceType,
        "os": Platform.operatingSystem,
        "spatial_position": spatialPosition,
      };
      if (!isLocalLoopback) ws.add(jsonEncode(announce));

      // Keepalive ping across all active peer sockets
      _lastFrameAt[ip] = DateTime.now();
      _lastPongAt[ip] = DateTime.now();
      _keepAliveTimer?.cancel();
      _keepAliveTimer = Timer.periodic(const Duration(seconds: 10), (_) {
        if (isConnected) {
          final now = DateTime.now();
          final pingData = jsonEncode({"type": "PING", "time": now.millisecondsSinceEpoch});
          for (final entry in _peerSockets.entries.toList()) {
            final peerIp = entry.key;
            final last = _lastPongAt[peerIp];
            final loopback = peerIp == '127.0.0.1' || peerIp == 'localhost';
            // #39: il timeout si basa sull'ultimo PONG ricevuto su questo socket, non su
            // qualunque frame; onDone/onError eseguono la pulizia di rotte e stato.
            if (!loopback && last != null && now.difference(last) > _peerSilenceTimeout) {
              try {
                entry.value.close();
              } catch (_) {}
              _lastFrameAt.remove(peerIp);
              _lastPongAt.remove(peerIp);
              continue;
            }
            try {
              entry.value.add(pingData);
            } catch (_) {}
          }
        }
      });

      // #63: pulizia comune a onDone/onError (prima era duplicata).
      void cleanupClosedSocket() {
        if (!identical(_peerSockets[ip], ws)) return;
        _peerSockets.remove(ip);
        _lastPongAt.remove(ip);
        final disconnectedId = _socketPeerIds.remove(ip);
        for (final entry in _peerRoutes.entries) {
          entry.value.remove(ip);
          if (entry.value.isEmpty && !_socketPeerIds.containsValue(entry.key)) {
            for (final peer in discoveredPeers) {
              if (peer['id'] == entry.key) peer['online'] = false;
            }
          }
        }
        final pIdx = discoveredPeers.indexWhere((p) => p['id'] == disconnectedId || p['id'] == peerId);
        if (pIdx >= 0 && !_socketPeerIds.containsValue(disconnectedId) &&
            (_peerRoutes[disconnectedId]?.isEmpty ?? true)) {
          discoveredPeers[pIdx]['online'] = false;
        }
        if (_peerSockets.isEmpty) {
          isConnected = false;
          _ws = null;
          _keepAliveTimer?.cancel();
        } else {
          _ws = _peerSockets.values.first;
        }
        notifyListeners();
      }

      ws.listen(
        (data) {
          try {
            // #40: accetta solo frame testuali di dimensione limitata con oggetto JSON.
            if (data is! String || data.length > _maxWsFrameChars) return;
            _lastFrameAt[ip] = DateTime.now();
            final decoded = jsonDecode(data);
            if (decoded is! Map<String, dynamic>) return;
            final json = decoded;
            // #39: PONG aggiorna il timestamp per socket; ai PING si risponde con PONG.
            if (json['type'] == 'PONG') {
              _lastPongAt[ip] = DateTime.now();
              return;
            }
            if (json['type'] == 'PING') {
              try {
                ws.add(jsonEncode({"type": "PONG", "time": DateTime.now().millisecondsSinceEpoch}));
              } catch (_) {}
              return;
            }
            if (json['type'] == 'INPUT_STATUS') {
              final responseId = json['device_id'] as String?;
              final id = responseId != null && (_socketPeerIds[ip] == responseId || (_peerRoutes[responseId]?.contains(ip) ?? false)) ? responseId : _socketPeerIds[ip];
              if (id != null) _setInputError(id, json['ok'] == true ? null : json['message'] as String? ?? 'Input non disponibile.');
              final pending = _pendingText[json['request_id']];
              if (pending != null && pending.target == id && !pending.reply.isCompleted) {
                pending.reply.complete(json['ok'] == true ? null :
                    json['message'] as String? ?? 'Digitazione non riuscita.');
              }
              return;
            }
            if (json['type'] == 'PEER_DISCONNECTED') {
              final id = json['id'];
              if (id is! String || id.isEmpty) return;
              // #41: solo il nodo che fa da rotta verso quel peer puo' segnalarne la disconnessione.
              final removed = _peerRoutes[id]?.remove(ip) ?? false;
              if (!removed) return;
              for (final peer in discoveredPeers) {
                if (peer['id'] == id && !_socketPeerIds.containsValue(id) && (_peerRoutes[id]?.isEmpty ?? true)) peer['online'] = false;
              }
              notifyListeners();
              return;
            }


            final inputType = json['type'] as String? ?? '';
            if (json['target_device_id'] == deviceId &&
                (inputType.startsWith('TOUCHPAD_') || inputType.startsWith('KEYBOARD_') || json['action'] != null)) {
              ws.add(jsonEncode({
                'type': 'INPUT_STATUS', 'ok': false, 'device_id': deviceId,
                if (json['request_id'] is String) 'request_id': json['request_id'],
                'message': 'Questo comando richiede una connessione diretta al backend del PC.',
              }));
              return;
            }

            if (json['type'] == 'OPEN_URL') {
              final url = json['url'] as String? ?? '';
              NexusLogger.log("LAN_SYNC", "Received remote OPEN_URL: $url");
              _openUrlController.add(json);
              if (mediaHandoffEnabled && url.isNotEmpty && (Platform.isAndroid || Platform.isIOS)) {
                // #42: solo http/https (blocca intent:, tel:, file: e deep link di altre app) e conferma locale.
                if (!isAllowedRemoteUrl(url)) {
                  NexusLogger.log("LAN_SYNC", "OPEN_URL rejected (unsupported or invalid URL): $url");
                } else {
                  _confirmAndLaunchUrl(Uri.parse(url), url);
                }
              }
              return;
            }

            if (json['type'] == 'CLIPBOARD_SYNC') {
              final rawClip = json['text'];
              final clipText = rawClip is String ? rawClip : '';
              // #43: niente contenuto in chiaro nel log, solo la lunghezza.
              NexusLogger.log("LAN_SYNC", "Received remote CLIPBOARD_SYNC (len=${clipText.length})");
              const maxClipLen = 256 * 1024;
              if (clipText.length > maxClipLen) {
                NexusLogger.log("LAN_SYNC", "CLIPBOARD_SYNC rejected: payload too large");
                return;
              }
              if (clipboardSyncEnabled && clipText.isNotEmpty) {
                _lastSeenClipboardText = clipText;
                Clipboard.setData(ClipboardData(text: clipText)).catchError((Object e) {
                  NexusLogger.log("LAN_SYNC", "Clipboard.setData failed: $e");
                });
                _clipboardController.add(clipText);
              }
              return;
            }

            if (json['type'] == 'CLIPBOARD_SECRET_ANNOUNCE') {
              final entryId = json['entry_id'] as String? ?? '';
              final secretType = json['secret_type'] as String? ?? 'Segreto';
              final maskedPreview = json['masked_preview'] as String? ?? '••••••';
              final sourceDevice = json['source_device'] as String? ?? 'Dispositivo Remoto';

              NexusLogger.log("PRIVACY_GATE", "Received remote CLIPBOARD_SECRET_ANNOUNCE ($secretType, ID: $entryId): $maskedPreview from $sourceDevice");
              if (entryId.isNotEmpty) {
                // #72: remember the socket of the announcing device, so the reveal request goes back to it.
                _secretAnnounceSockets.remove(entryId);
                _secretAnnounceSockets[entryId] = ws;
                while (_secretAnnounceSockets.length > 32) {
                  _secretAnnounceSockets.remove(_secretAnnounceSockets.keys.first);
                }
              }
              _secretAnnounceController.add(json);
              return;
            }

            if (json['type'] == 'CLIPBOARD_REVEAL_REQUEST') {
              final entryId = json['entry_id'] as String? ?? '';
              final requestingDevice = json['requesting_device'] as String? ?? 'Dispositivo Remoto';
              NexusLogger.log("PRIVACY_GATE", "Received CLIPBOARD_REVEAL_REQUEST for entry $entryId from $requestingDevice");

              if (_pendingLocalSecrets.containsKey(entryId)) {
                final cleartext = _pendingLocalSecrets[entryId]!;
                final respMsg = {
                  "type": "CLIPBOARD_REVEAL_RESPONSE",
                  "entry_id": entryId,
                  "text": cleartext,
                  "source_device": deviceName,
                };
                try {
                  // #37: reply on the socket the request arrived on, not on the global _ws.
                  ws.add(jsonEncode(respMsg));
                } catch (e) {
                  NexusLogger.log("PRIVACY_GATE", "Failed to send CLIPBOARD_REVEAL_RESPONSE for entry $entryId: $e");
                  return;
                }
                // #38: one-time secret, removed after the reveal has been sent.
                _pendingLocalSecrets.remove(entryId);
                NexusLogger.log("PRIVACY_GATE", "Authorized and sent CLIPBOARD_REVEAL_RESPONSE for entry $entryId over peer WebSocket (ws://, not encrypted)");
              }
              return;
            }

            if (json['type'] == 'CLIPBOARD_REVEAL_RESPONSE') {
              final entryId = json['entry_id'] as String? ?? '';
              final text = json['text'] as String? ?? '';
              NexusLogger.log("PRIVACY_GATE", "Received CLIPBOARD_REVEAL_RESPONSE for entry $entryId");
              if (!_pendingClipboardRevealRequests.remove(entryId)) {
                NexusLogger.log("PRIVACY_GATE", "Ignoring unsolicited CLIPBOARD_REVEAL_RESPONSE for entry $entryId");
                return;
              }
              if (text.isNotEmpty) {
                _lastSeenClipboardText = text;
                Clipboard.setData(ClipboardData(text: text));
                _secretRevealedController.add(json);
              }
              return;
            }

            if (json['type'] == 'NOTIFICATION_SYNC') {
              // #45: validazione tipi e troncamento dei campi (nessun cast che lancia).
              String? readStr(String k, int max) {
                final v = json[k];
                if (v is! String) return null;
                return v.length > max ? v.substring(0, max) : v;
              }
              final id = readStr('id', 128) ?? 'notif_${DateTime.now().millisecondsSinceEpoch}';
              final title = readStr('title', 256) ?? 'Notifica';
              final body = readStr('body', 4096) ?? '';
              final appName = readStr('app_name', 128) ?? 'App';
              final senderDevice = readStr('sender_device', 128) ?? 'Dispositivo Remoto';
              final senderDeviceId = readStr('sender_device_id', 128) ?? 'remote';
              final timestampStr = readStr('timestamp', 64);
              final timestamp = timestampStr != null ? (DateTime.tryParse(timestampStr) ?? DateTime.now()) : DateTime.now();
              final hasSecret = json['has_secret'] == true;
              final secretCategory = readStr('secret_category', 64) ?? '';

              final notif = NexusNotification(
                id: id,
                title: title,
                rawBody: body,
                currentBody: body,
                appName: appName,
                senderDevice: senderDevice,
                senderDeviceId: senderDeviceId,
                timestamp: timestamp,
                hasSecret: hasSecret,
                secretCategory: secretCategory,
                isRevealed: !hasSecret,
                category: readStr('category', 32) == 'internalApp'
                    ? NexusNotificationCategory.internalApp
                    : NexusNotificationCategory.osNotification,
              );

              notifications.removeWhere((n) => n.id == id);
              _insertNotification(notif);
              _notificationController.add(notif);
              NexusLogger.log("NOTIF_SYNC", "Received cross-device notification: $title ($appName) from $senderDevice");
              return;
            }

            if (json['type'] == 'NOTIFICATION_REVEAL_REQUEST') {
              final notifId = json['id'] as String? ?? '';
              final requestingDevice = json['requesting_device'] as String? ?? 'Dispositivo Remoto';
              NexusLogger.log("NOTIF_PRIVACY", "Received NOTIFICATION_REVEAL_REQUEST for $notifId from $requestingDevice");
              if (_pendingLocalNotificationSecrets.containsKey(notifId)) {
                final cleartext = _pendingLocalNotificationSecrets[notifId]!;
                final resp = {
                  "type": "NOTIFICATION_REVEAL_RESPONSE",
                  "id": notifId,
                  "cleartext": cleartext,
                };
                try {
                  // #37: reply on the socket the request arrived on, not on the global _ws.
                  ws.add(jsonEncode(resp));
                  // #38: one-time secret, removed after the reveal has been sent.
                  _pendingLocalNotificationSecrets.remove(notifId);
                  NexusLogger.log("NOTIF_PRIVACY", "Sent NOTIFICATION_REVEAL_RESPONSE for $notifId");
                } catch (e) {
                  NexusLogger.log("NOTIF_PRIVACY", "Failed to send NOTIFICATION_REVEAL_RESPONSE for $notifId: $e");
                }
              }
              return;
            }

            if (json['type'] == 'NOTIFICATION_REVEAL_RESPONSE') {
              final notifId = json['id'] as String? ?? '';
              final cleartext = json['cleartext'] as String? ?? '';
              NexusLogger.log("NOTIF_PRIVACY", "Received NOTIFICATION_REVEAL_RESPONSE for $notifId");
              if (!_pendingNotificationRevealRequests.remove(notifId)) {
                NexusLogger.log("NOTIF_PRIVACY", "Ignoring unsolicited NOTIFICATION_REVEAL_RESPONSE for $notifId");
                return;
              }
              if (cleartext.isNotEmpty) {
                final idx = notifications.indexWhere((n) => n.id == notifId);
                if (idx != -1) {
                  notifications[idx].currentBody = cleartext;
                  notifications[idx].isRevealed = true;
                }
                _notificationRevealedController.add(notifId);
              }
              return;
            }

            if (json['type'] == 'FILE_OFFER') {
              if (!fileTransferEnabled) {
                NexusLogger.log("FILE_TRANSFER", "Ignoring incoming FILE_OFFER: transfers are disabled in Settings.");
                return;
              }
              final rawFileId = json['file_id'];
              final rawFileName = json['file_name'];
              final rawFileSize = json['file_size'];
              final rawTotalChunks = json['total_chunks'];
              if (rawFileId is! String || rawFileId.isEmpty || rawFileId.length > 128 || rawFileSize is! num || rawTotalChunks is! num) {
                NexusLogger.log("FILE_TRANSFER", "Rejected malformed FILE_OFFER (missing or invalid file_id/file_size/total_chunks).");
                return;
              }
              final fileId = rawFileId;
              final fileName = _sanitizeIncomingFileName(rawFileName is String ? rawFileName : 'file');
              final fileSize = rawFileSize.toInt();
              final totalChunks = rawTotalChunks.toInt();
              if (fileSize < 0 || fileSize > _maxIncomingFileBytes || totalChunks <= 0 || totalChunks > _maxIncomingFileChunks) {
                NexusLogger.log("FILE_TRANSFER", "Rejected FILE_OFFER $fileId: size $fileSize bytes / $totalChunks chunks outside allowed limits.");
                return;
              }
              _pruneStaleIncomingFiles();
              if (!_incomingFiles.containsKey(fileId) && _incomingFiles.length >= _maxConcurrentIncomingFiles) {
                NexusLogger.log("FILE_TRANSFER", "Rejected FILE_OFFER $fileId: too many concurrent incoming transfers.");
                return;
              }
              final rawSender = json['sender_device'];
              final sender = rawSender is String && rawSender.isNotEmpty ? rawSender : 'Dispositivo Remoto';

              NexusLogger.log("FILE_TRANSFER", "Received FILE_OFFER: $fileName ($fileSize bytes, $totalChunks chunks) from $sender");
              _incomingFiles[fileId] = {
                'file_id': fileId,
                'file_name': fileName,
                'file_size': fileSize,
                'total_chunks': totalChunks,
                'sender': sender,
                // #51: digest announced by the sender, verified on FILE_COMPLETE.
                'sha256': json['sha256'] is String && RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(json['sha256'] as String)
                    ? (json['sha256'] as String).toLowerCase()
                    : null,
                'chunks': <int, List<int>>{},
                'received_bytes': 0,
                'start_time': DateTime.now(),
              };
              // Forward the offer with the sanitized name so the UI never shows/uses the raw peer-supplied path.
              _fileOfferController.add(Map<String, dynamic>.from(json)..['file_name'] = fileName);
              return;
            }

            if (json['type'] == 'FILE_CHUNK') {
              final fileId = json['file_id'] as String? ?? '';
              final session = _incomingFiles[fileId];
              if (session != null) {
                // Chunk bounds come from the accepted offer, not from the chunk message itself.
                final totalChunks = (session['total_chunks'] as num?)?.toInt() ?? (json['total_chunks'] as num?)?.toInt() ?? 1;
                final rawChunkIndex = json['chunk_index'];
                final b64 = json['data'];
                if (rawChunkIndex is! num || b64 is! String) {
                  NexusLogger.log("FILE_TRANSFER", "Ignoring malformed FILE_CHUNK for $fileId.");
                  return;
                }
                final chunkIndex = rawChunkIndex.toInt();
                if (chunkIndex < 0 || chunkIndex >= totalChunks) {
                  NexusLogger.log("FILE_TRANSFER", "Ignoring FILE_CHUNK $chunkIndex for $fileId: index outside 0..${totalChunks - 1}.");
                  return;
                }
                final List<int> chunkBytes;
                try {
                  chunkBytes = base64Decode(b64);
                } on FormatException catch (e) {
                  NexusLogger.log("FILE_TRANSFER", "Ignoring FILE_CHUNK $chunkIndex for $fileId: invalid base64 ($e).");
                  return;
                }
                final chunks = session['chunks'] as Map<int, List<int>>;
                final previousLength = chunks[chunkIndex]?.length ?? 0;
                final newReceived = ((session['received_bytes'] as num?)?.toInt() ?? 0) - previousLength + chunkBytes.length;
                final declaredSize = (session['file_size'] as num?)?.toInt();
                if (declaredSize != null && newReceived > declaredSize) {
                  NexusLogger.log("FILE_TRANSFER", "Aborting transfer $fileId: received $newReceived bytes, more than the declared $declaredSize.");
                  _incomingFiles.remove(fileId);
                  return;
                }
                chunks[chunkIndex] = chunkBytes;
                session['received_bytes'] = newReceived;
                session['last_activity'] = DateTime.now();
                final elapsedSec = DateTime.now().difference(session['start_time'] as DateTime).inMilliseconds / 1000.0;
                final speedMbps = elapsedSec > 0.05 ? ((session['received_bytes'] as int) / (1024 * 1024)) / elapsedSec : 0.0;

                _fileProgressController.add({
                  'file_id': fileId,
                  'progress': (session['chunks'] as Map).length / totalChunks,
                  'speed': '${speedMbps.toStringAsFixed(1)} MB/s',
                  'received_chunks': (session['chunks'] as Map).length,
                  'total_chunks': totalChunks,
                });
              }
              return;
            }

            if (json['type'] == 'FILE_COMPLETE') {
              final fileId = json['file_id'] as String? ?? '';
              final session = _incomingFiles[fileId];
              if (session != null) {
                final fileName = _sanitizeIncomingFileName(session['file_name'] as String? ?? 'file');
                final chunks = session['chunks'] as Map<int, List<int>>;
                final totalChunks = session['total_chunks'] as int;
                final missingChunks = totalChunks - chunks.length;
                if (missingChunks > 0) {
                  // Do not save a corrupted file; keep the session so FILE_RESUME_REQUEST can complete it.
                  NexusLogger.log("FILE_TRANSFER", "FILE_COMPLETE for $fileId with $missingChunks missing chunks: not saving an incomplete file.");
                  // Ask the sending peer for the missing chunks automatically.
                  requestFileResume(fileId, via: _peerSockets[ip]);
                  return;
                }

                final fullBytes = BytesBuilder();
                for (int i = 0; i < totalChunks; i++) {
                  if (chunks.containsKey(i)) {
                    fullBytes.add(chunks[i]!);
                  }
                }
                final assembled = fullBytes.takeBytes();
                // #51: refuse a file whose assembled size differs from the size announced in FILE_OFFER.
                final expectedSize = session['file_size'];
                if (expectedSize is int && expectedSize != assembled.length) {
                  NexusLogger.log("FILE_TRANSFER", "FILE_COMPLETE for $fileId: size mismatch (expected $expectedSize, got ${assembled.length}); file discarded.");
                  _incomingFiles.remove(fileId);
                  return;
                }
                // #51: refuse a file whose SHA-256 differs from the digest announced in FILE_OFFER.
                final expectedDigest = session['sha256'];
                if (expectedDigest is String) {
                  final actualDigest = lanSyncSha256Hex(assembled);
                  if (actualDigest != expectedDigest) {
                    NexusLogger.log("FILE_TRANSFER", "FILE_COMPLETE for $fileId: SHA-256 mismatch (expected $expectedDigest, got $actualDigest); file discarded.");
                    _incomingFiles.remove(fileId);
                    return;
                  }
                } else {
                  NexusLogger.log("FILE_TRANSFER", "FILE_COMPLETE for $fileId: no valid SHA-256 in FILE_OFFER, only the size was verified.");
                }

                // #52: directory resolution and write are fully async (no existsSync/createSync on the UI isolate).
                _saveIncomingFile(fileId, fileName, assembled);
                _incomingFiles.remove(fileId);
              }
              return;
            }


            if (json['type'] == 'FILE_RESUME_REQUEST') {
              final fileId = json['file_id'] as String? ?? '';
              final rawMissing = json['missing_chunks'];
              // Tolerate malformed entries and drop duplicates: the range check below bounds the list.
              final missingList = rawMissing is List ? rawMissing.whereType<int>().toSet().toList() : <int>[];
              // Reply on the socket of the peer that asked, not on the global connection.
              final replySocket = _peerSockets[ip] ?? _ws;
              // #53: the cache is bound to the destination socket; a resume from another socket is refused.
              final cachedBytes = _getCachedOutgoingFile(fileId, requester: replySocket);
              if (cachedBytes == null && _outgoingFileCache.containsKey(fileId)) {
                NexusLogger.log("FILE_TRANSFER", "Refusing FILE_RESUME_REQUEST for $fileId: requester is not the original peer");
              }
              if (cachedBytes != null && missingList.isNotEmpty && replySocket != null) {
                const chunkSize = _fileChunkSize;
                final fileSize = cachedBytes.length;
                final totalChunks = fileSize == 0 ? 1 : (fileSize / chunkSize).ceil();
                NexusLogger.log("FILE_TRANSFER", "Resending ${missingList.length} missing chunks for file $fileId");
                for (final idx in missingList) {
                  if (idx >= 0 && idx < totalChunks) {
                    final start = idx * chunkSize;
                    final end = (start + chunkSize < fileSize) ? start + chunkSize : fileSize;
                    final slice = fileSize == 0 ? <int>[] : cachedBytes.sublist(start, end);
                    final b64 = base64Encode(slice);
                    final chunkMsg = {
                      "type": "FILE_CHUNK",
                      "file_id": fileId,
                      "chunk_index": idx,
                      "total_chunks": totalChunks,
                      "data": b64,
                    };
                    try {
                      replySocket.add(jsonEncode(chunkMsg));
                    } catch (_) {}
                  }
                }
              }
              return;
            }

            if (json['type'] == 'TOPOLOGY_SYNC') {
              final sender = json['sender_device_id'];
              final knownSender = sender is String && sender != deviceId &&
                  (_socketPeerIds[ip] == sender || (_peerRoutes[sender]?.contains(ip) ?? false));
              final incoming = SharedTopology.parse(json['topology']);
              if (knownSender && incoming != null && incoming.points.containsKey(deviceId) &&
                  incoming.newerThan(_sharedTopology)) {
                _sharedTopology = _cleanLegacyBleTopology(incoming);
                _projectTopology();
                unawaited(_saveTopology());
                _broadcastTopology();
                notifyListeners();
                _topologyController.add(json);
              }
              return;
            }

            if (json['type'] == 'SPATIAL_ARRANGEMENT') {
              if (topologySyncEnabled) return;
              final sender = json['sender_device_id'] as String?;
              if (json['peer_id'] == deviceId && sender != null && sender != deviceId &&
                  (_socketPeerIds[ip] == sender || (_peerRoutes[sender]?.contains(ip) ?? false))) {
                final x = json['offset_x'];
                final y = json['offset_y'];
                if (x is num && y is num && x.isFinite && y.isFinite) {
                  customDeviceOffsets[sender] = Offset(-x.toDouble(), -y.toDouble());
                  unawaited(_saveTopology());
                  notifyListeners();
                  // #58: emit only frames whose sender has been validated.
                  _topologyController.add(json);
                }
              }
              return;
            }

            if (json['type'] == 'PEER_METADATA' || json['type'] == 'PEER_ANNOUNCE') {
              // #57: typed reads, no throwing casts.
              String? str(String k) {
                final v = json[k];
                return v is String ? v : null;
              }
              final pId = str('id') ?? str('device_id') ?? str('sender_device_id') ?? '';
              // #56: log only the message type and the peer ID.
              final msgType = json['type'];
              NexusLogger.log("LAN_SYNC", "Received $msgType for peer $pId");
              final pName = str('name') ?? str('sender_device') ?? '';
              final peerType = str('device_type');
              final peerOs = str('os');
              final peerPos = str('spatial_position');

              final isHost = json['is_host'] == true ||
                  (!_socketPeerIds.containsKey(ip) && json['type'] == 'PEER_ANNOUNCE' && json['metadata_source'] != 'discovery');
              // #55: a socket already bound to an ID cannot be rebound to another one
              // (except the trusted local loopback daemon).
              final boundId = _socketPeerIds[ip];
              if (isHost && pId.isNotEmpty && (boundId == null || boundId == pId || isLocalLoopback)) {
                _socketPeerIds[ip] = pId;
                if (isLocalLoopback) {
                  // The local UI and daemon represent the same physical device.
                  unawaited(adoptNativeIdentity(pId));
                  broadcastDeviceMetadata();
                  _broadcastTopology();
                }
              }
              if (pId.isNotEmpty && pId != deviceId) {
                final direct = _socketPeerIds[ip] == pId;
                registerOrUpdatePeer(
                  id: pId,
                  name: pName,
                  // #57: IP only from direct observation, or relayed by the local daemon.
                  ip: direct ? ip : (isLocalLoopback ? str('ip') : null),
                  deviceType: peerType,
                  os: peerOs,
                  spatialPosition: peerPos,
                  namePriority: json['metadata_source'] == 'discovery' ? 0 : 2,
                  discoveryOnly: json['metadata_source'] == 'discovery',
                  sharedInput: json['shared_input'] is Map<String, dynamic>
                      ? json['shared_input'] as Map<String, dynamic>
                      : null,
                  updateSharedInput: json.containsKey('shared_input') && json['metadata_source'] != 'discovery',
                );
                if (json['metadata_source'] != 'discovery') {
                  final newRoute = _peerRoutes.putIfAbsent(pId, () => <String>{}).add(ip);
                  if (newRoute) _broadcastTopology();
                }
              }
              _topologyController.add(json);
              return;
            }

            if (json['type'] == 'PROXIMITY_UPDATE') {
              // Legacy frames contain an unscoped estimate, not a local observation.
              // Never let another computer's distance drive this machine's policy.
              return;
            }

            if (json['type'] == 'PROXIMITY_DEPARTURE_HANDOFF') {
              // #59: only from the local daemon or a socket already bound to a peer ID.
              if (!isLocalLoopback && _socketPeerIds[ip] == null) {
                NexusLogger.log("LAN_SYNC", "Ignored PROXIMITY_DEPARTURE_HANDOFF from unbound socket $ip");
                return;
              }
              NexusLogger.log("LAN_SYNC", "Received PROXIMITY_DEPARTURE_HANDOFF from ${_socketPeerIds[ip] ?? 'local daemon'}");
              final rawTitle = json['media_title'];
              final title = rawTitle is String && rawTitle.isNotEmpty
                  ? (rawTitle.length > 200 ? rawTitle.substring(0, 200) : rawTitle)
                  : 'Video PC';
              final rawMediaUrl = json['media_url'];
              var url = rawMediaUrl is String ? rawMediaUrl.trim() : '';
              if (url.isNotEmpty) {
                final parsed = Uri.tryParse(url);
                final scheme = parsed?.scheme.toLowerCase();
                if (parsed == null || (scheme != 'http' && scheme != 'https') || parsed.host.isEmpty) {
                  NexusLogger.log("LAN_SYNC", "Dropped handoff media URL with disallowed scheme");
                  url = '';
                }
              }
              final rawPos = json['position_ms'];
              final pos = rawPos is num && rawPos >= 0 ? rawPos.toInt() : 0;
              final rawApp = json['source_app'];
              final app = rawApp is String && rawApp.isNotEmpty
                  ? (rawApp.length > 100 ? rawApp.substring(0, 100) : rawApp)
                  : 'PC Media';
              _triggerMediaHandoffPrompt(
                title: title,
                rawUrl: url,
                positionMs: pos,
                sourceApp: app,
              );
              return;
            }

            if (json['type'] == 'VOLUME_UPDATE') {
              // #60: solo da socket associato, valore numerico finito e non negativo (nessun cast che lancia).
              if (!isLocalLoopback && _socketPeerIds[ip] == null) {
                NexusLogger.log("LAN_SYNC", "Ignored VOLUME_UPDATE from unbound socket $ip");
                return;
              }
              final rawVolume = json['volume'];
              if (rawVolume is num && rawVolume.isFinite && rawVolume >= 0 && rawVolume <= 100) {
                currentVolume = rawVolume.toDouble();
              } else {
                NexusLogger.log("LAN_SYNC", "Dropped VOLUME_UPDATE with invalid volume");
                return;
              }
              NexusLogger.log("LAN_SYNC", "Received VOLUME_UPDATE: $currentVolume");
              return;
            }

            if (json['type'] == 'AUDIO_MUTE') {
              // #60: solo da socket associato, tipo bool verificato senza cast che lancia.
              if (!isLocalLoopback && _socketPeerIds[ip] == null) {
                NexusLogger.log("LAN_SYNC", "Ignored AUDIO_MUTE from unbound socket $ip");
                return;
              }
              final rawMuted = json['muted'];
              if (rawMuted is bool) isAudioMuted = rawMuted;
              NexusLogger.log("LAN_SYNC", "Received AUDIO_MUTE: $isAudioMuted");
              return;
            }

            if (json['media_title'] != null || json['session_id'] != null) {
              // #62: fallback media accettato solo da socket associato e con campi di tipo corretto.
              if (!isLocalLoopback && _socketPeerIds[ip] == null) {
                NexusLogger.log("LAN_SYNC", "Ignored media update from unbound socket $ip");
                return;
              }
              final rawTitle = json['media_title'];
              final rawSession = json['session_id'];
              final rawPlaying = json['is_playing'];
              if ((rawTitle != null && rawTitle is! String) ||
                  (rawSession != null && rawSession is! String) ||
                  (rawPlaying != null && rawPlaying is! bool)) {
                NexusLogger.log("LAN_SYNC", "Ignored malformed media update from $ip");
                return;
              }
              activeMedia = json;
              NexusLogger.log("LAN_SYNC", "Received media update from PC: ${json['media_title']} (Playing: ${json['is_playing']})");
              _updateLockScreenMediaNotification();
            }
          } catch (e) {
            NexusLogger.log("LAN_SYNC", "Message parse error: $e");
          }
        },
        onDone: () {
          NexusLogger.log("LAN_SYNC", "WebSocket connection to PC at $ip closed.");
          cleanupClosedSocket();
        },
        onError: (err) {
          NexusLogger.log("LAN_SYNC", "WebSocket error on $ip: $err");
          cleanupClosedSocket();
        },
      );
    } catch (e) {
      NexusLogger.log("LAN_SYNC", "Failed to connect to $ip: $e");
      // #64: exponential backoff (4 -> 60 s), mark peer offline, stop keepalive if idle.
      final backoff = _peerBackoffSeconds[ip] ?? 4;
      _peerNextAttempt[ip] = DateTime.now().add(Duration(seconds: backoff));
      _peerBackoffSeconds[ip] = backoff >= 60 ? 60 : backoff * 2;
      var changed = false;
      for (final p in discoveredPeers) {
        if (p['ip'] == ip && p['online'] != false) {
          p['online'] = false;
          changed = true;
        }
      }
      if (_peerSockets.isEmpty) {
        isConnected = false;
        _ws = null;
        _keepAliveTimer?.cancel();
        _keepAliveTimer = null;
        changed = true;
      }
      if (changed) notifyListeners();
    }
    finally {
      _connectingIps.remove(ip);
    }
  }

  void sendCommand(String action, {int? positionMs, String? targetPeerId}) {
    _sendInput({'action': action, 'position_ms': positionMs}, targetPeerId);
  }

  void sendVolume(double vol, {String? targetPeerId}) {
    // #65: reject NaN/Infinity (clamp propagates NaN to the peer).
    if (!vol.isFinite) return;
    currentVolume = vol.clamp(0.0, 1.0);
    if (vol > 0.0) isAudioMuted = false;
    final msg = {
      "type": "VOLUME_UPDATE",
      "volume": currentVolume,
    };
    final sock = socketForDevice(targetPeerId);
    if (sock != null) {
      try {
        sock.add(_encodeForDevice(msg, targetPeerId));
      } catch (_) {}
    }

    final target = targetPeerId != null
        ? discoveredPeers.firstWhere((p) => p['id'] == targetPeerId || p['ip'] == targetPeerId, orElse: () => <String, dynamic>{})
        : selectedTargetPeer;
    final targetIp = target?['ip'] as String?;
    if (sock == null && targetIp != null) _sendHttpVolume(targetIp, currentVolume);
  }

  void _sendHttpVolume(String ip, double vol) async {
    // #66: always release the HttpClient, also on connect/timeout errors.
    final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 500);
    try {
      final req = await client.getUrl(Uri.parse('http://$ip:28472/api/volume?v=$vol'));
      final res = await req.close();
      await res.drain<void>();
    } catch (_) {
    } finally {
      client.close(force: true);
    }
  }

  void sendAudioMute(bool muted, {String? targetPeerId}) {
    isAudioMuted = muted;
    final msg = {
      "type": "AUDIO_MUTE",
      "muted": muted,
    };
    final sock = socketForDevice(targetPeerId);
    if (sock != null) {
      try {
        sock.add(_encodeForDevice(msg, targetPeerId));
        NexusLogger.log("LAN_SYNC", "Sent AUDIO_MUTE: $msg");
      } catch (e) {
        NexusLogger.log("LAN_SYNC", "AUDIO_MUTE delivery failed: $e");
      }
    } else {
      // #67: no socket and no HTTP endpoint for an absolute mute state: make the loss visible.
      NexusLogger.log("LAN_SYNC", "AUDIO_MUTE not sent: no socket for target ${targetPeerId ?? '(default)'}");
    }
    notifyListeners();
  }

  Future<void> togglePcSpeakersMute({String? targetPeerId}) async {
    final target = targetPeerId != null
        ? discoveredPeers.firstWhere((p) => p['id'] == targetPeerId || p['ip'] == targetPeerId, orElse: () => <String, dynamic>{})
        : selectedTargetPeer;
    // #68: one channel only (WS, HTTP as fallback) and never fall back to the local device.
    if (socketForDevice(targetPeerId) != null) {
      sendCommand("MUTE", targetPeerId: targetPeerId);
      return;
    }
    final ip = target?['ip'] as String? ?? pcIp;
    if (ip == null || ip.isEmpty) {
      NexusLogger.log("LAN_SYNC", "PC speaker mute not sent: no valid target");
      return;
    }
    final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 800);
    try {
      final req = await client.getUrl(Uri.parse('http://$ip:28472/api/pc_mute'));
      await req.close();
      NexusLogger.log("LAN_SYNC", "Toggled PC speaker mute via http://$ip:28472/api/pc_mute");
    } catch (e) {
      NexusLogger.log("LAN_SYNC", "Failed to toggle PC speaker mute: $e");
    } finally {
      client.close(force: true);
    }
  }

  void sendOpenUrl(String url, String title, int positionMs, {String? targetPeerId}) {
    // #69: only http/https URLs may be opened on the remote device.
    final parsed = Uri.tryParse(url);
    if (parsed == null || !(parsed.scheme == 'http' || parsed.scheme == 'https') || parsed.host.isEmpty) {
      NexusLogger.log('LAN_SYNC', 'OPEN_URL rejected: unsupported URL scheme');
      return;
    }
    final socket = targetPeerId == null ? _ws : socketForDevice(targetPeerId);
    if (socket == null) return;
    final message = {'type': 'OPEN_URL', 'url': url, 'title': title, 'position_ms': positionMs};
    try {
      // #69: always encode per device, also on the default socket.
      socket.add(_encodeForDevice(message, targetPeerId));
    } catch (error) {
      NexusLogger.log('LAN_SYNC', 'OPEN_URL delivery failed: $error');
    }
  }

  void sendClipboardSync(String text) {
    _lastSeenClipboardText = text;
    if (_ws != null && isConnected) {
      final msg = {
        "type": "CLIPBOARD_SYNC",
        "text": text,
      };
      try {
        // #70: encode per device and never log the clipboard content.
        _ws!.add(_encodeForDevice(msg, null));
        NexusLogger.log("LAN_SYNC", "Sent CLIPBOARD_SYNC over LAN WebSocket (${text.length} chars)");
      } catch (e) {
        NexusLogger.log("LAN_SYNC", "CLIPBOARD_SYNC delivery failed: $e");
      }
    }
  }

  /// Synchronizes clipboard with Zero-Trust Privacy Gate and selective secret censoring
  void sendClipboardWithPrivacyGate(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final censor = censorSecretsInText(text);

    if (censor.hasSecret && clipboardPrivacyGate) {
      // ZERO-TRUST GATE: Cleartext NEVER leaves the source device automatically!
      // #38: unpredictable entry_id (128 bit from a CSPRNG) instead of a timestamp-based one.
      final rng = math.Random.secure();
      final entryId = "sec_${List<String>.generate(16, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}";
      if (_ws != null && isConnected) {
        final msg = {
          "type": "CLIPBOARD_SECRET_ANNOUNCE",
          "entry_id": entryId,
          "secret_type": censor.primarySecretType,
          "masked_preview": censor.maskedText,
          "source_device": deviceName,
          "timestamp_ms": DateTime.now().millisecondsSinceEpoch,
        };
        try {
          _ws!.add(jsonEncode(msg));
          // #71: keep the cleartext only when the announce was actually sent,
          // bounded in count (oldest evicted first) and in time (TTL).
          _pendingLocalSecrets[entryId] = text;
          while (_pendingLocalSecrets.length > 32) {
            _pendingLocalSecrets.remove(_pendingLocalSecrets.keys.first);
          }
          Timer(const Duration(minutes: 5), () => _pendingLocalSecrets.remove(entryId));
          NexusLogger.log("PRIVACY_GATE", "Announced protected secret placeholder: ${censor.maskedText} (ID: $entryId)");
        } catch (e) {
          NexusLogger.log("PRIVACY_GATE", "Failed to announce protected secret (ID: $entryId): $e");
        }
      }
    } else {
      // Safe content: auto-shared immediately
      sendClipboardSync(text);
    }
  }

  /// #72: socket on which each remote secret announce arrived (bounded, see handler).
  final Map<String, WebSocket> _secretAnnounceSockets = {};

  /// Sends a direct request to reveal an encrypted secret on-demand
  void requestSecretReveal(String entryId) {
    // #72: send the request to the device that announced the secret, not to the global _ws.
    final socket = _secretAnnounceSockets[entryId];
    if (socket == null || socket.readyState != WebSocket.open) {
      NexusLogger.log("PRIVACY_GATE", "CLIPBOARD_REVEAL_REQUEST not sent for entry $entryId: announcing device not connected");
      return;
    }
    final msg = {
      "type": "CLIPBOARD_REVEAL_REQUEST",
      "entry_id": entryId,
      "requesting_device": deviceName,
    };
    try {
      _pendingClipboardRevealRequests.add(entryId);
      socket.add(jsonEncode(msg));
      NexusLogger.log("PRIVACY_GATE", "Sent CLIPBOARD_REVEAL_REQUEST for entry $entryId");
    } catch (e) {
      _pendingClipboardRevealRequests.remove(entryId);
      NexusLogger.log("PRIVACY_GATE", "Failed to send CLIPBOARD_REVEAL_REQUEST for entry $entryId: $e");
    }
  }

  bool hasPendingLocalSecret(String entryId) => _pendingLocalSecrets.containsKey(entryId);
  String? getPendingLocalSecret(String entryId) => _pendingLocalSecrets[entryId];

  @visibleForTesting
  void handleSecretAnnounceForTesting(Map<String, dynamic> json) {
    _secretAnnounceController.add(json);
  }

  @visibleForTesting
  void handleSecretRevealResponseForTesting(Map<String, dynamic> json) {
    _secretRevealedController.add(json);
  }

  void sendSpatialArrangement(String peerId, String arrangement, {int width = 1920, int height = 1080, Offset? customOffset}) {
    final socket = socketForDevice(peerId);
    if (socket == null) {
      NexusLogger.log("LAN_SYNC", "SPATIAL_ARRANGEMENT not sent: no socket for $peerId");
      return;
    }
    {
      final msg = {
        "type": "SPATIAL_ARRANGEMENT",
        "peer_id": peerId,
        "sender_device_id": deviceId,
        "spatial_position": arrangement,
        "screen_width": width,
        "screen_height": height,
        if (customOffset != null) ...{
          "offset_x": customOffset.dx,
          "offset_y": customOffset.dy,
        }
      };
      try {
        // #74: per-device encoding; state is updated only after a successful send.
        socket.add(_encodeForDevice(msg, peerId));
        spatialPosition = arrangement;
        NexusLogger.log("LAN_SYNC", "Sent SPATIAL_ARRANGEMENT: $msg");
        notifyListeners();
      } catch (e) {
        NexusLogger.log("LAN_SYNC", "SPATIAL_ARRANGEMENT delivery failed: $e");
      }
    }
  }

  void _applyBleMonitoring() {
    final active = isBleHardwareAvailable && bleSpatialAutoDetect;
    if (_bleMonitoringApplied == active) return;
    _bleMonitoringApplied = active;
    // #75: guard the FFI call and roll the flag back on failure so a later call retries.
    try {
      NexusFfiBridge.instance.setBleScanningEnabled(active);
    } catch (e) {
      _bleMonitoringApplied = !active;
      bleScanError = 'Scansione BLE non disponibile: $e';
      NexusLogger.log("LAN_SYNC", "setBleScanningEnabled failed: $e");
    }
    if (Platform.isAndroid) {
      unawaited(_hardwareChannel.invokeMethod(active ? 'startBleProximity' : 'stopBleProximity',
          active ? {'device_id': deviceId} : null).then((_) {
        bleScanError = null;
        notifyListeners();
      }, onError: (Object e) {
        _bleMonitoringApplied = !active;
        bleScanError = 'Bluetooth non disponibile: $e';
        notifyListeners();
      }));
    }
    if (!active) {
      proximity.reset(peer: proximityPeerId, reference: _proximityCalibration[proximityPeerId]);
      estimatedDistanceMeters = null;
      liveRssi = null;
      proximityMotion = null;
    }
    notifyListeners();
  }

  void setBleSpatialAutoDetect(bool enabled) {
    bleSpatialAutoDetect = enabled;
    _applyBleMonitoring();
    unawaited(saveSettingBool('bleSpatialAutoDetect', enabled));
    notifyListeners();
  }

  bool get hasProximityPeer => proximityPeerId != null && discoveredPeers.any(
      (p) => p['id'] == proximityPeerId && p['online'] == true);

  String get proximityStatus {
    if (!bleSpatialAutoDetect) return 'Monitoraggio Bluetooth disattivato';
    if (proximityPeerId == null) return 'Scegli il dispositivo da monitorare';
    if (!hasProximityPeer) return 'Dispositivo selezionato non connesso';
    if (!proximity.isFresh(DateTime.now())) {
      if (bleScanError != null) return bleScanError!;
      return 'Nessun segnale BLE Nexus identificato recente';
    }
    if (proximity.referenceRssi == null) return 'Segnale ricevuto: calibrazione a 1 metro necessaria';
    return 'Stima BLE indicativa, sensibile a ostacoli e orientamento';
  }

  Future<void> setProximityPeer(String? id) async {
    proximityPeerId = id;
    proximity.reset(peer: id, reference: _proximityCalibration[id]);
    estimatedDistanceMeters = null;
    liveRssi = null;
    proximityMotion = null;
    _isDeparted = false;
    _hasFiredDepartureAlert = false;
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove('proximity_peer_v2');
    } else {
      await prefs.setString('proximity_peer_v2', id);
    }
    notifyListeners();
  }

  Future<bool> calibrateProximityAtOneMeter() async {
    if (!hasProximityPeer) return false;
    final reference = proximity.calibrateAtOneMeter(DateTime.now());
    if (reference == null) return false;
    final peer = proximityPeerId!;
    // Persist first: in-memory state changes only once the calibration is stored.
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = await prefs.setString('proximity_calibration_v2',
          jsonEncode({..._proximityCalibration, peer: reference}));
      if (!saved) throw StateError('SharedPreferences.setString returned false');
    } catch (e) {
      NexusLogger.log('PROXIMITY', 'Calibration not persisted for $peer: $e');
      return false;
    }
    _proximityCalibration[peer] = reference;
    estimatedDistanceMeters = proximity.distance(DateTime.now());
    notifyListeners();
    return true;
  }

  Future<void> setAutoLockOnWalkAway(bool enabled) async {
    proximityLockError = null;
    try {
      final applied = NexusFfiBridge.instance.setProximityLockEnabled(enabled);
      if (!applied && NexusFfiBridge.instance.isLoaded) {
        proximityLockError = 'Impostazione del blocco rifiutata dal backend nativo.';
        NexusLogger.log('PROXIMITY', 'setProximityLockEnabled($enabled) returned false');
        notifyListeners();
        return;
      }
    } catch (e) {
      proximityLockError = 'Impostazione del blocco non applicata dal backend nativo: $e';
      NexusLogger.log('PROXIMITY', 'setProximityLockEnabled($enabled) failed: $e');
      notifyListeners();
      return;
    }
    autoLockOnWalkAway = enabled;
    proximity.resetLock();
    _proximityLockFired = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('proximity_lock_opt_in_v2', enabled);
    } catch (e) {
      NexusLogger.log('PROXIMITY', 'Proximity lock opt-in not persisted: $e');
    }
    notifyListeners();
  }

  void handleIncomingBleRssi(double rawRssi, {String? address, String? name,
      bool? isNexus, String? peerId, DateTime? observedAt, bool evaluate = true}) {
    // A rotating radio address and a product name are not Nexus peer identities.
    if (!isBleHardwareAvailable || !bleSpatialAutoDetect || isNexus != true || peerId == null || peerId != proximityPeerId ||
        !hasProximityPeer || peerId == deviceId) {
      return;
    }
    final now = DateTime.now();
    if (!proximity.add(peerId, rawRssi, observedAt ?? now)) return;
    if (evaluate) _evaluateProximity();
  }

  void _evaluateProximity() {
    final now = DateTime.now();
    final filteredRssi = proximity.filteredRssi;
    if (!proximity.isFresh(now) || !hasProximityPeer || filteredRssi == null) return;
    liveRssi = filteredRssi.round();
    estimatedDistanceMeters = proximity.distance(now);
    proximityMotion = null;
    final distance = estimatedDistanceMeters;
    if (!_proximityLockFired && proximity.shouldLock(now: now, enabled: autoLockOnWalkAway,
        threshold: autoLockThresholdMeters, returnThreshold: returnThresholdMeters)) {
      // One lock attempt per departure; re-armed when the peer comes back.
      _proximityLockFired = true;
      Object? result;
      try {
        result = NexusFfiBridge.instance.lockForProximity();
      } catch (e) {
        result = -1;
        NexusLogger.log('PROXIMITY', 'lockForProximity threw: $e');
      }
      proximityLockError = result == 0 ? null :
          'Blocco non eseguito: backend di sistema non disponibile o consenso non attivo (codice $result).';
      NexusLogger.log('PROXIMITY', 'Local calibrated departure lock result: $result');
    }
    if (distance != null && distance <= returnThresholdMeters) { _proximityLockFired = false; }
    if (distance != null) { _checkProximityWalkAway(distance, null); }
    if (!_proximityController.isClosed) {
      _proximityController.add({'type': 'PROXIMITY_UPDATE', 'peer_id': proximityPeerId,
        'distance_m': distance, 'rssi': liveRssi});
    }
    notifyListeners();
  }

  void pollBleObservations() {
    final Map native;
    try {
      native = NexusFfiBridge.instance.getBleObservations();
    } catch (e) {
      bleScanStatus = 'unavailable';
      bleScanError = 'Lettura delle osservazioni BLE non riuscita';
      NexusLogger.log('PROXIMITY', 'getBleObservations failed: $e');
      return;
    }
    bleScanStatus = native['ble_scan_status'] as String? ?? 'unavailable';
    bleScanError = native['ble_scan_error'] as String?;
    final samples = native['ble_samples'];
    if (samples is List) {
      // A native counter restart (plugin/service restart) makes every sequence
      // lower than the last one seen: re-align instead of discarding forever.
      final maxSequence = samples.whereType<Map>()
          .map((s) => (s['sequence'] as num?)?.toInt())
          .whereType<int>()
          .fold<int?>(null, (m, s) => m == null || s > m ? s : m);
      if (maxSequence != null && maxSequence < _lastBleSequence) {
        NexusLogger.log('PROXIMITY', 'BLE sequence restarted ($maxSequence < $_lastBleSequence), re-aligning');
        _lastBleSequence = -1;
      }
    }
    final previousSequence = _lastBleSequence;
    if (samples is List) {
      // Each observation is consumed once; repeated UI polling cannot create samples.
      final fresh = samples.whereType<Map>().toList()
        ..sort((a, b) => ((a['sequence'] as num?) ?? -1).compareTo((b['sequence'] as num?) ?? -1));
      for (final sample in fresh) {
        final sequence = (sample['sequence'] as num?)?.toInt();
        final at = (sample['observed_at_ms'] as num?)?.toInt();
        if (sequence == null || sequence <= _lastBleSequence) continue;
        _lastBleSequence = sequence;
        final age = at == null ? -1 : DateTime.now().millisecondsSinceEpoch - at;
        if (age < 0 || age > ProximityMonitor.freshness.inMilliseconds) continue;
        final rssi = (sample['rssi'] as num?)?.toDouble();
        if (rssi != null) {
          // Identity comes from the native field when provided; peer_id
          // authentication itself must be enforced by the native scanner.
          handleIncomingBleRssi(rssi, peerId: sample['peer_id'] as String?,
            isNexus: sample['is_nexus'] is bool ? sample['is_nexus'] as bool : sample['peer_id'] != null, observedAt: DateTime.fromMillisecondsSinceEpoch(at!), evaluate: false);
        }
      }
    }
    if (_lastBleSequence != previousSequence) _evaluateProximity();
    final freshNow = hasProximityPeer && proximity.isFresh(DateTime.now());
    final hadReading = estimatedDistanceMeters != null || liveRssi != null;
    // Reset only on the fresh -> stale transition, not on every poll.
    if (!freshNow && (_bleReadingFresh || hadReading)) {
      estimatedDistanceMeters = null;
      liveRssi = null;
      proximityMotion = null;
      proximity.reset(peer: proximityPeerId, reference: _proximityCalibration[proximityPeerId]);
      if (hadReading) notifyListeners();
    }
    _bleReadingFresh = freshNow;
  }

  // #80: route through the selected target socket with per-device encoding,
  // instead of the global _ws in plain form; failures are logged, not swallowed.
  bool _sendToTarget(Map<String, dynamic> msg) {
    final socket = socketForDevice(null);
    if (socket == null || !isConnected) return false;
    try {
      socket.add(_encodeForDevice(msg, null));
      return true;
    } catch (e) {
      NexusLogger.log("LAN_SYNC", "Failed to send ${msg['type']}: $e");
      return false;
    }
  }

  void sendUniversalControlHop(int entryX, int entryY, int screenWidth, int screenHeight) {
    _sendToTarget({
      "type": "UNIVERSAL_CONTROL_HOP",
      "entry_x": entryX,
      "entry_y": entryY,
      "screen_width": screenWidth,
      "screen_height": screenHeight,
    });
  }

  void sendUniversalControlDelta(int dx, int dy) {
    _sendToTarget({
      "type": "UNIVERSAL_CONTROL_DELTA",
      "dx": dx,
      "dy": dy,
    });
  }

  void sendProximityTrigger(String action) {
    if (action == 'LOCK_WORKSTATION') return;
    _sendToTarget({
      "type": "PROXIMITY_TRIGGER",
      "action": action,
    });
  }

  int _lastWalkAwayPromptTime = 0;
  int _lastReturnWelcomeTime = 0;
  bool _isDeparted = false;
  bool _hasFiredDepartureAlert = false;
  bool _proximityLockFired = false;
  bool _bleReadingFresh = false;
  double? _lastWalkAwayDistance;

  void _checkProximityWalkAway(double distanceMeters, String? motion) {
    final now = DateTime.now().millisecondsSinceEpoch;

    // Hysteresis guard: walk-away must be strictly beyond the return threshold,
    // otherwise departure/return would oscillate on every sample.
    if (!distanceMeters.isFinite || walkAwayThresholdMeters <= returnThresholdMeters) {
      NexusLogger.log("PROXIMITY", "Walk-away check skipped: invalid distance or thresholds (walkAway=$walkAwayThresholdMeters, return=$returnThresholdMeters)");
      return;
    }

    // Derive motion from consecutive samples when the caller has none,
    // so the MovingAway/Approaching biases are actually applied.
    final prevDistance = _lastWalkAwayDistance;
    _lastWalkAwayDistance = distanceMeters;
    if (motion == null && prevDistance != null) {
      final delta = distanceMeters - prevDistance;
      if (delta > 0.15) {
        motion = 'MovingAway';
      } else if (delta < -0.15) {
        motion = 'Approaching';
      }
    }

    // 2. Realistic indoor walk-away thresholds (configurable)
    // MovingAway bias allows triggering slightly earlier when walking fast
    final walkAwayBias = (motion == 'MovingAway') ? 0.4 : 0.0;
    final isDeparting = distanceMeters > (walkAwayThresholdMeters - walkAwayBias);
    final returnBias = (motion == 'Approaching') ? 0.2 : 0.0;
    final isApproaching = distanceMeters <= (returnThresholdMeters + returnBias);

    if (isDeparting && !_isDeparted) {
      _isDeparted = true;
      NexusLogger.log("PROXIMITY", "Walk-away event triggered! (Distance: ${distanceMeters.toStringAsFixed(1)}m, motion: $motion)");

      final hasActiveMedia = activeMedia != null &&
          (activeMedia!['is_playing'] == true || activeMedia!['status'] == 'playing');

      if (autoPauseMediaOnWalkAway && hasActiveMedia) {
        final title = activeMedia!['media_title'] as String? ?? 'Video PC';
        final rawUrl = activeMedia!['media_url'] as String? ?? '';
        final posMs = (activeMedia!['position_ms'] as num?)?.toInt() ?? 0;
        final app = activeMedia!['source_app'] as String? ?? 'Browser';

        NexusLogger.log("PROXIMITY", "Auto-pausing PC media '$title' and triggering continuity handoff prompt.");

        // Pause PC media over a single channel (WS command); sending both PAUSE and
        // PAUSE_ON_WALK_AWAY made the PC toggle/pause twice.
        sendCommand("PAUSE");
        // Optimistic local state (required by the handoff UI/test); the next
        // MEDIA_STATE from the PC overwrites it with the confirmed value.
        activeMedia!['is_playing'] = false;

        if (!_hasFiredDepartureAlert) {
          _hasFiredDepartureAlert = true;
          _triggerMediaHandoffPrompt(
            title: title,
            rawUrl: rawUrl,
            positionMs: posMs,
            sourceApp: app,
          );
        }
      } else {
        // Walk-away without active media: notify user of proximity departure & lock once
        if (!_hasFiredDepartureAlert) {
          _hasFiredDepartureAlert = true;
          _triggerWalkAwaySecurityAlert(distanceMeters);
        }
      }
    } else if (isApproaching && _isDeparted) {
      // User returned to desk
      _isDeparted = false;
      _hasFiredDepartureAlert = false; // Reset gate so next walk-away triggers cleanly
      NexusLogger.log("PROXIMITY", "Return to workstation detected! (Distance: ${distanceMeters.toStringAsFixed(1)}m)");

      if (wakeOnApproach) {
        sendProximityTrigger("WAKE_ON_APPROACH");
      }

      if (now - _lastReturnWelcomeTime > 15000) {
        _lastReturnWelcomeTime = now;
        _triggerReturnWelcomeAlert(distanceMeters);
      }
    }
  }

  void _triggerWalkAwaySecurityAlert(double distanceMeters) {
    final distStr = distanceMeters.toStringAsFixed(1);
    const title = 'Allontanamento Rilevato';
    final body = 'Ti sei allontanato da $pcName (${distStr}m). Distanza BLE stimata.';

    NexusLogger.log("PROXIMITY", "Walk-away security alert dispatched: $body");

    // 1. In-App Notification Center (upsert fixed ID)
    const notifId = 'walkaway-proximity-alert';
    notifications.removeWhere((n) => n.id == notifId);
    final notif = NexusNotification(
      id: notifId,
      title: title,
      rawBody: body,
      currentBody: body,
      appName: 'Nexus Proximity',
      senderDevice: pcName,
      senderDeviceId: 'pc-windows',
      timestamp: DateTime.now(),
      hasSecret: false,
      isRevealed: true,
      category: NexusNotificationCategory.internalApp,
    );
    _insertNotification(notif);
    _notificationController.add(notif);

    // 2. Android Native OS Notification
    _showAndroidSystemNotification(title, body);
  }

  void _triggerReturnWelcomeAlert(double distanceMeters) {
    final distStr = distanceMeters.toStringAsFixed(1);
    const title = 'Bentornato alla postazione';
    final body = 'Riconnesso a $pcName (${distStr}m). Segnale BLE nuovamente vicino.';

    NexusLogger.log("PROXIMITY", "Return welcome alert dispatched: $body");

    const notifId = 'return-proximity-alert';
    notifications.removeWhere((n) => n.id == notifId);
    final notif = NexusNotification(
      id: notifId,
      title: title,
      rawBody: body,
      currentBody: body,
      appName: 'Nexus Proximity',
      senderDevice: pcName,
      senderDeviceId: 'pc-windows',
      timestamp: DateTime.now(),
      hasSecret: false,
      isRevealed: true,
      category: NexusNotificationCategory.internalApp,
    );
    _insertNotification(notif);
    if (!_notificationController.isClosed) _notificationController.add(notif);

    _showAndroidSystemNotification(title, body);
  }

  /// Mostra una notifica di sistema Android senza lasciare Future non gestiti.
  void _showAndroidSystemNotification(String title, String body, {String url = ''}) {
    if (!Platform.isAndroid) return;
    unawaited(_hardwareChannel.invokeMethod('showSystemNotification', {
      'title': title,
      'body': body,
      'url': url,
    }).catchError((Object e) {
      NexusLogger.log("PROXIMITY", "Failed to show Android system notification: $e");
      return null;
    }));
  }

  /// Aggiunge il parametro t= a un URL http/https; restituisce '' se l'URL non e' valido.
  static String _buildTimestampedMediaUrl(String rawUrl, int positionMs) {
    if (rawUrl.isEmpty) return '';
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https')) || uri.host.isEmpty) return '';
    final posSeconds = positionMs < 0 ? 0 : positionMs ~/ 1000;
    final params = Map<String, String>.from(uri.queryParameters)..['t'] = '${posSeconds}s';
    return uri.replace(queryParameters: params).toString();
  }

  /// Restituisce true solo se il prompt e' stato mostrato davvero (non scartato dal debounce).
  bool _triggerMediaHandoffPrompt({
    required String title,
    required String rawUrl,
    required int positionMs,
    String sourceApp = 'PC Media',
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastWalkAwayPromptTime < 4000) return false; // 4s debounce
    _lastWalkAwayPromptTime = now;

    final timestampedUrl = _buildTimestampedMediaUrl(rawUrl, positionMs);

    final promptData = {
      'title': title,
      'source_app': sourceApp,
      'media_url': timestampedUrl.isEmpty ? '' : rawUrl,
      'timestamped_url': timestampedUrl,
      'position_ms': positionMs,
      'prompt_text': 'Vuoi continuare la riproduzione qui?',
      'full_message': 'Vuoi continuare la riproduzione di "$title" qui sul telefono?',
    };

    NexusLogger.log("PROXIMITY", "Media handoff prompt dispatched (source: $sourceApp, has_url: ${timestampedUrl.isNotEmpty})");

    // 1. Add to In-App Notification Center
    final notifId = 'handoff-${DateTime.now().millisecondsSinceEpoch}';
    final notif = NexusNotification(
      id: notifId,
      title: 'Continua la riproduzione?',
      rawBody: 'Vuoi continuare la riproduzione di "$title" qui?',
      currentBody: 'Vuoi continuare la riproduzione di "$title" qui sul telefono?',
      appName: 'Continuity Video',
      senderDevice: pcName,
      senderDeviceId: 'pc-windows',
      timestamp: DateTime.now(),
      hasSecret: false,
      isRevealed: true,
      category: NexusNotificationCategory.internalApp,
    );
    _insertNotification(notif);
    if (!_notificationController.isClosed) _notificationController.add(notif);

    // 2. Android Native OS Notification (NotificationManager with PendingIntent)
    _showAndroidSystemNotification('Continua la riproduzione?', 'Vuoi continuare la riproduzione qui? - $title', url: timestampedUrl);

    // 3. Emit on Stream for In-App Banner/Snackbar UI
    if (!_mediaHandoffPromptController.isClosed) _mediaHandoffPromptController.add(promptData);
    return true;
  }

  /// Test-only hook: simulates a walk-away departure. Not for production callers.
  @visibleForTesting
  void triggerProximityDepartureHandoff({double? distanceMeters}) {
    final dist = distanceMeters ?? 3.5;
    proximityMotion = "MovingAway";
    estimatedDistanceMeters = dist;
    _isDeparted = false; // Reset so departure trigger fires cleanly
    _checkProximityWalkAway(dist, "MovingAway");
  }

  void sendTouchpadDelta(int dx, int dy, {String? targetPeerId}) {
    _sendInput({"type": "TOUCHPAD_DELTA", "dx": dx, "dy": dy}, targetPeerId);
  }

  void sendTouchpadScroll(int dy, {String? targetPeerId}) {
    _sendInput({"type": "TOUCHPAD_SCROLL", "dy": dy}, targetPeerId);
  }

  void sendTouchpadClick(String button, {String? targetPeerId}) {
    _sendInput({"type": "TOUCHPAD_CLICK", "button": button}, targetPeerId);
  }

  void sendTouchpadButton(String button, bool isDown, {String? targetPeerId}) {
    _sendInput({"type": "TOUCHPAD_BUTTON", "button": button, "is_down": isDown}, targetPeerId);
  }

  void sendKeyboardKey(String key, {bool? isDown, String? targetPeerId}) {
    _sendInput({'type': 'KEYBOARD_KEY', 'key': key, 'is_down': ?isDown}, targetPeerId);
  }

  void sendKeyboardCombo(List<String> keys, {String? targetPeerId}) {
    _sendInput({'type': 'KEYBOARD_COMBO', 'keys': keys}, targetPeerId);
  }

  Future<String?> sendTextInputConfirmed(String text, {required String targetPeerId}) async {
    if (text.runes.length > 4096) return 'Invia al massimo 4096 caratteri per volta.';
    final requestId = '$deviceId-${DateTime.now().microsecondsSinceEpoch}-${_textRequestSequence++}';
    final reply = Completer<String?>();
    _pendingText[requestId] = (target: targetPeerId, reply: reply);
    try {
      if (!_sendInput({'type': 'KEYBOARD_TEXT', 'text': text, 'request_id': requestId}, targetPeerId)) {
        return inputErrorFor(targetPeerId) ?? 'Connessione al PC non disponibile.';
      }
      return await reply.future.timeout(const Duration(seconds: 40), onTimeout: () =>
          'Conferma del PC non ricevuta. Il testo potrebbe essere parziale: verifica la finestra di destinazione prima di reinviare.');
    } finally {
      _pendingText.remove(requestId);
    }
  }

  void sendTextInput(String text, {String? targetPeerId}) {
    _sendInput({'type': 'KEYBOARD_TEXT', 'text': text}, targetPeerId);
  }

  void requestFileResume(String fileId, {WebSocket? via}) {
    final missing = getMissingChunksForFile(fileId);
    final target = via ?? (isConnected ? _ws : null);
    if (missing.isNotEmpty && target != null) {
      final msg = {
        "type": "FILE_RESUME_REQUEST",
        "file_id": fileId,
        "missing_chunks": missing,
      };
      try {
        // #87: encoded for the peer when going through the default socket; errors are logged.
        target.add(via == null ? _encodeForDevice(msg, null) : jsonEncode(msg));
        NexusLogger.log("FILE_TRANSFER", "Sent FILE_RESUME_REQUEST for $fileId (${missing.length} missing chunks)");
      } catch (e) {
        NexusLogger.log("FILE_TRANSFER", "FILE_RESUME_REQUEST failed for $fileId: $e");
      }
    }
  }

  List<int> getMissingChunksForFile(String fileId) {
    final session = _incomingFiles[fileId];
    if (session == null) return [];
    final totalChunks = session['total_chunks'];
    final chunks = session['chunks'];
    // #87: peer-supplied chunk count is bounded, so the loop cannot exhaust memory.
    if (totalChunks is! int || totalChunks < 0 || totalChunks > _maxIncomingFileChunks || chunks is! Map) return [];
    final missing = <int>[];
    for (int i = 0; i < totalChunks; i++) {
      if (!chunks.containsKey(i)) {
        missing.add(i);
      }
    }
    return missing;
  }

  /// Streams a real file in 64KB chunks over WebSocket with real speed & progress reporting
  Future<void> sendRealFileStream(
    String filePath,
    String fileName, {
    Function(double progress, String speed)? onProgress,
  }) async {
    if (!fileTransferEnabled) {
      throw Exception("I trasferimenti file sono disabilitati nelle Impostazioni.");
    }
    final ws = _ws;
    if (ws == null || !isConnected) {
      throw Exception("Non connesso alla rete Nexus LAN. Assicurati che PC e Android siano sulla stessa rete.");
    }
    final file = File(filePath);
    if (!await file.exists()) {
      // #88: the full local path is not exposed in the error.
      throw Exception("File non trovato su disco: $fileName");
    }
    // #88: size limit checked before the file is loaded into memory.
    if (await file.length() > _maxIncomingFileBytes) {
      throw Exception("File troppo grande per il trasferimento (massimo 512 MB).");
    }

    final fileBytes = await file.readAsBytes();
    final fileSize = fileBytes.length;
    // #51: digest declared in the offer, verified by the receiver before saving.
    final fileDigest = lanSyncSha256Hex(fileBytes);
    // #53: unguessable file id, so FILE_RESUME_REQUEST cannot be used to pull cached files blindly.
    final rnd = math.Random.secure();
    final nonce = List<int>.generate(8, (_) => rnd.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final fileId = "file_${DateTime.now().millisecondsSinceEpoch}_$nonce";
    _cacheOutgoingFile(fileId, fileBytes, peer: ws);
    const chunkSize = _fileChunkSize; // 64 KB chunks
    final totalChunks = fileSize == 0 ? 1 : (fileSize / chunkSize).ceil();
    final senderName = deviceName;

    // 1. Invia offerta
    final offerMsg = {
      "type": "FILE_OFFER",
      "file_id": fileId,
      "file_name": fileName,
      "file_size": fileSize,
      "total_chunks": totalChunks,
      "chunk_size": chunkSize,
      "sender_device": senderName,
      "sha256": fileDigest,
    };
    ws.add(_encodeForDevice(offerMsg, null));
    await Future.delayed(const Duration(milliseconds: 60));

    // 2. Invia blocchi 64KB
    final startTime = DateTime.now();
    int sentBytes = 0;
    for (int i = 0; i < totalChunks; i++) {
      final start = i * chunkSize;
      final end = (start + chunkSize < fileSize) ? start + chunkSize : fileSize;
      final chunkSlice = fileSize == 0 ? <int>[] : fileBytes.sublist(start, end);
      final b64 = base64Encode(chunkSlice);

      final chunkMsg = {
        "type": "FILE_CHUNK",
        "file_id": fileId,
        "chunk_index": i,
        "total_chunks": totalChunks,
        "data": b64,
      };
      // #88: stop if the connection dropped or changed during the transfer.
      if (!identical(_ws, ws) || !isConnected) {
        throw Exception("Connessione persa durante l'invio di $fileName.");
      }
      ws.add(_encodeForDevice(chunkMsg, null));
      sentBytes += chunkSlice.length;

      final elapsed = DateTime.now().difference(startTime).inMilliseconds / 1000.0;
      final speedMbps = elapsed > 0.05 ? (sentBytes / (1024 * 1024)) / elapsed : 0.0;
      final progress = (i + 1) / totalChunks;

      if (onProgress != null) {
        onProgress(progress, '${speedMbps.toStringAsFixed(1)} MB/s');
      }

      // Small throttling yield to maintain socket stability
      if (i % 3 == 0) {
        await Future.delayed(const Duration(milliseconds: 4));
      }
    }

    // 3. Completa invio
    final completeMsg = {
      "type": "FILE_COMPLETE",
      "file_id": fileId,
      "file_name": fileName,
      "file_size": fileSize,
    };
    if (!identical(_ws, ws) || !isConnected) {
      throw Exception("Connessione persa durante l'invio di $fileName.");
    }
    ws.add(_encodeForDevice(completeMsg, null));
    NexusLogger.log("FILE_TRANSFER", "File $fileName inviato con successo ($fileSize byte, $totalChunks chunk)");
  }

  void sendNotification({
    required String title,
    required String body,
    String appName = 'Sistema',
  }) {
    final censorResult = censorSecretsInText(body);
    // #89: the title is censored too, so a secret in it never reaches the peer.
    final titleCensor = censorSecretsInText(title);
    final wireTitle = titleCensor.hasSecret ? titleCensor.maskedText : title;
    // #38: unpredictable id (128 bit from a CSPRNG): it is also the key of the pending secret.
    final idRng = math.Random.secure();
    final id = 'notif_${List<String>.generate(16, (_) => idRng.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    final thisDeviceName = deviceName;
    final thisDeviceId = deviceId;

    if (censorResult.hasSecret) {
      _storePendingNotificationSecret(id, body);
    }

    final notif = NexusNotification(
      id: id,
      title: title,
      rawBody: body,
      currentBody: censorResult.hasSecret ? censorResult.maskedText : body,
      appName: appName,
      senderDevice: thisDeviceName,
      senderDeviceId: thisDeviceId,
      timestamp: DateTime.now(),
      hasSecret: censorResult.hasSecret,
      secretCategory: censorResult.primarySecretType,
      isRevealed: !censorResult.hasSecret,
    );

    notifications.removeWhere((n) => n.id == id);
    _insertNotification(notif);
    _notificationController.add(notif);

    if (_ws != null && isConnected) {
      final msg = {
        "type": "NOTIFICATION_SYNC",
        "id": id,
        "title": wireTitle,
        "body": censorResult.maskedText,
        "app_name": appName,
        "sender_device": thisDeviceName,
        "sender_device_id": thisDeviceId,
        "timestamp": DateTime.now().toIso8601String(),
        "has_secret": censorResult.hasSecret,
        "secret_category": censorResult.primarySecretType,
        "category": "osNotification",
      };
      try {
        _ws!.add(_encodeForDevice(msg, null));
        NexusLogger.log("NOTIF_SYNC", "Broadcasted notification $id (${censorResult.hasSecret ? 'Sanitizzata' : 'Normale'})");
      } catch (e) {
        NexusLogger.log("NOTIF_SYNC", "NOTIFICATION_SYNC failed for $id: $e");
      }
    }
  }

  void _markNotificationRevealed(String notifId, String cleartext) {
    final idx = notifications.indexWhere((n) => n.id == notifId);
    if (idx != -1) {
      notifications[idx].currentBody = cleartext;
      notifications[idx].isRevealed = true;
    }
    if (!_notificationRevealedController.isClosed) {
      _notificationRevealedController.add(notifId);
    }
    notifyListeners();
  }

  /// #90: explicit local confirmation before protected notification content is revealed
  /// or sent to another device. The app has no authentication package (no local_auth in
  /// pubspec), so the UI injects this callback (e.g. a confirmation dialog). `outgoing` is
  /// true when the content would leave this device. Without a callback reveals are refused.
  Future<bool> Function(String notifId, bool outgoing)? notificationRevealConfirmer;

  /// #42: explicit local confirmation before a peer-requested URL is opened.
  /// Injected by the UI; without a callback remote OPEN_URL requests are refused.
  Future<bool> Function(Uri uri)? openUrlConfirmer;

  /// #42: only absolute http/https URLs with a host are accepted from peers.
  @visibleForTesting
  static bool isAllowedRemoteUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final scheme = uri.scheme.toLowerCase();
    return (scheme == 'http' || scheme == 'https') && uri.host.isNotEmpty;
  }

  Future<void> _confirmAndLaunchUrl(Uri uri, String url) async {
    final confirmer = openUrlConfirmer;
    if (confirmer == null) {
      NexusLogger.log("LAN_SYNC", "OPEN_URL refused: no local confirmation available");
      return;
    }
    try {
      if (!await confirmer(uri)) {
        NexusLogger.log("LAN_SYNC", "OPEN_URL declined by user: $url");
        return;
      }
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) NexusLogger.log("LAN_SYNC", "OPEN_URL launch returned false: $url");
    } catch (e) {
      NexusLogger.log("LAN_SYNC", "OPEN_URL launch failed: $e");
    }
  }

  Future<bool> _confirmNotificationReveal(String notifId, {required bool outgoing}) async {
    final confirmer = notificationRevealConfirmer;
    if (confirmer == null) {
      NexusLogger.log("NOTIF_PRIVACY", "Reveal of $notifId refused: no local confirmation available");
      return false;
    }
    try {
      return await confirmer(notifId, outgoing);
    } catch (e) {
      NexusLogger.log("NOTIF_PRIVACY", "Local confirmation for $notifId failed: $e");
      return false;
    }
  }

  Future<void> requestNotificationReveal(String notifId) async {
    // #90: nothing is revealed or requested without an explicit local confirmation.
    if (!await _confirmNotificationReveal(notifId, outgoing: false)) return;
    // #90: the local secret is removed from memory once it has been revealed.
    final cleartext = _pendingLocalNotificationSecrets.remove(notifId);
    if (cleartext != null) {
      _markNotificationRevealed(notifId, cleartext);
      return;
    }

    if (_ws != null && isConnected) {
      _pendingNotificationRevealRequests.add(notifId);
      final msg = {
        "type": "NOTIFICATION_REVEAL_REQUEST",
        "id": notifId,
        "requesting_device": deviceName,
        "requesting_device_id": deviceId,
      };
      try {
        _ws!.add(_encodeForDevice(msg, null));
        NexusLogger.log("NOTIF_PRIVACY", "Sent NOTIFICATION_REVEAL_REQUEST for $notifId");
      } catch (e) {
        _pendingNotificationRevealRequests.remove(notifId);
        NexusLogger.log("NOTIF_PRIVACY", "NOTIFICATION_REVEAL_REQUEST failed for $notifId: $e");
      }
    }
  }

  void clearNotifications() {
    notifications.clear();
    // #91: pending cleartext secrets are dropped together with the notifications.
    _pendingLocalNotificationSecrets.clear();
    notifyListeners();
  }

  @visibleForTesting
  void handleNotificationForTesting(NexusNotification notif) {
    notifications.removeWhere((n) => n.id == notif.id);
    _insertNotification(notif);
    if (!_notificationController.isClosed) {
      _notificationController.add(notif);
    }
  }

  @visibleForTesting
  void handleNotificationRevealResponseForTesting(String notifId, String cleartext) {
    _markNotificationRevealed(notifId, cleartext);
  }

  // Limits for incoming transfers: the file is assembled in memory, so size and count are capped.
  static const int _maxIncomingFileBytes = 512 * 1024 * 1024;
  static const int _maxIncomingFileChunks = 1 << 20;
  static const int _maxConcurrentIncomingFiles = 8;
  // #48: idle incoming sessions (no FILE_COMPLETE) expire after this TTL.
  static const Duration _incomingFileTtl = Duration(minutes: 10);

  /// #48: drops incoming sessions idle for longer than [_incomingFileTtl].
  int _pruneStaleIncomingFiles([DateTime? now]) {
    final cutoff = (now ?? DateTime.now()).subtract(_incomingFileTtl);
    final stale = <String>[];
    _incomingFiles.forEach((id, session) {
      final last = session['last_activity'] ?? session['start_time'];
      if (last is! DateTime || last.isBefore(cutoff)) stale.add(id);
    });
    for (final id in stale) {
      _incomingFiles.remove(id);
    }
    if (stale.isNotEmpty) {
      NexusLogger.log("FILE_TRANSFER", "Expired ${stale.length} stale incoming transfer(s).");
    }
    return stale.length;
  }

  /// Reduces a peer-supplied file name to a safe base name (no directories,
  /// no traversal, no characters invalid on Windows/Android).
  static String _sanitizeIncomingFileName(String raw) {
    var name = raw.split(RegExp(r'[\\/]')).last;
    name = name.replaceAll(RegExp(r'[<>:"|?*\x00-\x1F]'), '_').trim();
    name = name.replaceAll(RegExp(r'^\.+'), '').replaceAll(RegExp(r'[. ]+$'), '');
    if (RegExp(r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\..*)?$', caseSensitive: false).hasMatch(name)) {
      name = '_$name';
    }
    if (name.isEmpty) {
      name = 'file';
    }
    if (name.length > 200) {
      name = name.substring(name.length - 200);
    }
    return name;
  }

  /// #52: resolves the target directory with async I/O only.
  static Future<Directory> _resolveIncomingSaveDir() async {
    Future<Directory?> ensure(String path) async {
      final dir = Directory(path);
      try {
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        return dir;
      } catch (_) {
        return null;
      }
    }

    if (Platform.isAndroid) {
      return await ensure('/storage/emulated/0/Download/Nexus') ??
          await ensure('/storage/emulated/0/Download') ??
          Directory.systemTemp;
    }
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile == null || userProfile.isEmpty) {
        return Directory.systemTemp;
      }
      return await ensure('$userProfile\\Downloads\\Nexus') ??
          await ensure('$userProfile\\Downloads') ??
          Directory.systemTemp;
    }
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      return await ensure('$home/Downloads/Nexus') ?? Directory.systemTemp;
    }
    return Directory.systemTemp;
  }

  /// #52: returns a non-overwriting path inside [dir] using async I/O only.
  static Future<String> _uniqueTargetPathAsync(Directory dir, String fileName) async {
    final sep = Platform.pathSeparator;
    var candidate = '${dir.path}$sep$fileName';
    if (!await File(candidate).exists()) {
      return candidate;
    }
    final dot = fileName.lastIndexOf('.');
    final base = dot > 0 ? fileName.substring(0, dot) : fileName;
    final ext = dot > 0 ? fileName.substring(dot) : '';
    for (var i = 1; i < 1000; i++) {
      candidate = '${dir.path}$sep$base ($i)$ext';
      if (!await File(candidate).exists()) {
        return candidate;
      }
    }
    return '${dir.path}$sep$base (${DateTime.now().millisecondsSinceEpoch})$ext';
  }

  /// #52: saves an assembled incoming file asynchronously and always notifies
  /// [onFileReceived], with an 'error' key when the save fails.
  Future<void> _saveIncomingFile(String fileId, String fileName, List<int> bytes) async {
    try {
      final saveDir = await _resolveIncomingSaveDir();
      final targetPath = await _uniqueTargetPathAsync(saveDir, fileName);
      await File(targetPath).writeAsBytes(bytes, flush: true);
      NexusLogger.log("FILE_TRANSFER", "Saved complete file to: $targetPath (${bytes.length} bytes)");
      if (!_fileReceivedController.isClosed) {
        _fileReceivedController.add({
          'file_id': fileId,
          'file_name': fileName,
          'file_size': bytes.length,
          'saved_path': targetPath,
        });
      }
    } catch (e) {
      NexusLogger.log("FILE_TRANSFER", "Error saving file: $e");
      if (!_fileReceivedController.isClosed) {
        _fileReceivedController.add({
          'file_id': fileId,
          'file_name': fileName,
          'file_size': bytes.length,
          'saved_path': null,
          'error': e.toString(),
        });
      }
    }
  }

  @visibleForTesting
  static Future<Directory> testResolveIncomingSaveDir() => _resolveIncomingSaveDir();

  @visibleForTesting
  Future<void> testSaveIncomingFile(String fileId, String fileName, List<int> bytes) =>
      _saveIncomingFile(fileId, fileName, bytes);

  @visibleForTesting
  void testInjectIncomingSession(String fileId, Map<String, dynamic> session) {
    _incomingFiles[fileId] = session;
  }

  @visibleForTesting
  int testPruneStaleIncomingFiles(DateTime now) => _pruneStaleIncomingFiles(now);

  @visibleForTesting
  bool testHasIncomingSession(String fileId) => _incomingFiles.containsKey(fileId);

  @visibleForTesting
  void testInjectOffer(Map<String, dynamic> offer) {
    if (!_fileOfferController.isClosed) {
      _fileOfferController.add(offer);
    }
  }

  @visibleForTesting
  void testInjectProgress(Map<String, dynamic> progress) {
    if (!_fileProgressController.isClosed) {
      _fileProgressController.add(progress);
    }
  }
}

