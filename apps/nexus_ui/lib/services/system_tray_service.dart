import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'nexus_ffi_bridge.dart';

class SystemTrayService with TrayListener, WindowListener {
  static final SystemTrayService instance = SystemTrayService._();

  bool _isAudioActive = false;

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
        String iconPath = 'app_icon.ico';
        if (File('app_icon.ico').existsSync()) {
          iconPath = 'app_icon.ico';
        } else if (File('windows/runner/resources/app_icon.ico').existsSync()) {
          iconPath = 'windows/runner/resources/app_icon.ico';
        }
        await trayManager.setIcon(iconPath);
      } catch (e) {
        debugPrint('[SystemTray] setIcon non-fatal: $e');
      }

      await updateContextMenu();
    } catch (e) {
      debugPrint('[SystemTray] Desktop tray initialization non-fatal: $e');
    }
  }

  Future<void> updateContextMenu() async {
    if (kIsWeb || !(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return;
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
      await trayManager.setToolTip('Nexus Universal Continuity');
    } catch (_) {}
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
          NexusFfiBridge.instance.startAudioRelay("00000000-0000-0000-0000-000000000001");
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
      await windowManager.hide();
    }
  }

  Future<void> _showAndRestoreWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _exitApp() async {
    await windowManager.destroy();
    exit(0);
  }
}
