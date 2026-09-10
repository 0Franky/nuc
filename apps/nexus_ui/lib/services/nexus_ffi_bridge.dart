import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'lan_sync_service.dart';
import 'logger_service.dart';

// Native function typedefs
typedef NexusInitC = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8> deviceName);
typedef NexusInitDart = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8> deviceName);

typedef NexusFreeStringC = ffi.Void Function(ffi.Pointer<Utf8> ptr);
typedef NexusFreeStringDart = void Function(ffi.Pointer<Utf8> ptr);

typedef NexusGetStateJsonC = ffi.Pointer<Utf8> Function();
typedef NexusGetStateJsonDart = ffi.Pointer<Utf8> Function();

typedef NexusStartAudioRelayC = ffi.Int32 Function(ffi.Pointer<Utf8> peerIdStr);
typedef NexusStartAudioRelayDart = int Function(ffi.Pointer<Utf8> peerIdStr);

typedef NexusStopAudioRelayC = ffi.Int32 Function();
typedef NexusStopAudioRelayDart = int Function();

typedef NexusSetMasterVolumeC = ffi.Int32 Function(ffi.Float volume);
typedef NexusSetMasterVolumeDart = int Function(double volume);

typedef NexusToggleAudioMuteC = ffi.Int32 Function();
typedef NexusToggleAudioMuteDart = int Function();

typedef NexusSendMediaControlC = ffi.Int32 Function(ffi.Pointer<Utf8> actionStr, ffi.Int64 positionMs);
typedef NexusSendMediaControlDart = int Function(ffi.Pointer<Utf8> actionStr, int positionMs);

typedef NexusSendTouchpadDeltaC = ffi.Int32 Function(ffi.Pointer<Utf8> peerIdStr, ffi.Int16 dx, ffi.Int16 dy);
typedef NexusSendTouchpadDeltaDart = int Function(ffi.Pointer<Utf8> peerIdStr, int dx, int dy);

typedef NexusSyncClipboardC = ffi.Int32 Function(ffi.Pointer<Utf8> text, ffi.Pointer<Utf8> targetPeerStr);
typedef NexusSyncClipboardDart = int Function(ffi.Pointer<Utf8> text, ffi.Pointer<Utf8> targetPeerStr);

typedef NexusOfferFileTransferC = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8> fileName, ffi.Pointer<Utf8> targetPeerStr, ffi.Uint64 fileBytesLen);
typedef NexusOfferFileTransferDart = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8> fileName, ffi.Pointer<Utf8> targetPeerStr, int fileBytesLen);

typedef NexusClassifyClipboardC = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8> text);
typedef NexusClassifyClipboardDart = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8> text);

typedef NexusSetClipboardPrivacyGateC = ffi.Int32 Function(ffi.Int32 enabled);
typedef NexusSetClipboardPrivacyGateDart = int Function(int enabled);

typedef NexusRevealClipboardSecretC = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8> entryIdStr);
typedef NexusRevealClipboardSecretDart = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8> entryIdStr);

typedef NexusIsBluetoothEnabledC = ffi.Int32 Function();
typedef NexusIsBluetoothEnabledDart = int Function();

/// Singleton Bridge to the High-Performance Rust Core
class NexusFfiBridge {
  static final NexusFfiBridge instance = NexusFfiBridge._();

  ffi.DynamicLibrary? _lib;
  String? _deviceId;
  String? _lastLoadError;

  NexusInitDart? _nexusInit;
  NexusFreeStringDart? _nexusFreeString;
  NexusGetStateJsonDart? _nexusGetStateJson;
  NexusStartAudioRelayDart? _nexusStartAudioRelay;
  NexusStopAudioRelayDart? _nexusStopAudioRelay;
  NexusSetMasterVolumeDart? _nexusSetMasterVolume;
  NexusToggleAudioMuteDart? _nexusToggleAudioMute;
  NexusSendMediaControlDart? _nexusSendMediaControl;
  NexusSyncClipboardDart? _nexusSyncClipboard;
  NexusOfferFileTransferDart? _nexusOfferFileTransfer;
  NexusClassifyClipboardDart? _nexusClassifyClipboard;
  NexusSetClipboardPrivacyGateDart? _nexusSetClipboardPrivacyGate;
  NexusRevealClipboardSecretDart? _nexusRevealClipboardSecret;
  NexusIsBluetoothEnabledDart? _nexusIsBluetoothEnabled;

