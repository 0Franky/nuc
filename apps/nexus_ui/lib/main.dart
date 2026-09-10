import 'package:flutter/material.dart';
import 'services/lan_sync_service.dart';
import 'services/logger_service.dart';
import 'services/nexus_ffi_bridge.dart';
import 'services/nexus_permission_service.dart';
import 'services/system_tray_service.dart';
import 'theme/nexus_theme.dart';

import 'screens/dashboard_screen.dart';
import 'screens/notification_screen.dart';
import 'screens/spatial_topology_screen.dart';
import 'screens/file_transfer_screen.dart';
import 'screens/touchpad_screen.dart';
import 'screens/clipboard_screen.dart';
import 'screens/settings_screen.dart';

// Re-export screens and widgets for full backwards compatibility with tests and callers
export 'screens/dashboard_screen.dart';
export 'screens/notification_screen.dart';
export 'screens/spatial_topology_screen.dart';
export 'screens/file_transfer_screen.dart';
export 'screens/touchpad_screen.dart';
export 'screens/clipboard_screen.dart';
export 'screens/settings_screen.dart';
export 'theme/nexus_theme.dart';
export 'widgets/nexus_card.dart';
export 'widgets/nexus_pill.dart';
export 'widgets/nexus_button.dart';
export 'widgets/nexus_segmented_control.dart';
export 'widgets/nexus_media_card.dart';
export 'widgets/nexus_audio_card.dart';
export 'widgets/nexus_continuity_island.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LanSyncService.instance.loadSettings();
  try {
    final id = NexusFfiBridge.instance.init(LanSyncService.instance.deviceName);
    await LanSyncService.instance.adoptNativeIdentity(id);
  } catch (e) {
    NexusLogger.log("INIT", "Native FFI init non-fatal: $e");
  }
  LanSyncService.instance.start();
  runApp(const NexusApp());
  SystemTrayService.instance.init();

  // Request all platform permissions asynchronously after app launch
  WidgetsBinding.instance.addPostFrameCallback((_) {
    NexusPermissionService.instance.requestAllPermissions();
  });
}

class NexusApp extends StatelessWidget {
  const NexusApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nexus Universal Continuity',
      debugShowCheckedModeBanner: false,
      theme: NexusTheme.darkTheme,
      home: const MainNavigationShell(),
    );
  }
}

class MainNavigationShell extends StatefulWidget {
  const MainNavigationShell({super.key});

  @override
  State<MainNavigationShell> createState() => _MainNavigationShellState();
}

class _MainNavigationShellState extends State<MainNavigationShell> {
  int _selectedIndex = 0;

