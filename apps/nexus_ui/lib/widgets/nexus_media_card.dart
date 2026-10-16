import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../services/logger_service.dart';
import '../services/lan_sync_service.dart';
import '../services/nexus_ffi_bridge.dart';
import '../theme/nexus_theme.dart';
import 'nexus_card.dart';
import 'nexus_pill.dart';
import 'nexus_button.dart';

typedef _LiveCardBuilder = Widget Function(BuildContext context, int positionMs);

/// D48: firma del sender play/pausa (uguale a NexusFfiBridge.sendPlayPause).
typedef MediaPlayPauseSender = int Function(bool play, {String? targetPeerId});

/// D48: override usato solo dai test per intercettare il routing.
@visibleForTesting
MediaPlayPauseSender? debugMediaPlayPauseSender;

/// D48: normalizza il target: id vuoto o nullo => FFI locale (null).
String? resolveMediaTargetPeerId(String? targetId) =>
    (targetId != null && targetId.isNotEmpty) ? targetId : null;

/// D48: unico punto di routing play/pausa della media card.
int routeMediaPlayPause(bool play, {String? targetPeerId}) {
  final sender = debugMediaPlayPauseSender ?? NexusFfiBridge.instance.sendPlayPause;
  return sender(play, targetPeerId: resolveMediaTargetPeerId(targetPeerId));
}

/// Advances the media position in real time while playing (point 55).
/// The time reference is reset on every external update (position, play
/// state, duration, url or title change); the timer is released on dispose.
class _LiveMediaPosition extends StatefulWidget {
  const _LiveMediaPosition({required this.media, required this.builder});

  final Map<String, dynamic> media;
  final _LiveCardBuilder builder;

  @override
  State<_LiveMediaPosition> createState() => _LiveMediaPositionState();
}

class _LiveMediaPositionState extends State<_LiveMediaPosition> {
  static const _syncKeys = ['position_ms', 'is_playing', 'duration_ms', 'media_url', 'media_title'];

  int _elapsedMs = 0;
  Timer? _ticker;
  int _basePosMs = 0;
  int _durMs = 0;
  bool _playing = false;

  static int _asInt(Object? v) =>
      v is num ? v.toInt() : (v is String ? (num.tryParse(v.trim())?.toInt() ?? 0) : 0);

  static bool _asBool(Object? v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final s = v.trim().toLowerCase();
      return s == 'true' || s == '1';
    }
    return false;
  }

  void _resync() {
    _basePosMs = _asInt(widget.media['position_ms']);
    _durMs = _asInt(widget.media['duration_ms']);
    _playing = _asBool(widget.media['is_playing']);
    _ticker?.cancel();
    _ticker = null;
    _elapsedMs = 0;
    if (_playing) {
      // timer.tick counts elapsed periods (including missed ones), so it
      // follows the real clock at runtime and the fake clock in tests.
      _ticker = Timer.periodic(const Duration(seconds: 1), (t) {
        if (mounted) setState(() => _elapsedMs = t.tick * 1000);
      });
    }
  }

  int get _livePosMs {
    final pos = _playing ? _basePosMs + _elapsedMs : _basePosMs;
    return _durMs > 0 ? pos.clamp(0, _durMs) : pos;
  }

  @override
  void initState() {
    super.initState();
    _resync();
  }

  @override
  void didUpdateWidget(covariant _LiveMediaPosition oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changed = _syncKeys.any((k) => '${oldWidget.media[k]}' != '${widget.media[k]}');
    if (changed) _resync();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _livePosMs);
}

class NexusMediaCard extends StatelessWidget {
  final Map<String, dynamic> media;
  final VoidCallback? onRefresh;

  const NexusMediaCard({
    super.key,
    required this.media,
    this.onRefresh,
  });