  NexusFfiBridge._() {
    _loadLibrary();
  }

  void _loadLibrary() {
    final libraryName = Platform.isWindows ? 'nexus_ffi.dll'
        : (Platform.isMacOS ? 'libnexus_ffi.dylib' : 'libnexus_ffi.so');
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final curr = Directory.current.path;
    final searchPaths = <String>[
      '$exeDir/$libraryName', '$exeDir/lib/$libraryName',
      for (final root in [curr, '$curr/..', '$curr/../..']) ...[
        '$root/target/release/$libraryName', '$root/target/debug/$libraryName',
      ],
      '$curr/$libraryName', '$curr/dist/${Platform.operatingSystem}/$libraryName',
    ];

    for (final path in searchPaths) {
      if (File(path).existsSync()) {
        try {
          _lib = ffi.DynamicLibrary.open(path);
          _bindFunctions(_lib!);
          _lastLoadError = null;
          NexusLogger.log('FFI', 'Successfully loaded native library from: $path');
          return;
        } catch (e) {
          _lastLoadError = 'Failed to load $path: $e';
        }
      }
    }

    try {
      if (Platform.isAndroid || Platform.isLinux) {
        _lib = ffi.DynamicLibrary.open('libnexus_ffi.so');
      } else if (Platform.isMacOS || Platform.isIOS) {
        _lib = ffi.DynamicLibrary.process();
      } else if (Platform.isWindows) {
        _lib = ffi.DynamicLibrary.open('nexus_ffi.dll');
      }

      if (_lib != null) {
        _bindFunctions(_lib!);
        _lastLoadError = null;
        return;
      }
    } catch (e) {
      _lastLoadError = 'DynamicLibrary.open failed: $e';
    }

    developer.log('[NexusFfiBridge] CRITICAL: Could not load $libraryName! Error: $_lastLoadError', name: 'NexusFfiBridge');
  }

  void _bindFunctions(ffi.DynamicLibrary lib) {
    _nexusInit = lib.lookupFunction<NexusInitC, NexusInitDart>('nexus_init');
    _nexusFreeString = lib.lookupFunction<NexusFreeStringC, NexusFreeStringDart>('nexus_free_string');
    _nexusGetStateJson = lib.lookupFunction<NexusGetStateJsonC, NexusGetStateJsonDart>('nexus_get_state_json');
    _nexusStartAudioRelay = lib.lookupFunction<NexusStartAudioRelayC, NexusStartAudioRelayDart>('nexus_start_audio_relay');
    _nexusStopAudioRelay = lib.lookupFunction<NexusStopAudioRelayC, NexusStopAudioRelayDart>('nexus_stop_audio_relay');
    _nexusSetMasterVolume = lib.lookupFunction<NexusSetMasterVolumeC, NexusSetMasterVolumeDart>('nexus_set_master_volume');
    try {
      _nexusToggleAudioMute = lib.lookupFunction<NexusToggleAudioMuteC, NexusToggleAudioMuteDart>('nexus_toggle_audio_mute');
    } catch (_) {}
    _nexusSendMediaControl = lib.lookupFunction<NexusSendMediaControlC, NexusSendMediaControlDart>('nexus_send_media_control');
    _nexusSyncClipboard = lib.lookupFunction<NexusSyncClipboardC, NexusSyncClipboardDart>('nexus_sync_clipboard');
    _nexusOfferFileTransfer = lib.lookupFunction<NexusOfferFileTransferC, NexusOfferFileTransferDart>('nexus_offer_file_transfer');
    try {
      _nexusClassifyClipboard = lib.lookupFunction<NexusClassifyClipboardC, NexusClassifyClipboardDart>('nexus_classify_clipboard');
      _nexusSetClipboardPrivacyGate = lib.lookupFunction<NexusSetClipboardPrivacyGateC, NexusSetClipboardPrivacyGateDart>('nexus_set_clipboard_privacy_gate');
      _nexusRevealClipboardSecret = lib.lookupFunction<NexusRevealClipboardSecretC, NexusRevealClipboardSecretDart>('nexus_reveal_clipboard_secret');
      _nexusIsBluetoothEnabled = lib.lookupFunction<NexusIsBluetoothEnabledC, NexusIsBluetoothEnabledDart>('nexus_is_bluetooth_enabled');
    } catch (_) {}
  }

