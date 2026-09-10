import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../services/lan_sync_service.dart';
import '../theme/nexus_theme.dart';
import '../widgets/nexus_card.dart';
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
  bool _autoLock = LanSyncService.instance.autoLockOnWalkAway;
  bool _autoPauseMedia = LanSyncService.instance.autoPauseMediaOnWalkAway;
  bool _wakeOnApproach = LanSyncService.instance.wakeOnApproach;
  bool _bleAutoDetect = LanSyncService.instance.bleSpatialAutoDetect;
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
          if (_bleAutoDetect) {
            _selectedPosition = LanSyncService.instance.spatialPosition;
          }
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

                // Auto-determine BLE Switch Container
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: NexusTheme.surfaceSecondary,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: (isBleAvailable && _bleAutoDetect) ? NexusTheme.successGreen.withAlpha(120) : NexusTheme.borderCard,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            isBleAvailable ? Icons.bluetooth_searching_rounded : Icons.bluetooth_disabled_rounded,
                            size: 20,
                            color: (isBleAvailable && _bleAutoDetect) ? NexusTheme.successGreen : NexusTheme.textTertiary,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Auto-Determina via Bluetooth LE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                Text(
                                  !isBleAvailable
                                      ? 'Disabilitato: Nessun adattatore Bluetooth attivo sul dispositivo'
                                      : _bleAutoDetect
                                          ? 'Posizione calcolata automaticamente dal raggio radio BLE (<1.8m desk)'
                                          : 'Controllo manuale attivo (tocca o trascina sullo slot desiderato)',
                                  style: TextStyle(
                                    color: !isBleAvailable ? NexusTheme.warningAmber : NexusTheme.textSecondary,
                                    fontSize: 10.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: isBleAvailable && _bleAutoDetect,
                            onChanged: isBleAvailable
                                ? (v) {
                                    setState(() {
                                      _bleAutoDetect = v;
                                      LanSyncService.instance.setBleSpatialAutoDetect(v);
                                      if (v && LanSyncService.instance.estimatedDistanceMeters != null) {
                                        _selectedPosition = LanSyncService.instance.spatialPosition;
                                      }
                                    });
                                  }
                                : null,
                          ),
                        ],
                      ),
                      if (isBleAvailable && _bleAutoDetect) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                          decoration: BoxDecoration(
                            color: LanSyncService.instance.isTopologyScanActive
                                ? NexusTheme.accentIndigo.withAlpha(20)
                                : NexusTheme.successGreen.withAlpha(20),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: LanSyncService.instance.isTopologyScanActive
                                  ? NexusTheme.accentIndigo.withAlpha(60)
                                  : NexusTheme.successGreen.withAlpha(60),
                              width: 0.8,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                LanSyncService.instance.isTopologyScanActive
                                    ? Icons.sync_rounded
                                    : Icons.check_circle_outline_rounded,
                                size: 14,
                                color: LanSyncService.instance.isTopologyScanActive
                                    ? NexusTheme.accentIndigo
                                    : NexusTheme.successGreen,
                              ),
                              const SizedBox(width: 7),
                              Expanded(
                                child: Text(
                                  LanSyncService.instance.isTopologyScanActive
                                      ? 'Scansione Topologia attiva (${LanSyncService.instance.consecutiveUnchangedScans}/3) • In ascolto'
                                      : 'Topologia stabilizzata (3/3 scansioni identiche) • Prossimità BLE attiva',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: LanSyncService.instance.isTopologyScanActive
                                        ? NexusTheme.accentIndigo
                                        : NexusTheme.successGreen,
                                  ),
                                ),
                              ),
                              if (!LanSyncService.instance.isTopologyScanActive)
                                InkWell(
                                  onTap: () {
                                    setState(() {
                                      LanSyncService.instance.restartSpatialTopologyScan(isManual: true);
                                      _bleAutoDetect = true;
                                      _selectedPosition = LanSyncService.instance.spatialPosition;
                                    });
                                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('🔍 Nuova scansione topologia avviata... Posizione: $_selectedPosition'),
                                        backgroundColor: NexusTheme.accentIndigo,
                                        duration: const Duration(seconds: 2),
                                      ),
                                    );
                                  },
                                  child: const Padding(
                                    padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    child: Text(
                                      'RISCANSIONA',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: NexusTheme.accentIndigo,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],

                      // Flapping suppression warning message (>2 changes in 5 min)
                      if (LanSyncService.instance.isAutoScanSuppressedDueToFlapping) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: NexusTheme.warningAmber.withAlpha(25),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: NexusTheme.warningAmber.withAlpha(90)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.warning_amber_rounded, color: NexusTheme.warningAmber, size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  LanSyncService.instance.scanFlappingWarningMessage ??
                                      'Scansione automatica disattivata per saturazione: rilevate più di 2 variazioni in 5 minuti.',
                                  style: const TextStyle(color: NexusTheme.warningAmber, fontSize: 11, fontWeight: FontWeight.w600),
                                ),
                              ),
                              TextButton(
                                onPressed: () {
                                  setState(() {
                                    LanSyncService.instance.restartSpatialTopologyScan(isManual: true);
                                    _bleAutoDetect = true;
                                  });
                                },
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  minimumSize: Size.zero,
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                ),
                                child: const Text('RISCANSIONA', style: TextStyle(color: NexusTheme.warningAmber, fontWeight: FontWeight.bold, fontSize: 11)),
                              ),
                            ],
                          ),
                        ),
                      ],
                ],
              ),
            ),
          ],
        ),
      ),
          const SizedBox(height: 16),

          // 2. Proximity & Motion Radar
          NexusCard(
            title: 'Radar Prossimità BLE & Vettore Moto',
            subtitle: !isBleAvailable
                ? 'Radio Bluetooth disattivata a livello di sistema operativo'
                : distance != null
                    ? 'Stima continua di distanza e presenza sulla postazione'
                    : LanSyncService.instance.isConnected
                        ? 'Peer LAN collegato • In attesa di pacchetti BLE beacon...'
                        : 'In ascolto beacon BLE del dispositivo associato...',
            icon: motionIcon,
            iconColor: motionColor,
            trailing: NexusPill(
              label: !isBleAvailable
                  ? 'RADIO OFF'
                  : distance != null
                      ? '${distance.toStringAsFixed(1)} m'
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
                        !isBleAvailable
                            ? 'Attiva il Bluetooth in Windows/Android per avviare il filtro Kalman'
                            : distance != null
                                ? 'Filtro di Kalman 1D attivo • ${LanSyncService.instance.liveRssi != null ? "RSSI ${LanSyncService.instance.liveRssi} dBm • " : ""}Precisione ±0.15m'
                                : LanSyncService.instance.isConnected
                                    ? 'Connessione LAN P2P attiva • In attesa del primo campionamento RF'
                                    : 'Associa un peer ed entra nel raggio Bluetooth per la misurazione',
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
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Smart Walk-Away Lock (Auto-Lock)', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                  subtitle: const Text('Blocca istantaneamente il PC quando ti allontani dalla scrivania',
                      style: TextStyle(fontSize: 11.5, color: NexusTheme.textSecondary)),
                  value: _autoLock,
                  onChanged: (v) {
                    setState(() => _autoLock = v);
                    LanSyncService.instance.autoLockOnWalkAway = v;
                    LanSyncService.instance.saveSettingBool('autoLockOnWalkAway', v);
                  },
                ),
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
