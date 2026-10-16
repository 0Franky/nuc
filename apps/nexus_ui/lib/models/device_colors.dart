import 'dart:ui';

/// Per-device color palette for notification cards and UI indicators.
class NexusDeviceColors {
  static const List<Color> _palette = [
    Color(0xFF6366F1), // Indigo (PC)
    Color(0xFF10B981), // Emerald (Android)
    Color(0xFFF59E0B), // Amber
    Color(0xFFF43F5E), // Rose
    Color(0xFF06B6D4), // Cyan
    Color(0xFF8B5CF6), // Violet
  ];

  static final Map<String, Color> _deviceColorCache = {};
  /// Palette indices 0 (PC / desktop) and 1 (phone) are reserved for
  /// [colorForDeviceName]; generic devices never receive them.
  static const int _reservedCount = 2;

  static const _desktopTokens = {
    'pc',
    'windows',
    'desktop',
    'laptop',
    'mac',
    'macbook',
    'imac',
    'linux',
  };

  static const _phoneTokens = {
    'android',
    'smartphone',
    'phone',
    'iphone',
  };

  static Color colorForDevice(String deviceId) {
    final cached = _deviceColorCache[deviceId];
    if (cached != null) return cached;
    // Stable FNV-1a hash: the same id always gets the same colour, regardless
    // of discovery order or session.
    var hash = 0x811c9dc5;
    for (final unit in deviceId.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    final color =
        _palette[_reservedCount + hash % (_palette.length - _reservedCount)];
    _deviceColorCache[deviceId] = color;
    return color;
  }

  static Color colorForDeviceName(String deviceName) {
    // Map common names to stable IDs, matching whole words only
    // (e.g. 'mac' must not match 'macchina').
    final normalizedId = deviceName.toLowerCase().trim();
    final tokens = normalizedId
        .split(RegExp(r'[^a-z0-9]+'))
        .where((t) => t.isNotEmpty)
        .toSet();
    if (tokens.any(_desktopTokens.contains)) {
      return _palette[0]; // Indigo for primary PC / Desktop
    }
    if (tokens.any(_phoneTokens.contains)) {
      return _palette[1]; // Emerald for Mobile / Phone
    }
    return colorForDevice(normalizedId);
  }
}
