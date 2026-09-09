import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/lan_sync_service.dart';
import '../services/logger_service.dart';
import '../services/nexus_ffi_bridge.dart';
import '../theme/nexus_theme.dart';
import '../widgets/nexus_card.dart';
import '../widgets/nexus_pill.dart';
import '../widgets/nexus_media_card.dart';
import '../widgets/nexus_audio_card.dart';
import 'notification_screen.dart';

class DashboardScreen extends StatefulWidget {
  final ValueChanged<int>? onNavigateTab;

  const DashboardScreen({super.key, this.onNavigateTab});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  Timer? _pollTimer;
  Map<String, dynamic> _engineState = {};
  String? _lastLoggedMediaTitle;
  StreamSubscription<Map<String, dynamic>>? _openUrlSub;
  StreamSubscription<Map<String, dynamic>>? _mediaPromptSub;

  @override
  void initState() {
    super.initState();
    _fetchState();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => _fetchState());

    _openUrlSub = LanSyncService.instance.onOpenUrl.listen((data) {
      final url = data['url'] as String? ?? '';
      final title = data['title'] as String? ?? 'Video PC';
      if (mounted && url.isNotEmpty) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: NexusTheme.accentIndigo,
            content: Text('🎬 Video Trasferito: $title'),
            action: SnackBarAction(
              label: 'APRI ORA',
              textColor: NexusTheme.successGreen,
              onPressed: () {
                NexusFfiBridge.instance.sendMediaControl('PAUSE');
                launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
              },
            ),
            duration: const Duration(seconds: 8),
          ),
        );
      }
    });

    _mediaPromptSub = LanSyncService.instance.onMediaHandoffPrompt.listen((data) {
      if (!mounted) return;
      final title = data['title'] as String? ?? 'Video PC';
      final timestampedUrl = data['timestamped_url'] as String? ?? (data['media_url'] as String? ?? '');
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: NexusTheme.surfaceCard,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: NexusTheme.accentIndigo, width: 1.5),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          duration: const Duration(seconds: 12),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withAlpha(40),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(Icons.pause_circle_filled_rounded, color: Colors.redAccent, size: 16),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'PC in Pausa (Allontanamento)',
                    style: TextStyle(color: NexusTheme.textSecondary, fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'Vuoi continuare la riproduzione qui?',
                style: TextStyle(color: NexusTheme.textPrimary, fontSize: 14, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 2),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: NexusTheme.textSecondary, fontSize: 12),
              ),
            ],
          ),
          action: SnackBarAction(
            label: 'RIPRODUCI',
            textColor: NexusTheme.accentIndigo,
            onPressed: () {
              if (timestampedUrl.isNotEmpty) {
                NexusLogger.log('HANDOFF', 'User confirmed handoff playback on mobile: $timestampedUrl');
                launchUrl(Uri.parse(timestampedUrl), mode: LaunchMode.externalApplication);
              }
            },
          ),
        ),
      );
    });

    NexusLogger.log('UI', 'Dashboard initialized. Starting 500ms state polling.');
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _openUrlSub?.cancel();
    _mediaPromptSub?.cancel();
    super.dispose();
  }

  void _fetchState() {
    final state = NexusFfiBridge.instance.getState();
    if (mounted) {
      setState(() {
        _engineState = state;
      });
    }

    final active = state['active_media'] as Map<String, dynamic>?;
    final title = active != null ? active['media_title'] as String? : null;
    if (title != _lastLoggedMediaTitle) {
      _lastLoggedMediaTitle = title;
      NexusLogger.log('UI_STATE', 'Active media state changed: $active');
    }
  }

  void _showPairingDialog(BuildContext context) {
    final localIp = _engineState['local_lan_ip'] as String? ?? '127.0.0.1';
    final pairingPayload = 'nexus://pair?host=$localIp&port=28471&id=${LanSyncService.instance.deviceId}';

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NexusTheme.surfaceCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(NexusTheme.radiusModal)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: NexusTheme.accentIndigo.withAlpha(40),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.qr_code_rounded, color: NexusTheme.accentIndigo, size: 20),
            ),
            const SizedBox(width: 10),
            const Text('Associazione Rapida', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Inquadra il codice con un altro dispositivo Nexus sulla stessa rete LAN Wi-Fi:',
              style: TextStyle(fontSize: 13, color: NexusTheme.textSecondary),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: QrImageView(
                data: pairingPayload,
                version: QrVersions.auto,
                size: 200.0,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'IP Locale: $localIp • Porta 28471 (E2EE ChaCha20)',
              style: const TextStyle(fontSize: 12, color: NexusTheme.textSecondary),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Chiudi', style: TextStyle(color: NexusTheme.accentIndigo)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeMedia = _engineState['active_media'] as Map<String, dynamic>?;
    final audioRelayActive = _engineState['audio_relay_active'] as bool? ?? false;
    final volume = (_engineState['audio_volume'] as num?)?.toDouble() ?? 0.80;
    final rawPeers = _engineState['discovered_peers'] as List? ?? [];
    final peers = rawPeers.map((p) => p is Map ? Map<String, dynamic>.from(p) : <String, dynamic>{}).where((p) => p.isNotEmpty).toList();

    final isMobile = Platform.isAndroid || Platform.isIOS;
    final isConnected = LanSyncService.instance.isConnected || !isMobile;
    final localIp = _engineState['local_lan_ip'] as String? ?? '127.0.0.1';

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: NexusTheme.accentIndigo.withAlpha(40),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.all_inclusive_rounded, color: NexusTheme.accentIndigo, size: 20),
            ),
            const SizedBox(width: 10),
            const Text('Nexus Universal Continuity'),
          ],
        ),
        actions: [
          IconButton(
            icon: Badge(
              isLabelVisible: LanSyncService.instance.notifications.isNotEmpty,
              label: Text('${LanSyncService.instance.notifications.length}'),
              child: const Icon(Icons.notifications_outlined),
            ),
            tooltip: 'Centro Notifiche',
            onPressed: () {
              if (widget.onNavigateTab != null) {
                widget.onNavigateTab!(1);
              } else {
                Navigator.push(context, MaterialPageRoute(builder: (_) => const NotificationCenterScreen()));
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.qr_code_scanner_rounded),
            tooltip: 'Associa Dispositivo',
            onPressed: () => _showPairingDialog(context),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          // 1. Status Capsule Banner
          NexusCard(
            title: isMobile
                ? (isConnected ? 'Connesso al PC ($localIp)' : 'Ricerca PC su Rete LAN...')
                : 'Nexus Core Attivo (IP: $localIp)',
            subtitle: isMobile
                ? 'Latenza socket ~2ms • E2EE ChaCha20-Poly1305'
                : 'In ascolto su 0.0.0.0:28471 • Canale P2P E2EE Pronto',
            icon: isConnected ? Icons.wifi_rounded : Icons.wifi_find_rounded,
            iconColor: isConnected ? NexusTheme.successGreen : NexusTheme.accentIndigo,
            trailing: NexusPill(
              label: isConnected ? 'Online' : 'Discovery',
              style: isConnected ? NexusPillStyle.success : NexusPillStyle.accent,
              showDot: true,
            ),
          ),
          const SizedBox(height: 16),

          // 2. Continuity Quick Glance Tiles (Control Center Grid)
          const Text(
            'Moduli di Continuità & Accesso Rapido',
            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: NexusTheme.textSecondary),
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final crossAxisCount = constraints.maxWidth > 600 ? 4 : 2;
              return GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: crossAxisCount,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.5,
                children: [
                  _buildQuickTile(
                    title: 'Schermi & Prossimità',
                    subtitle: !LanSyncService.instance.isBleHardwareAvailable
                        ? '${LanSyncService.instance.spatialPosition} • Bluetooth OFF'
                        : LanSyncService.instance.estimatedDistanceMeters != null
                            ? '${LanSyncService.instance.spatialPosition} • ${LanSyncService.instance.estimatedDistanceMeters!.toStringAsFixed(1)}m'
                            : '${LanSyncService.instance.spatialPosition} • BLE Standby',
                    icon: Icons.devices_other_rounded,
                    color: Colors.blueAccent,
                    onTap: () => widget.onNavigateTab?.call(2),
                  ),
                  _buildQuickTile(
                    title: 'File Drop (P2P)',
                    subtitle: 'BLAKE3 • Chunk 64KB',
                    icon: Icons.folder_shared_rounded,
                    color: Colors.orangeAccent,
                    onTap: () => widget.onNavigateTab?.call(3),
                  ),
                  _buildQuickTile(
                    title: 'Magic Trackpad',
                    subtitle: 'Multi-touch & Tastiera',
                    icon: Icons.touch_app_rounded,
                    color: Colors.tealAccent,
                    onTap: () => widget.onNavigateTab?.call(4),
                  ),
                  _buildQuickTile(
                    title: 'Appunti E2EE',
                    subtitle: LanSyncService.instance.clipboardPrivacyGate ? 'Zero-Trust Attivo' : 'Sincronizzazione Diretta',
                    icon: Icons.content_paste_rounded,
                    color: Colors.purpleAccent,
                    onTap: () => widget.onNavigateTab?.call(5),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),

          // 3. Now Playing (Unified Component)
          if (activeMedia != null) ...[
            NexusMediaCard(media: activeMedia),
            const SizedBox(height: 16),
          ],

          // 4. Audio Relay (Unified Component)
          NexusAudioCard(
            audioRelayActive: audioRelayActive,
            initialVolume: volume,
          ),
          const SizedBox(height: 16),

          // 5. Discovered Peers (Apple Inset List)
          _buildPeersSection(peers),
        ],
      ),
    );
  }

  Widget _buildQuickTile({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return NexusCard(
      padding: const EdgeInsets.all(12),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: color.withAlpha(35),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 18, color: color),
              ),
              const Icon(Icons.arrow_forward_ios_rounded, size: 11, color: NexusTheme.textTertiary),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: NexusTheme.textPrimary),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: NexusTheme.textSecondary),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPeersSection(List<Map<String, dynamic>> peers) {
    return NexusCard(
      title: 'Dispositivi Connessi & Rilevati',
      subtitle: '${peers.length} nodi attivi sulla rete locale (LAN P2P)',
      icon: Icons.hub_rounded,
      iconColor: NexusTheme.accentIndigo,
      trailing: NexusPill(
        label: '${peers.length} Nodi',
        style: peers.isNotEmpty ? NexusPillStyle.success : NexusPillStyle.neutral,
      ),
      child: peers.isEmpty
          ? Container(
              padding: const EdgeInsets.symmetric(vertical: 20),
              alignment: Alignment.center,
              child: Column(
                children: [
                  Icon(Icons.radar_rounded, size: 36, color: NexusTheme.textTertiary.withAlpha(120)),
                  const SizedBox(height: 8),
                  const Text('In attesa di altri dispositivi Nexus...', style: TextStyle(color: NexusTheme.textSecondary, fontSize: 13)),
                  const SizedBox(height: 2),
                  const Text('Verifica che siano connessi alla stessa rete Wi-Fi.', style: TextStyle(color: NexusTheme.textTertiary, fontSize: 11.5)),
                ],
              ),
            )
          : Column(
              children: peers.map((peer) {
                final name = peer['name'] as String? ?? 'Dispositivo Sconosciuto';
                final ip = peer['ip'] as String? ?? 'N/A';
                final os = peer['os'] as String? ?? 'Dispositivo';
                final isCenter = peer['spatial_position'] == 'Center';

                IconData osIcon = Icons.devices_other_rounded;
                if (os.toLowerCase().contains('win')) {
                  osIcon = Icons.laptop_windows_rounded;
                } else if (os.toLowerCase().contains('and') || os.toLowerCase().contains('ios')) {
                  osIcon = Icons.phone_iphone_rounded;
                } else if (os.toLowerCase().contains('mac')) {
                  osIcon = Icons.laptop_mac_rounded;
                }

                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: NexusTheme.surfaceSecondary,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: NexusTheme.borderCard),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: NexusTheme.accentIndigo.withAlpha(35),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(osIcon, color: NexusTheme.accentIndigo, size: 18),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                            Text('$ip • $os${isCenter ? " • Hub Centrale" : ""}', style: const TextStyle(color: NexusTheme.textSecondary, fontSize: 11.5)),
                          ],
                        ),
                      ),
                      NexusPill(
                        label: 'E2EE',
                        style: NexusPillStyle.success,
                        icon: Icons.lock_outline_rounded,
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
    );
  }
}
