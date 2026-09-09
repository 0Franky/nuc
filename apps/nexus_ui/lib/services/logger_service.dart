import 'dart:io';

class NexusLogger {
  static void log(String tag, String message) {
    // ignore: avoid_print
    print('[$tag] $message');
    final now = DateTime.now().toIso8601String();
    final formatted = '[$now] [$tag] $message\n';

    final path = 'logs/nexus_ui.log';
    try {
      final file = File(path);
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
      file.writeAsStringSync(formatted, mode: FileMode.append, flush: true);
    } catch (_) {}
  }
}
