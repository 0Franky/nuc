import 'dart:async';
import 'package:flutter/material.dart';
import '../services/lan_sync_service.dart';
import '../services/logger_service.dart';
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
  static const Duration _revealTimeout = Duration(seconds: 10);
  final Map<String, Timer> _pendingReveals = {};

  @override
  void initState() {
    super.initState();
    _notifSub = LanSyncService.instance.onNotificationReceived.listen(
      (_) {
        if (mounted) setState(() {});
      },
      onError: (Object e) => NexusLogger.log('NOTIFICATIONS', 'Errore stream notifiche: $e'),
    );
    _revealSub = LanSyncService.instance.onNotificationRevealed.listen(
      (notifId) {
        _pendingReveals.remove(notifId)?.cancel();
        if (!mounted) return;
        setState(() {});
        _showRevealMessage('🔓 Notifica rivelata con successo via E2EE!', NexusTheme.successGreen);
      },
      onError: (Object e) => NexusLogger.log('NOTIFICATIONS', 'Errore stream rivelazioni: $e'),
    );
  }

  void _showRevealMessage(String text, Color color, {Duration duration = const Duration(seconds: 2)}) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: Text(text), backgroundColor: color, duration: duration),
    );
  }

  void _requestReveal(String notifId) {
    if (_pendingReveals.containsKey(notifId)) return;
    try {
      LanSyncService.instance.requestNotificationReveal(notifId);
    } catch (e, st) {
      NexusLogger.log('NOTIFICATIONS', 'Richiesta di rivelazione fallita: $e\n$st');
      if (mounted) {
        _showRevealMessage('Impossibile inviare la richiesta di rivelazione', NexusTheme.warningAmber);
      }
      return;
    }
    setState(() {
      _pendingReveals[notifId] = Timer(_revealTimeout, () {
        _pendingReveals.remove(notifId);
        if (!mounted) return;
        setState(() {});
        _showRevealMessage('Nessuna risposta dal dispositivo: riprova', NexusTheme.warningAmber);
      });
    });
    _showRevealMessage('Richiesta inviata, in attesa del dispositivo...', NexusTheme.accentIndigo,
        duration: _revealTimeout);
  }

  @override
  void dispose() {
    _notifSub?.cancel();
    _revealSub?.cancel();
    for (final t in _pendingReveals.values) {
      t.cancel();
    }
    _pendingReveals.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allNotifs = LanSyncService.instance.notifications;
    // Problema 41: conteggi per dispositivo in una sola passata.
    final deviceCounts = <String, int>{};
    for (final n in allNotifs) {
      deviceCounts[n.senderDevice] = (deviceCounts[n.senderDevice] ?? 0) + 1;
    }
    final devices = deviceCounts.keys.toList();
    // Se il dispositivo filtrato non ha più notifiche (es. storico svuotato),
    // si torna a 'ALL' invece di mostrare una lista vuota senza chip selezionato.
    // Assegnazione diretta: il valore è usato subito in questo build.
    if (_selectedDeviceFilter != 'ALL' && !deviceCounts.containsKey(_selectedDeviceFilter)) {
      _selectedDeviceFilter = 'ALL';
    }

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
                      final count = deviceCounts[dev] ?? 0;
                      final isPc = _isPcDevice(dev);
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

  /// Unico punto in cui si deduce il tipo di dispositivo dal nome (problema 42).
  /// Il servizio non espone la piattaforma del peer: si usano parole intere,
  /// così nomi come "Epcot" non vengono più classificati come PC.
  static final RegExp _pcNamePattern =
      RegExp(r'(^|[^a-z0-9])(pc|windows|win|desktop|laptop|notebook|mac|macbook|imac|linux)([^a-z0-9]|$)');

  static bool _isPcDevice(String name) => _pcNamePattern.hasMatch(name.toLowerCase());

  /// Orario della notifica; aggiunge la data se non è di oggi (problema 44).
  static String _formatTimestamp(DateTime ts) {
    String two(int v) => v.toString().padLeft(2, '0');
    final now = DateTime.now();
    final time = '${two(ts.hour)}:${two(ts.minute)}:${two(ts.second)}';
    final sameDay = ts.year == now.year && ts.month == now.month && ts.day == now.day;
    return sameDay ? time : '${two(ts.day)}/${two(ts.month)}/${ts.year} $time';
  }

  Widget _buildNotifList(List<NexusNotification> listNotifs) {
    if (listNotifs.isEmpty) {
      // Problema 43: distingue la lista vuota per filtro da quella senza notifiche.
      final isFiltered = _selectedDeviceFilter != 'ALL';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.notifications_off_outlined, size: 48, color: NexusTheme.textTertiary),
              const SizedBox(height: 12),
              Text(
                isFiltered ? 'Nessuna notifica da $_selectedDeviceFilter' : 'Nessuna notifica ricevuta',
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: NexusTheme.textPrimary),
              ),
              const SizedBox(height: 6),
              Text(
                isFiltered
                    ? 'Il filtro dispositivo esclude le notifiche\ndi questa categoria.'
                    : 'Le notifiche trasmesse appariranno qui,\nschedate per sorgente e categorizzate.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: NexusTheme.textSecondary, fontSize: 12, height: 1.4),
              ),
              if (isFiltered) ...[
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: () => setState(() => _selectedDeviceFilter = 'ALL'),
                  icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
                  label: const Text('Mostra tutti i dispositivi'),
                ),
              ],
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
        final isPc = _isPcDevice(notif.senderDevice);
        final devColor = NexusDeviceColors.colorForDeviceName(notif.senderDevice);
        final timeStr = _formatTimestamp(notif.timestamp);

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
                              onPressed: _pendingReveals.containsKey(notif.id)
                                  ? null
                                  : () => _requestReveal(notif.id),
                              icon: _pendingReveals.containsKey(notif.id)
                                  ? const SizedBox(
                                      width: 15,
                                      height: 15,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                    )
                                  : const Icon(Icons.visibility_rounded, size: 15),
                              label: Text(
                                _pendingReveals.containsKey(notif.id)
                                    ? 'Richiesta in corso...'
                                    : 'Rivela Notifica Completa',
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
