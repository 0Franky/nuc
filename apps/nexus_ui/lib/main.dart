import 'dart:async';
import 'package:flutter/material.dart';
import 'services/shared_input_service.dart';
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

/// Runs a startup task (sync or async) so that failures reach the log
/// instead of becoming unhandled errors.
void _launchGuarded(String tag, FutureOr<void> Function() task) {
  try {
    final result = task();
    if (result is Future<void>) {
      unawaited(result.then<void>((_) {}, onError: (Object e, StackTrace st) {
        NexusLogger.log("INIT", "$tag failed: $e");
      }));
    }
  } catch (e) {
    NexusLogger.log("INIT", "$tag failed: $e");
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await LanSyncService.instance.loadSettings();
  } catch (e) {
    // Corrupted or unreadable settings must not keep the app on a blank screen.
    NexusLogger.log("INIT", "Settings load failed, using defaults: $e");
  }
  try {
    final id = NexusFfiBridge.instance.init(LanSyncService.instance.deviceName);
    await LanSyncService.instance.adoptNativeIdentity(id);
  } catch (e) {
    NexusLogger.log("INIT", "Native FFI init non-fatal: $e");
  }
  _launchGuarded("LanSyncService.start", () => LanSyncService.instance.start());
  unawaited(SharedInputService.instance.initialize(LanSyncService.instance));
  runApp(const NexusApp());
  _launchGuarded("SystemTrayService.init", () => SystemTrayService.instance.init());

  // Request all platform permissions asynchronously after app launch
  WidgetsBinding.instance.addPostFrameCallback((_) {
    _launchGuarded("requestAllPermissions",
        () => NexusPermissionService.instance.requestAllPermissions());
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
  int _notifCount = 0;

  // Keeps the IndexedStack (and the state of every tab) alive when the
  // layout switches between desktop rail and mobile bar on resize.
  final GlobalKey _bodyKey = GlobalKey(debugLabel: 'nexus-tabs');

  Widget _buildBody(List<Widget> screens) =>
      IndexedStack(key: _bodyKey, index: _selectedIndex, children: screens);

  // Built once: not recreated on every build or LayoutBuilder resize.
  late final List<Widget> _screens = [
    DashboardScreen(onNavigateTab: _onSelectTab),
    const NotificationCenterScreen(),
    const SpatialTopologyScreen(),
    const FileTransferScreen(),
    const TouchpadRemoteScreen(),
    const ClipboardScreen(),
    const SettingsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    _notifCount = LanSyncService.instance.notifications.length;
    LanSyncService.instance.addListener(_onSyncChanged);
  }

  @override
  void dispose() {
    LanSyncService.instance.removeListener(_onSyncChanged);
    super.dispose();
  }

  void _onSyncChanged() {
    final count = LanSyncService.instance.notifications.length;
    if (mounted && count != _notifCount) {
      setState(() => _notifCount = count);
    }
  }

  void _onSelectTab(int index) {
    setState(() => _selectedIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final screens = _screens;
    final notifCount = _notifCount;

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
                    for (final item in _sharedNavItems)
                      NavigationRailDestination(
                        icon: Icon(item.icon),
                        selectedIcon: Icon(item.selectedIcon, color: NexusTheme.accentIndigo),
                        label: Text(item.label, style: const TextStyle(fontSize: 11)),
                      ),
                  ],
                ),
                const VerticalDivider(thickness: 1, width: 1),
                Expanded(child: _buildBody(screens)),
              ],
            ),
          );
        }

        // iOS / Mobile Layout: Sleek bottom NavigationBar
        return Scaffold(
          body: _buildBody(screens),
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
              for (final item in _sharedNavItems)
                NavigationDestination(
                  icon: Icon(item.icon),
                  selectedIcon: Icon(item.selectedIcon, color: NexusTheme.accentIndigo),
                  label: item.label,
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Destinazione di navigazione condivisa da NavigationRail (desktop) e
/// NavigationBar (mobile), per evitare che le due liste divergano.
class _NavItem {
  const _NavItem(this.icon, this.selectedIcon, this.label);
  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

/// Destinazioni successive a Dashboard e Notifiche (quest'ultima ha il badge
/// e resta definita a parte). L'ordine deve seguire quello di `screens`.
const List<_NavItem> _sharedNavItems = [
  _NavItem(Icons.devices_outlined, Icons.devices_other_rounded, 'Schermi'),
  _NavItem(Icons.folder_outlined, Icons.folder_shared_rounded, 'File Drop'),
  _NavItem(Icons.touch_app_outlined, Icons.touch_app_rounded, 'Trackpad'),
  _NavItem(Icons.content_paste_outlined, Icons.content_paste_rounded, 'Appunti'),
  _NavItem(Icons.settings_outlined, Icons.settings_rounded, 'Impostazioni'),
];