  /// True if the real Rust engine is loaded
  bool get isLoaded => _nexusGetStateJson != null;

  /// Current Device ID
  String? get deviceId => _deviceId;

  /// Initializes the Nexus Engine
  String init(String deviceName) {
    if (_nexusInit == null) {
      _loadLibrary();
      if (_nexusInit == null) {
        NexusLogger.log('FFI', 'Native DLL not available on ${Platform.operatingSystem}. Starting LanSyncService.');
        _deviceId = LanSyncService.instance.deviceId;
        LanSyncService.instance.start();
        return _deviceId!;
      }
    }

    final namePtr = deviceName.toNativeUtf8();
    final resPtr = _nexusInit!(namePtr);
    malloc.free(namePtr);

    if (resPtr == ffi.nullptr) throw StateError("Nexus identity initialization failed");
    final id = resPtr.toDartString();
    _nexusFreeString!(resPtr);
    _deviceId = id;
    return id;
  }

  /// Gets the live state JSON snapshot directly from Rust Core or LAN Sync
  Map<String, dynamic> getState() {
    if (_nexusGetStateJson == null) {
      _loadLibrary();
      if (_nexusGetStateJson == null) {
        final lan = LanSyncService.instance;
        return {
          "initialized": true,
          "device_id": lan.deviceId,
          "local_lan_ip": lan.pcIp ?? "127.0.0.1",
          "active_media": lan.activeMedia,
          "discovered_peers": lan.discoveredPeers,
          "clipboard_history": [],
          "audio_relay_active": false,
          "audio_volume": lan.currentVolume,
          "audio_muted": lan.isAudioMuted,
          "spatial_position": lan.spatialPosition,
          "device_type": lan.deviceType,
          "proximity_motion": lan.proximityMotion,
          "estimated_distance_m": lan.estimatedDistanceMeters,
        };
      }
    }

    final resPtr = _nexusGetStateJson!();
    final jsonStr = resPtr.toDartString();
    _nexusFreeString!(resPtr);
    final parsed = jsonDecode(jsonStr) as Map<String, dynamic>;
    parsed["spatial_position"] = LanSyncService.instance.spatialPosition;
    parsed["device_type"] = LanSyncService.instance.deviceType;
    parsed["proximity_motion"] = LanSyncService.instance.proximityMotion;
    parsed["estimated_distance_m"] = LanSyncService.instance.estimatedDistanceMeters;
    parsed["discovered_peers"] = LanSyncService.instance.discoveredPeers;
    parsed["device_id"] = _deviceId ?? parsed["device_id"];
    return parsed;
  }

  /// Sets spatial arrangement of a peer (Left, Right, Above, Below)
  void setSpatialArrangement(String peerId, String arrangement, {int width = 1920, int height = 1080}) {
    LanSyncService.instance.sendSpatialArrangement(peerId, arrangement, width: width, height: height);
  }

  /// Sends Universal Control edge hop coordinate
  void sendUniversalControlHop(int entryX, int entryY, int screenWidth, int screenHeight) {
    LanSyncService.instance.sendUniversalControlHop(entryX, entryY, screenWidth, screenHeight);
  }

  /// Sends Universal Control delta mouse movement
  void sendUniversalControlDelta(int dx, int dy) {
    LanSyncService.instance.sendUniversalControlDelta(dx, dy);
  }

