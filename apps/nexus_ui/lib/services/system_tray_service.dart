import 'shared_input_service.dart';
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

  SystemTrayService._();

  Future<void> init() async {
    if (kIsWeb || !(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return;
    }

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
            label: 'Nexus Continuity (Connesso)',
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
    _showAndRestoreWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show_window':
        _showAndRestoreWindow();
        break;
      case 'toggle_audio':
        _isAudioActive = !_isAudioActive;
        if (_isAudioActive) {
          final target = LanSyncService.instance.selectedTargetDeviceId ??
              (LanSyncService.instance.discoveredPeers.isNotEmpty
                  ? LanSyncService.instance.discoveredPeers.first['id'] as String
                  : "all");
          NexusFfiBridge.instance.startAudioRelay(target);
        } else {
          NexusFfiBridge.instance.stopAudioRelay();
        }
        updateContextMenu();
        break;
      case 'exit':
        _exitApp();
        break;
    }
  }

  @override
  void onWindowClose() async {
    // When clicking 'X', hide window to tray instead of quitting
    final isPreventClose = await windowManager.isPreventClose();
    if (isPreventClose) {
      if (_trayReady) {
        await windowManager.hide();
      } else {
        await _exitApp();
      }
    }
  }

  Future<void> _showAndRestoreWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _exitApp() async {
    await SharedInputService.instance.shutdown();
    await windowManager.destroy();
    exit(0);
  }
}
