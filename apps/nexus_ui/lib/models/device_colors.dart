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
  static int _nextColorIndex = 0;

  static Color colorForDevice(String deviceId) {
    if (_deviceColorCache.containsKey(deviceId)) {
      return _deviceColorCache[deviceId]!;
    }
    final color = _palette[_nextColorIndex % _palette.length];
    _deviceColorCache[deviceId] = color;
    _nextColorIndex++;
    return color;
  }

  static Color colorForDeviceName(String deviceName) {
    // Map common names to stable IDs
    final normalizedId = deviceName.toLowerCase().trim();
    if (normalizedId.contains('pc') ||
        normalizedId.contains('windows') ||
        normalizedId.contains('desktop') ||
        normalizedId.contains('laptop') ||
        normalizedId.contains('mac') ||
        normalizedId.contains('linux')) {
      return _palette[0]; // Indigo for primary PC / Desktop
    }
    if (normalizedId.contains('android') ||
        normalizedId.contains('smartphone') ||
        normalizedId.contains('phone') ||
        normalizedId.contains('iphone')) {
      return _palette[1]; // Emerald for Mobile / Phone
    }
    return colorForDevice(normalizedId);
  }
}
