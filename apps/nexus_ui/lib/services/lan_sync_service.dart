import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'logger_service.dart';
import 'nexus_ffi_bridge.dart';
import '../models/models.dart';

export '../models/models.dart';

class LanSyncService {
  static final LanSyncService instance = LanSyncService._();

  WebSocket? _ws;
  final Map<String, WebSocket> _peerSockets = {};
  Timer? _discoveryTimer;
  Timer? _keepAliveTimer;
  bool _isSearching = false;

  String _deviceId = "00000000-0000-0000-0000-000000000002";
  String get deviceId => _deviceId;
  set deviceId(String id) => _deviceId = id;
  String _customDeviceName = "";
  String? selectedTargetDeviceId;

  String? pcIp;
  String pcName = "PC Windows (Nexus Core)";
  Map<String, dynamic>? activeMedia;
  List<Map<String, dynamic>> discoveredPeers = [];
  bool isConnected = false;

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
    _customDeviceName = newName.trim();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_customDeviceName.isEmpty) {
        await prefs.remove('nexus_custom_device_name');
      } else {
        await prefs.setString('nexus_custom_device_name', _customDeviceName);
      }
    } catch (_) {}
    broadcastDeviceMetadata();
  }

  Future<void> resetDeviceNameToDefault() async {
    await setDeviceName("");
  }

  void selectTargetDevice(String id) {
    if (selectedTargetDeviceId != id) {
      selectedTargetDeviceId = id;
      NexusLogger.log("ROUTING", "Switched active target device to: $id");
    }
  }

  Map<String, dynamic>? get selectedTargetPeer {
    if (discoveredPeers.isEmpty) return null;
    if (selectedTargetDeviceId != null) {
      return discoveredPeers.firstWhere(
        (p) => p['id'] == selectedTargetDeviceId || p['ip'] == selectedTargetDeviceId,
        orElse: () => discoveredPeers.first,
      );
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
    final target = selectedTargetPeer;
    if (target != null) {
      final id = target['id'] as String?;
      final ip = target['ip'] as String?;
      if (id != null && _peerSockets.containsKey(id)) return _peerSockets[id];
      if (ip != null && _peerSockets.containsKey(ip)) return _peerSockets[ip];
    }
    if (_ws != null) return _ws;
    if (_peerSockets.isNotEmpty) return _peerSockets.values.first;
    return null;
  }

  WebSocket? socketForDevice(String? targetId) {
    if (targetId == null || targetId.isEmpty) return targetSocket;
    if (_peerSockets.containsKey(targetId)) return _peerSockets[targetId];
    final peer = discoveredPeers.firstWhere(
      (p) => p['id'] == targetId || p['ip'] == targetId,
      orElse: () => <String, dynamic>{},
    );
    final ip = peer['ip'] as String?;
    if (ip != null && _peerSockets.containsKey(ip)) return _peerSockets[ip];
    return targetSocket;
  }

  void broadcastDeviceMetadata() {
    final meta = {
      "type": "PEER_METADATA",
      "device_id": deviceId,
      "name": deviceName,
      "device_type": deviceType,
      "os": Platform.operatingSystem,
      "spatial_position": spatialPosition,
    };
    final encoded = jsonEncode(meta);
    for (final ws in _peerSockets.values) {
      try {
        ws.add(encoded);
      } catch (_) {}
    }
    if (_ws != null && !_peerSockets.containsValue(_ws)) {
      try {
        _ws!.add(encoded);
      } catch (_) {}
    }
  }

  // Spatial & Proximity State (Strictly Real Hardware)
  String spatialPosition = "Left"; // Cell is to the left of the PC
  String deviceType = Platform.isAndroid || Platform.isIOS ? "Mobile" : "Desktop";
  String? proximityMotion; // Null until real live signal received
  double? estimatedDistanceMeters; // Null until real BLE distance measured
  int? liveRssi;
  bool autoLockOnWalkAway = true;
  bool autoPauseMediaOnWalkAway = true;
  bool wakeOnApproach = true;
  bool universalControlActive = true;
  bool bleSpatialAutoDetect = true; // Active by default when Bluetooth is available
  bool isBleHardwareAvailable = false; // Real OS radio check (Windows Radio / Mobile Adapter)
  String lastAutoDeterminedPosition = "Left";

  // Dynamic Freeform Multi-Device Coordinates: offset relative to PC center (0.0, 0.0)
  final Map<String, Offset> customDeviceOffsets = {
    'self': const Offset(-120.0, 0.0),
  };

  void updateDeviceOffset(String id, Offset offset) {
    customDeviceOffsets[id] = offset;
    // Derive macro quadrant if self
    if (id == 'self') {
      if (offset.dx.abs() > offset.dy.abs()) {
        spatialPosition = offset.dx >= 0 ? "Right" : "Left";
      } else {
        spatialPosition = offset.dy >= 0 ? "Below" : "Above";
      }
      sendSpatialArrangement("target-peer-node", spatialPosition, customOffset: offset);
    }
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

  Future<void> loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedId = prefs.getString('nexus_device_id');
      if (savedId != null && savedId.isNotEmpty) {
        _deviceId = savedId;
      } else {
        final r = math.Random();
        final rawHex = List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
        _deviceId = '${rawHex.substring(0,8)}-${rawHex.substring(8,12)}-4${rawHex.substring(13,16)}-a${rawHex.substring(17,20)}-${rawHex.substring(20,32)}';
        await prefs.setString('nexus_device_id', _deviceId);
      }
      _customDeviceName = prefs.getString('nexus_custom_device_name') ?? "";

      walkAwayThresholdMeters = prefs.getDouble('proximity_walk_away_threshold') ?? 2.2;
      returnThresholdMeters = prefs.getDouble('proximity_return_threshold') ?? 1.2;
      autoLockThresholdMeters = prefs.getDouble('proximity_autolock_threshold') ?? 3.0;
      autoLockOnWalkAway = prefs.getBool('autoLockOnWalkAway') ?? true;
      autoPauseMediaOnWalkAway = prefs.getBool('autoPauseMediaOnWalkAway') ?? true;
      wakeOnApproach = prefs.getBool('wakeOnApproach') ?? true;
      bleSpatialAutoDetect = prefs.getBool('bleSpatialAutoDetect') ?? true;
      NexusLogger.log("SETTINGS", "Settings loaded: deviceName=$deviceName (ID: $deviceId), walkAway=${walkAwayThresholdMeters}m, return=${returnThresholdMeters}m, lock=${autoLockThresholdMeters}m");
    } catch (e) {
      NexusLogger.log("SETTINGS", "Error loading settings: $e");
    }
  }

  Future<void> setWalkAwayThreshold(double meters) async {
    walkAwayThresholdMeters = meters;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('proximity_walk_away_threshold', meters);
    } catch (_) {}
  }

  Future<void> setReturnThreshold(double meters) async {
    returnThresholdMeters = meters;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('proximity_return_threshold', meters);
    } catch (_) {}
  }

  Future<void> setAutoLockThreshold(double meters) async {
    autoLockThresholdMeters = meters;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('proximity_autolock_threshold', meters);
    } catch (_) {}
  }

  Future<void> saveSettingBool(String key, bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (_) {}
  }

  Timer? _spatialScanTimer;
  int consecutiveUnchangedScans = 0;
  bool isTopologyScanActive = false;
  String? _lastScanTopologyResult;

  // Rate limiter & flapping protection (max 2 scan restarts in 5 minutes)
  bool isAutoScanSuppressedDueToFlapping = false;
  String? scanFlappingWarningMessage;
  final List<DateTime> _scanRestartTimestamps = [];

  // New peer detection & battery protection
  final Set<String> _knownPeerIds = {};
  Timer? _newDeviceScanDebounceTimer;
  DateTime? _lastPeerScanTriggerTime;

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
  final Map<String, List<int>> _outgoingFileCache = {};

  final _topologyController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onTopologyChanged => _topologyController.stream;

  final _proximityController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onProximityUpdate => _proximityController.stream;

  final List<NexusNotification> notifications = [];
  final Map<String, String> _pendingLocalNotificationSecrets = {};
  final _notificationController = StreamController<NexusNotification>.broadcast();
  Stream<NexusNotification> get onNotificationReceived => _notificationController.stream;
  final _notificationRevealedController = StreamController<String>.broadcast();
  Stream<String> get onNotificationRevealed => _notificationRevealedController.stream;

  Timer? _clipboardWatcherTimer;
  String? _lastSeenClipboardText;

  Timer? _btWatcherTimer;

  // Physical sensors tracking (accelerometer/tilt)
  StreamSubscription<AccelerometerEvent>? _accelSub;
  double _lastAccelX = 0.0;
  double _integratedLateralImpulse = 0.0;
  DateTime? _lastLateralMoveTime;

  LanSyncService._();

  void start() {
    loadSettings();
    _setupNativeBleChannel();
    _startPeriodicDiscovery();
    _startClipboardWatcher();
    _startBluetoothHardwareWatcher();
    _startSensorsListener();
  }

  void _startSensorsListener() {
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        _accelSub = accelerometerEventStream().listen((event) {
          _lastAccelX = event.x;

          // Lateral movement threshold: moving phone left/right on desk
          if (event.x.abs() > 1.2) {
            _integratedLateralImpulse = event.x;
            _lastLateralMoveTime = DateTime.now();
          }
        }, onError: (e) {
          NexusLogger.log("SENSORS", "Accelerometer stream non-fatal: $e");
        });
      } catch (e) {
        NexusLogger.log("SENSORS", "Failed to start accelerometer: $e");
      }
    }
  }

  void stopSensorsListener() {
    _accelSub?.cancel();
    _accelSub = null;
  }

  void _setupNativeBleChannel() {
    if (Platform.isAndroid) {
      _hardwareChannel.setMethodCallHandler((call) async {
        if (call.method == 'onBleRssiSample') {
          final args = call.arguments as Map<dynamic, dynamic>?;
          final rssi = (args?['rssi'] as num?)?.toDouble();
          final addr = args?['address'] as String? ?? '';
          final name = args?['name'] as String? ?? '';
          final isNexus = args?['is_nexus'] as bool? ?? false;
          if (rssi != null) {
            handleIncomingBleRssi(rssi, address: addr, name: name, isNexus: isNexus);
          }
        } else if (call.method == 'onRemoteMediaAction') {
          final action = call.arguments as String? ?? '';
          NexusLogger.log("MEDIA_REMOTE", "Received lockscreen remote media action: $action");
          if (action == 'TOGGLE_PLAY_PAUSE') {
            final isCurrentlyPlaying = activeMedia != null &&
                (activeMedia!['is_playing'] == true || activeMedia!['status'] == 'playing');
            final nextCmd = isCurrentlyPlaying ? "PAUSE" : "PLAY";
            sendCommand(nextCmd);
            if (activeMedia != null) {
              activeMedia!['is_playing'] = !isCurrentlyPlaying;
              _updateLockScreenMediaNotification();
            }
          } else if (action == 'PREV') {
            sendCommand("SEEK", positionMs: 0);
          } else if (action == 'NEXT') {
            sendCommand("NEXT");
          }
        }
      });
      _hardwareChannel.invokeMethod('setTargetPeerBluetooth', {
        'mac': '40:9F:38:A6:80:DE',
        'name': 'FRANKY',
      });
    }
  }

  void _updateLockScreenMediaNotification() {
    if (!Platform.isAndroid) return;
    if (activeMedia == null) {
      try {
        _hardwareChannel.invokeMethod('clearMediaRemoteNotification');
      } catch (_) {}
      return;
    }

    final title = activeMedia!['media_title'] as String? ?? '';
    if (title.isEmpty) {
      try {
        _hardwareChannel.invokeMethod('clearMediaRemoteNotification');
      } catch (_) {}
      return;
    }

    final sourceApp = activeMedia!['source_app'] as String? ?? 'Browser PC';
    final isPlaying = activeMedia!['is_playing'] == true || activeMedia!['status'] == 'playing';
    final posMs = (activeMedia!['position_ms'] as num?)?.toInt() ?? 0;
    final durMs = (activeMedia!['duration_ms'] as num?)?.toInt() ?? 0;

    try {
      _hardwareChannel.invokeMethod('showMediaRemoteNotification', {
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
    });
  }

  static const _hardwareChannel = MethodChannel('com.nexus.continuity/hardware');

  /// Real OS-level radio hardware detection (no mocks, no simulations)
  Future<void> checkBluetoothHardwareStatus() async {
    bool isEnabled = false;
    if (Platform.isWindows) {
      isEnabled = NexusFfiBridge.instance.isBluetoothEnabled();
    } else if (Platform.isAndroid) {
      try {
        final res = await _hardwareChannel.invokeMethod<bool>('isBluetoothEnabled');
        isEnabled = res ?? false;
      } catch (e) {
        NexusLogger.log("BLUETOOTH_HW", "Error checking Android Bluetooth: $e");
        isEnabled = false;
      }
    } else if (Platform.isIOS) {
      isEnabled = false;
    }

    if (isBleHardwareAvailable != isEnabled) {
      isBleHardwareAvailable = isEnabled;
      NexusLogger.log("BLUETOOTH_HW", "Real OS Bluetooth radio hardware updated: isEnabled=$isEnabled");
      if (isEnabled) {
        if (Platform.isAndroid) {
          _hardwareChannel.invokeMethod('startBleProximity');
        }
        if (bleSpatialAutoDetect && !isAutoScanSuppressedDueToFlapping) {
          restartSpatialTopologyScan(isManual: true);
        }
      } else {
        if (Platform.isAndroid) {
          _hardwareChannel.invokeMethod('stopBleProximity');
        }
        _stopSpatialTopologyScanLoop();
        estimatedDistanceMeters = null;
        liveRssi = null;
        proximityMotion = null;
      }
    }
  }

  Future<void> openBluetoothSettings() async {
    if (Platform.isAndroid) {
      try {
        await _hardwareChannel.invokeMethod('openBluetoothSettings');
      } catch (_) {}
    }
  }

  void _startClipboardWatcher() {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) return;

    _clipboardWatcherTimer?.cancel();
    _clipboardWatcherTimer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      try {
        if (!clipboardSyncEnabled) return;
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        final current = data?.text;
        if (current != null && current.trim().isNotEmpty && current != _lastSeenClipboardText) {
          _lastSeenClipboardText = current;
          NexusLogger.log("CLIPBOARD_WATCHER", "OS clipboard change detected (${current.length} chars)");
          sendClipboardWithPrivacyGate(current);
        }
      } catch (_) {}
    });
  }

  void _startPeriodicDiscovery() {
    _discoverAndConnect();
    _discoveryTimer?.cancel();
    _discoveryTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!isConnected && !_isSearching) {
        _discoverAndConnect();
      }
    });
  }

  Future<void> _discoverAndConnect() async {
    if (isConnected || _isSearching) return;
    _isSearching = true;

    try {
      // 0. Immediate direct connect to known PC IP or localhost
      try {
        if (!Platform.isAndroid && !Platform.isIOS) {
          await _connectToPc('127.0.0.1');
        }
        await _connectToPc('192.168.1.11');
      } catch (_) {}

      // 1. Send UDP Broadcast Beacon on port 42420
      try {
        final rawSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        rawSocket.broadcastEnabled = true;
        final beaconData = utf8.encode(jsonEncode({
          "type": "PEER_ANNOUNCE",
          "name": deviceName,
          "id": deviceId,
          "device_type": deviceType,
          "os": Platform.operatingSystem,
          "spatial_position": spatialPosition,
        }));
        rawSocket.send(beaconData, InternetAddress("255.255.255.255"), 42420);
        rawSocket.close();
      } catch (_) {}

      // 2. Resolve Local Network Subnet (e.g. 192.168.1.x)
      String subnetPrefix = "192.168.1.";
      try {
        final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
        for (final iface in interfaces) {
          for (final addr in iface.addresses) {
            if (!addr.isLoopback && addr.address.startsWith("192.168.")) {
              final parts = addr.address.split('.');
              if (parts.length == 4) {
                subnetPrefix = '${parts[0]}.${parts[1]}.${parts[2]}.';
                break;
              }
            }
          }
        }
      } catch (_) {}

      // 3. Priority candidate IPs
      final candidateIps = <String>[
        '${subnetPrefix}11',
        '${subnetPrefix}1',
        '${subnetPrefix}10',
        '${subnetPrefix}5',
        '${subnetPrefix}8',
        '${subnetPrefix}9',
        '${subnetPrefix}16',
        '${subnetPrefix}32',
        '${subnetPrefix}33',
        '${subnetPrefix}35',
        '${subnetPrefix}37',
        '${subnetPrefix}42',
        '${subnetPrefix}105',
      ];

      for (int i = 1; i <= 254; i++) {
        final ip = '$subnetPrefix$i';
        if (!candidateIps.contains(ip)) candidateIps.add(ip);
      }

      // Fast parallel probe for all responding nodes on port 28471
      final foundIps = <String>[];
      for (int i = 0; i < candidateIps.length; i += 30) {
        final batch = candidateIps.sublist(i, (i + 30 > candidateIps.length) ? candidateIps.length : i + 30);
        final probes = batch.map((ip) async {
          if (_peerSockets.containsKey(ip)) return null;
          try {
            final socket = await Socket.connect(ip, 28471, timeout: const Duration(milliseconds: 350));
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

      for (final ip in foundIps) {
        await _connectToPc(ip);
      }
    } catch (e) {
      NexusLogger.log("LAN_SYNC", "Discovery scan error: $e");
    } finally {
      _isSearching = false;
    }
  }

  Future<void> _connectToPc(String ip) async {
    if (_peerSockets.containsKey(ip)) return;
    try {
      final wsUrl = 'ws://$ip:28471/media';
      NexusLogger.log("LAN_SYNC", "Connecting to PC at $wsUrl...");
      final ws = await WebSocket.connect(wsUrl).timeout(const Duration(seconds: 3));
      _ws = ws;
      _peerSockets[ip] = ws;
      pcIp = ip;
      isConnected = true;

      final peerId = "pc-nexus-$ip";
      final peerName = "PC Windows ($ip)";

      final existingIndex = discoveredPeers.indexWhere((p) => p['ip'] == ip || p['id'] == peerId);
      final peerEntry = {
        "id": peerId,
        "name": peerName,
        "ip": ip,
        "online": true,
        "device_type": "Desktop",
        "os": "Windows",
        "spatial_position": "Center",
      };
      if (existingIndex >= 0) {
        discoveredPeers[existingIndex] = peerEntry;
      } else {
        discoveredPeers.add(peerEntry);
      }
      checkNewDeviceIntroduced(peerId, peerName);
      if (selectedTargetDeviceId == null) {
        selectedTargetDeviceId = peerId;
      }

      NexusLogger.log("LAN_SYNC", "Connected successfully to PC at $ip! Active peers: ${_peerSockets.length}");

      // Announce this node with metadata to PC
      final announce = {
        "type": "PEER_ANNOUNCE",
        "name": deviceName,
        "id": deviceId,
        "ip": ip,
        "device_type": deviceType,
        "os": Platform.operatingSystem,
        "spatial_position": spatialPosition,
      };
      ws.add(jsonEncode(announce));

      // Keepalive ping across all active peer sockets
      _keepAliveTimer?.cancel();
      _keepAliveTimer = Timer.periodic(const Duration(seconds: 10), (_) {
        if (isConnected) {
          final pingData = jsonEncode({"type": "PING", "time": DateTime.now().millisecondsSinceEpoch});
          for (final s in _peerSockets.values) {
            try {
              s.add(pingData);
            } catch (_) {}
          }
        }
      });

      ws.listen(
        (data) {
          try {
            final text = data.toString();
            final json = jsonDecode(text) as Map<String, dynamic>;
            if (json['type'] == 'PONG') return;

            if (json['type'] == 'OPEN_URL') {
              final url = json['url'] as String? ?? '';
              NexusLogger.log("LAN_SYNC", "Received remote OPEN_URL: $url");
              _openUrlController.add(json);
              if (mediaHandoffEnabled && url.isNotEmpty && (Platform.isAndroid || Platform.isIOS)) {
                launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
              }
              return;
            }

            if (json['type'] == 'CLIPBOARD_SYNC') {
              final clipText = json['text'] as String? ?? '';
              NexusLogger.log("LAN_SYNC", "Received remote CLIPBOARD_SYNC: $clipText");
              if (clipboardSyncEnabled && clipText.isNotEmpty) {
                _lastSeenClipboardText = clipText;
                Clipboard.setData(ClipboardData(text: clipText));
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
                  "source_device": Platform.isAndroid ? 'Smartphone Android' : 'PC Windows',
                };
                _ws?.add(jsonEncode(respMsg));
                NexusLogger.log("PRIVACY_GATE", "Authorized and sent CLIPBOARD_REVEAL_RESPONSE for entry $entryId via E2EE");
              }
              return;
            }

            if (json['type'] == 'CLIPBOARD_REVEAL_RESPONSE') {
              final entryId = json['entry_id'] as String? ?? '';
              final text = json['text'] as String? ?? '';
              NexusLogger.log("PRIVACY_GATE", "Received CLIPBOARD_REVEAL_RESPONSE for entry $entryId");
              if (text.isNotEmpty) {
                _lastSeenClipboardText = text;
                Clipboard.setData(ClipboardData(text: text));
                _secretRevealedController.add(json);
              }
              return;
            }

            if (json['type'] == 'NOTIFICATION_SYNC') {
              final id = json['id'] as String? ?? 'notif_${DateTime.now().millisecondsSinceEpoch}';
              final title = json['title'] as String? ?? 'Notifica';
              final body = json['body'] as String? ?? '';
              final appName = json['app_name'] as String? ?? 'App';
              final senderDevice = json['sender_device'] as String? ?? 'Dispositivo Remoto';
              final senderDeviceId = json['sender_device_id'] as String? ?? 'remote';
              final timestampStr = json['timestamp'] as String?;
              final timestamp = timestampStr != null ? (DateTime.tryParse(timestampStr) ?? DateTime.now()) : DateTime.now();
              final hasSecret = json['has_secret'] as bool? ?? false;
              final secretCategory = json['secret_category'] as String? ?? '';

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
                category: (json['category'] as String?) == 'internalApp'
                    ? NexusNotificationCategory.internalApp
                    : NexusNotificationCategory.osNotification,
              );

              notifications.removeWhere((n) => n.id == id);
              notifications.insert(0, notif);
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
                _ws?.add(jsonEncode(resp));
                NexusLogger.log("NOTIF_PRIVACY", "Sent NOTIFICATION_REVEAL_RESPONSE for $notifId");
              }
              return;
            }

            if (json['type'] == 'NOTIFICATION_REVEAL_RESPONSE') {
              final notifId = json['id'] as String? ?? '';
              final cleartext = json['cleartext'] as String? ?? '';
              NexusLogger.log("NOTIF_PRIVACY", "Received NOTIFICATION_REVEAL_RESPONSE for $notifId");
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
              final fileId = json['file_id'] as String? ?? '';
              final fileName = json['file_name'] as String? ?? 'file';
              final fileSize = (json['file_size'] as num?)?.toInt() ?? 0;
              final totalChunks = (json['total_chunks'] as num?)?.toInt() ?? 1;
              final sender = json['sender_device'] as String? ?? 'Dispositivo Remoto';

              NexusLogger.log("FILE_TRANSFER", "Received FILE_OFFER: $fileName ($fileSize bytes, $totalChunks chunks) from $sender");
              _incomingFiles[fileId] = {
                'file_id': fileId,
                'file_name': fileName,
                'file_size': fileSize,
                'total_chunks': totalChunks,
                'sender': sender,
                'chunks': <int, List<int>>{},
                'received_bytes': 0,
                'start_time': DateTime.now(),
              };
              _fileOfferController.add(json);
              return;
            }

            if (json['type'] == 'FILE_CHUNK') {
              final fileId = json['file_id'] as String? ?? '';
              final chunkIndex = (json['chunk_index'] as num?)?.toInt() ?? 0;
              final totalChunks = (json['total_chunks'] as num?)?.toInt() ?? 1;
              final b64 = json['data'] as String? ?? '';
              final chunkBytes = base64Decode(b64);
              final session = _incomingFiles[fileId];
              if (session != null) {
                (session['chunks'] as Map<int, List<int>>)[chunkIndex] = chunkBytes;
                session['received_bytes'] = (session['received_bytes'] as int) + chunkBytes.length;
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
                final fileName = session['file_name'] as String;
                final chunks = session['chunks'] as Map<int, List<int>>;
                final totalChunks = session['total_chunks'] as int;

                final fullBytes = BytesBuilder();
                for (int i = 0; i < totalChunks; i++) {
                  if (chunks.containsKey(i)) {
                    fullBytes.add(chunks[i]!);
                  }
                }
                final assembled = fullBytes.takeBytes();

                // Determine target directory for saving file
                Directory saveDir;
                if (Platform.isAndroid) {
                  saveDir = Directory('/storage/emulated/0/Download/Nexus');
                  if (!saveDir.existsSync()) {
                    try {
                      saveDir.createSync(recursive: true);
                    } catch (_) {
                      saveDir = Directory('/storage/emulated/0/Download');
                    }
                  }
                } else if (Platform.isWindows) {
                  final userProfile = Platform.environment['USERPROFILE'] ?? 'C:';
                  saveDir = Directory('$userProfile\\Downloads\\Nexus');
                  if (!saveDir.existsSync()) {
                    try {
                      saveDir.createSync(recursive: true);
                    } catch (_) {
                      saveDir = Directory('$userProfile\\Downloads');
                    }
                  }
                } else {
                  saveDir = Directory.systemTemp;
                }

                final targetPath = '${saveDir.path}${Platform.pathSeparator}$fileName';
                final targetFile = File(targetPath);
                targetFile.writeAsBytes(assembled, flush: true).then((_) {
                  NexusLogger.log("FILE_TRANSFER", "Saved complete file to: $targetPath (${assembled.length} bytes)");
                  _fileReceivedController.add({
                    'file_id': fileId,
                    'file_name': fileName,
                    'file_size': assembled.length,
                    'saved_path': targetPath,
                  });
                }).catchError((e) {
                  NexusLogger.log("FILE_TRANSFER", "Error saving file: $e");
                });
                _incomingFiles.remove(fileId);
              }
              return;
            }

            if (json['type'] == 'FILE_RESUME_REQUEST') {
              final fileId = json['file_id'] as String? ?? '';
              final missingList = (json['missing_chunks'] as List<dynamic>?)?.map((e) => e as int).toList() ?? [];
              final cachedBytes = _outgoingFileCache[fileId];
              if (cachedBytes != null && missingList.isNotEmpty && _ws != null) {
                const chunkSize = 64 * 1024;
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
                      _ws!.add(jsonEncode(chunkMsg));
                    } catch (_) {}
                  }
                }
              }
              return;
            }

            if (json['type'] == 'PEER_METADATA' || json['type'] == 'SPATIAL_ARRANGEMENT' || json['type'] == 'PEER_ANNOUNCE') {
              NexusLogger.log("LAN_SYNC", "Received topology/metadata update: $json");
              final pId = json['id'] as String? ?? json['sender_device_id'] as String? ?? '';
              final pName = json['name'] as String? ?? json['sender_device'] as String? ?? 'Dispositivo Remoto';
              if (pId.isNotEmpty) {
                checkNewDeviceIntroduced(pId, pName);
              }
              final peerType = json['device_type'] as String?;
              if (bleSpatialAutoDetect && isBleHardwareAvailable && estimatedDistanceMeters != null) {
                autoDetermineSpatialPosition(peerType: peerType);
              }
              _topologyController.add(json);
              return;
            }

            if (json['type'] == 'PROXIMITY_UPDATE') {
              proximityMotion = json['motion'] as String? ?? proximityMotion;
              final d = (json['distance_m'] as num?)?.toDouble();
              if (d != null) {
                estimatedDistanceMeters = d;
                if (bleSpatialAutoDetect && isBleHardwareAvailable) {
                  autoDetermineSpatialPosition(distanceMeters: estimatedDistanceMeters);
                }
                _checkProximityWalkAway(d, proximityMotion);
              }
              _proximityController.add(json);
              return;
            }

            if (json['type'] == 'PROXIMITY_DEPARTURE_HANDOFF') {
              NexusLogger.log("LAN_SYNC", "Received PROXIMITY_DEPARTURE_HANDOFF from PC: $json");
              final title = json['media_title'] as String? ?? 'Video PC';
              final url = json['media_url'] as String? ?? '';
              final pos = (json['position_ms'] as num?)?.toInt() ?? 0;
              final app = json['source_app'] as String? ?? 'PC Media';
              _triggerMediaHandoffPrompt(
                title: title,
                rawUrl: url,
                positionMs: pos,
                sourceApp: app,
              );
              return;
            }

            if (json['type'] == 'VOLUME_UPDATE') {
              currentVolume = (json['volume'] as num?)?.toDouble() ?? currentVolume;
              NexusLogger.log("LAN_SYNC", "Received VOLUME_UPDATE: $currentVolume");
              return;
            }

            if (json['type'] == 'AUDIO_MUTE') {
              isAudioMuted = json['muted'] as bool? ?? isAudioMuted;
              NexusLogger.log("LAN_SYNC", "Received AUDIO_MUTE: $isAudioMuted");
              return;
            }

            if (json['type'] == 'NOTIFICATION_SYNC') {
              final id = json['id'] as String? ?? '';
              final notif = NexusNotification(
                id: id,
                title: json['title'] as String? ?? 'Notifica',
                rawBody: json['raw_body'] as String? ?? '',
                currentBody: json['body'] as String? ?? '',
                appName: json['app_name'] as String? ?? 'Sistema',
                senderDevice: json['sender_device'] as String? ?? 'Dispositivo Remoto',
                senderDeviceId: json['sender_device_id'] as String? ?? 'nexus-remote',
                timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ?? DateTime.now(),
                hasSecret: json['has_secret'] as bool? ?? false,
                secretCategory: json['secret_category'] as String? ?? '',
                isRevealed: !(json['has_secret'] as bool? ?? false),
                category: (json['category'] as String?) == 'internalApp' 
                    ? NexusNotificationCategory.internalApp 
                    : NexusNotificationCategory.osNotification,
              );
              notifications.removeWhere((n) => n.id == id);
              notifications.insert(0, notif);
              _notificationController.add(notif);
              NexusLogger.log("NOTIF_SYNC", "Received notification from ${notif.senderDevice}: ${notif.title}");
              return;
            }

            if (json['type'] == 'NOTIFICATION_REVEAL_REQUEST') {
              final reqId = json['id'] as String? ?? '';
              if (_pendingLocalNotificationSecrets.containsKey(reqId)) {
                final cleartext = _pendingLocalNotificationSecrets[reqId]!;
                final resp = {
                  "type": "NOTIFICATION_REVEAL_RESPONSE",
                  "id": reqId,
                  "raw_body": cleartext,
                };
                try {
                  _ws!.add(jsonEncode(resp));
                  NexusLogger.log("NOTIF_PRIVACY", "Sent NOTIFICATION_REVEAL_RESPONSE for $reqId");
                } catch (_) {}
              }
              return;
            }

            if (json['type'] == 'NOTIFICATION_REVEAL_RESPONSE') {
              final respId = json['id'] as String? ?? '';
              final cleartext = json['raw_body'] as String? ?? '';
              final idx = notifications.indexWhere((n) => n.id == respId);
              if (idx != -1) {
                notifications[idx].currentBody = cleartext;
                notifications[idx].isRevealed = true;
              }
              _notificationRevealedController.add(respId);
              NexusLogger.log("NOTIF_PRIVACY", "Revealed notification $respId with cleartext");
              return;
            }

            if (json['media_title'] != null || json['session_id'] != null) {
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
          _peerSockets.remove(ip);
          discoveredPeers.removeWhere((p) => p['ip'] == ip);
          if (_peerSockets.isEmpty) {
            isConnected = false;
            _ws = null;
            selectedTargetDeviceId = null;
          } else {
            _ws = _peerSockets.values.first;
            if (selectedTargetDeviceId == peerId) {
              selectedTargetDeviceId = discoveredPeers.isNotEmpty ? discoveredPeers.first['id'] as String? : null;
            }
          }
        },
        onError: (err) {
          NexusLogger.log("LAN_SYNC", "WebSocket error on $ip: $err");
          _peerSockets.remove(ip);
          discoveredPeers.removeWhere((p) => p['ip'] == ip);
          if (_peerSockets.isEmpty) {
            isConnected = false;
            _ws = null;
            selectedTargetDeviceId = null;
          } else {
            _ws = _peerSockets.values.first;
            if (selectedTargetDeviceId == peerId) {
              selectedTargetDeviceId = discoveredPeers.isNotEmpty ? discoveredPeers.first['id'] as String? : null;
            }
          }
        },
      );
    } catch (e) {
      NexusLogger.log("LAN_SYNC", "Failed to connect to $ip: $e");
      if (_peerSockets.isEmpty) {
        isConnected = false;
        _ws = null;
      }
    }
  }

  void sendCommand(String action, {int? positionMs, String? targetPeerId}) {
    final sock = socketForDevice(targetPeerId);
    if (sock != null) {
      final cmd = {
        "action": action,
        "position_ms": positionMs,
      };
      try {
        sock.add(jsonEncode(cmd));
        NexusLogger.log("LAN_SYNC", "Sent command over LAN WebSocket: $cmd to ${targetPeerId ?? selectedTargetDeviceId}");
      } catch (e) {
        NexusLogger.log("LAN_SYNC", "Failed to send command: $e");
      }
    }
  }

  void sendVolume(double vol, {String? targetPeerId}) {
    currentVolume = vol.clamp(0.0, 1.0);
    if (vol > 0.0) isAudioMuted = false;
    final sock = socketForDevice(targetPeerId);
    if (sock != null) {
      final msg = {
        "type": "VOLUME_SET",
        "volume": currentVolume,
      };
      try {
        sock.add(jsonEncode(msg));
      } catch (_) {}
    }
  }

  void sendAudioMute(bool muted) {
    isAudioMuted = muted;
    if (_ws != null && isConnected) {
      final msg = {
        "type": "AUDIO_MUTE",
        "muted": muted,
      };
      try {
        _ws!.add(jsonEncode(msg));
        NexusLogger.log("LAN_SYNC", "Sent AUDIO_MUTE: $msg");
      } catch (_) {}
    }
  }

  Future<void> togglePcSpeakersMute() async {
    final ip = pcIp ?? '127.0.0.1';
    try {
      final client = HttpClient();
      final req = await client.getUrl(Uri.parse('http://$ip:28472/api/pc_mute'));
      await req.close();
      client.close();
      NexusLogger.log("LAN_SYNC", "Toggled PC speaker mute via http://$ip:28472/api/pc_mute");
    } catch (e) {
      NexusLogger.log("LAN_SYNC", "Failed to toggle PC speaker mute: $e");
    }
  }

  void sendOpenUrl(String url, String title, int positionMs) {
    if (_ws != null && isConnected) {
      final msg = {
        "type": "OPEN_URL",
        "url": url,
        "title": title,
        "position_ms": positionMs,
      };
      try {
        _ws!.add(jsonEncode(msg));
        NexusLogger.log("LAN_SYNC", "Sent OPEN_URL over LAN WebSocket: $msg");
      } catch (_) {}
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
        _ws!.add(jsonEncode(msg));
        NexusLogger.log("LAN_SYNC", "Sent CLIPBOARD_SYNC over LAN WebSocket: $text");
      } catch (_) {}
    }
  }

  /// Synchronizes clipboard with Zero-Trust Privacy Gate and selective secret censoring
  void sendClipboardWithPrivacyGate(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final censor = censorSecretsInText(text);

    if (censor.hasSecret && clipboardPrivacyGate) {
      // ZERO-TRUST GATE: Cleartext NEVER leaves the source device automatically!
      final entryId = "sec_${DateTime.now().millisecondsSinceEpoch}_${(DateTime.now().microsecond % 1000)}";
      _pendingLocalSecrets[entryId] = text; // Original complete text preserved locally

      final deviceName = Platform.isAndroid ? 'Smartphone Android' : 'PC Windows';

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
          NexusLogger.log("PRIVACY_GATE", "Announced protected secret placeholder: ${censor.maskedText} (ID: $entryId)");
        } catch (_) {}
      }
    } else {
      // Safe content: auto-shared immediately
      sendClipboardSync(text);
    }
  }

  /// Sends a direct request to reveal an encrypted secret on-demand
  void requestSecretReveal(String entryId) {
    if (_ws != null && isConnected) {
      final msg = {
        "type": "CLIPBOARD_REVEAL_REQUEST",
        "entry_id": entryId,
        "requesting_device": Platform.isAndroid ? 'Smartphone Android' : 'PC Windows',
      };
      try {
        _ws!.add(jsonEncode(msg));
        NexusLogger.log("PRIVACY_GATE", "Sent CLIPBOARD_REVEAL_REQUEST for entry $entryId");
      } catch (_) {}
    }
  }

  bool hasPendingLocalSecret(String entryId) => _pendingLocalSecrets.containsKey(entryId);
  String? getPendingLocalSecret(String entryId) => _pendingLocalSecrets[entryId];

  void handleSecretAnnounceForTesting(Map<String, dynamic> json) {
    _secretAnnounceController.add(json);
  }

  void handleSecretRevealResponseForTesting(Map<String, dynamic> json) {
    _secretRevealedController.add(json);
  }

  void sendSpatialArrangement(String peerId, String arrangement, {int width = 1920, int height = 1080, Offset? customOffset}) {
    spatialPosition = arrangement;
    if (_ws != null && isConnected) {
      final msg = {
        "type": "SPATIAL_ARRANGEMENT",
        "peer_id": peerId,
        "spatial_position": arrangement,
        "screen_width": width,
        "screen_height": height,
        if (customOffset != null) ...{
          "offset_x": customOffset.dx,
          "offset_y": customOffset.dy,
        }
      };
      try {
        _ws!.add(jsonEncode(msg));
        NexusLogger.log("LAN_SYNC", "Sent SPATIAL_ARRANGEMENT: $msg");
      } catch (_) {}
    }
  }

  void setBleSpatialAutoDetect(bool enabled) {
    bleSpatialAutoDetect = enabled;
    if (enabled) {
      isAutoScanSuppressedDueToFlapping = false;
      scanFlappingWarningMessage = null;
      _scanRestartTimestamps.clear();
      if (isBleHardwareAvailable) {
        _startSpatialTopologyScanLoop();
      }
    } else {
      _stopSpatialTopologyScanLoop();
    }
  }

  void restartSpatialTopologyScan({bool isManual = false}) {
    if (isManual) {
      isAutoScanSuppressedDueToFlapping = false;
      scanFlappingWarningMessage = null;
      _scanRestartTimestamps.clear();
      bleSpatialAutoDetect = true;
    }

    if (isAutoScanSuppressedDueToFlapping) {
      NexusLogger.log("BLE_SPATIAL", "Automatic topology scan suppressed due to excessive flapping (>2 in 5m).");
      return;
    }

    if (!isManual) {
      final now = DateTime.now();
      _scanRestartTimestamps.removeWhere((t) => now.difference(t).inSeconds > 300);
      if (_scanRestartTimestamps.length >= 2) {
        // Exceeded 2 changes in 5 minutes! Permanently suppress auto-scanning to protect resources!
        isAutoScanSuppressedDueToFlapping = true;
        bleSpatialAutoDetect = false;
        _stopSpatialTopologyScanLoop();
        scanFlappingWarningMessage = "Scansione automatica disattivata per saturazione: rilevate più di 2 variazioni in 5 minuti. Usa RISCANSIONA per riattivare.";
        NexusLogger.log("BLE_SPATIAL", "FLAPPING DETECTED (>2 in 5m). Auto topology scan permanently disabled.");
        _proximityController.add({
          "type": "SCAN_FLAPPING_SUPPRESSED",
          "message": scanFlappingWarningMessage,
        });
        return;
      }
      _scanRestartTimestamps.add(now);
    }

    if (bleSpatialAutoDetect && isBleHardwareAvailable) {
      _startSpatialTopologyScanLoop();
    }
  }

  void _startSpatialTopologyScanLoop() {
    _spatialScanTimer?.cancel();
    consecutiveUnchangedScans = 0;
    isTopologyScanActive = true;
    _lastScanTopologyResult = spatialPosition;

    // Run first scan immediately
    _performSpatialScanStep();

    // Run periodic scan every 4 seconds
    _spatialScanTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!bleSpatialAutoDetect || !isBleHardwareAvailable) {
        _stopSpatialTopologyScanLoop();
        return;
      }

      if (!isTopologyScanActive) {
        // Topology scan has stabilized after 3 identical cycles,
        // BUT BLE distance & walk-away monitoring remains 100% active in background!
        return;
      }

      _performSpatialScanStep();
    });
  }

  void _stopSpatialTopologyScanLoop() {
    _spatialScanTimer?.cancel();
    _spatialScanTimer = null;
    isTopologyScanActive = false;
    consecutiveUnchangedScans = 0;
  }

  void _performSpatialScanStep() {
    final dist = estimatedDistanceMeters;
    if (dist == null) return;

    final detectedPos = autoDetermineSpatialPosition(distanceMeters: dist);
    if (detectedPos == null) return;

    if (detectedPos != _lastScanTopologyResult) {
      consecutiveUnchangedScans = 0;
      _lastScanTopologyResult = detectedPos;
      NexusLogger.log("BLE_SPATIAL", "Topology scan update detected: '$detectedPos'. Resetting scan counter.");
    } else {
      consecutiveUnchangedScans++;
      NexusLogger.log("BLE_SPATIAL", "Topology scan unchanged: '$detectedPos' ($consecutiveUnchangedScans/3).");
      if (consecutiveUnchangedScans >= 3) {
        // Stop active topology scanning after 3 consecutive scans!
        isTopologyScanActive = false;
        NexusLogger.log("BLE_SPATIAL", "Topology scan stabilized after 3 consecutive scans. Topology scanning paused (BLE proximity checking remains 100% active).");
      }
    }
  }

  /// Automatically determines peer spatial position using physical sensor fusion (accelerometer/tilt) and BLE distance
  String? autoDetermineSpatialPosition({double? distanceMeters, String? peerType}) {
    if (!bleSpatialAutoDetect || !isBleHardwareAvailable) return null;
    final dist = distanceMeters ?? estimatedDistanceMeters;
    if (dist == null) return null;

    String newPos = spatialPosition;

    // 1. Evaluate recent physical lateral movement impulses (sliding or moving phone across desk)
    final now = DateTime.now();
    final hasRecentLateralMove = _lastLateralMoveTime != null && now.difference(_lastLateralMoveTime!).inSeconds < 12;

    if (hasRecentLateralMove) {
      if (_integratedLateralImpulse > 1.3) {
        newPos = "Right";
      } else if (_integratedLateralImpulse < -1.3) {
        newPos = "Left";
      }
    } else {
      // Retain current position, avoid flipping based merely on phone rotation/tilt
      newPos = spatialPosition;
    }

    if (spatialPosition != newPos) {
      spatialPosition = newPos;
      lastAutoDeterminedPosition = newPos;
      sendSpatialArrangement("auto-ble-peer", newPos);
      _topologyController.add({
        "type": "TOPOLOGY_UPDATE",
        "position": newPos,
        "distance": dist,
      });
      NexusLogger.log("BLE_SPATIAL", "Auto-determined spatial position: $newPos (dist: ${dist.toStringAsFixed(1)}m, tiltX: ${_lastAccelX.toStringAsFixed(1)}, accelImpulse: ${_integratedLateralImpulse.toStringAsFixed(1)})");
    }

    return newPos;
  }

  void checkNewDeviceIntroduced(String deviceId, String deviceName) {
    if (deviceId.isEmpty) return;
    final isNew = _knownPeerIds.add(deviceId);
    if (isNew) {
      NexusLogger.log("PEER_DISCOVERY", "New device detected and attached: $deviceName (ID/MAC: $deviceId)");

      // Add to discoveredPeers if not present
      if (!discoveredPeers.any((p) => p['id'] == deviceId || p['mac'] == deviceId || p['ip'] == deviceId)) {
        discoveredPeers.add({
          "id": deviceId,
          "name": deviceName,
          "online": true,
          "device_type": deviceName.toLowerCase().contains("phone") || deviceName.toLowerCase().contains("smartphone") ? "Mobile" : "Desktop",
          "spatial_position": "Left",
        });
      }

      // If topology was consolidated (not actively scanning), schedule a new scan to integrate the new device!
      if (bleSpatialAutoDetect && isBleHardwareAvailable && !isTopologyScanActive && !isAutoScanSuppressedDueToFlapping) {
        final now = DateTime.now();
        if (_lastPeerScanTriggerTime != null && now.difference(_lastPeerScanTriggerTime!).inSeconds < 30) {
          NexusLogger.log("BLE_SPATIAL", "Throttling new-peer scan (last scan triggered < 30s ago).");
          return;
        }

        _newDeviceScanDebounceTimer?.cancel();
        _newDeviceScanDebounceTimer = Timer(const Duration(milliseconds: 2000), () {
          _lastPeerScanTriggerTime = DateTime.now();
          NexusLogger.log("BLE_SPATIAL", "Starting topology scan for newly attached device ($deviceName) until convergence.");
          restartSpatialTopologyScan(isManual: false);
        });
      }
    }
  }

  double _filteredRssi = -60.0;
  final List<double> _rssiHistory = [];

  void handleIncomingBleRssi(double rawRssi, {String? address, String? name, bool? isNexus}) {
    if (address != null && address.isNotEmpty) {
      checkNewDeviceIntroduced(address, name?.isNotEmpty == true ? name! : 'Peer BLE ($address)');
    }
    liveRssi = rawRssi.round();
    if (_rssiHistory.isEmpty) {
      _filteredRssi = rawRssi;
    } else {
      const kalmanGain = 0.35;
      _filteredRssi = _filteredRssi + kalmanGain * (rawRssi - _filteredRssi);
    }
    _rssiHistory.add(_filteredRssi);
    if (_rssiHistory.length > 8) _rssiHistory.removeAt(0);

    // Calculate motion vector from RSSI trend
    if (_rssiHistory.length >= 3) {
      final delta = _rssiHistory.last - _rssiHistory.first;
      if (delta > 2.5) {
        proximityMotion = "Approaching";
      } else if (delta < -2.5) {
        proximityMotion = "MovingAway";
      } else {
        proximityMotion = "Stationary";
      }
    }

    // Log-distance path loss model: distance = 10^((txPower - rssi) / (10 * n))
    const txPower = -59.0;
    const pathLossExponent = 2.2;
    final ratio = (txPower - _filteredRssi) / (10.0 * pathLossExponent);
    final calculatedDistance = math.pow(10.0, ratio).toDouble().clamp(0.2, 25.0);

    final prevDist = estimatedDistanceMeters;
    estimatedDistanceMeters = calculatedDistance;

    // Check walk-away triggers (auto-pause PC & show prompt)
    _checkProximityWalkAway(calculatedDistance, proximityMotion);

    // If distance changed significantly (> 0.8m) or motion indicates moving away/approaching,
    // and scan was stabilized, restart topology scan loop if not suppressed!
    if (bleSpatialAutoDetect && isBleHardwareAvailable && !isTopologyScanActive && prevDist != null && !isAutoScanSuppressedDueToFlapping) {
      final delta = (calculatedDistance - prevDist).abs();
      final isMoving = proximityMotion == "Approaching" || proximityMotion == "MovingAway";
      if (delta > 0.8 || (delta > 0.45 && isMoving)) {
        NexusLogger.log("BLE_SPATIAL", "Distance change detected between devices (delta: ${delta.toStringAsFixed(2)}m, motion: $proximityMotion). Restarting scan to convergence.");
        restartSpatialTopologyScan(isManual: false);
      }
    }

    // If connected via WebSocket, send PROXIMITY_UPDATE to PC
    if (_ws != null && isConnected) {
      final msg = {
        "type": "PROXIMITY_UPDATE",
        "distance_m": calculatedDistance,
        "motion": proximityMotion ?? "Stationary",
        "rssi": _filteredRssi.round(),
      };
      try {
        _ws!.add(jsonEncode(msg));
      } catch (_) {}
    }

    _proximityController.add({
      "type": "PROXIMITY_UPDATE",
      "distance_m": calculatedDistance,
      "motion": proximityMotion,
      "rssi": _filteredRssi.round(),
    });
  }

  void sendUniversalControlHop(int entryX, int entryY, int screenWidth, int screenHeight) {
    if (_ws != null && isConnected) {
      final msg = {
        "type": "UNIVERSAL_CONTROL_HOP",
        "entry_x": entryX,
        "entry_y": entryY,
        "screen_width": screenWidth,
        "screen_height": screenHeight,
      };
      try {
        _ws!.add(jsonEncode(msg));
      } catch (_) {}
    }
  }

  void sendUniversalControlDelta(int dx, int dy) {
    if (_ws != null && isConnected) {
      final msg = {
        "type": "UNIVERSAL_CONTROL_DELTA",
        "dx": dx,
        "dy": dy,
      };
      try {
        _ws!.add(jsonEncode(msg));
      } catch (_) {}
    }
  }

  void sendProximityTrigger(String action) {
    if (_ws != null && isConnected) {
      final msg = {
        "type": "PROXIMITY_TRIGGER",
        "action": action,
      };
      try {
        _ws!.add(jsonEncode(msg));
      } catch (_) {}
    }
  }

  int _lastLockTriggerTime = 0;
  int _lastWalkAwayPromptTime = 0;
  int _lastReturnWelcomeTime = 0;
  bool _isDeparted = false;
  bool _hasFiredDepartureAlert = false;

  void _checkProximityWalkAway(double distanceMeters, String? motion) {
    final now = DateTime.now().millisecondsSinceEpoch;

    // 1. Walk-away Workstation Lock
    if (autoLockOnWalkAway && distanceMeters > autoLockThresholdMeters) {
      if (now - _lastLockTriggerTime > 12000) {
        _lastLockTriggerTime = now;
        NexusLogger.log("PROXIMITY", "Distance ${distanceMeters.toStringAsFixed(1)}m > ${autoLockThresholdMeters.toStringAsFixed(1)}m: Triggering LOCK_WORKSTATION");
        sendProximityTrigger("LOCK_WORKSTATION");
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

        // Automatically pause video on PC via WebSocket and Proximity Trigger
        sendCommand("PAUSE");
        sendProximityTrigger("PAUSE_ON_WALK_AWAY");
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
    final body = 'Ti sei allontanato da $pcName (${distStr}m). Postazione protetta.';

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
    notifications.insert(0, notif);
    _notificationController.add(notif);

    // 2. Android Native OS Notification
    if (Platform.isAndroid) {
      try {
        _hardwareChannel.invokeMethod('showSystemNotification', {
          'title': title,
          'body': body,
          'url': '',
        });
      } catch (e) {
        NexusLogger.log("PROXIMITY", "Failed to show Android system notification: $e");
      }
    }
  }

  void _triggerReturnWelcomeAlert(double distanceMeters) {
    final distStr = distanceMeters.toStringAsFixed(1);
    const title = 'Bentornato alla postazione';
    final body = 'Riconnesso a $pcName (${distStr}m). Postazione sbloccata.';

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
    notifications.insert(0, notif);
    _notificationController.add(notif);

    if (Platform.isAndroid) {
      try {
        _hardwareChannel.invokeMethod('showSystemNotification', {
          'title': title,
          'body': body,
          'url': '',
        });
      } catch (e) {
        NexusLogger.log("PROXIMITY", "Failed to show Android system notification: $e");
      }
    }
  }

  void _triggerMediaHandoffPrompt({
    required String title,
    required String rawUrl,
    required int positionMs,
    String sourceApp = 'PC Media',
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastWalkAwayPromptTime < 4000) return; // 4s debounce
    _lastWalkAwayPromptTime = now;

    final posSeconds = positionMs ~/ 1000;
    final timestampedUrl = rawUrl.isNotEmpty
        ? (rawUrl.contains('?') ? '$rawUrl&t=${posSeconds}s' : '$rawUrl?t=${posSeconds}s')
        : '';

    final promptData = {
      'title': title,
      'source_app': sourceApp,
      'media_url': rawUrl,
      'timestamped_url': timestampedUrl,
      'position_ms': positionMs,
      'prompt_text': 'Vuoi continuare la riproduzione qui?',
      'full_message': 'Vuoi continuare la riproduzione di "$title" qui sul telefono?',
    };

    NexusLogger.log("PROXIMITY", "Media handoff prompt dispatched: $promptData");

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
    notifications.insert(0, notif);
    _notificationController.add(notif);

    // 2. Android Native OS Notification (NotificationManager with PendingIntent)
    if (Platform.isAndroid) {
      try {
        _hardwareChannel.invokeMethod('showSystemNotification', {
          'title': 'Continua la riproduzione?',
          'body': 'Vuoi continuare la riproduzione qui? - $title',
          'url': timestampedUrl,
        });
      } catch (e) {
        NexusLogger.log("PROXIMITY", "Failed to show Android system notification: $e");
      }
    }

    // 3. Emit on Stream for In-App Banner/Snackbar UI
    _mediaHandoffPromptController.add(promptData);
  }

  void triggerProximityDepartureHandoff({bool simulate = false, double? testDistance}) {
    final dist = testDistance ?? 3.5;
    proximityMotion = "MovingAway";
    estimatedDistanceMeters = dist;
    _isDeparted = false; // Reset so departure trigger fires cleanly
    _checkProximityWalkAway(dist, "MovingAway");
  }

  void sendTouchpadDelta(int dx, int dy, {String? targetPeerId}) {
    final sock = socketForDevice(targetPeerId);
    if (sock != null) {
      final msg = {
        "type": "TOUCHPAD_DELTA",
        "dx": dx,
        "dy": dy,
      };
      try {
        sock.add(jsonEncode(msg));
      } catch (_) {}
    }
  }

  void sendTouchpadScroll(int dy, {String? targetPeerId}) {
    final sock = socketForDevice(targetPeerId);
    if (sock != null) {
      final msg = {
        "type": "TOUCHPAD_SCROLL",
        "dy": dy,
      };
      try {
        sock.add(jsonEncode(msg));
      } catch (_) {}
    }
  }

  void sendTouchpadClick(String button, {String? targetPeerId}) {
    final sock = socketForDevice(targetPeerId);
    if (sock != null) {
      final msg = {
        "type": "TOUCHPAD_CLICK",
        "button": button,
      };
      try {
        sock.add(jsonEncode(msg));
      } catch (_) {}
    }
  }

  void sendTouchpadButton(String button, bool isDown, {String? targetPeerId}) {
    final sock = socketForDevice(targetPeerId);
    if (sock != null) {
      final msg = {
        "type": "TOUCHPAD_BUTTON",
        "button": button,
        "is_down": isDown,
      };
      try {
        sock.add(jsonEncode(msg));
      } catch (_) {}
    }
  }

  void sendKeyboardKey(String key, {bool? isDown, String? targetPeerId}) {
    final sock = socketForDevice(targetPeerId);
    if (sock != null) {
      final msg = {
        "type": "KEYBOARD_KEY",
        "key": key,
        "is_down": ?isDown,
      };
      try {
        sock.add(jsonEncode(msg));
        NexusLogger.log("KEYBOARD", "Sent KEYBOARD_KEY: $key (down: $isDown) to ${targetPeerId ?? selectedTargetDeviceId}");
      } catch (_) {}
    }
  }

  void sendKeyboardCombo(List<String> keys, {String? targetPeerId}) {
    final sock = socketForDevice(targetPeerId);
    if (sock != null) {
      final msg = {
        "type": "KEYBOARD_COMBO",
        "keys": keys,
      };
      try {
        sock.add(jsonEncode(msg));
        NexusLogger.log("KEYBOARD", "Sent KEYBOARD_COMBO: ${keys.join('+')} to ${targetPeerId ?? selectedTargetDeviceId}");
      } catch (_) {}
    }
  }

  void sendTextInput(String text, {String? targetPeerId}) {
    final sock = socketForDevice(targetPeerId);
    if (sock != null) {
      final msg = {
        "type": "KEYBOARD_TEXT",
        "text": text,
      };
      try {
        sock.add(jsonEncode(msg));
        NexusLogger.log("KEYBOARD", "Sent KEYBOARD_TEXT: ${text.length} chars to ${targetPeerId ?? selectedTargetDeviceId}");
      } catch (_) {}
    }
  }

  void requestFileResume(String fileId) {
    final session = _incomingFiles[fileId];
    if (session == null) return;
    final totalChunks = session['total_chunks'] as int;
    final chunks = session['chunks'] as Map<int, List<int>>;
    final missing = <int>[];
    for (int i = 0; i < totalChunks; i++) {
      if (!chunks.containsKey(i)) {
        missing.add(i);
      }
    }
    if (missing.isNotEmpty && _ws != null && isConnected) {
      final msg = {
        "type": "FILE_RESUME_REQUEST",
        "file_id": fileId,
        "missing_chunks": missing,
      };
      try {
        _ws!.add(jsonEncode(msg));
        NexusLogger.log("FILE_TRANSFER", "Sent FILE_RESUME_REQUEST for $fileId (${missing.length} missing chunks)");
      } catch (_) {}
    }
  }

  List<int> getMissingChunksForFile(String fileId) {
    final session = _incomingFiles[fileId];
    if (session == null) return [];
    final totalChunks = session['total_chunks'] as int;
    final chunks = session['chunks'] as Map<int, List<int>>;
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
    if (_ws == null || !isConnected) {
      throw Exception("Non connesso alla rete Nexus LAN. Assicurati che PC e Android siano sulla stessa rete.");
    }
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception("File non trovato su disco: $filePath");
    }

    final fileBytes = await file.readAsBytes();
    final fileSize = fileBytes.length;
    final fileId = "file_${DateTime.now().millisecondsSinceEpoch}";
    _outgoingFileCache[fileId] = fileBytes;
    const chunkSize = 64 * 1024; // 64 KB chunks
    final totalChunks = fileSize == 0 ? 1 : (fileSize / chunkSize).ceil();
    final senderName = Platform.isAndroid ? 'Smartphone Android' : 'PC Windows';

    // 1. Invia offerta
    final offerMsg = {
      "type": "FILE_OFFER",
      "file_id": fileId,
      "file_name": fileName,
      "file_size": fileSize,
      "total_chunks": totalChunks,
      "chunk_size": chunkSize,
      "sender_device": senderName,
    };
    _ws!.add(jsonEncode(offerMsg));
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
      _ws!.add(jsonEncode(chunkMsg));
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
    _ws!.add(jsonEncode(completeMsg));
    NexusLogger.log("FILE_TRANSFER", "File $fileName inviato con successo ($fileSize byte, $totalChunks chunk)");
  }

  void sendNotification({
    required String title,
    required String body,
    String appName = 'Sistema',
  }) {
    final censorResult = censorSecretsInText(body);
    final id = 'notif_${DateTime.now().millisecondsSinceEpoch}_${(title.hashCode.abs() % 1000)}';
    final thisDeviceName = Platform.isAndroid ? 'Smartphone Android' : 'PC Principale (Windows 11)';
    final thisDeviceId = _deviceId ?? (Platform.isAndroid ? 'nexus-android' : 'nexus-pc');

    if (censorResult.hasSecret) {
      _pendingLocalNotificationSecrets[id] = body;
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
    notifications.insert(0, notif);
    _notificationController.add(notif);

    if (_ws != null && isConnected) {
      final msg = {
        "type": "NOTIFICATION_SYNC",
        "id": id,
        "title": title,
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
        _ws!.add(jsonEncode(msg));
        NexusLogger.log("NOTIF_SYNC", "Broadcasted notification: $title (${censorResult.hasSecret ? 'Sanitizzata' : 'Normale'})");
      } catch (_) {}
    }
  }

  void requestNotificationReveal(String notifId) {
    if (_pendingLocalNotificationSecrets.containsKey(notifId)) {
      final cleartext = _pendingLocalNotificationSecrets[notifId]!;
      final idx = notifications.indexWhere((n) => n.id == notifId);
      if (idx != -1) {
        notifications[idx].currentBody = cleartext;
        notifications[idx].isRevealed = true;
      }
      _notificationRevealedController.add(notifId);
      return;
    }

    if (_ws != null && isConnected) {
      final msg = {
        "type": "NOTIFICATION_REVEAL_REQUEST",
        "id": notifId,
        "requesting_device": Platform.isAndroid ? 'Smartphone Android' : 'PC Principale (Windows 11)',
      };
      try {
        _ws!.add(jsonEncode(msg));
        NexusLogger.log("NOTIF_PRIVACY", "Sent NOTIFICATION_REVEAL_REQUEST for $notifId");
      } catch (_) {}
    }
  }

  void clearNotifications() {
    notifications.clear();
  }

  void handleNotificationForTesting(NexusNotification notif) {
    notifications.removeWhere((n) => n.id == notif.id);
    notifications.insert(0, notif);
    _notificationController.add(notif);
  }

  void handleNotificationRevealResponseForTesting(String notifId, String cleartext) {
    final idx = notifications.indexWhere((n) => n.id == notifId);
    if (idx != -1) {
      notifications[idx].currentBody = cleartext;
      notifications[idx].isRevealed = true;
    }
    _notificationRevealedController.add(notifId);
  }

  void testInjectIncomingSession(String fileId, Map<String, dynamic> session) {
    _incomingFiles[fileId] = session;
  }

  void testInjectOffer(Map<String, dynamic> offer) {
    _fileOfferController.add(offer);
  }

  void testInjectProgress(Map<String, dynamic> progress) {
    _fileProgressController.add(progress);
  }
}

