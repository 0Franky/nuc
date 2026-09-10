import 'dart:io';
import 'package:flutter/material.dart';
import '../services/lan_sync_service.dart';
import '../services/nexus_ffi_bridge.dart';
import '../theme/nexus_theme.dart';
import '../widgets/nexus_card.dart';
import '../widgets/proximity_lock_switch.dart';
import '../widgets/nexus_pill.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _nameCtrl;

  @override
  void initState() {
    super.initState();
    LanSyncService.instance.addListener(_refresh);
    _nameCtrl = TextEditingController(text: LanSyncService.instance.deviceName);
  }

  void _refresh() { if (mounted) setState(() {}); }

  @override
  void dispose() {
    LanSyncService.instance.removeListener(_refresh);
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = LanSyncService.instance;
    final isMobile = Platform.isAndroid || Platform.isIOS;
    final localIp = service.pcIp ?? '127.0.0.1';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Impostazioni & Continuità'),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          // Section 0: Identità Dispositivo
          NexusCard(
            title: 'Identità Dispositivo',
            subtitle: 'Nome visibile sui peer e suffisso anticollisione',
            icon: Icons.badge_outlined,
            iconColor: NexusDeviceColors.colorForDeviceName(service.deviceName),
            trailing: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: NexusDeviceColors.colorForDeviceName(service.deviceName),
                shape: BoxShape.circle,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _nameCtrl,
                        decoration: InputDecoration(
                          labelText: 'Nome Dispositivo',
                          hintText: service.defaultDeviceName,
                          prefixIcon: const Icon(Icons.edit_outlined, size: 18),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () async {
                        await service.setDeviceName(_nameCtrl.text);
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('✅ Nome dispositivo aggiornato: ${service.deviceName}'),
                            backgroundColor: NexusTheme.successGreen,
                            duration: const Duration(seconds: 2),
                          ),
                        );
                        setState(() {});
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: NexusTheme.accentIndigo,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: const Text('Salva'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Default: ${service.defaultDeviceName}',
                      style: const TextStyle(fontSize: 11, color: NexusTheme.textSecondary),
                    ),
                    TextButton(
                      onPressed: () async {
                        await service.resetDeviceNameToDefault();
                        _nameCtrl.text = service.deviceName;
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('🔄 Nome ripristinato al default: ${service.deviceName}'),
                            backgroundColor: NexusTheme.accentIndigo,
                            duration: const Duration(seconds: 2),
                          ),
                        );
                        setState(() {});
                      },
                      child: const Text('Ripristina Default', style: TextStyle(fontSize: 11)),
                    ),
                  ],
                ),
                const Divider(),
                Row(
                  children: [
                    const Icon(Icons.fingerprint, size: 14, color: NexusTheme.textTertiary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'ID Univoco: ${service.deviceId}',
                        style: const TextStyle(fontSize: 10.5, color: NexusTheme.textTertiary, fontFamily: 'monospace'),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Section 1: Continuità & Flussi P2P
          NexusCard(
            title: 'Moduli di Continuità P2P',
            subtitle: 'Attiva o disattiva la sincronizzazione dei dati tra i tuoi dispositivi',
            icon: Icons.sync_alt_rounded,
            iconColor: NexusTheme.accentIndigo,
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Sincronizzazione Appunti E2EE', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                  subtitle: const Text('Copia e incolla continuo tra computer e smartphone', style: TextStyle(fontSize: 11.5, color: NexusTheme.textSecondary)),
                  value: service.clipboardSyncEnabled,
                  onChanged: (v) {
                    setState(() => service.clipboardSyncEnabled = v);
                  },
                ),
                const Divider(),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Continuità Video & Browser (Handoff)', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                  subtitle: const Text('Trasferisci i video di YouTube e link al minuto esatto', style: TextStyle(fontSize: 11.5, color: NexusTheme.textSecondary)),
                  value: service.mediaHandoffEnabled,
                  onChanged: (v) {
                    setState(() => service.mediaHandoffEnabled = v);
                  },
                ),
                const Divider(),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Private Listening (Audio Relay)', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                  subtitle: const Text('Streaming audio WASAPI/Opus ultra-low-latency su cuffie mobile', style: TextStyle(fontSize: 11.5, color: NexusTheme.textSecondary)),
                  value: service.audioRelayEnabled,
                  onChanged: (v) {
                    setState(() => service.audioRelayEnabled = v);
                  },
                ),
                const Divider(),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('AirDrop & Trasferimento File P2P', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                  subtitle: const Text('Condivisione file diretta a 64KB/chunk con hash BLAKE3', style: TextStyle(fontSize: 11.5, color: NexusTheme.textSecondary)),
                  value: service.fileTransferEnabled,
                  onChanged: (v) {
                    setState(() => service.fileTransferEnabled = v);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Section 2: Zero-Trust & Privacy Gate
          NexusCard(
            title: 'Sicurezza, Privacy & Zero-Trust',
            subtitle: 'Protezione crittografica di credenziali, chiavi e sensori',
            icon: Icons.shield_rounded,
            iconColor: NexusTheme.successGreen,
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('🛡️ Zero-Trust Privacy Gate (PII / Segreti)', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                  subtitle: const Text('Censura codici OTP, API token e credenziali: rivelabili solo on-demand',
                      style: TextStyle(fontSize: 11.5, color: NexusTheme.textSecondary)),
                  value: service.clipboardPrivacyGate,
                  onChanged: (v) {
                    setState(() {
                      service.clipboardPrivacyGate = v;
                      service.saveSettingBool('clipboardPrivacyGate', v);
                    });
                    NexusFfiBridge.instance.setClipboardPrivacyGate(v);
                  },
                ),
                const Divider(),
                const ProximityLockSwitch(),
                const Divider(),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Auto-Pausa Media & Handoff Cellulare', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                  subtitle: const Text('Pausa automaticamente il PC e propone la ripresa su smartphone quando ti allontani',
                      style: TextStyle(fontSize: 11.5, color: NexusTheme.textSecondary)),
                  value: service.autoPauseMediaOnWalkAway,
                  onChanged: (v) {
                    setState(() {
                      service.autoPauseMediaOnWalkAway = v;
                      service.saveSettingBool('autoPauseMediaOnWalkAway', v);
                    });
                  },
                ),
                const Divider(),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Smart Wake on Approach', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                  subtitle: const Text('Risveglia monitor e riscalda canale LAN quando ti avvicini alla postazione',
                      style: TextStyle(fontSize: 11.5, color: NexusTheme.textSecondary)),
                  value: service.wakeOnApproach,
                  onChanged: (v) {
                    setState(() {
                      service.wakeOnApproach = v;
                      service.saveSettingBool('wakeOnApproach', v);
                    });
                  },
                ),
                const Divider(),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Monitoraggio prossimità BLE', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                  subtitle: Text(
                    service.isBleHardwareAvailable
                        ? 'Monitoraggio BLE: la disposizione degli schermi si imposta nel canvas'
                        : 'Determina la posizione via BLE (Disabilitato: Bluetooth spento sul dispositivo)',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: service.isBleHardwareAvailable ? NexusTheme.textSecondary : NexusTheme.warningAmber,
                    ),
                  ),
                  value: service.isBleHardwareAvailable && service.bleSpatialAutoDetect,
                  onChanged: service.isBleHardwareAvailable
                      ? (v) {
                          setState(() {
                            service.setBleSpatialAutoDetect(v);
                          });
                        }
                      : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Section 2.5: Distanze & Soglie Prossimità (Configurabili)
          NexusCard(
            title: 'Soglie di Distanza Prossimità (BLE)',
            subtitle: 'Il BLE fornisce una stima, non una misura precisa. Calibra il dispositivo scelto a 1 metro.',
            icon: Icons.social_distance_rounded,
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: NexusTheme.accentIndigo.withAlpha(40),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: NexusTheme.accentIndigo.withAlpha(80)),
              ),
              child: Text(
                'Stima: ${service.estimatedDistanceMeters != null ? "${service.estimatedDistanceMeters!.toStringAsFixed(1)}m" : "N/D"}',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: NexusTheme.accentIndigo),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<String>(
                  key: ValueKey(service.proximityPeerId),
                  initialValue: service.discoveredPeers.any((p) => p['id'] == service.proximityPeerId)
                      ? service.proximityPeerId : null,
                  decoration: const InputDecoration(labelText: 'Dispositivo di prossimità'),
                  items: service.discoveredPeers.map((p) => DropdownMenuItem<String>(
                    value: p['id'] as String,
                    child: Text('${p['name']}${p['online'] == true ? '' : ' (offline)'}'),
                  )).toList(),
                  onChanged: (id) => service.setProximityPeer(id),
                ),
                const SizedBox(height: 8),
                Text(service.proximityStatus, style: const TextStyle(fontSize: 12)),
                if (service.liveRssi != null)
                  Text('Segnale: ${service.liveRssi} dBm', style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.straighten),
                  label: const Text('Calibra: dispositivi a 1 metro'),
                  onPressed: service.hasProximityPeer && service.proximity.canCalibrate(DateTime.now())
                      ? () async {
                          final done = await service.calibrateProximityAtOneMeter();
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done
                              ? 'Calibrazione salvata per questo dispositivo'
                              : 'Attendi almeno 5 campioni stabili con i dispositivi a 1 metro')));
                        } : null,
                ),
                const Text('Prima allontana fisicamente i dispositivi a 1 metro e attendi un segnale stabile. '
                    'Ostacoli e orientamento possono comunque alterare la stima.',
                    style: TextStyle(fontSize: 11, color: NexusTheme.textSecondary)),
                const SizedBox(height: 16),
                // 1. Walk-Away Threshold
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Soglia Notifica Allontanamento (Walk-Away)',
                              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                          Text('Distanza per triggerare la notifica di handoff e pausa PC',
                              style: TextStyle(fontSize: 11, color: NexusTheme.textSecondary)),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: NexusTheme.surfaceCard,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: NexusTheme.accentIndigo),
                      ),
                      child: Text(
                        '${service.walkAwayThresholdMeters.toStringAsFixed(1)} m',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: NexusTheme.accentIndigo),
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: service.walkAwayThresholdMeters.clamp(1.0, 5.0),
                  min: 1.0,
                  max: 5.0,
                  divisions: 40,
                  label: '${service.walkAwayThresholdMeters.toStringAsFixed(1)} m',
                  activeColor: NexusTheme.accentIndigo,
                  onChanged: (val) {
                    setState(() {
                      service.setWalkAwayThreshold(double.parse(val.toStringAsFixed(1)));
                    });
                  },
                ),
                const SizedBox(height: 10),
                const Divider(),
                const SizedBox(height: 10),

                // 2. Return Threshold
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Soglia Rientro alla Scrivania (Approach / Welcome)',
                              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                          Text('Distanza a cui viene riconosciuto il ritorno e risvegliato il PC',
                              style: TextStyle(fontSize: 11, color: NexusTheme.textSecondary)),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: NexusTheme.surfaceCard,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: NexusTheme.successGreen),
                      ),
                      child: Text(
                        '${service.returnThresholdMeters.toStringAsFixed(1)} m',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: NexusTheme.successGreen),
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: service.returnThresholdMeters.clamp(0.5, 3.0),
                  min: 0.5,
                  max: 3.0,
                  divisions: 25,
                  label: '${service.returnThresholdMeters.toStringAsFixed(1)} m',
                  activeColor: NexusTheme.successGreen,
                  onChanged: (val) {
                    setState(() {
                      service.setReturnThreshold(double.parse(val.toStringAsFixed(1)));
                    });
                  },
                ),
                const SizedBox(height: 10),
                const Divider(),
                const SizedBox(height: 10),

                // 3. Workstation Auto-Lock Threshold
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Soglia Blocco Postazione (Auto-Lock PC)',
                              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                          Text('Distanza oltre la quale il PC viene bloccato dopo 10 secondi oltre soglia',
                              style: TextStyle(fontSize: 11, color: NexusTheme.textSecondary)),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: NexusTheme.surfaceCard,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: NexusTheme.errorRed),
                      ),
                      child: Text(
                        '${service.autoLockThresholdMeters.toStringAsFixed(1)} m',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: NexusTheme.errorRed),
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: service.autoLockThresholdMeters.clamp(1.5, 6.0),
                  min: 1.5,
                  max: 6.0,
                  divisions: 45,
                  label: '${service.autoLockThresholdMeters.toStringAsFixed(1)} m',
                  activeColor: NexusTheme.errorRed,
                  onChanged: (val) {
                    setState(() {
                      service.setAutoLockThreshold(double.parse(val.toStringAsFixed(1)));
                    });
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Section 3: Engine Details & Version
          NexusCard(
            title: 'Informazioni Motore & Hardware',
            subtitle: 'Nexus Universal Ecosystem • Architettura Nativa Rust C-ABI',
            icon: Icons.info_outline_rounded,
            iconColor: NexusTheme.textTertiary,
            trailing: const NexusPill(
              label: 'v1.1.0-release',
              style: NexusPillStyle.accent,
            ),
            child: Column(
              children: [
                _buildInfoRow('ID Dispositivo', service.deviceId),
                _buildInfoRow('Tipo Nodo', isMobile ? 'Mobile Node (Flutter Android)' : 'Core Desktop (Windows 11)'),
                _buildInfoRow('Indirizzo LAN', localIp),
                _buildInfoRow('Porta Daemon WebSocket', '28471 (Media & Input) / 28472 (Audio)'),
                _buildInfoRow('Crittografia P2P', 'ChaCha20-Poly1305 + Ed25519 Key Exchange'),
                _buildInfoRow('Integrità File Streaming', 'BLAKE3 Chunk Tree (64KB block)'),
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: NexusTheme.textSecondary, fontSize: 12)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: NexusTheme.textPrimary, fontWeight: FontWeight.w600, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
