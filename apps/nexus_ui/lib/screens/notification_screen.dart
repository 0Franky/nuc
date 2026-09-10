import 'dart:async';
import 'package:flutter/material.dart';
import '../services/lan_sync_service.dart';
import '../theme/nexus_theme.dart';
import '../widgets/nexus_card.dart';
import '../widgets/nexus_pill.dart';

class NotificationCenterScreen extends StatefulWidget {
  const NotificationCenterScreen({super.key});

  @override
  State<NotificationCenterScreen> createState() => _NotificationCenterScreenState();
}

class _NotificationCenterScreenState extends State<NotificationCenterScreen> {
  StreamSubscription<NexusNotification>? _notifSub;
  StreamSubscription<String>? _revealSub;
  String _selectedDeviceFilter = 'ALL';

  @override
  void initState() {
    super.initState();
    _notifSub = LanSyncService.instance.onNotificationReceived.listen((_) {
      if (mounted) setState(() {});
    });
    _revealSub = LanSyncService.instance.onNotificationRevealed.listen((_) {
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('🔓 Notifica rivelata con successo via E2EE!'),
            backgroundColor: NexusTheme.successGreen,
            duration: Duration(seconds: 2),
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    _notifSub?.cancel();
    _revealSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allNotifs = LanSyncService.instance.notifications;
    final devices = allNotifs.map((n) => n.senderDevice).toSet().toList();

    final filteredNotifs = _selectedDeviceFilter == 'ALL'
        ? allNotifs
        : allNotifs.where((n) => n.senderDevice == _selectedDeviceFilter).toList();

    final osNotifs = filteredNotifs.where((n) => n.category == NexusNotificationCategory.osNotification).toList();
    final internalNotifs = filteredNotifs.where((n) => n.category == NexusNotificationCategory.internalApp).toList();

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Centro Notifiche'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Notifiche'),
              Tab(text: 'Sistema'),
            ],
            indicatorColor: NexusTheme.accentIndigo,
            labelColor: Colors.white,
            unselectedLabelColor: NexusTheme.textSecondary,
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: 'Svuota Notifiche',
              onPressed: () {
                setState(() {
                  LanSyncService.instance.clearNotifications();
                });
                ScaffoldMessenger.of(context).hideCurrentSnackBar();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Storico notifiche svuotato.'),
                    backgroundColor: NexusTheme.surfaceCard,
                  ),
                );
              },
            ),
          ],
        ),
        body: Column(
          children: [
            // Apple-style Device Filter Bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: NexusTheme.surfaceSecondary,
                border: Border(bottom: BorderSide(color: NexusTheme.borderSubtle)),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    ChoiceChip(
                      label: Text('Tutti (${allNotifs.length})'),
                      selected: _selectedDeviceFilter == 'ALL',
                      onSelected: (sel) {
                        if (sel) setState(() => _selectedDeviceFilter = 'ALL');
                      },
                      selectedColor: NexusTheme.accentIndigo,
                      backgroundColor: NexusTheme.surfaceCard,
                      labelStyle: TextStyle(
                        color: _selectedDeviceFilter == 'ALL' ? Colors.white : NexusTheme.textSecondary,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(NexusTheme.radiusPill)),
                    ),
                    const SizedBox(width: 8),
                    ...devices.map((dev) {
                      final count = allNotifs.where((n) => n.senderDevice == dev).length;
                      final isPc = dev.toLowerCase().contains('pc') || dev.toLowerCase().contains('windows');
                      final isSelected = _selectedDeviceFilter == dev;
                      final devColor = NexusDeviceColors.colorForDeviceName(dev);

                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          avatar: Icon(
                            isPc ? Icons.desktop_windows_rounded : Icons.phone_android_rounded,
                            size: 15,
                            color: isSelected ? Colors.white : devColor,
                          ),
                          label: Text('$dev ($count)'),
                          selected: isSelected,
                          onSelected: (sel) {
                            if (sel) setState(() => _selectedDeviceFilter = dev);
                          },
                          selectedColor: devColor,
                          backgroundColor: NexusTheme.surfaceCard,
                          labelStyle: TextStyle(
                            color: isSelected ? Colors.white : NexusTheme.textSecondary,
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(NexusTheme.radiusPill)),
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ),

            // Notifications List Tabs
            Expanded(
              child: TabBarView(
                children: [
                  _buildNotifList(osNotifs),
                  _buildNotifList(internalNotifs),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotifList(List<NexusNotification> listNotifs) {
    if (listNotifs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.notifications_off_outlined, size: 48, color: NexusTheme.textTertiary),
              const SizedBox(height: 12),
              const Text(
                'Nessuna notifica ricevuta',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: NexusTheme.textPrimary),
              ),
              const SizedBox(height: 6),
              const Text(
                'Le notifiche trasmesse appariranno qui,\nschedate per sorgente e categorizzate.',
                textAlign: TextAlign.center,
                style: TextStyle(color: NexusTheme.textSecondary, fontSize: 12, height: 1.4),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: listNotifs.length,
      itemBuilder: (ctx, idx) {
        final notif = listNotifs[idx];
        final isPc = notif.senderDevice.toLowerCase().contains('pc') || notif.senderDevice.toLowerCase().contains('windows');
        final devColor = NexusDeviceColors.colorForDeviceName(notif.senderDevice);
        final timeStr =
            '${notif.timestamp.hour.toString().padLeft(2, '0')}:${notif.timestamp.minute.toString().padLeft(2, '0')}:${notif.timestamp.second.toString().padLeft(2, '0')}';

        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Container(
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: devColor, width: 4)),
              borderRadius: BorderRadius.circular(12),
            ),
            child: NexusCard(
              title: notif.title,
              subtitle: '${notif.appName} • $timeStr',
              icon: isPc ? Icons.desktop_windows_rounded : Icons.phone_android_rounded,
              iconColor: devColor,
              trailing: NexusPill(
                label: notif.senderDevice,
                style: isPc ? NexusPillStyle.accent : NexusPillStyle.success,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (notif.hasSecret && !notif.isRevealed) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: NexusTheme.warningAmberMuted,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: NexusTheme.warningAmber.withAlpha(160)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.security_rounded, size: 16, color: NexusTheme.warningAmber),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  '⚠️ Notifica sanitizzata (${notif.secretCategory})',
                                  style: const TextStyle(
                                    color: NexusTheme.warningAmber,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 11.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            notif.currentBody,
                            style: const TextStyle(
                              color: NexusTheme.textPrimary,
                              fontSize: 12,
                              fontFamily: 'monospace',
                            ),
                          ),
                          const SizedBox(height: 10),
                          Align(
                            alignment: Alignment.centerRight,
                            child: FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFFD97706),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                              ),
                              onPressed: () {
                                LanSyncService.instance.requestNotificationReveal(notif.id);
                              },
                              icon: const Icon(Icons.visibility_rounded, size: 15),
                              label: const Text(
                                'Rivela Notifica Completa',
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ] else ...[
                    Text(
                      notif.currentBody,
                      style: const TextStyle(fontSize: 13.5, height: 1.4, color: NexusTheme.textPrimary),
                    ),
                    if (notif.isRevealed && notif.hasSecret) ...[
                      const SizedBox(height: 8),
                      NexusPill(
                        label: 'Contenuto rivelato su richiesta E2EE',
                        style: NexusPillStyle.success,
                        icon: Icons.lock_open_rounded,
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
