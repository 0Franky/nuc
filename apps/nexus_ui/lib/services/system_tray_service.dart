import 'shared_input_service.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'nexus_ffi_bridge.dart';
import 'lan_sync_service.dart';

class SystemTrayService with TrayListener, WindowListener {
  static final SystemTrayService instance = SystemTrayService._();

  bool _isAudioActive = false;
  bool _trayReady = false;
  bool _initialized = false;

  SystemTrayService._();

  Future<void> init() async {
    if (kIsWeb || !(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return;
    }
    // Idempotent: a second call must not register the listeners again.
    if (_initialized) return;
    _initialized = true;

    try {
      // 1. Initialize Window Manager
      await windowManager.ensureInitialized();
      windowManager.addListener(this);
      await windowManager.setPreventClose(true);

      final windowOptions = WindowOptions(
        size: const Size(1100, 750),
        center: true,
        title: 'Nexus Universal Continuity',
      );

      await windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.show();
        await windowManager.focus();
      });

      // 2. Initialize Tray Manager
      trayManager.addListener(this);
      LanSyncService.instance.addListener(_onLanStateChanged);

      try {
        await trayManager.setIcon(Platform.isWindows ? 'assets/tray_icon.ico' : 'assets/tray_icon.png');
        _trayReady = await updateContextMenu();
      } catch (e) {
        debugPrint('[SystemTray] setIcon non-fatal: $e');
      }

    } catch (e) {
      debugPrint('[SystemTray] Desktop tray initialization non-fatal: $e');
    }
  }

  Future<bool> updateContextMenu() async {
    if (kIsWeb || !(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return false;
    }

    try {
      final menu = Menu(
        items: [
          MenuItem(
            key: 'status',
            label: _isConnected()
                ? 'Nexus Continuity (Connesso)'
                : 'Nexus Continuity (Non connesso)',
            disabled: true,
          ),
          MenuItem.separator(),
          MenuItem.checkbox(
            key: 'toggle_audio',
            label: 'Private Listening (Audio in Cuffia)',
            checked: _isAudioActive,
          ),
          MenuItem(
            key: 'show_window',
            label: 'Mostra Finestra Principale',
          ),
          MenuItem.separator(),
          MenuItem(
            key: 'exit',
            label: 'Esci dall\'applicazione',
          ),
        ],
      );

      await trayManager.setContextMenu(menu);
      if (!Platform.isLinux) await trayManager.setToolTip('Nexus Universal Continuity');
      return true;
    } catch (e) {
      debugPrint('[SystemTray] Menu unavailable: $e');
      return false;
    }
  }

  @override
  void onTrayIconMouseDown() {
    // Left click on tray icon restores window
    _guard('showWindow', () => _showAndRestoreWindow());
  }

  @override
  void onTrayIconRightMouseDown() {
    _guard('popUpContextMenu', () => trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show_window':
        _guard('showWindow', () => _showAndRestoreWindow());
        break;
      case 'toggle_audio':
        _guard('toggleAudio', () => _toggleAudio());
        break;
      case 'exit':
        _guard('exitApp', () => _exitApp());
        break;
    }
  }

  bool _isConnected() {
    final lan = LanSyncService.instance;
    return lan.selectedTargetDeviceId != null || lan.discoveredPeers.isNotEmpty;
  }

  void _onLanStateChanged() {
    if (_trayReady) _guard('updateContextMenu', () => updateContextMenu());
  }

  /// Runs an async action started from a synchronous callback, logging
  /// errors instead of leaving them as unhandled async errors.
  void _guard(String label, FutureOr<void> Function() action) {
    unawaited(Future<void>.sync(action).catchError((Object e, StackTrace st) {
      debugPrint('[SystemTray] $label failed: $e');
    }));
  }

  /// Removes the listeners registered by [init]; [init] can then run again.
  void dispose() {
    if (!_initialized) return;
    _initialized = false;
    _trayReady = false;
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    LanSyncService.instance.removeListener(_onLanStateChanged);
  }

  /// Resolves the audio relay target. Never falls back to a broadcast:
  /// private listening must go to one specific device.
  String? _resolveAudioTarget() {
    final lan = LanSyncService.instance;
    final selected = lan.selectedTargetDeviceId;
    if (selected != null && selected.isNotEmpty) return selected;
    for (final peer in lan.discoveredPeers) {
      final id = peer['id'];
      if (id is String && id.isNotEmpty) return id;
    }
    return null;
  }

  Future<void> _toggleAudio() async {
    try {
      if (!_isAudioActive) {
        final target = _resolveAudioTarget();
        if (target == null) {
          debugPrint('[SystemTray] Private Listening: nessun dispositivo di destinazione');
        } else {
          final res = NexusFfiBridge.instance.startAudioRelay(target);
          if (res < 0) {
            debugPrint('[SystemTray] startAudioRelay fallito ($res)');
          } else {
            _isAudioActive = true;
          }
        }
      } else {
        final res = NexusFfiBridge.instance.stopAudioRelay();
        if (res < 0) debugPrint('[SystemTray] stopAudioRelay fallito ($res)');
        _isAudioActive = false;
      }
    } catch (e) {
      debugPrint('[SystemTray] Audio relay error: $e');
    }
    await updateContextMenu();
  }

  @override
  void onWindowClose() async {
    // When clicking 'X', hide window to tray instead of quitting
    try {
      final isPreventClose = await windowManager.isPreventClose();
      if (isPreventClose) {
        if (_trayReady) {
          await windowManager.hide();
        } else {
          await _exitApp();
        }
      }
    } catch (e) {
      debugPrint('[SystemTray] onWindowClose error: $e');
    }
  }

  Future<void> _showAndRestoreWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _exitApp() async {
    try {
      LanSyncService.instance.removeListener(_onLanStateChanged);
      if (_isAudioActive) {
        NexusFfiBridge.instance.stopAudioRelay();
        _isAudioActive = false;
      }
      await SharedInputService.instance.shutdown();
    } catch (e) {
      debugPrint('[SystemTray] shutdown error: $e');
    } finally {
      try {
        await windowManager.destroy();
      } catch (e) {
        debugPrint('[SystemTray] destroy error: $e');
      }
      exit(0);
    }
  }
}
