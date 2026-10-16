import 'dart:async';

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

/// Porta HTTP del relay audio / web player (Bassa 10).
const int kAudioRelayPort = 28472;

/// Filtro dispositivi per la sorgente audio (Bassa 11).
const String kAudioSourceDeviceFilter = 'Desktop';

/// D14: testi visibili della card audio centralizzati in un solo punto.
class AudioCardStrings {
  AudioCardStrings._();

  static const String cardTitle = 'Ascolto Privato (Relay Audio)';
  static const String cardSubtitle = 'Streaming audio WASAPI/Opus';
  static const String relayDisabled = 'Disattivato';
  static const String relayWaiting = 'In attesa';
  static String relayPort(int port) => 'Porta $port';
  static const String sourceSelectorTitle = 'Sorgente Audio PC';
  static const String unmuteTooltip = 'Ripristina Audio';
  static const String muteTooltip = 'Muto Cuffie';
  static const String openWebPlayer = 'Apri Web Player';
  static const String ipUnavailable =
      'Indirizzo IP del dispositivo non disponibile: impossibile aprire il Web Player';
  static const String unmutePcSpeakers = 'Riattiva Altoparlanti PC';
  static const String mutePcSpeakers = 'Muto Altoparlanti PC';
  static const String pcSpeakersMuted = '🔇 Altoparlanti del PC messi in muto';
  static const String pcSpeakersUnmuted = '🔊 Altoparlanti del PC riattivati';
  static const String dialogTitle = 'Ascolto Privato Wireless';
  static const String dialogBody =
      "Apri questo indirizzo su qualsiasi browser (smartphone, tablet o PC) per ascoltare l'audio del PC in tempo reale:";
  static const String browserOpenFailed = 'Impossibile aprire il browser';
  static const String openInBrowser = 'Apri nel Browser';
  static const String close = 'Chiudi';
  static String volumeSendError(Object e) => 'Invio del volume non riuscito: $e';
  static String muteSendError(Object e) => 'Invio del comando di muto non riuscito: $e';
  static String pcSpeakersSendError(Object e) =>
      'Invio del comando agli altoparlanti del PC non riuscito: $e';
}

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
  // Bassa 12: stato locale del toggle altoparlanti PC, per label/icona.
  bool _pcSpeakersMuted = false;

  @override
  void initState() {
    super.initState();
    // Media 4: Slider asserisce value in [0,1]; un initialVolume fuori range romperebbe il build.
    _volume = widget.initialVolume.clamp(0.0, 1.0);
    _isMuted = LanSyncService.instance.isAudioMuted;
    // Media 5: la card segue i cambi di muto arrivati dal servizio (peer/altre UI).
    LanSyncService.instance.addListener(_onServiceChanged);
  }

  void _onServiceChanged() {
    if (!mounted) return;
    // Punto 5: ricostruisce per ogni cambio del servizio (peer, relay, pcIp, muto),
    // non solo per il muto.
    setState(() {
      _isMuted = LanSyncService.instance.isAudioMuted;
    });
  }

  @override
  void dispose() {
    LanSyncService.instance.removeListener(_onServiceChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant NexusAudioCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialVolume != widget.initialVolume) {
      _volume = widget.initialVolume.clamp(0.0, 1.0);
    }
  }

  void _showWebPlayerDialog(BuildContext context, String ip) {
    final playerUrl = 'http://$ip:$kAudioRelayPort/';

    // D8: il Future del dialog e' esplicitamente non atteso.
    unawaited(showDialog<void>(
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
                AudioCardStrings.dialogTitle,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              AudioCardStrings.dialogBody,
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
            onPressed: () async {
              // Media 7: il lancio va atteso e un fallimento segnalato all'utente.
              bool opened;
              try {
                opened = await launchUrl(Uri.parse(playerUrl), mode: LaunchMode.externalApplication);
              } catch (_) {
                opened = false;
              }
              if (!opened && ctx.mounted) {
                ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
                  const SnackBar(content: Text(AudioCardStrings.browserOpenFailed)),
                );
              }
            },
            child: const Text(AudioCardStrings.openInBrowser, style: TextStyle(color: NexusTheme.accentIndigo)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(AudioCardStrings.close, style: TextStyle(color: NexusTheme.textSecondary)),
          ),
        ],
      ),
    ));
  }

  void _showSendError(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(content: Text(message), backgroundColor: NexusTheme.errorRed),
    );
  }

  /// Throttle dell'invio del volume durante il drag dello slider (Media 3).
  DateTime _lastVolumeSend = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _volumeSendInterval = Duration(milliseconds: 80);

  Future<void> _sendVolume(double v, String? targetId) async {
    _lastVolumeSend = DateTime.now();
    // Punto 8 / D8: l'invio al peer avviene solo con un target selezionato;
    // ogni invio viene atteso, cosi' anche un Future fallito arriva al catch
    // e l'errore viene mostrato all'utente invece di andare perso.
    try {
      if (targetId != null) {
        await Future<void>.sync(
          () => LanSyncService.instance.sendVolume(v, targetPeerId: targetId),
        );
      }
      await Future<void>.sync(() => NexusFfiBridge.instance.setAudioVolume(v));
    } catch (e) {
      _showSendError(AudioCardStrings.volumeSendError(e));
      return;
    }
    if (!mounted) return;
    // Media 9: notifica il genitore del cambio di stato.
    widget.onStateChanged?.call();
  }

  /// Imposta il muto con un solo percorso: prima si inviava sendAudioMute(target)
  /// e poi toggleAudioMute(), che rileggeva isAudioMuted gia' aggiornato e
  /// rimandava in broadcast lo stato opposto (muto annullato).
  Future<void> _setMuted(bool desired, String? targetId) async {
    if (desired == _isMuted) return;
    try {
      if (targetId != null) {
        await Future<void>.sync(
          () => LanSyncService.instance.sendAudioMute(desired, targetPeerId: targetId),
        );
      } else {
        // Punto 1: setter esplicito, nessun toggle che possa restare invertito
        // rispetto a _isMuted.
        await Future<void>.sync(() => NexusFfiBridge.instance.setAudioMuted(desired));
      }
    } catch (e) {
      // Punto 8: in caso di errore lo stato locale non cambia.
      _showSendError(AudioCardStrings.muteSendError(e));
      return;
    }
    // D8: dopo l'await il widget potrebbe essere stato smontato.
    if (!mounted) return;
    LanSyncService.instance.isAudioMuted = desired;
    setState(() {
      _isMuted = desired;
    });
    // Media 9: notifica il genitore del cambio di stato.
    widget.onStateChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final targetPeer = LanSyncService.instance.selectedTargetPeer;
    final String? targetId = targetPeer?['id'] as String?;
    final String? localIp = targetPeer?['ip'] as String? ?? LanSyncService.instance.pcIp;
    final volPercent = (_volume * 100).round();

    return NexusCard(
      title: AudioCardStrings.cardTitle,
      // Punto 14: nessuna affermazione di latenza non verificata.
      subtitle: AudioCardStrings.cardSubtitle,
      icon: Icons.headphones_rounded,
      iconColor: NexusTheme.accentIndigo,
      trailing: NexusPill(
        label: !LanSyncService.instance.audioRelayEnabled
            ? AudioCardStrings.relayDisabled
            : (widget.audioRelayActive ? AudioCardStrings.relayPort(kAudioRelayPort) : AudioCardStrings.relayWaiting),
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
            filterType: kAudioSourceDeviceFilter,
            title: AudioCardStrings.sourceSelectorTitle,
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
                tooltip: _isMuted ? AudioCardStrings.unmuteTooltip : AudioCardStrings.muteTooltip,
                // D8: Future esplicitamente non atteso; gli errori sono gestiti in _setMuted.
                onPressed: () => unawaited(_setMuted(!_isMuted, targetPeer?['id'] as String?)),
              ),
              Expanded(
                child: Slider(
                  value: _volume,
                  min: 0.0,
                  max: 1.0,
                  onChanged: (v) {
                    final targetId = targetPeer?['id'] as String?;
                    // Alzare il volume da muto toglie il muto anche al peer e al
                    // relay nativo, non solo nella UI.
                    // D8: _setMuted/_sendVolume gestiscono gli errori al proprio interno.
                    if (_isMuted && v > 0) unawaited(_setMuted(false, targetId));
                    setState(() {
                      _volume = v;
                      LanSyncService.instance.currentVolume = v;
                    });
                    if (DateTime.now().difference(_lastVolumeSend) >= _volumeSendInterval) {
                      unawaited(_sendVolume(v, targetId));
                    }
                  },
                  // Il valore finale viene sempre inviato, anche se il throttle
                  // ha scartato l'ultimo evento del drag.
                  // D8: Future esplicitamente non atteso; gli errori sono gestiti in _sendVolume.
                  onChangeEnd: (v) => unawaited(_sendVolume(v, targetPeer?['id'] as String?)),
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
                  label: AudioCardStrings.openWebPlayer,
                  icon: Icons.open_in_browser_rounded,
                  style: NexusButtonStyle.secondary,
                  onPressed: () {
                    if (localIp == null || localIp.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(AudioCardStrings.ipUnavailable),
                        ),
                      );
                      return;
                    }
                    _showWebPlayerDialog(context, localIp);
                  },
                ),
              ),
              const SizedBox(width: 8),
              NexusButton(
                label: _pcSpeakersMuted ? AudioCardStrings.unmutePcSpeakers : AudioCardStrings.mutePcSpeakers,
                icon: _pcSpeakersMuted ? Icons.volume_up_rounded : Icons.speaker_notes_off_rounded,
                style: NexusButtonStyle.ghost,
                // Punto 8: senza peer target il comando remoto è disabilitato.
                onPressed: targetId == null
                    ? null
                    : () async {
                        final messenger = ScaffoldMessenger.of(context);
                        try {
                          await LanSyncService.instance.togglePcSpeakersMute(targetPeerId: targetId);
                        } catch (e) {
                          if (!mounted) return;
                          messenger.hideCurrentSnackBar();
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text(AudioCardStrings.pcSpeakersSendError(e)),
                              backgroundColor: NexusTheme.errorRed,
                            ),
                          );
                          return;
                        }
                        if (!mounted) return;
                        setState(() {
                          _pcSpeakersMuted = !_pcSpeakersMuted;
                        });
                        messenger.hideCurrentSnackBar();
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(_pcSpeakersMuted
                                ? AudioCardStrings.pcSpeakersMuted
                                : AudioCardStrings.pcSpeakersUnmuted),
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
