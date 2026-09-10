import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../services/lan_sync_service.dart';
import '../theme/nexus_theme.dart';
import '../widgets/nexus_card.dart';
import '../widgets/proximity_lock_switch.dart';
import '../widgets/nexus_pill.dart';
import '../widgets/topology_canvas.dart';
import '../widgets/target_device_selector.dart';
import '../widgets/shared_input_panel.dart';

class SpatialTopologyScreen extends StatefulWidget {
  const SpatialTopologyScreen({super.key});

  @override
  State<SpatialTopologyScreen> createState() => _SpatialTopologyScreenState();
}

class _SpatialTopologyScreenState extends State<SpatialTopologyScreen> {
  String _selectedPosition = LanSyncService.instance.spatialPosition;
  bool _autoPauseMedia = LanSyncService.instance.autoPauseMediaOnWalkAway;
  bool _wakeOnApproach = LanSyncService.instance.wakeOnApproach;
  bool _isDragging = false;

  Timer? _timer;
  StreamSubscription? _topologySub;

  @override
  void initState() {
    super.initState();
    _topologySub = LanSyncService.instance.onTopologyChanged.listen((_) {
      if (mounted && !_isDragging) {
        setState(() {
          _selectedPosition = LanSyncService.instance.spatialPosition;
        });
      }
    });
    _timer = Timer.periodic(const Duration(milliseconds: 600), (_) {
      if (mounted && !_isDragging) {
        setState(() {
          _selectedPosition = LanSyncService.instance.spatialPosition;
        });
      }
    });
  }

