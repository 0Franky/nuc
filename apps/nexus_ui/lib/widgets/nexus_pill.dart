import 'package:flutter/material.dart';
import '../theme/nexus_theme.dart';

enum NexusPillStyle {
  neutral,
  success,
  accent,
  warning,
  error,
}

class NexusPill extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Widget? leading;
  final NexusPillStyle style;
  final VoidCallback? onTap;
  final bool showDot;

  const NexusPill({
    super.key,
    required this.label,
    this.icon,
    this.leading,
    this.style = NexusPillStyle.neutral,
    this.onTap,
    this.showDot = false,
  });

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color border;
    Color fg;

    switch (style) {
      case NexusPillStyle.success:
        bg = NexusTheme.successGreenMuted;
        border = NexusTheme.successGreen.withAlpha(80);
        fg = NexusTheme.successGreen;
        break;
      case NexusPillStyle.accent:
        bg = NexusTheme.accentIndigoMuted;
        border = NexusTheme.accentIndigo.withAlpha(80);
        fg = const Color(0xFF818CF8);
        break;
      case NexusPillStyle.warning:
        bg = NexusTheme.warningAmberMuted;
        border = NexusTheme.warningAmber.withAlpha(90);
        fg = NexusTheme.warningAmber;
        break;
      case NexusPillStyle.error:
        bg = NexusTheme.errorRedMuted;
        border = NexusTheme.errorRed.withAlpha(90);
        fg = NexusTheme.errorRed;
        break;
      case NexusPillStyle.neutral:
        bg = NexusTheme.surfaceSecondary;
        border = NexusTheme.borderCard;
        fg = NexusTheme.textSecondary;
        break;
    }

    Widget content = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (showDot) ...[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: fg,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
        ],
        if (leading != null) ...[
          leading!,
          const SizedBox(width: 5),
        ] else if (icon != null) ...[
          Icon(icon, size: 13, color: fg),
          const SizedBox(width: 5),
        ],
        Text(
          label,
          style: TextStyle(
            color: fg,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.1,
          ),
        ),
      ],
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(NexusTheme.radiusPill),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(NexusTheme.radiusPill),
            border: Border.all(color: border, width: 1),
          ),
          child: content,
        ),
      ),
    );
  }
}
