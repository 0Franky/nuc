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
        fg = const Color(0xFF818CF8);
        borderSide = BorderSide(color: NexusTheme.accentIndigo.withAlpha(80), width: 1);
        break;
      case NexusButtonStyle.destructive:
        bg = NexusTheme.errorRed.withAlpha(40);
        fg = NexusTheme.errorRed;
        borderSide = BorderSide(color: NexusTheme.errorRed.withAlpha(90), width: 1);
        break;
    }

    Widget content = isLoading
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
          )
        : Row(
            mainAxisSize: isExpanded ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 17, color: fg),
                const SizedBox(width: 8),
              ],
              Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  letterSpacing: -0.1,
                ),
              ),
            ],
          );

    final buttonWidget = ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: bg,
        foregroundColor: fg,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NexusTheme.radiusButton),
          side: borderSide,
        ),
        minimumSize: Size(isExpanded ? double.infinity : 0, height),
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
