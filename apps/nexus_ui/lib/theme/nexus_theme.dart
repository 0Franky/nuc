import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Apple-grade Human Interface Guidelines (HIG) theme for Nexus Universal Continuity.
/// Surfaces: Deep space frosted glass, rich slate elevated cards, delicate glassy borders.
class NexusTheme {
  NexusTheme._();

  // --- Palette ---
  static const Color background = Color(0xFF0F172A); // Slate 900 base
  static const Color surfaceCard = Color(0xFF1E293B); // Slate 800 inset card
  static const Color surfaceCardHover = Color(0xFF273549);
  static const Color surfaceSecondary = Color(0xFF162032);

  // Accents
  static const Color accentIndigo = Color(0xFF6366F1); // Primary Continuity
  static const Color accentIndigoMuted = Color(0x336366F1);
  static const Color accentIndigoLight = Color(0xFF818CF8); // Indigo 400 icons/borders
  static const Color successGreen = Color(0xFF10B981); // Online / Verified
  static const Color successGreenMuted = Color(0x2610B981);
  static const Color mediaAccentRed = Color(0xFFFF5252); // Media playback accent (was Colors.redAccent)
  static const Color qrBackground = Color(0xFFFFFFFF); // QR code quiet zone must stay white
  static const Color iconOnSurface = Color(0xFFFFFFFF); // Icons on dark surfaces (was Colors.white)
  static const Color warningAmber = Color(0xFFF59E0B); // Zero-Trust / Secret
  static const Color warningAmberMuted = Color(0x26F59E0B);
  static const Color errorRed = Color(0xFFEF4444); // Disconnected / Blocked
  static const Color errorRedMuted = Color(0x26EF4444);

  // Text
  static const Color textPrimary = Color(0xFFF8FAFC);
  static const Color textSecondary = Color(0xFF94A3B8);
  // #8494A9: contrast ~4.7:1 on surfaceCard, above WCAG AA 4.5:1 (was #64748B, ~3:1).
  static const Color textTertiary = Color(0xFF8494A9);

  // Borders & Dividers (Apple subtle translucent hair-line)
  static final Color borderSubtle = Colors.white.withAlpha(20);
  static final Color borderCard = Colors.white.withAlpha(28);

  // --- Radii ---
  static const double radiusPill = 999.0;
  static const double radiusCard = 16.0;
  static const double radiusModal = 20.0;
  static const double radiusButton = 12.0;

  // --- BoxDecorations ---
  static BoxDecoration cardDecoration({
    Color? color,
    Border? border,
    double radius = radiusCard,
    List<BoxShadow>? shadows,
  }) {
    return BoxDecoration(
      color: color ?? surfaceCard,
      borderRadius: BorderRadius.circular(radius),
      border: border ?? Border.all(color: borderCard, width: 1),
      boxShadow: shadows ??
          [
            BoxShadow(
              color: Colors.black.withAlpha(40),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
    );
  }

  // --- ThemeData ---
  /// Built once: a getter would create a new ThemeData on every MaterialApp rebuild.
  static final ThemeData darkTheme = _buildDarkTheme();

  static ThemeData _buildDarkTheme() {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: background,
      primaryColor: accentIndigo,
      colorScheme: const ColorScheme.dark(
        primary: accentIndigo,
        secondary: successGreen,
        surface: surfaceCard,
        error: errorRed,
        onPrimary: Colors.white,
        onSurface: textPrimary,
      ),
      useMaterial3: true,
      // 'Segoe UI' exists only on Windows; elsewhere keep the platform default font.
      fontFamily: defaultTargetPlatform == TargetPlatform.windows ? 'Segoe UI' : null,
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
        iconTheme: IconThemeData(color: textPrimary),
      ),
      cardTheme: CardThemeData(
        color: surfaceCard,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusCard),
          side: BorderSide(color: borderCard, width: 1),
        ),
        margin: EdgeInsets.zero,
      ),
      dividerTheme: DividerThemeData(
        color: borderSubtle,
        thickness: 1,
        space: 1,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return Colors.white;
          }
          return textTertiary;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return successGreen;
          }
          return surfaceSecondary;
        }),
        trackOutlineColor: WidgetStateProperty.all(borderCard),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: accentIndigo,
        inactiveTrackColor: surfaceSecondary,
        thumbColor: Colors.white,
        trackHeight: 6,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
      ),
    );
  }
}