  /// Builds the URL to open. Returns null when media_url is missing or invalid
  /// (no silent fallback). The `t=` timestamp is only added for YouTube and is
  /// set as a real query parameter (no duplicates, fragment preserved).
  static String? _timestampedUrl(String? rawUrl, int posSeconds) {
    if (rawUrl == null || rawUrl.trim().isEmpty) return null;
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || !uri.hasScheme) return null;
    final host = uri.host.toLowerCase();
    final isYouTube = host.endsWith('youtube.com') || host == 'youtu.be';
    if (!isYouTube || posSeconds <= 0) return uri.toString();
    final params = Map<String, String>.from(uri.queryParameters)..['t'] = '${posSeconds}s';
    return uri.replace(queryParameters: params).toString();
  }

  static bool get _isMobilePlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> _openUrlOnDesktop(BuildContext context, String url) async {
    final messenger = ScaffoldMessenger.of(context);
    final uri = Uri.tryParse(url);
    bool launched = false;
    if (uri != null) {
      try {
        launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (e) {
        NexusLogger.log('HANDOFF', 'Failed to open url on desktop: $url ($e)');
      }
    }
    if (!launched) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        const SnackBar(content: Text('Impossibile aprire il link del video.')),
      );
    }
  }

  Future<void> _openVideoOnMobile(BuildContext context, String url, {String? title}) async {
    final messenger = ScaffoldMessenger.of(context);
    bool launched = false;
    try {
      launched = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      NexusLogger.log('HANDOFF', 'Failed to open video on mobile: $url ($e)');
      launched = false;
    }

    if (!launched) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Impossibile aprire il video sul telefono. Il PC continua la riproduzione.'),
          duration: Duration(seconds: 4),
        ),
      );
      return;
    }

    // Pause the PC only once the video actually opened on the phone.
    routeMediaPlayPause(false);
    onRefresh?.call();
    NexusLogger.log('HANDOFF', 'Opened video on mobile and sent PAUSE command to PC: $url');

    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        backgroundColor: NexusTheme.successGreen,
        content: Text('▶️ Video aperto su Telefono • PC messo in pausa!${title != null ? "\n$title" : ""}'),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Future<void> _showVideoHandoffQrDialog(BuildContext context, String timestampedUrl, String title, int posMs) async {
    final posSeconds = posMs ~/ 1000;

    final confirmed = await showDialog<bool>(
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
              child: const Icon(Icons.qr_code_2_rounded, color: NexusTheme.accentIndigo, size: 20),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Continuità Video Rapida',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Scansiona con la fotocamera del tuo smartphone per aprire istantaneamente il video al secondo esatto ($posSeconds s):',
              style: const TextStyle(fontSize: 13, color: NexusTheme.textSecondary),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: NexusTheme.qrBackground,
                borderRadius: BorderRadius.circular(12),
              ),
              child: QrImageView(
                data: timestampedUrl,
                version: QrVersions.auto,
                size: 200.0,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Chiudi', style: TextStyle(color: NexusTheme.accentIndigo)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Invia al telefono e pausa PC', style: TextStyle(color: NexusTheme.accentIndigo)),
          ),
        ],
      ),
    );

    // Only push the URL and pause the PC once the user confirms the handoff.
    if (confirmed != true) return;
    NexusFfiBridge.instance.sendOpenUrl(timestampedUrl, title, posMs);
    routeMediaPlayPause(false);
    NexusLogger.log('HANDOFF', 'Sent video to phone and PAUSE to PC: $timestampedUrl');
    onRefresh?.call();
  }

  @override
  Widget build(BuildContext context) {
    return _LiveMediaPosition(media: media, builder: _buildCard);
  }

  Widget _buildCard(BuildContext context, int livePosMs) {
    String? asString(Object? v) => v?.toString();
    int asInt(Object? v) => v is num ? v.toInt() : (v is String ? (num.tryParse(v.trim())?.toInt() ?? 0) : 0);
    bool asBool(Object? v) {
      if (v is bool) return v;
      if (v is num) return v != 0;
      if (v is String) {
        final s = v.trim().toLowerCase();
        return s == 'true' || s == '1';
      }
      return false;
    }

    final title = asString(media['media_title']) ?? 'Media Attivo';
    final sourceApp = asString(media['source_app']) ?? 'Browser';
    final posMs = livePosMs;
    final durMs = asInt(media['duration_ms']);
    final isPlaying = asBool(media['is_playing']);
    final timestampedUrl = _timestampedUrl(asString(media['media_url']), posMs ~/ 1000);
    final displayUrl = timestampedUrl ?? 'Link del video non disponibile';

    String fmtTime(int ms) {
      final h = ms ~/ 3600000;
      final mm = ((ms % 3600000) ~/ 60000).toString().padLeft(2, '0');
      final ss = ((ms % 60000) ~/ 1000).toString().padLeft(2, '0');
      return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
    }

    final timeStr = fmtTime(posMs);
    // Durata nascosta quando è 0 (es. live stream).
    final durSuffix = durMs > 0 ? ' / ${fmtTime(durMs)}' : '';
    final isMobile = _isMobilePlatform;

    final progressRatio = durMs > 0 ? (posMs / durMs).clamp(0.0, 1.0) : 0.0;

    return NexusCard(
      title: 'In Riproduzione',
      subtitle: '$sourceApp • al minuto $timeStr$durSuffix',
      icon: Icons.play_circle_filled_rounded,
      iconColor: NexusTheme.mediaAccentRed,
      trailing: NexusPill(
        label: isPlaying ? 'In Corso' : 'In Pausa',
        style: isPlaying ? NexusPillStyle.success : NexusPillStyle.neutral,
        showDot: true,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: NexusTheme.textPrimary,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 10),
          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progressRatio,
              minHeight: 4,
              backgroundColor: NexusTheme.surfaceSecondary,
              valueColor: const AlwaysStoppedAnimation<Color>(NexusTheme.accentIndigo),
            ),
          ),
          const SizedBox(height: 10),
          // Clickable URL container
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: timestampedUrl == null
                ? null
                : () {
                    if (isMobile) {
                      _openVideoOnMobile(context, timestampedUrl, title: title);
                    } else {
                      _openUrlOnDesktop(context, timestampedUrl);
                    }
                  },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: NexusTheme.accentIndigo.withAlpha(25),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: NexusTheme.accentIndigo.withAlpha(60)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.link_rounded, size: 15, color: NexusTheme.accentIndigoLight),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      displayUrl,
                      style: const TextStyle(
                        color: NexusTheme.accentIndigoLight,
                        fontSize: 11.5,
                        decoration: TextDecoration.underline,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.open_in_new_rounded, size: 13, color: NexusTheme.accentIndigoLight),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: NexusButton(
                  label: isMobile ? 'Apri sul Telefono' : 'Trasferisci su Telefono',
                  icon: isMobile ? Icons.play_arrow_rounded : Icons.phone_android_rounded,
                  style: NexusButtonStyle.primary,
                  onPressed: timestampedUrl == null
                      ? null
                      : () {
                          if (isMobile) {
                            _openVideoOnMobile(context, timestampedUrl, title: title);
                          } else {
                            _showVideoHandoffQrDialog(context, timestampedUrl, title, posMs);
                          }
                        },
                ),
              ),
              const SizedBox(width: 8),
              Container(
                decoration: BoxDecoration(
                  color: NexusTheme.surfaceSecondary,
                  borderRadius: BorderRadius.circular(NexusTheme.radiusButton),
                  border: Border.all(color: NexusTheme.borderCard),
                ),
                child: IconButton(
                  icon: Icon(
                    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: NexusTheme.iconOnSurface,
                  ),
                  tooltip: isPlaying ? 'Pausa PC' : 'Riprendi PC',
                  onPressed: () {
                    final cmd = isPlaying ? 'PAUSE' : 'PLAY';
                    // Shared API (same as the continuity island): it picks
                    // LAN peer vs local FFI internally.
                    routeMediaPlayPause(
                      !isPlaying,
                      targetPeerId: LanSyncService.instance.selectedTargetDeviceId,
                    );
                    NexusLogger.log('UI_CONTROL', 'Toggled play/pause -> sent $cmd');
                    onRefresh?.call();
                  },
                ),
              ),
            ],
          ),
          if (isMobile) ...[
            const SizedBox(height: 8),
            NexusButton(
              label: 'Rimanda Riproduzione a PC',
              icon: Icons.laptop_chromebook_rounded,
              style: NexusButtonStyle.ghost,
              isExpanded: true,
              onPressed: timestampedUrl == null
                  ? null
                  : () {
                NexusFfiBridge.instance.sendOpenUrl(timestampedUrl, title, posMs);
                onRefresh?.call();
                ScaffoldMessenger.of(context).hideCurrentSnackBar();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('💻 Richiesta di apertura inviata al PC'),
                    backgroundColor: NexusTheme.accentIndigo,
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}