  /// Triggers a proximity action (e.g. LOCK_WORKSTATION, WAKE)
  void triggerProximityAction(String action) {
    LanSyncService.instance.sendProximityTrigger(action);
  }

  /// Starts Private Listening Audio Relay
  int startAudioRelay(String peerId) {
    if (_nexusStartAudioRelay == null) return -1;
    final peerPtr = peerId.toNativeUtf8();
    final res = _nexusStartAudioRelay!(peerPtr);
    malloc.free(peerPtr);
    return res;
  }

  /// Stops Private Listening Audio Relay
  int stopAudioRelay() {
    if (_nexusStopAudioRelay == null) return -1;
    return _nexusStopAudioRelay!();
  }

  /// Sets Master Audio Volume (0.0 to 1.0)
  int setMasterVolume(double volume) {
    final lan = LanSyncService.instance;
    if (lan.selectedTargetDeviceId != null || _nexusSetMasterVolume == null) {
      lan.sendVolume(volume);
      return lan.targetSocket == null ? -1 : 0;
    }
    if (_nexusSetMasterVolume == null) return 0;
    return _nexusSetMasterVolume!(volume.clamp(0.0, 1.0));
  }

  /// Sets audio relay volume
  int setAudioVolume(double volume) {
    return setMasterVolume(volume);
  }

  /// Toggles PC speaker hardware mute via Audio Relay HTTP API
  void togglePcSpeakersMute() {
    LanSyncService.instance.togglePcSpeakersMute();
  }

  /// Toggles Private Listening headphone mute
  int toggleAudioMute() {
    final nextMute = !LanSyncService.instance.isAudioMuted;
    LanSyncService.instance.sendAudioMute(nextMute);
    if (_nexusToggleAudioMute != null) {
      return _nexusToggleAudioMute!();
    }
    return nextMute ? 1 : 0;
  }

  /// Sends a remote control command (PLAY, PAUSE, SEEK, MUTE) to browser extensions or PC over LAN
  int sendMediaControl(String action, {int? positionMs}) {
    final lan = LanSyncService.instance;
    if (lan.selectedTargetDeviceId != null || _nexusSendMediaControl == null) {
      lan.sendCommand(action, positionMs: positionMs);
      return lan.targetSocket == null ? -1 : 0;
    }
    if (_nexusSendMediaControl == null) {
      return 0;
    }
    final actionPtr = action.toNativeUtf8();
    final res = _nexusSendMediaControl!(actionPtr, positionMs ?? -1);
    malloc.free(actionPtr);
    NexusLogger.log('FFI', 'Sent remote control command: $action (pos: $positionMs) -> code: $res');
    return res;
  }

  /// Emits trackpad delta
  int sendTouchpadDelta(String peerId, int dx, int dy) {
    LanSyncService.instance.sendTouchpadDelta(dx, dy, targetPeerId: peerId);
    return LanSyncService.instance.socketForDevice(peerId) == null ? -1 : 0;
  }

  /// Emits mouse button click (Left, Right)
  int sendTouchpadClick(String button, {String? targetPeerId}) {
    LanSyncService.instance.sendTouchpadClick(button, targetPeerId: targetPeerId);
    return 0;
  }

  /// Emits mouse button down/up event for holding mouse and text selection / drag-drop
  int sendTouchpadButton(String button, bool isDown, {String? targetPeerId}) {
    LanSyncService.instance.sendTouchpadButton(button, isDown, targetPeerId: targetPeerId);
    return 0;
  }

  /// Emits vertical scroll wheel delta
  int sendTouchpadScroll(int dy, {String? targetPeerId}) {
    LanSyncService.instance.sendTouchpadScroll(dy, targetPeerId: targetPeerId);
    return 0;
  }

  /// Sends a single keyboard keystroke (Esc, Tab, Enter, etc.)
  void sendKeyboardKey(String key, {bool? isDown, String? targetPeerId}) {
    LanSyncService.instance.sendKeyboardKey(key, isDown: isDown, targetPeerId: targetPeerId);
  }

