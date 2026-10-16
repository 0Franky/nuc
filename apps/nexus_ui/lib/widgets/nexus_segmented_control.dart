import 'package:flutter/material.dart';

import '../theme/nexus_theme.dart';

class NexusSegmentedControl<T> extends StatelessWidget {
  final Map<T, String> segments;
  final T selectedValue;
  final ValueChanged<T> onValueChanged;
  final Map<T, IconData>? segmentIcons;

  /// Altezza minima (px) dell'area di tocco di ogni segmento (Material: 48).
  static const double minTapTarget = 48.0;

  const NexusSegmentedControl({
    super.key,
    required this.segments,
    required this.selectedValue,
    required this.onValueChanged,
    this.segmentIcons,
  });

  @override
  Widget build(BuildContext context) {
    assert(segments.isNotEmpty, 'NexusSegmentedControl: segments è vuota');
    assert(
      segments.containsKey(selectedValue),
      'NexusSegmentedControl: selectedValue non è tra le chiavi di segments',
    );
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: NexusTheme.surfaceSecondary,
        borderRadius: BorderRadius.circular(NexusTheme.radiusPill),
        border: Border.all(color: NexusTheme.borderCard, width: 1),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Con larghezza vincolata i segmenti si dividono lo spazio (Expanded);
          // in contesti non vincolati (Row, scroll orizzontale, Wrap) Expanded
          // lancerebbe un errore, quindi si usa la larghezza naturale.
          final bounded = constraints.hasBoundedWidth;
          return Row(
            mainAxisSize: bounded ? MainAxisSize.max : MainAxisSize.min,
            children: segments.entries.map((entry) {
              final isSelected = entry.key == selectedValue;
              final icon = segmentIcons?[entry.key];

              final segment = Semantics(
                button: true,
                selected: isSelected,
                child: Material(
                  type: MaterialType.transparency,
                  // InkWell: focus da tastiera, attivazione con Invio/Spazio,
                  // hover, ripple e cursore su desktop (#65).
                  child: InkWell(
                    // Nessuna notifica se il segmento è già selezionato.
                    onTap: () {
                      if (!isSelected) onValueChanged(entry.key);
                    },
                    mouseCursor: isSelected
                        ? SystemMouseCursors.basic
                        : SystemMouseCursors.click,
                    borderRadius: BorderRadius.circular(
                      NexusTheme.radiusPill,
                    ),
                    child: AnimatedContainer(
                      constraints: const BoxConstraints(
                        minHeight: minTapTarget,
                      ),
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeInOut,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? NexusTheme.surfaceCardHover
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(
                          NexusTheme.radiusPill,
                        ),
                        border: isSelected
                            ? Border.all(
                                color: NexusTheme.accentIndigo.withAlpha(90),
                                width: 1,
                              )
                            : Border.all(color: Colors.transparent, width: 1),
                        boxShadow: isSelected
                            ? [
                                BoxShadow(
                                  color: Colors.black.withAlpha(30),
                                  blurRadius: 4,
                                  offset: const Offset(0, 2),
                                ),
                              ]
                            : null,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (icon != null) ...[
                            Icon(
                              icon,
                              size: 13,
                              color: isSelected
                                  ? NexusTheme.textPrimary
                                  : NexusTheme.textSecondary,
                            ),
                            const SizedBox(width: 5),
                          ],
                          Flexible(
                            child: Text(
                              entry.value,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: isSelected
                                    ? NexusTheme.textPrimary
                                    : NexusTheme.textSecondary,
                                fontSize: 12,
                                fontWeight: isSelected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
              return bounded ? Expanded(child: segment) : segment;
            }).toList(),
          );
        },
      ),
    );
  }
}
