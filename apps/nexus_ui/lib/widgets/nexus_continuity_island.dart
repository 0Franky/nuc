import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../services/lan_sync_service.dart';
import '../services/logger_service.dart';
import '../services/nexus_ffi_bridge.dart';
import '../theme/nexus_theme.dart';
import 'nexus_button.dart';

/// Unified Continuity Island: SSOT component merging Media Playback,
/// Universal Master Volume, and Audio Relay without duplicate controls.
class NexusContinuityIsland extends StatefulWidget {
  final Map<String, dynamic>? activeMedia;
  final bool audioRelayActive;
  final double initialVolume;
  final VoidCallback? onStateChanged;

  const NexusContinuityIsland({
    super.key,
    this.activeMedia,
    required this.audioRelayActive,
    required this.initialVolume,
    this.onStateChanged,
  });

  @override
  State<NexusContinuityIsland> createState() => _NexusContinuityIslandState();
}

class _NexusContinuityIslandState extends State<NexusContinuityIsland> {
  late double _volume;
  bool _isMuted = false;

  @override
  void initState() {
    super.initState();
    _volume = widget.initialVolume;
    _isMuted = LanSyncService.instance.isAudioMuted;
  }

  @override
  void didUpdateWidget(covariant NexusContinuityIsland oldWidget) {
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
              'Scansiona il codice o apri l\'indirizzo nel browser per ascoltare l\'audio PC a bassissima latenza:',
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
                size: 180.0,
              ),
            ),
            const SizedBox(height: 12),
            SelectableText(
              playerUrl,
              style: const TextStyle(
                color: NexusTheme.accentIndigo,
                fontWeight: FontWeight.bold,
                fontSize: 13.5,
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
    final lan = LanSyncService.instance;
    final targetPeer = lan.selectedTargetPeer;
    final targetName = targetPeer?['name'] as String? ?? (lan.pcIp != null ? 'PC Windows' : 'Nessun Target');
    final targetIp = targetPeer?['ip'] as String? ?? lan.pcIp ?? '127.0.0.1';

    final media = widget.activeMedia;
    final hasMedia = media != null;
    final title = hasMedia ? (media['media_title'] as String? ?? 'Media Attivo') : 'Nessun Media in Riproduzione';
    final sourceApp = hasMedia ? (media['source_app'] as String? ?? 'Sistema') : 'In Standby';
    final isPlaying = hasMedia ? (media['is_playing'] as bool? ?? false) : false;
    final posMs = hasMedia ? ((media['position_ms'] as num?)?.toInt() ?? 0) : 0;
    final durMs = hasMedia ? ((media['duration_ms'] as num?)?.toInt() ?? 0) : 0;
    final progressRatio = durMs > 0 ? (posMs / durMs).clamp(0.0, 1.0) : 0.0;

    final posMin = (posMs ~/ 60000).toString().padLeft(2, '0');
    final posSec = ((posMs % 60000) ~/ 1000).toString().padLeft(2, '0');
    final durMin = (durMs ~/ 60000).toString().padLeft(2, '0');
    final durSec = ((durMs % 60000) ~/ 1000).toString().padLeft(2, '0');
    final timeFormatted = durMs > 0 ? '$posMin:$posSec / $durMin:$durSec' : '$posMin:$posSec';

    final volPercent = (_volume * 100).toInt();

    return Container(
      decoration: BoxDecoration(
        color: NexusTheme.surfaceCard,
        borderRadius: BorderRadius.circular(NexusTheme.radiusCard),
        border: Border.all(color: NexusTheme.borderCard),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(50),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. Header: Info Media & Badge di Stato
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: isPlaying ? NexusTheme.successGreen.withAlpha(30) : NexusTheme.accentIndigo.withAlpha(30),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  hasMedia ? Icons.music_note_rounded : Icons.radio_rounded,
                  color: isPlaying ? NexusTheme.successGreen : const Color(0xFF818CF8),
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: NexusTheme.textPrimary,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$sourceApp • Destinazione: $targetName',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: NexusTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: isPlaying ? NexusTheme.successGreen.withAlpha(30) : NexusTheme.surfaceSecondary,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: isPlaying ? NexusTheme.successGreen.withAlpha(80) : NexusTheme.borderCard,
                  ),
                ),
                child: Text(
                  isPlaying ? 'IN CORSO' : 'PAUSA',
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                    color: isPlaying ? NexusTheme.successGreen : NexusTheme.textSecondary,
                  ),
                ),
              ),
            ],
          ),

          // 2. Barra di Avanzamento e Posizione
          if (durMs > 0) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progressRatio,
                minHeight: 4,
                backgroundColor: NexusTheme.surfaceSecondary,
                valueColor: const AlwaysStoppedAnimation<Color>(NexusTheme.accentIndigo),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  timeFormatted,
                  style: const TextStyle(fontSize: 10, color: NexusTheme.textTertiary, fontFamily: 'monospace'),
                ),
                Text(
                  '${(progressRatio * 100).toInt()}%',
                  style: const TextStyle(fontSize: 10, color: NexusTheme.textTertiary, fontFamily: 'monospace'),
                ),
              ],
            ),
          ],

          const SizedBox(height: 14),

          // 3. Central Control Strip: SSOT Play/Pause & Universal Volume Slider
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: NexusTheme.surfaceSecondary,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: NexusTheme.borderSubtle),
            ),
            child: Row(
              children: [
                // Single Play / Pause Button (SSOT)
                IconButton.filled(
                  style: IconButton.styleFrom(
                    backgroundColor: isPlaying ? NexusTheme.accentIndigo : const Color(0xFFF59E0B),
                    foregroundColor: isPlaying ? Colors.white : Colors.black,
                    padding: const EdgeInsets.all(8),
                    minimumSize: const Size(38, 38),
                  ),
                  icon: Icon(
                    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: 22,
                  ),
                  tooltip: isPlaying ? 'Metti in Pausa' : 'Riprendi Riproduzione',
                  onPressed: () {
                    final cmd = isPlaying ? 'PAUSE' : 'PLAY';
                    final targetId = targetPeer?['id'] as String?;
                    NexusFfiBridge.instance.sendMediaControl(cmd);
                    lan.sendCommand(cmd, targetPeerId: targetId);
                    widget.onStateChanged?.call();
                    NexusLogger.log('UI_CONTROL', 'SSOT media toggle: $cmd sent to $targetName');
                  },
                ),
                const SizedBox(width: 10),

                // Volume Mute Button
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  icon: Icon(
                    _isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                    color: _isMuted ? NexusTheme.errorRed : NexusTheme.textSecondary,
                    size: 20,
                  ),
                  tooltip: _isMuted ? 'Ripristina Volume' : 'Muto',
                  onPressed: () {
                    setState(() {
                      _isMuted = !_isMuted;
                      lan.isAudioMuted = _isMuted;
                    });
                    final targetId = targetPeer?['id'] as String?;
                    lan.sendAudioMute(_isMuted, targetPeerId: targetId);
                    NexusFfiBridge.instance.toggleAudioMute();
                  },
                ),

                // Universal Volume Slider
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                      trackHeight: 3,
                    ),
                    child: Slider(
                      value: _volume,
                      min: 0.0,
                      max: 1.0,
                      onChanged: (v) {
                        setState(() {
                          _volume = v;
                          if (_isMuted && v > 0) {
                            _isMuted = false;
                            lan.isAudioMuted = false;
                          }
                          lan.currentVolume = v;
                        });
                        final targetId = targetPeer?['id'] as String?;
                        lan.sendVolume(v, targetPeerId: targetId);
                        NexusFfiBridge.instance.setAudioVolume(v);
                      },
                    ),
                  ),
                ),

                // Volume Percentage Text
                SizedBox(
                  width: 38,
                  child: Text(
                    '$volPercent%',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                      fontFamily: 'monospace',
                      color: NexusTheme.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // 4. Azioni Rapide di Continuità (Ascolto Privato + Muto Casse PC)
          Row(
            children: [
              Expanded(
                child: NexusButton(
                  label: 'Ascolto Privato (28472)',
                  icon: Icons.headphones_rounded,
                  style: NexusButtonStyle.secondary,
                  height: 36,
                  onPressed: () => _showWebPlayerDialog(context, targetIp),
                ),
              ),
              const SizedBox(width: 8),
              NexusButton(
                label: 'Muto Casse',
                icon: Icons.speaker_notes_off_rounded,
                style: NexusButtonStyle.ghost,
                height: 36,
                onPressed: () {
                  final targetId = targetPeer?['id'] as String?;
                  lan.togglePcSpeakersMute(targetPeerId: targetId);
                  ScaffoldMessenger.of(context).hideCurrentSnackBar();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('🔇 Muto altoparlanti inviato a $targetName!'),
                      backgroundColor: NexusTheme.accentIndigo,
                      duration: const Duration(seconds: 2),
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

