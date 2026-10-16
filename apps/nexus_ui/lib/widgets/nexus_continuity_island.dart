import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../services/lan_sync_service.dart';
import '../services/logger_service.dart';
import '../services/nexus_ffi_bridge.dart';
import '../theme/nexus_theme.dart';
import 'nexus_audio_card.dart' show kAudioRelayPort;
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
  // Punto 40: stato locale delle casse del PC (toggle remoto).
  bool _pcSpeakersMuted = false;
  // Evita che didUpdateWidget sovrascriva _volume durante il drag dello slider.
  bool _isDraggingVolume = false;

  @override
  void initState() {
    super.initState();
    _volume = widget.initialVolume.clamp(0.0, 1.0).toDouble();
    _isMuted = LanSyncService.instance.isAudioMuted;
    LanSyncService.instance.addListener(_onLanChanged);
  }

  /// Ricostruisce l'isola quando cambiano target, pcIp o stato di muto nel
  /// servizio (prima il build leggeva il singleton senza ascoltarlo).
  void _onLanChanged() {
    if (!mounted) return;
    setState(() {
      _isMuted = LanSyncService.instance.isAudioMuted;
    });
  }

  /// Throttle dell'invio volume (Media 31): al massimo un invio ogni 80 ms
  /// durante il drag, più un invio finale forzato su onChangeEnd.
  DateTime _lastVolumeSent = DateTime.fromMillisecondsSinceEpoch(0);

  void _sendVolume(double v, String? targetId, {bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(_lastVolumeSent) < const Duration(milliseconds: 80)) {
      return;
    }
    _lastVolumeSent = now;
    LanSyncService.instance.sendVolume(v, targetPeerId: targetId);
    NexusFfiBridge.instance.setAudioVolume(v);
  }

  @override
  void dispose() {
    LanSyncService.instance.removeListener(_onLanChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant NexusContinuityIsland oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialVolume != widget.initialVolume && !_isDraggingVolume) {
      _volume = widget.initialVolume.clamp(0.0, 1.0).toDouble();
    }
  }

  void _showWebPlayerDialog(BuildContext context, String ip) {
    // Uri racchiude automaticamente gli indirizzi IPv6 tra [...].
    final playerUrl = Uri(scheme: 'http', host: ip, port: kAudioRelayPort, path: '/').toString();

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
                color: NexusTheme.iconOnSurface,
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
            onPressed: () async {
              bool ok = false;
              try {
                ok = await launchUrl(Uri.parse(playerUrl), mode: LaunchMode.externalApplication);
              } catch (e) {
                NexusLogger.log('UI_CONTROL', 'launchUrl web player fallito: $e');
              }
              if (!ok && ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(
                    content: Text('Impossibile aprire il browser'),
                    backgroundColor: NexusTheme.errorRed,
                  ),
                );
              }
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

  /// Imposta il muto con un solo percorso (stesso difetto di NexusAudioCard):
  /// prima si aggiornava isAudioMuted, si inviava sendAudioMute(target) e poi
  /// toggleAudioMute(), che rileggeva isAudioMuted gia' aggiornato e rimandava
  /// in broadcast lo stato opposto. Usato sia dal pulsante sia dallo slider.
  /// Ora usa il setter idempotente setAudioMuted (Media 29), che rilegge lo
  /// stato reale del nativo; con alsoLocal (Media 30) peer e FFI locale
  /// vengono aggiornati entrambi, senza escludersi a vicenda.
  void _setMuted(bool desired, String? targetId, {bool alsoLocal = false}) {
    var actual = desired;
    if (targetId != null) {
      LanSyncService.instance.sendAudioMute(desired, targetPeerId: targetId);
    }
    if (targetId == null || alsoLocal) {
      actual = NexusFfiBridge.instance.setAudioMuted(desired);
    }
    LanSyncService.instance.isAudioMuted = actual;
    if (!mounted) return;
    setState(() {
      _isMuted = actual;
    });
  }

  @override
  Widget build(BuildContext context) {
    final lan = LanSyncService.instance;
    final targetPeer = lan.selectedTargetPeer;
    final targetName = targetPeer?['name'] as String? ?? (lan.pcIp != null ? 'PC Windows' : 'Nessun Target');
    // Niente fallback silenzioso su 127.0.0.1 (puntava al dispositivo locale).
    final String? targetIp = targetPeer?['ip'] as String? ?? lan.pcIp;

    final media = widget.activeMedia;
    final hasMedia = media != null;
    // Parsing tollerante del payload: tipi inattesi non devono far crashare il build.
    String? asStr(Object? v) => v == null ? null : (v is String ? v : v.toString());
    bool? asBool(Object? v) {
      if (v is bool) return v;
      if (v is num) return v != 0;
      if (v is String) {
        final s = v.trim().toLowerCase();
        if (s == 'true' || s == '1') return true;
        if (s == 'false' || s == '0') return false;
      }
      return null;
    }
    int? asInt(Object? v) {
      if (v is num) return v.round();
      if (v is String) return num.tryParse(v.trim())?.round();
      return null;
    }
    final title = hasMedia ? (asStr(media['media_title']) ?? 'Media Attivo') : 'Nessun Media in Riproduzione';
    final sourceApp = hasMedia ? (asStr(media['source_app']) ?? 'Sistema') : 'In Standby';
    final isPlaying = hasMedia ? (asBool(media['is_playing']) ?? false) : false;
    final posMs = hasMedia ? (asInt(media['position_ms']) ?? 0) : 0;
    final durMs = hasMedia ? (asInt(media['duration_ms']) ?? 0) : 0;
    final progressRatio = durMs > 0 ? (posMs / durMs).clamp(0.0, 1.0) : 0.0;

    // Formato h:mm:ss oltre l'ora (prima 2 ore diventavano 120:00).
    String fmtTime(int ms) {
      final h = ms ~/ 3600000;
      final mm = ((ms % 3600000) ~/ 60000).toString().padLeft(2, '0');
      final ss = ((ms % 60000) ~/ 1000).toString().padLeft(2, '0');
      return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
    }

    final timeFormatted = durMs > 0 ? '${fmtTime(posMs)} / ${fmtTime(durMs)}' : fmtTime(posMs);

    final volPercent = (_volume * 100).round();

    return Container(
      decoration: BoxDecoration(
        color: NexusTheme.surfaceCard,
        borderRadius: BorderRadius.circular(NexusTheme.radiusCard),
        border: Border.all(color: NexusTheme.borderCard),
        boxShadow: [
          BoxShadow(
            color: NexusTheme.background.withAlpha(50),
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
                  color: isPlaying ? NexusTheme.successGreen : NexusTheme.accentIndigoLight,
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
                  isPlaying ? 'IN CORSO' : (hasMedia ? 'PAUSA' : 'STANDBY'),
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
                  '${(progressRatio * 100).round()}%',
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
                    backgroundColor: isPlaying ? NexusTheme.accentIndigo : NexusTheme.warningAmber,
                    foregroundColor: isPlaying ? NexusTheme.iconOnSurface : NexusTheme.background,
                    padding: const EdgeInsets.all(8),
                    minimumSize: const Size(38, 38),
                  ),
                  icon: Icon(
                    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: 22,
                  ),
                  tooltip: isPlaying ? 'Metti in Pausa' : 'Riprendi Riproduzione',
                  // Senza media il pulsante e' disabilitato (niente PLAY a vuoto).
                  onPressed: !hasMedia
                      ? null
                      : () {
                    final cmd = isPlaying ? 'PAUSE' : 'PLAY';
                    final targetId = targetPeer?['id'] as String?;
                    // API condivisa (Media 48): sceglie internamente LAN/FFI.
                    NexusFfiBridge.instance.sendPlayPause(!isPlaying, targetPeerId: targetId);
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
                  onPressed: () => _setMuted(!_isMuted, targetPeer?['id'] as String?),
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
                      onChangeStart: (_) => _isDraggingVolume = true,
                      onChangeEnd: (v) {
                        _isDraggingVolume = false;
                        _sendVolume(v, targetPeer?['id'] as String?, force: true);
                      },
                      onChanged: (v) {
                        final targetId = targetPeer?['id'] as String?;
                        // Uscire dal muto via slider deve togliere il muto anche
                        // al peer / relay nativo, non solo alla UI.
                        if (_isMuted && v > 0) _setMuted(false, targetId, alsoLocal: true);
                        setState(() {
                          _volume = v;
                          lan.currentVolume = v;
                        });
                        _sendVolume(v, targetId);
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
                  label: 'Ascolto Privato ($kAudioRelayPort)',
                  icon: Icons.headphones_rounded,
                  style: NexusButtonStyle.secondary,
                  height: 36,
                  onPressed: () {
                    if (targetIp == null || targetIp.isEmpty) {
                      ScaffoldMessenger.of(context).hideCurrentSnackBar();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('IP del dispositivo target sconosciuto: seleziona un dispositivo connesso'),
                          backgroundColor: NexusTheme.errorRed,
                          duration: Duration(seconds: 2),
                        ),
                      );
                      return;
                    }
                    _showWebPlayerDialog(context, targetIp);
                  },
                ),
              ),
              const SizedBox(width: 8),
              NexusButton(
                label: _pcSpeakersMuted ? 'Riattiva Casse' : 'Muto Casse',
                icon: _pcSpeakersMuted ? Icons.volume_up_rounded : Icons.speaker_notes_off_rounded,
                style: NexusButtonStyle.ghost,
                height: 36,
                // Punto 40: senza peer target il comando e' disabilitato;
                // si attende l'esito, si aggiorna lo stato e si mostrano gli errori.
                onPressed: (targetPeer?['id'] as String?) == null
                    ? null
                    : () async {
                        final targetId = targetPeer?['id'] as String?;
                        final messenger = ScaffoldMessenger.of(context);
                        try {
                          await lan.togglePcSpeakersMute(targetPeerId: targetId);
                        } catch (e) {
                          if (!mounted) return;
                          messenger.hideCurrentSnackBar();
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text('Invio del comando alle casse di $targetName non riuscito: $e'),
                              backgroundColor: NexusTheme.errorRed,
                            ),
                          );
                          return;
                        }
                        if (!mounted) return;
                        setState(() => _pcSpeakersMuted = !_pcSpeakersMuted);
                        messenger.hideCurrentSnackBar();
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(_pcSpeakersMuted
                                ? '🔇 Casse di $targetName messe in muto'
                                : '🔊 Casse di $targetName riattivate'),
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

