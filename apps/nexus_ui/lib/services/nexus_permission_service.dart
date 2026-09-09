import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:permission_handler/permission_handler.dart';
import 'logger_service.dart';

/// Cross-platform permission manager for Nexus Continuity.
///
/// Requests all permissions required by the app's features:
/// - Bluetooth/BLE scanning and advertising
/// - Nearby devices discovery
/// - Location (required for BLE on Android/iOS)
/// - Notifications
/// - Media / Photo Library
/// - Microphone (audio relay)
/// - Storage / Files
class NexusPermissionService {
  static final NexusPermissionService instance = NexusPermissionService._();
  NexusPermissionService._();

  bool _hasRequestedOnce = false;

  /// All permissions the app needs, filtered by platform.
  List<Permission> get _requiredPermissions {
    if (kIsWeb) return []; // Web handles permissions via browser APIs

    final perms = <Permission>[];

    if (Platform.isAndroid) {
      // Bluetooth (Android 12+ / API 31+)
      perms.addAll([
        Permission.bluetoothScan,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
        Permission.bluetooth,
        Permission.nearbyWifiDevices,
      ]);

      // Location (required for BLE discovery on Android)
      perms.addAll([
        Permission.locationWhenInUse,
        Permission.location,
      ]);

      // Notifications (Android 13+ / API 33)
      perms.add(Permission.notification);

      // Media (Android 13+ granular media permissions)
      perms.addAll([
        Permission.photos,
        Permission.audio,
        Permission.videos,
      ]);

      // Microphone (audio relay)
      perms.add(Permission.microphone);
    }

    if (Platform.isIOS) {
      perms.addAll([
        Permission.bluetooth,
        Permission.locationWhenInUse,
        Permission.locationAlways,
        Permission.notification,
        Permission.photos,
        Permission.photosAddOnly,
        Permission.microphone,
      ]);
    }

    if (Platform.isMacOS) {
      perms.addAll([
        Permission.bluetooth,
        // macOS uses entitlements for network/file, but Bluetooth needs runtime consent
      ]);
    }

    // Windows and Linux don't use permission_handler
    // (permissions are handled via OS settings or not needed)

    return perms;
  }

  /// Request all required permissions at app startup.
  /// Returns a map of permission -> status.
  /// Only requests once per app session unless [force] is true.
  Future<Map<Permission, PermissionStatus>> requestAllPermissions({bool force = false}) async {
    if (kIsWeb) {
      NexusLogger.log('PERMS', 'Web platform: permissions handled via browser APIs');
      return {};
    }

    if (Platform.isWindows || Platform.isLinux) {
      NexusLogger.log('PERMS', '${Platform.operatingSystem}: no runtime permissions needed');
      return {};
    }

    if (_hasRequestedOnce && !force) {
      NexusLogger.log('PERMS', 'Permissions already requested this session, skipping');
      return {};
    }

    final perms = _requiredPermissions;
    if (perms.isEmpty) return {};

    NexusLogger.log('PERMS', 'Requesting ${perms.length} permissions...');

    final results = <Permission, PermissionStatus>{};

    for (final perm in perms) {
      try {
        final status = await perm.status;
        if (status.isDenied || status.isRestricted) {
          final result = await perm.request();
          results[perm] = result;
          NexusLogger.log('PERMS', '  ${perm.toString()}: $result');
        } else {
          results[perm] = status;
          NexusLogger.log('PERMS', '  ${perm.toString()}: already $status');
        }
      } catch (e) {
        NexusLogger.log('PERMS', '  ${perm.toString()}: error - $e');
      }
    }

    _hasRequestedOnce = true;

    final denied = results.entries.where((e) => e.value.isDenied || e.value.isPermanentlyDenied).toList();
    if (denied.isNotEmpty) {
      NexusLogger.log('PERMS', '⚠ ${denied.length} permissions denied: ${denied.map((e) => e.key.toString()).join(', ')}');
    } else {
      NexusLogger.log('PERMS', '✓ All permissions granted');
    }

    return results;
  }

  /// Check if a specific permission is granted.
  Future<bool> isGranted(Permission perm) async {
    if (kIsWeb || Platform.isWindows || Platform.isLinux) return true;
    try {
      return await perm.isGranted;
    } catch (_) {
      return false;
    }
  }

  /// Check Bluetooth permissions specifically.
  Future<bool> isBluetoothPermissionGranted() async {
    if (kIsWeb || Platform.isWindows || Platform.isLinux) return true;

    if (Platform.isAndroid) {
      final scan = await Permission.bluetoothScan.isGranted;
      final connect = await Permission.bluetoothConnect.isGranted;
      final location = await Permission.locationWhenInUse.isGranted;
      return scan && connect && location;
    }

    if (Platform.isIOS || Platform.isMacOS) {
      return await Permission.bluetooth.isGranted;
    }

    return true;
  }

  /// Request Bluetooth permissions only.
  Future<bool> requestBluetoothPermissions() async {
    if (kIsWeb || Platform.isWindows || Platform.isLinux) return true;

    if (Platform.isAndroid) {
      final results = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetoothAdvertise,
        Permission.locationWhenInUse,
      ].request();

      return results.values.every((s) => s.isGranted);
    }

    if (Platform.isIOS || Platform.isMacOS) {
      final result = await Permission.bluetooth.request();
      return result.isGranted;
    }

    return true;
  }

  /// Request notification permission only.
  Future<bool> requestNotificationPermission() async {
    if (kIsWeb || Platform.isWindows || Platform.isLinux) return true;
    final result = await Permission.notification.request();
    return result.isGranted;
  }

  /// Open app settings so user can manually enable permissions.
  Future<bool> openSettings() async {
    return await openAppSettings();
  }

  /// Get a human-readable summary of all permission states.
  Future<Map<String, String>> getPermissionSummary() async {
    if (kIsWeb) return {'platform': 'Web (browser-managed)'};
    if (Platform.isWindows) return {'platform': 'Windows (no runtime perms)'};
    if (Platform.isLinux) return {'platform': 'Linux (no runtime perms)'};

    final summary = <String, String>{};
    for (final perm in _requiredPermissions) {
      try {
        final status = await perm.status;
        summary[perm.toString()] = status.toString();
      } catch (e) {
        summary[perm.toString()] = 'error: $e';
      }
    }
    return summary;
  }
}
