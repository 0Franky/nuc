import 'dart:async';
import 'package:flutter/foundation.dart';
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
    _topologySub = LanSyncService.instance.onTopologyChanged
        .listen((_) => _syncFromService(force: true));
    // Polling di riserva per distanza/movimento BLE: ricostruisce solo se qualcosa cambia.
    _timer = Timer.periodic(const Duration(milliseconds: 600), (_) => _syncFromService());
  }

  Object? _lastDistance;
  Object? _lastMotion;
  Object? _lastBleAvailable;
  Object? _lastTargetId;
  int? _lastPeerCount;

  /// Riallinea lo stato locale con il servizio; chiama setState solo se un valore e' cambiato.
  void _syncFromService({bool force = false}) {
    if (!mounted || _isDragging) return;
    final lan = LanSyncService.instance;
    final distance = lan.estimatedDistanceMeters;
    final motion = lan.proximityMotion;
    final ble = lan.isBleHardwareAvailable;
    final targetId = lan.selectedTargetDeviceId;
    final peerCount = lan.discoveredPeers.length;
    final changed = force ||
        _selectedPosition != lan.spatialPosition ||
        _autoPauseMedia != lan.autoPauseMediaOnWalkAway ||
        _wakeOnApproach != lan.wakeOnApproach ||
        _lastDistance != distance ||
        _lastMotion != motion ||
        _lastBleAvailable != ble ||
        _lastTargetId != targetId ||
        _lastPeerCount != peerCount;
    _lastDistance = distance;
    _lastMotion = motion;
    _lastBleAvailable = ble;
    _lastTargetId = targetId;
    _lastPeerCount = peerCount;
    if (!changed) return;
    setState(() {
      _selectedPosition = lan.spatialPosition;
      _autoPauseMedia = lan.autoPauseMediaOnWalkAway;
      _wakeOnApproach = lan.wakeOnApproach;
    });
  }

  @override
  void dispose() {
    _topologySub?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  /// Unico punto di risoluzione del peer target (usato da build e _updatePosition).
  /// Esclude il dispositivo locale, 'self' e i peer senza id stringa.
  Map<String, dynamic>? _resolveTargetPeer() {
    final lan = LanSyncService.instance;
    final selected = lan.selectedTargetPeer;
    if (selected != null && selected['id'] is String) return selected;
    final realPeers = lan.discoveredPeers
        .where((p) => p['id'] is String && p['id'] != lan.deviceId && p['id'] != 'self')
        .toList();
    return realPeers.isNotEmpty ? realPeers.first : null;
  }

  void _updatePosition(String pos) {
    final lan = LanSyncService.instance;
    final targetPeerId = _resolveTargetPeer()?['id'] as String?;

    // Effetti collaterali sul servizio fuori da setState; setState solo per lo stato locale.
    Offset? targetOffset;
    switch (pos.toLowerCase()) {
      case 'left':
        targetOffset = const Offset(-120.0, 0.0);
        break;
      case 'right':
        targetOffset = const Offset(120.0, 0.0);
        break;
      case 'above':
        targetOffset = const Offset(0.0, -90.0);
        break;
      case 'below':
        targetOffset = const Offset(0.0, 90.0);
        break;
      default:
        targetOffset = null;
    }
    // Posizione sconosciuta: niente fallback silenzioso su 'left'.
    if (targetOffset == null) {
      debugPrint('SpatialTopology: posizione sconosciuta ignorata: $pos');
      return;
    }
    lan.spatialPosition = pos;
    lan.lastAutoDeterminedPosition = pos;
    {
      // Senza un peer reale si aggiorna solo la posizione locale, senza sync di rete.
      if (targetPeerId != null) {
        lan.updateDeviceOffset(targetPeerId, targetOffset, syncNetwork: true);
      }
    }
    setState(() => _selectedPosition = pos);
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
    final targetPeer = _resolveTargetPeer();
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
    } else if (motion == "Stationary") {
      motionColor = NexusTheme.successGreen;
      motionText = "Stazionario alla Scrivania (Stationary)";
      motionIcon = Icons.sensors_rounded;
    } else {
      motionColor = NexusTheme.textTertiary;
      motionText = "Movimento Sconosciuto";
      motionIcon = Icons.help_outline_rounded;
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
                      debugPrint('SpatialTopology: sincronizzazione topologia fallita: $e');
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Sincronizzazione non riuscita. Riprova più tardi.')));
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
                      const Icon(Icons.devices_rounded, color: NexusTheme.accentIndigoLight, size: 24),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (targetName != null) ...[
                              Text(
                                _positionTexts(localName, targetName).title,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                _positionTexts(localName, targetName).description,
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
                        icon: const Icon(Icons.swap_horiz_rounded, color: NexusTheme.accentIndigoLight),
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
                        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
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
                    lan.setBleSpatialAutoDetect(value);
                    setState(() {});
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
                  onChanged: (v) async {
                    final previous = _autoPauseMedia;
                    final messenger = ScaffoldMessenger.of(context);
                    setState(() => _autoPauseMedia = v);
                    LanSyncService.instance.autoPauseMediaOnWalkAway = v;
                    try {
                      await LanSyncService.instance.saveSettingBool('autoPauseMediaOnWalkAway', v);
                    } catch (_) {
                      LanSyncService.instance.autoPauseMediaOnWalkAway = previous;
                      if (!mounted) return;
                      setState(() => _autoPauseMedia = previous);
                      messenger.showSnackBar(
                        const SnackBar(content: Text('Impossibile salvare l\'impostazione Auto-Pausa Media')),
                      );
                    }
                  },
                ),
                const Divider(),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Smart Wake on Approach', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                  subtitle: const Text('Risveglia i monitor PC e pre-riscalda la connessione P2P quando ti avvicini',
                      style: TextStyle(fontSize: 11.5, color: NexusTheme.textSecondary)),
                  value: _wakeOnApproach,
                  onChanged: (v) async {
                    final previous = _wakeOnApproach;
                    final messenger = ScaffoldMessenger.of(context);
                    setState(() => _wakeOnApproach = v);
                    LanSyncService.instance.wakeOnApproach = v;
                    try {
                      await LanSyncService.instance.saveSettingBool('wakeOnApproach', v);
                    } catch (_) {
                      LanSyncService.instance.wakeOnApproach = previous;
                      if (!mounted) return;
                      setState(() => _wakeOnApproach = previous);
                      messenger.showSnackBar(
                        const SnackBar(content: Text('Impossibile salvare l\'impostazione Smart Wake')),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Titolo e descrizione per la posizione corrente, con un'unica logica
  /// di mappatura e un fallback neutro esplicito per valori sconosciuti.
  ({String title, String description}) _positionTexts(String localName, String targetName) {
    switch (_selectedPosition.toLowerCase()) {
      case 'right':
        return (
          title: '🖥️ $localName ── 📱 $targetName (a Destra)',
          description: 'Il puntatore del mouse salta su $targetName uscendo dal bordo DESTRO di $localName.',
        );
      case 'left':
        return (
          title: '📱 $targetName (a Sinistra) ── 🖥️ $localName',
          description: 'Il puntatore del mouse salta su $targetName uscendo dal bordo SINISTRO di $localName.',
        );
      case 'above':
        return (
          title: '📱 $targetName (in Alto) ── 🖥️ $localName',
          description: 'Il puntatore del mouse salta su $targetName uscendo dal bordo SUPERIORE di $localName.',
        );
      case 'below':
        return (
          title: '🖥️ $localName ── 📱 $targetName (in Basso)',
          description: 'Il puntatore del mouse salta su $targetName uscendo dal bordo INFERIORE di $localName.',
        );
      default:
        return (
          title: '🖥️ $localName ── 📱 $targetName',
          description: 'Posizione non riconosciuta: seleziona un quadrante per configurare il salto del puntatore.',
        );
    }
  }

  Widget _buildPositionChip(String pos, String label) {
    final isSelected = _selectedPosition.toLowerCase() == pos.toLowerCase();
    return InkWell(
      onTap: () => _updatePosition(pos),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: isSelected ? NexusTheme.accentIndigo : NexusTheme.surfaceCard,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected ? NexusTheme.accentIndigoLight : NexusTheme.borderCard,
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
        for (final peer in lan.discoveredPeers)
          if (peer['id'] is String) peer['id'] as String: peer['name'] as String? ?? 'Dispositivo'},
      onDragging: (active) => _isDragging = active,
      onMove: (id, point) {
        lan.moveTopologyDevice(id, point);
        setState(() => _selectedPosition = lan.spatialPosition);
      },
    );
  }
}
