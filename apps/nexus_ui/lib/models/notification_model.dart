enum NexusNotificationCategory {
  osNotification, // Real OS notifications (WhatsApp, Claude, Chrome, etc.)
  internalApp, // Internal Nexus app notifications (proximity, handoff, system)
}

class NexusNotification {
  final String id;
  final String title;
  final String rawBody;
  String currentBody;
  final String appName;
  final String senderDevice;
  final String senderDeviceId;
  final DateTime timestamp;
  final bool hasSecret;
  final String secretCategory;
  bool isRevealed;
  final NexusNotificationCategory category;

  NexusNotification({
    required this.id,
    required this.title,
    required this.rawBody,
    required this.currentBody,
    required this.appName,
    required this.senderDevice,
    required this.senderDeviceId,
    required this.timestamp,
    required this.hasSecret,
    this.secretCategory = '',
    this.isRevealed = false,
    this.category = NexusNotificationCategory.osNotification,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'body': currentBody,
    'raw_body': rawBody,
    'app_name': appName,
    'sender_device': senderDevice,
    'sender_device_id': senderDeviceId,
    'timestamp': timestamp.toIso8601String(),
    'has_secret': hasSecret,
    'secret_category': secretCategory,
    'is_revealed': isRevealed,
    'category': category.name,
  };
}
