import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../services/lan_sync_service.dart';
import '../theme/nexus_theme.dart';
import '../widgets/nexus_card.dart';
import '../widgets/nexus_pill.dart';
import '../widgets/nexus_button.dart';
import '../widgets/spatial_grid_painter.dart';
import '../widgets/target_device_selector.dart';

class SpatialTopologyScreen extends StatefulWidget {
  const SpatialTopologyScreen({super.key});

  @override
  State<SpatialTopologyScreen> createState() => _SpatialTopologyScreenState();
}

class _SpatialTopologyScreenState extends State<SpatialTopologyScreen> {
  String _selectedPosition = LanSyncService.instance.spatialPosition;
  bool _universalControl = LanSyncService.instance.universalControlActive;
  bool _autoLock = LanSyncService.instance.autoLockOnWalkAway;
  bool _autoPauseMedia = LanSyncService.instance.autoPauseMediaOnWalkAway;
  bool _wakeOnApproach = LanSyncService.instance.wakeOnApproach;
  bool _bleAutoDetect = LanSyncService.instance.bleSpatialAutoDetect;

  Timer? _timer;
  StreamSubscription? _topologySub;

  @override
  void initState() {
    super.initState();
    _topologySub = LanSyncService.instance.onTopologyChanged.listen((_) {
      if (mounted) {
        setState(() {
          _selectedPosition = LanSyncService.instance.spatialPosition;
        });
      }
    });
    _timer = Timer.periodic(const Duration(milliseconds: 600), (_) {
      if (mounted) {
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
    setState(() {
      _selectedPosition = pos;
      LanSyncService.instance.spatialPosition = pos;
      LanSyncService.instance.lastAutoDeterminedPosition = pos;
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
      LanSyncService.instance.updateDeviceOffset('self', targetOffset);
    });
    LanSyncService.instance.sendSpatialArrangement("target-peer-node", pos);
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
    final isBleAvailable = LanSyncService.instance.isBleHardwareAvailable;
    final distance = LanSyncService.instance.estimatedDistanceMeters;
    final motion = LanSyncService.instance.proximityMotion;

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
                            Text(
                              _selectedPosition.toLowerCase() == 'right'
                                  ? '💻 Computer a Sinistra ── 📱 Telefono a Destra'
                                  : _selectedPosition.toLowerCase() == 'left'
                                      ? '📱 Telefono a Sinistra ── 💻 Computer a Destra'
                                      : _selectedPosition.toLowerCase() == 'above'
                                          ? '📱 Telefono in Alto ── 💻 Computer in Basso'
                                          : '💻 Computer in Alto ── 📱 Telefono in Basso',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              _selectedPosition.toLowerCase() == 'right'
                                  ? 'Il puntatore del mouse salta sul telefono uscendo dal bordo DESTRO del PC.'
                                  : _selectedPosition.toLowerCase() == 'left'
                                      ? 'Il puntatore del mouse salta sul telefono uscendo dal bordo SINISTRO del PC.'
                                      : _selectedPosition.toLowerCase() == 'above'
                                          ? 'Il puntatore del mouse salta sul telefono uscendo dal bordo SUPERIORE del PC.'
                                          : 'Il puntatore del mouse salta sul telefono uscendo dal bordo INFERIORE del PC.',
                              style: const TextStyle(color: NexusTheme.textSecondary, fontSize: 11.5),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              '💡 Trascina liberamente il quadrato del Telefono oppure seleziona una posizione:',
                              style: TextStyle(color: NexusTheme.successGreen, fontSize: 10.5, fontStyle: FontStyle.italic),
                            ),
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
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Universal Control (Seamless Edge Hop)', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                  subtitle: const Text('Passa il mouse oltre il bordo dello schermo per controllare l\'altro dispositivo',
                      style: TextStyle(fontSize: 11.5, color: NexusTheme.textSecondary)),
                  value: _universalControl,
                  onChanged: (v) {
                    setState(() => _universalControl = v);
                    LanSyncService.instance.universalControlActive = v;
                    LanSyncService.instance.saveSettingBool('universalControlActive', v);
                  },
                ),
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
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: NexusButton(
                        label: 'Passa a DX',
                        icon: Icons.arrow_forward_rounded,
                        style: NexusButtonStyle.secondary,
                        onPressed: () {
                          LanSyncService.instance.sendUniversalControlHop(2, 540, 1920, 1080);
                          ScaffoldMessenger.of(context).hideCurrentSnackBar();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('🖱️ Test Passaggio Cursore a Destra inviato!'), duration: Duration(seconds: 2)),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: NexusButton(
                        label: 'Blocca PC',
                        icon: Icons.lock_rounded,
                        style: NexusButtonStyle.ghost,
                        onPressed: () {
                          LanSyncService.instance.sendProximityTrigger("LOCK_WORKSTATION");
                          ScaffoldMessenger.of(context).hideCurrentSnackBar();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('🔒 Test Blocco PC inviato!'), duration: Duration(seconds: 2)),
                          );
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                NexusButton(
                  label: 'Test Allontanamento (Pausa PC & Handoff)',
                  icon: Icons.directions_walk_rounded,
                  style: NexusButtonStyle.secondary,
                  onPressed: () {
                    LanSyncService.instance.triggerProximityDepartureHandoff(simulate: true);
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('🚶 Test Allontanamento: Pausa PC richiesta e notifica emessa!'),
                        backgroundColor: NexusTheme.accentIndigo,
                        duration: Duration(seconds: 3),
                      ),
                    );
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
    final liveDistance = LanSyncService.instance.estimatedDistanceMeters;
    final selfOffset = LanSyncService.instance.getDeviceOffset('self');

    // List of peers from LanSyncService
    final peers = LanSyncService.instance.discoveredPeers;

    return Container(
      width: double.infinity,
      height: 280,
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NexusTheme.borderCard),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final centerX = constraints.maxWidth / 2;
          final centerY = constraints.maxHeight / 2;

          return Stack(
            clipBehavior: Clip.none,
            children: [
              // Grid background lines for spatial orientation
              CustomPaint(
                size: Size(constraints.maxWidth, constraints.maxHeight),
                painter: const SpatialGridPainter(),
              ),

              // PC Node (Fixed in Center)
              Positioned(
                left: centerX - 58,
                top: centerY - 47,
                child: Container(
                  width: 116,
                  height: 94,
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6366F1).withAlpha(40),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF6366F1), width: 1.5),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF6366F1).withAlpha(60),
                        blurRadius: 10,
                        spreadRadius: 1,
                      )
                    ],
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.desktop_windows_rounded, size: 20, color: Color(0xFF818CF8)),
                        const SizedBox(height: 2),
                        const Text(
                          'PC Principale',
                          style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Colors.white),
                          textAlign: TextAlign.center,
                        ),
                        Text(
                          liveDistance != null ? '${liveDistance.toStringAsFixed(1)}m' : 'Host Centro',
                          style: const TextStyle(fontSize: 8.5, color: Colors.grey),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // Connection line from PC center to Phone
              CustomPaint(
                size: Size(constraints.maxWidth, constraints.maxHeight),
                painter: SpatialLinePainter(
                  start: Offset(centerX, centerY),
                  end: Offset(centerX + selfOffset.dx, centerY + selfOffset.dy),
                  color: const Color(0xFF10B981).withAlpha(120),
                ),
              ),

              // Primary Phone Node (Freeform Draggable anywhere in 2D space)
              Positioned(
                left: (centerX + selfOffset.dx) - 52,
                top: (centerY + selfOffset.dy) - 48,
                child: GestureDetector(
                  onPanUpdate: (details) {
                    setState(() {
                      final newX = (selfOffset.dx + details.delta.dx).clamp(-centerX + 60, centerX - 60);
                      final newY = (selfOffset.dy + details.delta.dy).clamp(-centerY + 50, centerY - 50);
                      final updated = Offset(newX, newY);
                      LanSyncService.instance.updateDeviceOffset('self', updated);
                      _selectedPosition = LanSyncService.instance.spatialPosition;
                    });
                  },
                  child: Container(
                    width: 104,
                    height: 96,
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981).withAlpha(50),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF10B981), width: 2.0),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF10B981).withAlpha(90),
                          blurRadius: 12,
                          spreadRadius: 2,
                        )
                      ],
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.phone_android_rounded, size: 20, color: Color(0xFF10B981)),
                          const SizedBox(height: 1),
                          const Text(
                            'Telefono (Tu)',
                            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Colors.white),
                            textAlign: TextAlign.center,
                          ),
                          Text(
                            liveDistance != null ? '${liveDistance.toStringAsFixed(1)}m • $_selectedPosition' : _selectedPosition,
                            style: const TextStyle(fontSize: 8, color: Color(0xFF6EE7B7)),
                            textAlign: TextAlign.center,
                          ),
                          const Text(
                            '✥ Trascina libero',
                            style: TextStyle(fontSize: 7.5, color: Colors.white60),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // Other Discovered Multi-Devices (e.g. tablet, second laptop, smart display)
              for (int i = 0; i < peers.length; i++) ...[
                if (peers[i]['id'] != 'self' && peers[i]['id'] != LanSyncService.instance.deviceId)
                  _buildPeerNode(peers[i], i, centerX, centerY),
              ],

              // Spatial Canvas Helper Overlay
              Positioned(
                top: 8,
                left: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withAlpha(120),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'Canvas 2D Libero: Posiziona i dispositivi attorno al PC (in diagonale, sopra, sotto, etc.)',
                    style: TextStyle(fontSize: 9, color: Colors.grey.shade300),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPeerNode(Map<String, dynamic> peer, int index, double centerX, double centerY) {
    final peerId = peer['id'] as String? ?? 'peer-$index';
    final name = peer['name'] as String? ?? 'Dispositivo ${index + 1}';
    final peerOffset = LanSyncService.instance.getDeviceOffset(peerId);

    return Positioned(
      left: (centerX + peerOffset.dx) - 45,
      top: (centerY + peerOffset.dy) - 35,
      child: GestureDetector(
        onPanUpdate: (details) {
          setState(() {
            final newX = (peerOffset.dx + details.delta.dx).clamp(-centerX + 50, centerX - 50);
            final newY = (peerOffset.dy + details.delta.dy).clamp(-centerY + 40, centerY - 40);
            LanSyncService.instance.updateDeviceOffset(peerId, Offset(newX, newY));
          });
        },
        child: Container(
          width: 90,
          height: 70,
          decoration: BoxDecoration(
            color: const Color(0xFFF59E0B).withAlpha(40),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFF59E0B), width: 1.5),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.devices_other_rounded, size: 18, color: Color(0xFFF59E0B)),
              const SizedBox(height: 2),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: Colors.white),
                textAlign: TextAlign.center,
              ),
              const Text('✥ Trascina', style: TextStyle(fontSize: 7.5, color: Colors.white60)),
            ],
          ),
        ),
      ),
    );
  }
}