  /// Sends a keyboard key combo (e.g. ['Ctrl', 'C'], ['Win', 'D'])
  void sendKeyboardCombo(List<String> keys, {String? targetPeerId}) {
    LanSyncService.instance.sendKeyboardCombo(keys, targetPeerId: targetPeerId);
  }

  /// Injects arbitrary Unicode text into active PC application
  void sendTextInput(String text, {String? targetPeerId}) {
    LanSyncService.instance.sendTextInput(text, targetPeerId: targetPeerId);
  }

  /// Sends Open URL remote command to mobile/PC
  void sendOpenUrl(String url, String title, int positionMs) {
    LanSyncService.instance.sendOpenUrl(url, title, positionMs);
  }

  /// Synchronizes clipboard text with Zero-Trust Privacy Gate
  int syncClipboard(String text, {String? targetPeerId}) {
    LanSyncService.instance.sendClipboardWithPrivacyGate(text);
    if (_nexusSyncClipboard == null) return 0;
    final textPtr = text.toNativeUtf8();
    final targetPtr = targetPeerId != null ? targetPeerId.toNativeUtf8() : ffi.nullptr;
    final res = _nexusSyncClipboard!(textPtr, targetPtr.cast());
    malloc.free(textPtr);
    if (targetPeerId != null) {
      malloc.free(targetPtr);
    }
    return res;
  }

  /// Classifies clipboard content into safe vs secret/PII
  Map<String, dynamic> classifyClipboard(String text) {
    if (_nexusClassifyClipboard == null) {
      return {"is_secret": false, "label": "Testo"};
    }
    final textPtr = text.toNativeUtf8();
    final resPtr = _nexusClassifyClipboard!(textPtr);
    malloc.free(textPtr);
    final jsonStr = resPtr.toDartString();
    _nexusFreeString!(resPtr);
    final map = jsonDecode(jsonStr) as Map<String, dynamic>;
    map['secret_type'] = map['label'];
    return map;
  }

  /// Sets whether the Zero-Trust Clipboard Privacy Gate is enabled
  int setClipboardPrivacyGate(bool enabled) {
    if (_nexusSetClipboardPrivacyGate == null) return 0;
    return _nexusSetClipboardPrivacyGate!(enabled ? 1 : 0);
  }

  /// Reveals a stored secret given its entry ID
  Map<String, dynamic> revealClipboardSecret(String entryId) {
    if (_nexusRevealClipboardSecret == null) {
      return {"revealed": false, "error": "DLL not loaded"};
    }
    final idPtr = entryId.toNativeUtf8();
    final resPtr = _nexusRevealClipboardSecret!(idPtr);
    malloc.free(idPtr);
    final jsonStr = resPtr.toDartString();
    _nexusFreeString!(resPtr);
    return jsonDecode(jsonStr) as Map<String, dynamic>;
  }

  /// Creates a P2P File Transfer Offer
  Map<String, dynamic> offerFileTransfer(String fileName, int fileSizeBytes, {String? targetPeerId}) {
    if (_nexusOfferFileTransfer == null) {
      return {
        "file_id": "file-err",
        "error": "DLL not loaded",
      };
    }

    final namePtr = fileName.toNativeUtf8();
    final effectivePeer = targetPeerId ?? LanSyncService.instance.selectedTargetDeviceId ?? "broadcast";
    final peerPtr = effectivePeer.toNativeUtf8();
    final resPtr = _nexusOfferFileTransfer!(namePtr, peerPtr, fileSizeBytes);
    malloc.free(namePtr);
    malloc.free(peerPtr);

    final jsonStr = resPtr.toDartString();
    _nexusFreeString!(resPtr);
    return jsonDecode(jsonStr) as Map<String, dynamic>;
  }

  /// Checks if real OS Bluetooth radio is enabled/On
  bool isBluetoothEnabled() {
    if (_nexusIsBluetoothEnabled != null) {
      try {
        return _nexusIsBluetoothEnabled!() == 1;
      } catch (_) {}
    }
    return false;
  }
}