  void _onSelectTab(int index) {
    setState(() => _selectedIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      DashboardScreen(onNavigateTab: _onSelectTab),
      const NotificationCenterScreen(),
      const SpatialTopologyScreen(),
      const FileTransferScreen(),
      const TouchpadRemoteScreen(),
      const ClipboardScreen(),
      const SettingsScreen(),
    ];

    final notifCount = LanSyncService.instance.notifications.length;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWideScreen = constraints.maxWidth >= 750;

        if (isWideScreen) {
          // macOS / iPadOS Desktop Layout: Left frosted NavigationRail
          return Scaffold(
            body: Row(
              children: [
                NavigationRail(
                  backgroundColor: NexusTheme.surfaceSecondary,
                  indicatorColor: NexusTheme.accentIndigo.withAlpha(50),
                  selectedIndex: _selectedIndex,
                  onDestinationSelected: _onSelectTab,
                  labelType: NavigationRailLabelType.all,
                  leading: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: NexusTheme.accentIndigo.withAlpha(40),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.all_inclusive_rounded, color: NexusTheme.accentIndigo, size: 24),
                    ),
                  ),
                  destinations: [
                    const NavigationRailDestination(
                      icon: Icon(Icons.dashboard_outlined),
                      selectedIcon: Icon(Icons.dashboard_rounded, color: NexusTheme.accentIndigo),
                      label: Text('Dashboard', style: TextStyle(fontSize: 11)),
                    ),
                    NavigationRailDestination(
                      icon: Badge(
                        isLabelVisible: notifCount > 0,
                        label: Text('$notifCount'),
                        child: const Icon(Icons.notifications_outlined),
                      ),
                      selectedIcon: Badge(
                        isLabelVisible: notifCount > 0,
                        label: Text('$notifCount'),
                        child: const Icon(Icons.notifications_active_rounded, color: NexusTheme.accentIndigo),
                      ),
                      label: const Text('Notifiche', style: TextStyle(fontSize: 11)),
                    ),
                    const NavigationRailDestination(
                      icon: Icon(Icons.devices_outlined),
                      selectedIcon: Icon(Icons.devices_other_rounded, color: NexusTheme.accentIndigo),
                      label: Text('Schermi', style: TextStyle(fontSize: 11)),
                    ),
                    const NavigationRailDestination(
                      icon: Icon(Icons.folder_outlined),
                      selectedIcon: Icon(Icons.folder_shared_rounded, color: NexusTheme.accentIndigo),
                      label: Text('File Drop', style: TextStyle(fontSize: 11)),
                    ),
                    const NavigationRailDestination(
                      icon: Icon(Icons.touch_app_outlined),
                      selectedIcon: Icon(Icons.touch_app_rounded, color: NexusTheme.accentIndigo),
                      label: Text('Trackpad', style: TextStyle(fontSize: 11)),
                    ),
                    const NavigationRailDestination(
                      icon: Icon(Icons.content_paste_outlined),
                      selectedIcon: Icon(Icons.content_paste_rounded, color: NexusTheme.accentIndigo),
                      label: Text('Appunti', style: TextStyle(fontSize: 11)),
                    ),
                    const NavigationRailDestination(
                      icon: Icon(Icons.settings_outlined),
                      selectedIcon: Icon(Icons.settings_rounded, color: NexusTheme.accentIndigo),
                      label: Text('Impostazioni', style: TextStyle(fontSize: 11)),
                    ),
                  ],
                ),
                const VerticalDivider(thickness: 1, width: 1),
                Expanded(child: screens[_selectedIndex]),
              ],
            ),
          );
        }

        // iOS / Mobile Layout: Sleek bottom NavigationBar
        return Scaffold(
          body: screens[_selectedIndex],
          bottomNavigationBar: NavigationBar(
            backgroundColor: NexusTheme.surfaceSecondary,
            indicatorColor: NexusTheme.accentIndigo.withAlpha(50),
            selectedIndex: _selectedIndex,
            onDestinationSelected: _onSelectTab,
            height: 64,
            destinations: [
              const NavigationDestination(
                icon: Icon(Icons.dashboard_outlined),
                selectedIcon: Icon(Icons.dashboard_rounded, color: NexusTheme.accentIndigo),
                label: 'Dashboard',
              ),
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: notifCount > 0,
                  label: Text('$notifCount'),
                  child: const Icon(Icons.notifications_outlined),
                ),
                selectedIcon: Badge(
                  isLabelVisible: notifCount > 0,
                  label: Text('$notifCount'),
                  child: const Icon(Icons.notifications_active_rounded, color: NexusTheme.accentIndigo),
                ),
                label: 'Notifiche',
              ),
              const NavigationDestination(
                icon: Icon(Icons.devices_outlined),
                selectedIcon: Icon(Icons.devices_other_rounded, color: NexusTheme.accentIndigo),
                label: 'Schermi',
              ),
              const NavigationDestination(
                icon: Icon(Icons.folder_outlined),
                selectedIcon: Icon(Icons.folder_shared_rounded, color: NexusTheme.accentIndigo),
                label: 'File Drop',
              ),
              const NavigationDestination(
                icon: Icon(Icons.touch_app_outlined),
                selectedIcon: Icon(Icons.touch_app_rounded, color: NexusTheme.accentIndigo),
                label: 'Trackpad',
              ),
              const NavigationDestination(
                icon: Icon(Icons.content_paste_outlined),
                selectedIcon: Icon(Icons.content_paste_rounded, color: NexusTheme.accentIndigo),
                label: 'Appunti',
              ),
              const NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings_rounded, color: NexusTheme.accentIndigo),
                label: 'Impostazioni',
              ),
            ],
          ),
        );
      },
    );
  }
}
