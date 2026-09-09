import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../services/lan_sync_service.dart';
import '../services/nexus_ffi_bridge.dart';
import '../theme/nexus_theme.dart';
import 'nexus_card.dart';
import 'nexus_pill.dart';
import 'nexus_button.dart';
import 'target_device_selector.dart';

class NexusAudioCard extends StatefulWidget {
  final bool audioRelayActive;
  final double initialVolume;
  final VoidCallback? onStateChanged;

  const NexusAudioCard({
    super.key,
    required this.audioRelayActive,
    required this.initialVolume,
    this.onStateChanged,
  });

  @override
  State<NexusAudioCard> createState() => _NexusAudioCardState();
}

class _NexusAudioCardState extends State<NexusAudioCard> {
  late double _volume;
  bool _isMuted = false;

  @override
  void initState() {
    super.initState();
    _volume = widget.initialVolume;
    _isMuted = LanSyncService.instance.isAudioMuted;
  }

  @override
  void didUpdateWidget(covariant NexusAudioCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialVolume != widget.initialVolume) {
      _volume = widget.initialVolume;
    }
  }

  void _showWebPlayerDialog(BuildContext context, String ip) {
    final playerUrl = 'http://$ip:28472/';

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
              child: const Icon(Icons.headphones_rounded, color: NexusTheme.accentIndigo, size: 20),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Ascolto Privato Wireless',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Apri questo indirizzo su qualsiasi browser (smartphone, tablet o PC) per ascoltare l\'audio in tempo reale a bassissima latenza:',
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
                data: playerUrl,
                version: QrVersions.auto,
                size: 200.0,
              ),
            ),
            const SizedBox(height: 12),
            SelectableText(
              playerUrl,
              style: const TextStyle(
                color: NexusTheme.accentIndigo,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              launchUrl(Uri.parse(playerUrl), mode: LaunchMode.externalApplication);
            },
            child: const Text('Apri nel Browser', style: TextStyle(color: NexusTheme.accentIndigo)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Chiudi', style: TextStyle(color: NexusTheme.textSecondary)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final targetPeer = LanSyncService.instance.selectedTargetPeer;
    final localIp = targetPeer?['ip'] as String? ?? LanSyncService.instance.pcIp ?? '127.0.0.1';
    final volPercent = (_volume * 100).toInt();

    return NexusCard(
      title: 'Private Listening (Audio Relay)',
      subtitle: 'Streaming WASAPI/Opus ultra-low-latency (~20ms)',
      icon: Icons.headphones_rounded,
      iconColor: NexusTheme.accentIndigo,
      trailing: NexusPill(
        label: !LanSyncService.instance.audioRelayEnabled
            ? 'Disattivato'
            : (widget.audioRelayActive ? 'Porta 28472' : 'Standby'),
        style: (!LanSyncService.instance.audioRelayEnabled || !widget.audioRelayActive)
            ? NexusPillStyle.neutral
            : NexusPillStyle.success,
        showDot: LanSyncService.instance.audioRelayEnabled && widget.audioRelayActive,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TargetDeviceSelector(
            compact: true,
            filterType: 'Desktop',
            title: "Sorgente Audio PC",
            onDeviceSelected: (_) {
              setState(() {});
            },
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              IconButton.filledTonal(
                style: IconButton.styleFrom(
                  backgroundColor: _isMuted ? NexusTheme.errorRed.withAlpha(40) : NexusTheme.surfaceSecondary,
                ),
                icon: Icon(
                  _isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                  color: _isMuted ? NexusTheme.errorRed : Colors.white,
                  size: 20,
                ),
                tooltip: _isMuted ? 'Ripristina Audio' : 'Muto Cuffie',
                onPressed: () {
                  setState(() {
                    _isMuted = !_isMuted;
                    LanSyncService.instance.isAudioMuted = _isMuted;
                  });
                  final newVol = _isMuted ? 0.0 : _volume;
                  NexusFfiBridge.instance.setAudioVolume(newVol);
                },
              ),
              Expanded(
                child: Slider(
                  value: _volume,
                  min: 0.0,
                  max: 1.0,
                  onChanged: (v) {
                    setState(() {
                      _volume = v;
                      if (_isMuted && v > 0) {
                        _isMuted = false;
                        LanSyncService.instance.isAudioMuted = false;
                      }
                      LanSyncService.instance.currentVolume = v;
                    });
                    NexusFfiBridge.instance.setAudioVolume(v);
                  },
                ),
              ),
              Text(
                '$volPercent%',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: NexusTheme.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: NexusButton(
                  label: 'Apri Web Player',
                  icon: Icons.open_in_browser_rounded,
                  style: NexusButtonStyle.secondary,
                  onPressed: () {
                    _showWebPlayerDialog(context, localIp);
                  },
                ),
              ),
              const SizedBox(width: 8),
              NexusButton(
                label: 'Muto Altoparlanti PC',
                icon: Icons.speaker_notes_off_rounded,
                style: NexusButtonStyle.ghost,
                onPressed: () {
                  NexusFfiBridge.instance.togglePcSpeakersMute();
                  ScaffoldMessenger.of(context).hideCurrentSnackBar();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('🔇 Segnale inviato agli altoparlanti del PC!'),
                      backgroundColor: NexusTheme.accentIndigo,
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
