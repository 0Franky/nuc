import 'dart:io';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../services/logger_service.dart';
import '../services/nexus_ffi_bridge.dart';
import '../theme/nexus_theme.dart';
import 'nexus_card.dart';
import 'nexus_pill.dart';
import 'nexus_button.dart';

class NexusMediaCard extends StatelessWidget {
  final Map<String, dynamic> media;
  final VoidCallback? onRefresh;

  const NexusMediaCard({
    super.key,
    required this.media,
    this.onRefresh,
  });

  void _openVideoOnMobile(BuildContext context, String url, {String? title}) {
    NexusFfiBridge.instance.sendMediaControl('PAUSE');
    NexusLogger.log('HANDOFF', 'Sent PAUSE command to PC and opening video on mobile: $url');
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: NexusTheme.successGreen,
        content: Text('▶️ Video aperto su Telefono • PC messo in pausa!${title != null ? "\n$title" : ""}'),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _showVideoHandoffQrDialog(BuildContext context, Map<String, dynamic> media) {
    final title = media['media_title'] as String? ?? 'Video Attivo';
    final rawUrl = media['media_url'] as String? ?? 'https://www.youtube.com';
    final posMs = (media['position_ms'] as num?)?.toInt() ?? 0;
    final posSeconds = posMs ~/ 1000;
    final timestampedUrl = rawUrl.contains('?') ? '$rawUrl&t=${posSeconds}s' : '$rawUrl?t=${posSeconds}s';

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
                color: Colors.white,
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
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Chiudi', style: TextStyle(color: NexusTheme.accentIndigo)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = media['media_title'] as String? ?? 'Media Attivo';
    final sourceApp = media['source_app'] as String? ?? 'Browser';
    final rawUrl = media['media_url'] as String? ?? 'https://www.youtube.com';
    final posMs = (media['position_ms'] as num?)?.toInt() ?? 0;
    final durMs = (media['duration_ms'] as num?)?.toInt() ?? 0;
    final isPlaying = media['is_playing'] as bool? ?? false;
    final posSeconds = posMs ~/ 1000;
    final timestampedUrl = rawUrl.contains('?') ? '$rawUrl&t=${posSeconds}s' : '$rawUrl?t=${posSeconds}s';

    final posMin = (posMs ~/ 60000).toString().padLeft(2, '0');
    final posSec = ((posMs % 60000) ~/ 1000).toString().padLeft(2, '0');
    final durMin = (durMs ~/ 60000).toString().padLeft(2, '0');
    final durSec = ((durMs % 60000) ~/ 1000).toString().padLeft(2, '0');

    final timeStr = '$posMin:$posSec';
    final durStr = '$durMin:$durSec';
    final isMobile = Platform.isAndroid || Platform.isIOS;

    final progressRatio = durMs > 0 ? (posMs / durMs).clamp(0.0, 1.0) : 0.0;

    return NexusCard(
      title: 'In Riproduzione',
      subtitle: '$sourceApp • al minuto $timeStr / $durStr',
      icon: Icons.play_circle_filled_rounded,
      iconColor: Colors.redAccent,
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
            onTap: () {
              if (isMobile) {
                _openVideoOnMobile(context, timestampedUrl, title: title);
              } else {
                launchUrl(Uri.parse(timestampedUrl), mode: LaunchMode.externalApplication);
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
                  const Icon(Icons.link_rounded, size: 15, color: Color(0xFF818CF8)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      timestampedUrl,
                      style: const TextStyle(
                        color: Color(0xFF818CF8),
                        fontSize: 11.5,
                        decoration: TextDecoration.underline,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.open_in_new_rounded, size: 13, color: Color(0xFF818CF8)),
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
                  onPressed: () {
                    if (isMobile) {
                      _openVideoOnMobile(context, timestampedUrl, title: title);
                    } else {
                      NexusFfiBridge.instance.sendOpenUrl(timestampedUrl, title, posMs);
                      NexusFfiBridge.instance.sendMediaControl('PAUSE');
                      _showVideoHandoffQrDialog(context, media);
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
                    color: Colors.white,
                  ),
                  tooltip: isPlaying ? 'Pausa PC' : 'Riprendi PC',
                  onPressed: () {
                    final cmd = isPlaying ? 'PAUSE' : 'PLAY';
                    NexusFfiBridge.instance.sendMediaControl(cmd);
                    NexusLogger.log('UI_CONTROL', 'Toggled play/pause -> sent $cmd');
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
              onPressed: () {
                NexusFfiBridge.instance.sendOpenUrl(timestampedUrl, title, posMs);
                ScaffoldMessenger.of(context).hideCurrentSnackBar();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('💻 Apertura video inviata al PC!'),
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
