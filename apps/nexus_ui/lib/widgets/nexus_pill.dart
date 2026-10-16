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

  /// Icona opzionale. Ignorata se è presente [leading]: non passarle entrambe.
  final IconData? icon;

  /// Widget iniziale personalizzato. Ha la precedenza su [icon].
  final Widget? leading;
  final NexusPillStyle style;
  final VoidCallback? onTap;
  final bool showDot;

  /// Area di tocco minima (px) della variante cliccabile.
  static const double minTapTarget = 48.0;

  const NexusPill({
    super.key,
    required this.label,
    this.icon,
    this.leading,
    this.style = NexusPillStyle.neutral,
    this.onTap,
    this.showDot = false,
  }) : assert(leading == null || icon == null,
            'NexusPill: passare leading oppure icon, non entrambi');

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
        fg = NexusTheme.accentIndigoLight;
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
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: fg,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.1,
            ),
          ),
        ),
      ],
    );

    final decoration = BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(NexusTheme.radiusPill),
      border: Border.all(color: border, width: 1),
    );
    const padding = EdgeInsets.symmetric(horizontal: 10, vertical: 4.5);

    // Pill statica: nessun InkWell montato.
    if (onTap == null) {
      return Container(
        padding: padding,
        decoration: decoration,
        child: content,
      );
    }

    // Pill cliccabile: lo sfondo sta in un Ink, così ripple e hover restano
    // visibili sopra la decorazione. L'area di tocco è estesa a minimo
    // [minTapTarget] px con un GestureDetector trasparente attorno alla pill,
    // senza cambiare la dimensione visiva; focus e cursore sono espliciti.
    // MergeSemantics unisce il flag button, l'etichetta e l'azione tap
    // dell'InkWell interno in un solo nodo accessibile.
    return MergeSemantics(
      child: Semantics(
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: minTapTarget,
              minHeight: minTapTarget,
            ),
            child: Center(
              widthFactor: 1.0,
              heightFactor: 1.0,
              child: Material(
                color: Colors.transparent,
                child: Ink(
                  decoration: decoration,
                  child: InkWell(
                    onTap: onTap,
                    canRequestFocus: true,
                    mouseCursor: SystemMouseCursors.click,
                    focusColor: fg.withAlpha(40),
                    hoverColor: fg.withAlpha(20),
                    borderRadius:
                        BorderRadius.circular(NexusTheme.radiusPill),
                    child: Padding(padding: padding, child: content),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      ),
    );
  }
}
