import 'package:flutter/material.dart';
import '../models/device_colors.dart';
import '../services/lan_sync_service.dart';
import '../theme/nexus_theme.dart';

/// Reusable widget for switching the active target device on-the-fly.
/// Displays connected online peers with their unique device colors.
class TargetDeviceSelector extends StatelessWidget {
  final String? selectedDeviceId;
  final ValueChanged<String>? onDeviceSelected;
  final String? filterType; // e.g. 'Desktop' to only show controllable PCs
  final bool compact;
  final String title;

  const TargetDeviceSelector({
    super.key,
    this.selectedDeviceId,
    this.onDeviceSelected,
    this.filterType,
    this.compact = false,
    this.title = "Dispositivo Destinazione",
  });

  @override
  Widget build(BuildContext context) {
    final lan = LanSyncService.instance;

    return ListenableBuilder(
      listenable: lan,
      builder: (context, _) {
        final allPeers = lan.discoveredPeers;

        // Filter peers if needed (e.g. desktop only for touchpad remote)
        var peers = allPeers.where((p) {
          if (p['online'] == false) return false;
          if (filterType != null && p['device_type'] != filterType) {
            final os = (p['os'] as String?)?.toLowerCase() ?? '';
            final isDesktopOs = os.contains('windows') || os.contains('mac') || os.contains('linux');
            if (!isDesktopOs) return false;
          }
          return true;
        }).toList();

        final currentTargetId = selectedDeviceId ?? lan.selectedTargetDeviceId ?? (peers.isNotEmpty ? peers.first['id'] as String : '');

        return Container(
          padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 12, vertical: compact ? 6 : 8),
          decoration: BoxDecoration(
            color: NexusTheme.surfaceSecondary.withAlpha(160),
            borderRadius: BorderRadius.circular(NexusTheme.radiusCard),
            border: Border.all(color: NexusTheme.borderCard),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!compact) ...[
                Row(
                  children: [
                    const Icon(Icons.swap_horiz, size: 14, color: NexusTheme.textSecondary),
                    const SizedBox(width: 6),
                    Text(
                      title.toUpperCase(),
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                        color: NexusTheme.textSecondary,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: NexusTheme.accentIndigoMuted,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        "${peers.length} ${peers.length == 1 ? 'nodo' : 'nodi'}",
                        style: const TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF818CF8),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
              if (peers.isEmpty)
                Row(
                  children: [
                    const Icon(
                      Icons.radar_rounded,
                      size: 14,
                      color: NexusTheme.accentIndigo,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'In ascolto LAN... Nessun peer rilevato',
                        style: TextStyle(
                          fontSize: compact ? 11 : 12,
                          color: NexusTheme.textTertiary,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  ],
                )
              else
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: peers.map((peer) {
                final id = peer['id'] as String? ?? '';
                final name = peer['name'] as String? ?? 'Dispositivo';
                final isSelected = id == currentTargetId || (peers.length == 1 && id.isNotEmpty);
                final devColor = NexusDeviceColors.colorForDeviceName(name);
                final isDesktop = (peer['device_type'] as String?) == 'Desktop' ||
                    (peer['os'] as String?)?.toLowerCase() == 'windows' ||
                    name.toLowerCase().contains('pc');

                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () {
                        lan.selectTargetDevice(id);
                        onDeviceSelected?.call(id);
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: EdgeInsets.symmetric(
                          horizontal: compact ? 10 : 12,
                          vertical: compact ? 6 : 8,
                        ),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? devColor.withAlpha(45)
                              : NexusTheme.surfaceCard.withAlpha(200),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isSelected
                                ? devColor
                                : NexusTheme.borderCard,
                            width: isSelected ? 1.8 : 1.0,
                          ),
                          boxShadow: isSelected
                              ? [
                                  BoxShadow(
                                    color: devColor.withAlpha(60),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  )
                                ]
                              : null,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: devColor,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: devColor.withAlpha(150),
                                    blurRadius: 4,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              isDesktop ? Icons.desktop_windows : Icons.smartphone,
                              size: 14,
                              color: isSelected ? devColor : NexusTheme.textSecondary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              name,
                              style: TextStyle(
                                fontSize: compact ? 12 : 13,
                                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                                color: isSelected ? Colors.white : NexusTheme.textPrimary,
                              ),
                            ),
                            if (isSelected) ...[
                              const SizedBox(width: 6),
                              Icon(
                                Icons.check_circle,
                                size: 13,
                                color: devColor,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  },
);
}
}