  @override
  void dispose() {
    _topologySub?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  void _updatePosition(String pos) {
    final lan = LanSyncService.instance;
    final peers = lan.discoveredPeers.where((p) => p['id'] != lan.deviceId).toList();
    final targetPeerId = lan.selectedTargetDeviceId ?? (peers.isNotEmpty ? peers.first['id'] as String : 'self');

    setState(() {
      _selectedPosition = pos;
      lan.spatialPosition = pos;
      lan.lastAutoDeterminedPosition = pos;
      Offset targetOffset;
      switch (pos.toLowerCase()) {
        case 'right':
          targetOffset = const Offset(120.0, 0.0);
          break;
        case 'above':
          targetOffset = const Offset(0.0, -90.0);
          break;
        case 'below':
          targetOffset = const Offset(0.0, 90.0);
          break;
        case 'left':
        default:
          targetOffset = const Offset(-120.0, 0.0);
          break;
      }
      lan.updateDeviceOffset(targetPeerId, targetOffset, syncNetwork: true);
    });
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Disposizione Spaziale Aggiornata: Dispositivo impostato $pos'),
        backgroundColor: NexusTheme.accentIndigo,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lan = LanSyncService.instance;
    final isBleAvailable = lan.isBleHardwareAvailable;
    final distance = lan.estimatedDistanceMeters;
    final motion = lan.proximityMotion;
    final localName = lan.deviceName;
    final realPeers = lan.discoveredPeers
        .where((p) => p['id'] != lan.deviceId && p['id'] != 'self')
        .toList();
    final targetPeer = lan.selectedTargetPeer ?? (realPeers.isNotEmpty ? realPeers.first : null);
    final targetName = targetPeer?['name'] as String?;

    Color motionColor;
    String motionText;
    IconData motionIcon;

    if (!isBleAvailable) {
      motionColor = NexusTheme.textTertiary;
      motionText = "Bluetooth Non Attivo sul Dispositivo";
      motionIcon = Icons.bluetooth_disabled_rounded;
    } else if (distance == null) {
      motionColor = NexusTheme.accentIndigo;
      motionText = "In Attesa di Segnale BLE dal Peer...";
      motionIcon = Icons.sensors_off_rounded;
    } else if (motion == "Approaching") {
      motionColor = NexusTheme.successGreen;
      motionText = "In Avvicinamento (Approaching)";
      motionIcon = Icons.arrow_downward_rounded;
    } else if (motion == "MovingAway") {
      motionColor = NexusTheme.errorRed;
      motionText = "In Allontanamento (Moving Away)";
      motionIcon = Icons.arrow_upward_rounded;
    } else {
      motionColor = NexusTheme.successGreen;
      motionText = "Stazionario alla Scrivania (Stationary)";
      motionIcon = Icons.sensors_rounded;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Schermi & Prossimità'),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          // 0. Target Device Context Bar
          const TargetDeviceSelector(
            compact: true,
            title: 'Dispositivo Target per Schermi & Input',
          ),
          const SizedBox(height: 10),

          // 1. macOS Displays Arrangement Aesthetic Canvas
          NexusCard(
            title: 'Disposizione Schermi Universal Control',
            subtitle: 'Trascina le icone per definire la posizione fisica dei monitor',
            icon: Icons.monitor_rounded,
            iconColor: NexusTheme.accentIndigo,
            trailing: NexusPill(
              label: _selectedPosition.toUpperCase(),
              style: NexusPillStyle.success,
              showDot: true,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSpatialCanvas(),
                const SizedBox(height: 12),
                FilledButton.icon(
                  icon: const Icon(Icons.sync),
                  label: const Text('Sincronizza topologia con gli altri dispositivi'),
                  onPressed: () async {
                    try {
                      await LanSyncService.instance.synchronizeTopology();
                      if (mounted) setState(() {});
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Sincronizzazione non riuscita: $e')));
                      }
                    }
                  },
                ),
                if (LanSyncService.instance.topologySyncEnabled)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('Sincronizzazione automatica attiva. Le modifiche vengono condivise; i dispositivi già disposti si aggiornano anche alla riconnessione. Richiede la nuova versione su tutte le macchine.'),
                  ),
                const SizedBox(height: 14),

                // Real status description card
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: NexusTheme.surfaceSecondary,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: NexusTheme.borderCard),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.devices_rounded, color: Color(0xFF818CF8), size: 24),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (targetName != null) ...[
                              Text(
                                _selectedPosition.toLowerCase() == 'right'
                                    ? '🖥️ $localName ── 📱 $targetName (a Destra)'
                                    : _selectedPosition.toLowerCase() == 'left'
                                        ? '📱 $targetName (a Sinistra) ── 🖥️ $localName'
                                        : _selectedPosition.toLowerCase() == 'above'
                                            ? '📱 $targetName (in Alto) ── 🖥️ $localName'
                                            : '🖥️ $localName ── 📱 $targetName (in Basso)',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                _selectedPosition.toLowerCase() == 'right'
                                    ? 'Il puntatore del mouse salta su $targetName uscendo dal bordo DESTRO di $localName.'
                                    : _selectedPosition.toLowerCase() == 'left'
                                        ? 'Il puntatore del mouse salta su $targetName uscendo dal bordo SINISTRO di $localName.'
                                        : _selectedPosition.toLowerCase() == 'above'
                                            ? 'Il puntatore del mouse salta su $targetName uscendo dal bordo SUPERIORE di $localName.'
                                            : 'Il puntatore del mouse salta su $targetName uscendo dal bordo INFERIORE di $localName.',
                                style: const TextStyle(color: NexusTheme.textSecondary, fontSize: 11.5),
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                '💡 Trascina liberamente il dispositivo nello spazio 2D oppure seleziona un quadrante:',
                                style: TextStyle(color: NexusTheme.successGreen, fontSize: 10.5, fontStyle: FontStyle.italic),
                              ),
                            ] else ...[
                              const Text(
                                '📡 In attesa di dispositivi LAN connessi...',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
                              ),
                              const SizedBox(height: 3),
                              const Text(
                                'Connetti un secondo nodo Nexus sulla stessa rete Wi-Fi per disporre gli schermi.',
                                style: TextStyle(color: NexusTheme.textSecondary, fontSize: 11.5),
                              ),
                            ],
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: [
                                _buildPositionChip('Left', '⬅️ Sinistra'),
                                _buildPositionChip('Right', '➡️ Destra'),
                                _buildPositionChip('Above', '⬆️ In Alto'),
                                _buildPositionChip('Below', '⬇️ In Basso'),
                              ],
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.swap_horiz_rounded, color: Color(0xFF818CF8)),
                        tooltip: 'Inverti Sinistra / Destra',
                        onPressed: () {
                          _updatePosition(_selectedPosition.toLowerCase() == 'right' ? 'Left' : 'Right');
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // Hardware Status Alert when Bluetooth is OFF
                if (!isBleAvailable) ...[
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: NexusTheme.warningAmber.withAlpha(25),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: NexusTheme.warningAmber.withAlpha(90)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.bluetooth_disabled_rounded, color: NexusTheme.warningAmber, size: 20),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Bluetooth disattivato sul dispositivo. Attiva il Bluetooth per consentire il rilevamento di prossimità.',
                            style: TextStyle(color: NexusTheme.warningAmber, fontSize: 11, fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (Platform.isAndroid)
                          TextButton(
                            onPressed: () => LanSyncService.instance.openBluetoothSettings(),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: const Text('ATTIVA', style: TextStyle(color: NexusTheme.warningAmber, fontWeight: FontWeight.bold, fontSize: 11)),
                          ),
                      ],
                    ),
                  ),
                ],

                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Monitoraggio prossimità Bluetooth'),
                  subtitle: const Text('Il segnale BLE non determina sinistra e destra. Disponi i dispositivi sul canvas e sincronizza la topologia.'),
                  value: isBleAvailable && lan.bleSpatialAutoDetect,
                  onChanged: isBleAvailable ? (value) {
                    setState(() => lan.setBleSpatialAutoDetect(value));
                  } : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 2. Proximity & Motion Radar
          NexusCard(
            title: 'Prossimità BLE stimata',
            subtitle: lan.proximityStatus,
            icon: motionIcon,
            iconColor: motionColor,
            trailing: NexusPill(
              label: !isBleAvailable
                  ? 'RADIO OFF'
                  : distance != null
                      ? '≈ ${distance.toStringAsFixed(1)} m'
                      : LanSyncService.instance.isConnected
                          ? 'SCANNING'
                          : 'NO SIGNAL',
              style: !isBleAvailable
                  ? NexusPillStyle.neutral
                  : (distance != null && distance < 1.8)
                      ? NexusPillStyle.success
                      : (distance != null)
                          ? NexusPillStyle.warning
                          : NexusPillStyle.neutral,
              icon: Icons.radar_rounded,
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: motionColor.withAlpha(30),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(motionIcon, color: motionColor, size: 28),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(motionText, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: motionColor)),
                      const SizedBox(height: 4),
                      Text(
                        lan.proximityStatus,
                        style: const TextStyle(fontSize: 11.5, color: NexusTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 3. Universal Control & Proximity Triggers
          NexusCard(
            title: 'Automazioni di Prossimità & Bordi Schermo',
            subtitle: 'Regole intelligenti al cambio di raggio e transizione bordi',
            icon: Icons.tune_rounded,
            iconColor: NexusTheme.accentIndigo,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SharedInputPanel(),
                const Divider(),
                const ProximityLockSwitch(),
                const Divider(),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Auto-Pausa Media & Handoff Cellulare', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                  subtitle: const Text('Pausa automaticamente il PC e mostra la notifica di ripresa su smartphone quando ti allontani',
                      style: TextStyle(fontSize: 11.5, color: NexusTheme.textSecondary)),
                  value: _autoPauseMedia,
                  onChanged: (v) {
                    setState(() => _autoPauseMedia = v);
                    LanSyncService.instance.autoPauseMediaOnWalkAway = v;
                    LanSyncService.instance.saveSettingBool('autoPauseMediaOnWalkAway', v);
                  },
                ),
                const Divider(),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Smart Wake on Approach', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                  subtitle: const Text('Risveglia i monitor PC e pre-riscalda la connessione P2P quando ti avvicini',
                      style: TextStyle(fontSize: 11.5, color: NexusTheme.textSecondary)),
                  value: _wakeOnApproach,
                  onChanged: (v) {
                    setState(() => _wakeOnApproach = v);
                    LanSyncService.instance.wakeOnApproach = v;
                    LanSyncService.instance.saveSettingBool('wakeOnApproach', v);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPositionChip(String pos, String label) {
    final isSelected = _selectedPosition.toLowerCase() == pos.toLowerCase();
    return InkWell(
      onTap: () => _updatePosition(pos),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF6366F1) : const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected ? const Color(0xFF818CF8) : Colors.white24,
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 9.5,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color: isSelected ? Colors.white : Colors.grey.shade300,
          ),
        ),
      ),
    );
  }

  Widget _buildSpatialCanvas() {
    final lan = LanSyncService.instance;
    return TopologyCanvas(
      points: lan.topologyPoints,
      localId: lan.deviceId,
      names: {lan.deviceId: lan.deviceName,
        for (final peer in lan.discoveredPeers) peer['id'] as String: peer['name'] as String? ?? 'Dispositivo'},
      onDragging: (active) => _isDragging = active,
      onMove: (id, point) {
        lan.moveTopologyDevice(id, point);
        setState(() => _selectedPosition = lan.spatialPosition);
      },
    );
  }
}
