import 'package:flutter/material.dart';
import '../theme/nexus_theme.dart';

class NexusSegmentedControl<T> extends StatelessWidget {
  final Map<T, String> segments;
  final T selectedValue;
  final ValueChanged<T> onValueChanged;
  final Map<T, IconData>? segmentIcons;

  const NexusSegmentedControl({
    super.key,
    required this.segments,
    required this.selectedValue,
    required this.onValueChanged,
    this.segmentIcons,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: NexusTheme.surfaceSecondary,
        borderRadius: BorderRadius.circular(NexusTheme.radiusPill),
        border: Border.all(color: NexusTheme.borderCard, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: segments.entries.map((entry) {
          final isSelected = entry.key == selectedValue;
          final icon = segmentIcons?[entry.key];

          return Expanded(
            child: GestureDetector(
              onTap: () => onValueChanged(entry.key),
              behavior: HitTestBehavior.opaque,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeInOut,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: isSelected ? NexusTheme.surfaceCardHover : Colors.transparent,
                  borderRadius: BorderRadius.circular(NexusTheme.radiusPill),
                  border: isSelected
                      ? Border.all(color: NexusTheme.accentIndigo.withAlpha(90), width: 1)
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
                        color: isSelected ? Colors.white : NexusTheme.textSecondary,
                      ),
                      const SizedBox(width: 5),
                    ],
                    Flexible(
                      child: Text(
                        entry.value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isSelected ? Colors.white : NexusTheme.textSecondary,
                          fontSize: 12,
                          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
