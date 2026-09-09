import 'package:flutter/material.dart';
import '../services/nexus_ffi_bridge.dart';
import '../theme/nexus_theme.dart';

/// Quick media playback & master volume control bar.
class MediaQuickBar extends StatelessWidget {
  const MediaQuickBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: NexusTheme.surfaceSecondary,
        border: Border(top: BorderSide(color: NexusTheme.borderSubtle)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton.filledTonal(
            style: IconButton.styleFrom(backgroundColor: NexusTheme.surfaceCard),
            onPressed: () => NexusFfiBridge.instance.sendMediaControl("SEEK", positionMs: 0),
            icon: const Icon(Icons.skip_previous_rounded),
            tooltip: 'Ricomincia Video',
          ),
          IconButton.filled(
            style: IconButton.styleFrom(backgroundColor: NexusTheme.accentIndigo),
            onPressed: () {
              NexusFfiBridge.instance.sendMediaControl("PAUSE");
              ScaffoldMessenger.of(context).hideCurrentSnackBar();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('⏸️ Comando PAUSA inviato al PC'),
                  duration: Duration(milliseconds: 600),
                ),
              );
            },
            icon: const Icon(Icons.pause_rounded, size: 26),
            tooltip: 'Pausa PC',
          ),
          IconButton.filled(
            style: IconButton.styleFrom(backgroundColor: NexusTheme.successGreen),
            onPressed: () {
              NexusFfiBridge.instance.sendMediaControl("PLAY");
              ScaffoldMessenger.of(context).hideCurrentSnackBar();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('▶️ Comando PLAY inviato al PC'),
                  duration: Duration(milliseconds: 600),
                ),
              );
            },
            icon: const Icon(Icons.play_arrow_rounded, size: 26),
            tooltip: 'Riprendi PC',
          ),
          const SizedBox(width: 12),
          IconButton.filledTonal(
            style: IconButton.styleFrom(backgroundColor: NexusTheme.surfaceCard),
            onPressed: () => NexusFfiBridge.instance.setMasterVolume(0.5),
            icon: const Icon(Icons.volume_down_rounded),
          ),
          IconButton.filledTonal(
            style: IconButton.styleFrom(backgroundColor: NexusTheme.surfaceCard),
            onPressed: () => NexusFfiBridge.instance.setMasterVolume(0.9),
            icon: const Icon(Icons.volume_up_rounded),
          ),
        ],
      ),
    );
  }
}
