import 'package:flutter/material.dart';
import '../services/lan_sync_service.dart';
import '../theme/nexus_theme.dart';

/// fix D #105: scroll orizzontale con Scrollbar visibile e controller proprio
/// (necessario su desktop, dove non c'è PrimaryScrollController orizzontale).
class _ScrollableRow extends StatefulWidget {
  const _ScrollableRow({required this.child});

  final Widget child;

  @override
  State<_ScrollableRow> createState() => _ScrollableRowState();
}

class _ScrollableRowState extends State<_ScrollableRow> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      key: const ValueKey('d105-selector-scrollbar'),
      controller: _controller,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(bottom: 8),
        child: widget.child,
      ),
    );
  }
}

/// Reusable widget for switching the active target device on-the-fly.
/// Displays connected online peers with their unique device colors.
class TargetDeviceSelector extends StatelessWidget {
  /// Id evidenziato. Se non nullo ha la precedenza su
  /// [LanSyncService.currentTargetId]: il genitore deve aggiornarlo in
  /// [onDeviceSelected], altrimenti dopo il tap l'evidenziazione resta
  /// sul vecchio dispositivo. Lasciarlo null per seguire il servizio.
  final String? selectedDeviceId;

  /// Chiamato dopo il tap su un peer online.
  final ValueChanged<String>? onDeviceSelected;

  /// Se true (default) il tap aggiorna anche il target globale con
  /// [LanSyncService.selectTargetDevice]. Impostarlo a false per una
  /// selezione solo locale, gestita tramite [selectedDeviceId] e
  /// [onDeviceSelected].
  final bool updateGlobalTarget;
  final String? filterType; // e.g. 'Desktop' to only show controllable PCs
  final bool compact;
  final String title;

  const TargetDeviceSelector({
    super.key,
    this.selectedDeviceId,
    this.onDeviceSelected,
    this.filterType,
    this.updateGlobalTarget = true,
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
          if (filterType != null) {
            if (filterType == 'Desktop') {
              final isDesktop = LanSyncService.isDesktopPeer(p);
              if (!isDesktop) return false;
            } else if (p['device_type'] != filterType) {
              return false;
            }
          }
          return true;
        }).toList();

        // Evidenzia solo il target realmente selezionato: un fallback solo
        // visivo sul primo peer faceva credere all'utente di aver scelto un
        // dispositivo che il servizio non conosce (selectTargetDevice mai chiamato).
        final currentTargetId = selectedDeviceId ?? lan.selectedTargetDeviceId ?? '';

        // fix D #97: se il target corrente è escluso dal filtro l'utente non
        // vedeva nessuna selezione; lo segnaliamo esplicitamente.
        String? hiddenTargetName;
        if (currentTargetId.isNotEmpty &&
            !peers.any((p) => p['id'] == currentTargetId)) {
          for (final p in allPeers) {
            if (p['id'] == currentTargetId) {
              hiddenTargetName = p['name'] as String? ?? 'Dispositivo';
              break;
            }
          }
        }

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
                    Expanded(
                      child: Text(
                        title.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: NexusTheme.textSecondary,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: NexusTheme.accentIndigoMuted,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        "${peers.where((p) => p['online'] != false).length}/${peers.length} online",
                        style: const TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          color: NexusTheme.accentIndigoLight,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
              if (hiddenTargetName != null) ...[
                Text(
                  'Destinazione attuale "$hiddenTargetName" non compatibile con questo filtro: selezionane una qui sotto.',
                  key: const ValueKey('d97-hidden-target'),
                  style: TextStyle(
                    fontSize: compact ? 11 : 12,
                    color: NexusTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 6),
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
                _ScrollableRow(
                  child: Row(
                    children: peers.map((peer) {
                final id = peer['id'] as String? ?? '';
                final online = peer['online'] != false;
                final name = peer['name'] as String? ?? 'Dispositivo';
                final isSelected = id == currentTargetId;
                final devColor = NexusDeviceColors.colorForDevice(id);
                final isDesktop = LanSyncService.isDesktopPeer(peer);

                return Padding(
                  key: ValueKey(id),
                  padding: const EdgeInsets.only(right: 8),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: !online ? null : () {
                        if (updateGlobalTarget) lan.selectTargetDevice(id);
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
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 180),
                              child: Text(
                                online ? name : '$name · offline',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: compact ? 12 : 13,
                                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                                  color: isSelected ? Colors.white : NexusTheme.textPrimary,
                                ),
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
