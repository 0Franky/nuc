import 'dart:io';

import 'package:flutter/foundation.dart';

/// File logger. Writes go through a buffered [IOSink] (no synchronous I/O
/// per message on the UI thread); the file rotates past [_maxBytes].
/// NOTE: callers must not log secrets or clipboard/notification contents.
class NexusLogger {
  static const int _maxBytes = 5 * 1024 * 1024;
  static const String _fileName = 'nexus_ui.log';

  static IOSink? _sink;
  static File? _file;
  static int _written = 0;
  static bool _disabled = false;
  static bool _rotating = false;

  static void log(String tag, String message) {
    if (!kReleaseMode) debugPrint('[$tag] $message');
    if (_disabled || _rotating) return;
    final now = DateTime.now().toIso8601String();
    final formatted = '[$now] [$tag] $message\n';

    final sink = _sink ?? _open();
    if (sink == null) return;
    try {
      sink.write(formatted);
      _written += formatted.length;
      if (_written > _maxBytes) _rotate();
    } catch (e) {
      _fail(e);
    }
  }

  /// Candidate directories: `logs/` in the working directory (dev layout),
  /// then the system temp directory when that one is not writable.
  static IOSink? _open() {
    final dirs = [
      Directory('logs'),
      Directory('${Directory.systemTemp.path}${Platform.pathSeparator}nexus_ui'),
    ];
    Object? lastError;
    for (final dir in dirs) {
      try {
        if (!dir.existsSync()) dir.createSync(recursive: true);
        final file = File('${dir.path}${Platform.pathSeparator}$_fileName');
        if (file.existsSync() && file.lengthSync() > _maxBytes) {
          _rotateFile(file);
        }
        // One-time writability probe, then buffered async writes.
        file.openSync(mode: FileMode.append).closeSync();
        final sink = file.openWrite(mode: FileMode.append);
        sink.done.catchError((Object e) => _fail(e));
        _file = file;
        _sink = sink;
        _written = 0;
        return sink;
      } catch (e) {
        lastError = e;
      }
    }
    _fail(lastError ?? 'no writable log directory');
    return null;
  }

  static void _rotate() {
    final sink = _sink;
    final file = _file;
    _sink = null;
    _rotating = true;
    Future<void>(() async {
      try {
        await sink?.close();
        if (file != null) _rotateFile(file);
      } catch (_) {
        // Rotation failure: keep appending to the current file.
      } finally {
        _written = 0;
        _rotating = false;
      }
    });
  }

  static void _rotateFile(File file) {
    final backup = File('${file.path}.1');
    if (backup.existsSync()) backup.deleteSync();
    file.renameSync(backup.path);
  }

  static void _fail(Object error) {
    if (_disabled) return;
    _disabled = true;
    _sink = null;
    // Report once instead of failing silently on every call.
    debugPrint('[NexusLogger] file logging disabled: $error');
  }
}
