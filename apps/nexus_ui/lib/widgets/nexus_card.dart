import 'package:flutter/material.dart';

import '../theme/nexus_theme.dart';

class NexusCard extends StatelessWidget {
  final Widget? child;
  final String? title;
  final String? subtitle;
  final IconData? icon;
  final Color? iconColor;
  final Color? iconBackgroundColor;
  final Widget? trailing;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final Color? backgroundColor;
  final Border? border;
  final double borderRadius;

  const NexusCard({
    super.key,
    this.child,
    this.title,
    this.subtitle,
    this.icon,
    this.iconColor,
    this.iconBackgroundColor,
    this.trailing,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
    this.backgroundColor,
    this.border,
    this.borderRadius = NexusTheme.radiusCard,
  });

  @override
  Widget build(BuildContext context) {
    // Con borderRadius Flutter richiede un Border uniforme, altrimenti il
    // paint lancia un'eccezione.
    assert(
      border == null || border!.isUniform,
      'NexusCard: border deve essere uniforme (usato con borderRadius).',
    );
    final hasHeader =
        title != null || subtitle != null || icon != null || trailing != null;

    final decoration = NexusTheme.cardDecoration(
      color: backgroundColor,
      border: border,
      radius: borderRadius,
    );

    // Superficie trasparente per l'ink degli InkWell figli: nella variante
    // non tappabile e' l'unico Material sopra la decorazione del Container.
    final Widget content = Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasHeader) ...[
            Row(
              children: [
                if (icon != null) ...[
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color:
                          iconBackgroundColor ??
                          (iconColor ?? NexusTheme.accentIndigo).withAlpha(35),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      icon,
                      color: iconColor ?? NexusTheme.accentIndigo,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (title != null)
                        Text(
                          title!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: NexusTheme.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 14.5,
                            letterSpacing: -0.2,
                          ),
                        ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: NexusTheme.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
            if (child != null) const SizedBox(height: 14),
          ],
          ?child,
        ],
      ),
    );

    if (onTap != null) {
      return Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(borderRadius),
        // Nessun clip: taglierebbe la boxShadow di cardDecoration. Ripple e
        // hover sono gia' limitati dal borderRadius dell'InkWell.
        // Ink dipinge la decorazione sul Material, cosi' ripple e hover
        // dell'InkWell restano visibili sopra lo sfondo della card.
        child: Ink(
          decoration: decoration,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(borderRadius),
            hoverColor: NexusTheme.surfaceCardHover,
            splashColor: NexusTheme.accentIndigo.withAlpha(40),
            child: Padding(padding: padding, child: content),
          ),
        ),
      );
    }

    return Container(padding: padding, decoration: decoration, child: content);
  }
}
