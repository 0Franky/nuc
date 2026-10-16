import 'package:flutter/material.dart';
import '../theme/nexus_theme.dart';

enum NexusButtonStyle {
  primary,
  secondary,
  ghost,
  destructive,
}

class NexusButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final NexusButtonStyle style;
  /// Se true il pulsante occupa tutta la larghezza disponibile: richiede un
  /// genitore con vincoli di larghezza finiti (per esempio non una [Row]
  /// senza [Expanded]).
  final bool isExpanded;
  final bool isLoading;
  final double height;

  const NexusButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.style = NexusButtonStyle.primary,
    this.isExpanded = false,
    this.isLoading = false,
    this.height = 42,
  });

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color fg;
    BorderSide borderSide = BorderSide.none;

    switch (style) {
      case NexusButtonStyle.primary:
        bg = NexusTheme.accentIndigo;
        fg = Colors.white;
        break;
      case NexusButtonStyle.secondary:
        bg = NexusTheme.surfaceSecondary;
        fg = NexusTheme.textPrimary;
        borderSide = BorderSide(color: NexusTheme.borderCard, width: 1);
        break;
      case NexusButtonStyle.ghost:
        bg = Colors.transparent;
        fg = NexusTheme.accentIndigoLight;
        borderSide = BorderSide(color: NexusTheme.accentIndigo.withAlpha(80), width: 1);
        break;
      case NexusButtonStyle.destructive:
        bg = NexusTheme.errorRed.withAlpha(40);
        fg = NexusTheme.errorRed;
        borderSide = BorderSide(color: NexusTheme.errorRed.withAlpha(90), width: 1);
        break;
    }

    // Disabilitato (non in loading): colori attenuati ma coerenti con lo stile.
    // In loading si mantengono i colori pieni per evitare il salto visivo.
    final bool isDisabled = onPressed == null && !isLoading;
    final Color effectiveFg = isDisabled ? fg.withAlpha(110) : fg;
    final Color effectiveBg = isDisabled && bg.a > 0 ? bg.withAlpha((bg.a * 255 * 0.5).round()) : bg;

    final Widget row = Row(
            mainAxisSize: isExpanded ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 17, color: effectiveFg),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: effectiveFg,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    letterSpacing: -0.1,
                  ),
                ),
              ),
            ],
          );

    // In loading il Row resta invisibile ma mantiene dimensioni e semantica
    // (la label resta annunciata), lo spinner viene sovrapposto al centro.
    final Widget content = isLoading
        ? Stack(
            alignment: Alignment.center,
            children: [
              Visibility(
                visible: false,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                maintainSemantics: true,
                child: row,
              ),
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: fg,
                  semanticsLabel: 'Caricamento in corso',
                ),
              ),
            ],
          )
        : row;

    final buttonWidget = ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: bg,
        foregroundColor: fg,
        disabledBackgroundColor: effectiveBg,
        disabledForegroundColor: effectiveFg,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NexusTheme.radiusButton),
          side: borderSide,
        ),
        minimumSize: Size(0, height),
      ),
      onPressed: isLoading ? null : onPressed,
      child: content,
    );

    if (isExpanded) {
      return SizedBox(width: double.infinity, height: height, child: buttonWidget);
    }
    return buttonWidget;
  }
}
