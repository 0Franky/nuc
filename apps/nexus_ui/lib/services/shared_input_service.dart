import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'lan_sync_service.dart';

/// The input engine runs as a separate, version-pinned native process. Nexus
/// owns configuration/topology; keystrokes never pass through the Flutter UI.
class SharedInputService extends ChangeNotifier {
  static final instance = SharedInputService();
  SharedInputService({Directory? engineDirectory, Directory? configDirectory})
    : _engineDirectory = engineDirectory,
      _configDirectory = configDirectory;
  final Directory? _engineDirectory;
  final Directory? _configDirectory;
  static const port = 4243;
  static final fingerprintPattern = RegExp(
    r'^(?:[0-9a-f]{2}:){31}[0-9a-f]{2}$',
  );
  LanSyncService? _lan;
  Process? _process;
  Socket? _ipc;
  Timer? _debounce;
  Timer? _heartbeat;
  bool enabled = false;
  bool busy = false;
  bool captureReady = false;
  bool emulationReady = false;
  String? fingerprint;
  String? error;
  final Map<String, String> trusted = {};
  String _lastConfig = '';
  Future<void> _writes = Future.value();
  Directory? _directory;
  bool get supported => Platform.isWindows || Platform.isLinux;
  bool get running => _process != null && _ipc != null;
  String get status =>
      error ??
      (busy
          ? 'Avvio input condiviso…'
          : !enabled
          ? 'Input condiviso disattivato'
          : !running
          ? 'Backend non avviato'
          : !captureReady || !emulationReady
          ? 'In attesa dei permessi del desktop'
          : 'Mouse e tastiera pronti • Ctrl + Alt + Shift + Win/Super per tornare in locale');

  Future<void> initialize(LanSyncService lan) async {
    if (_lan != null || !supported) return;
    _lan = lan;
    final prefs = await SharedPreferences.getInstance();
    final saved =
        jsonDecode(prefs.getString('shared_input_trusted') ?? '{}') as Map;
    for (final entry in saved.entries) {
      if (entry.key is String &&
          entry.value is String &&
          fingerprintPattern.hasMatch(entry.value)) {
        trusted[entry.key as String] = entry.value as String;
      }
    }
    lan.addListener(_scheduleConfig);
    // An old, previously cosmetic universalControlActive flag is not consent.
    if (prefs.getBool('shared_input_enabled') == true) await setEnabled(true);
  }

  void _scheduleConfig() {
    if (!running) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      _writes = _writes.then((_) => _writeConfig()).catchError((
        Object e,
      ) async {
        await _stop();
        enabled = false;
        error = 'Configurazione input: $e';
        notifyListeners();
      });
    });
  }

  static String position(double x, double y) => x.abs() >= y.abs()
      ? (x < 0 ? 'left' : 'right')
      : (y < 0 ? 'top' : 'bottom');

  /// Only explicitly approved fingerprints and live, directly reachable PCs
  /// enter the data-plane configuration. One neighbor per edge is unambiguous.
  static String configuration(
    List<Map<String, dynamic>> peers,
    Map<String, String> approved,
    Map<String, String> positions,
  ) {
    final lines = <String>[
      'port = $port',
      'release_bind = ["KeyLeftCtrl", "KeyLeftAlt", "KeyLeftShift", "KeyLeftMeta"]',
      '[authorized_fingerprints]',
    ];
    final clients = <Map<String, dynamic>>[];
    final edges = <String>{};
    final endpoints = <String>{};
    // Persistent receive authorization does not disappear during peer restart.
    for (final entry in approved.entries) {
      if (!fingerprintPattern.hasMatch(entry.value)) continue;
      final matches = peers.where((p) => p['id'] == entry.key);
      String endpoint = '';
      if (matches.isNotEmpty) {
        final peer = matches.first;
        final address = InternetAddress.tryParse(peer['ip'] as String? ?? '');
        final metadata = peer['shared_input'];
        final remotePort = metadata is Map ? metadata['port'] : null;
        if (address != null &&
            remotePort is int &&
            remotePort > 0 &&
            remotePort < 65536) {
          endpoint = address.type == InternetAddressType.IPv6
              ? '[${address.address}]:$remotePort'
              : '${address.address}:$remotePort';
        }
      }
      lines.add(
        '${jsonEncode(entry.value)} = ${jsonEncode('${entry.key}|$endpoint')}',
      );
    }
    for (final peer in peers) {
      final id = peer['id'] as String;
      final metadata = peer['shared_input'];
      if (metadata is! Map ||
          approved[id] == null ||
          metadata['fingerprint'] != approved[id] ||
          peer['online'] != true) {
        continue;
      }
      final ip = InternetAddress.tryParse(peer['ip'] as String? ?? '');
      if (ip == null || ip.isLoopback || !LanSyncService.isDesktopPeer(peer)) {
        continue;
      }
      final side = positions[id];
      if (!['left', 'right', 'top', 'bottom'].contains(side)) continue;
      final remotePort = metadata['port'];
      if (remotePort is! int || remotePort < 1 || remotePort > 65535) {
        continue;
      }
      if (!edges.add(side!)) {
        throw StateError(
          'Più dispositivi sul bordo $side: separali nella topologia.',
        );
      }
      if (!endpoints.add('${ip.address}:$remotePort')) {
        throw StateError('Due identità condividono lo stesso endpoint input');
      }
      clients.add({'ip': ip.address, 'port': remotePort, 'position': side});
    }
    for (final client in clients) {
      lines.addAll([
        '[[clients]]',
        'ips = [${jsonEncode(client['ip'])}]',
        'port = ${client['port']}',
        'position = ${jsonEncode(client['position'])}',
        'activate_on_startup = true',
      ]);
    }
    return '${lines.join('\n')}\n';
  }

  Future<void> _writeConfig() async {
    final lan = _lan!;
    final positions = <String, String>{};
    for (final peer in lan.discoveredPeers) {
      final id = peer['id'] as String;
      final offset = lan.customDeviceOffsets[id];
      if (offset != null && offset.distance > 1) {
        positions[id] = position(offset.dx, offset.dy);
      }
    }
    final config = configuration(lan.discoveredPeers, trusted, positions);
    if (config == _lastConfig) return;
    // The upstream watcher ignores malformed intermediate writes and reads the
    // closed file. Serialize updates so an old topology cannot win a race.
    await File(
      '${_directory!.path}/config.toml',
    ).writeAsString(config, flush: true);
    _lastConfig = config;
  }

  Future<void> authorize(String id, String expectedFingerprint) async {
    if (!fingerprintPattern.hasMatch(expectedFingerprint)) {
      throw StateError('Impronta non valida');
    }
    final peer = _lan!.discoveredPeers.firstWhere((p) => p['id'] == id);
    if ((peer['shared_input'] as Map?)?['fingerprint'] != expectedFingerprint) {
      throw StateError('Identità cambiata: verifica nuovamente il dispositivo');
    }
    trusted[id] = expectedFingerprint;
    await _saveTrust();
  }

  Future<void> revoke(String id) async {
    trusted.remove(id);
    await _saveTrust();
  }

  Future<void> _saveTrust() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('shared_input_trusted', jsonEncode(trusted));
    if (running) await setEnabled(true);
    notifyListeners();
  }

  Future<Socket> _connectIpc() => Platform.isWindows
      ? Socket.connect(
          '127.0.0.1',
          5252,
          timeout: const Duration(milliseconds: 250),
        )
      : Socket.connect(
          InternetAddress(
            '${Platform.environment['XDG_RUNTIME_DIR']}/lan-mouse-socket.sock',
            type: InternetAddressType.unix,
          ),
          0,
          timeout: const Duration(milliseconds: 250),
        );

  Future<void> setEnabled(bool value) async {
    if (busy || !supported || _lan == null) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await _stop();
      enabled = value;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('shared_input_enabled', value);
      if (!value) return;
      final base = Platform.isWindows
          ? Platform.environment['LOCALAPPDATA']
          : Platform.environment['XDG_CONFIG_HOME'] ??
                '${Platform.environment['HOME']}/.config';
      if (base == null) {
        throw StateError('Directory configurazione utente non disponibile');
      }
      _directory =
          await (_configDirectory ?? Directory('$base/nexus/shared-input'))
              .create(recursive: true);
      // Do not attach to or mutate an independently running LAN Mouse instance.
      try {
        final existing = await _connectIpc();
        existing.destroy();
        throw StateError(
          'Un altro motore LAN Mouse è già attivo. Chiudilo prima di usare Nexus.',
        );
      } on SocketException {
        /* endpoint free */
      }
      final engineDirectory =
          _engineDirectory ??
          Directory(
            '${File(Platform.resolvedExecutable).parent.path}/input-engine',
          );
      final executable =
          '${engineDirectory.path}/lan-mouse${Platform.isWindows ? '.exe' : ''}';
      if (!await File(executable).exists()) {
        throw StateError(
          'Backend input assente nel pacchetto. Ricompila con scripts/build_input_backend.py.',
        );
      }
      _lastConfig = '';
      await _writeConfig();
      final supervisor =
          '${File(executable).parent.path}/nexus-input-host${Platform.isWindows ? '.exe' : ''}';
      if (!await File(supervisor).exists()) {
        throw StateError('Supervisore input assente nel pacchetto');
      }
      final child = await Process.start(
        supervisor,
        [
          executable,
          '--config',
          '${_directory!.path}/config.toml',
          '--cert-path',
          '${_directory!.path}/identity.pem',
          'daemon',
        ],
        environment: {'RUST_LOG': 'warn'},
      );
      _process = child;
      unawaited(child.stdin.done.catchError((Object _) {}));
      child.stdin.writeln();
      _heartbeat = Timer.periodic(const Duration(seconds: 2), (_) {
        if (identical(_process, child)) child.stdin.writeln();
      });
      child.stdout.drain<void>();
      child.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line.contains('ERROR') || line.contains('WARN')) {
              error = 'Backend input: $line';
              notifyListeners();
            }
          });
      unawaited(
        child.exitCode.then((code) {
          if (!identical(_process, child)) return;
          _process = null;
          _heartbeat?.cancel();
          _ipc?.destroy();
          _ipc = null;
          captureReady = emulationReady = false;
          _publish(null);
          error =
              'Backend input terminato ($code). Riattiva la condivisione per riprovare.';
          notifyListeners();
        }),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while (_ipc == null &&
          identical(_process, child) &&
          DateTime.now().isBefore(deadline)) {
        try {
          _ipc = await _connectIpc();
        } on SocketException {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      if (_ipc == null) throw StateError(error ?? 'Il backend non risponde');
      final ipc = _ipc!;
      ipc
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            _event,
            onError: (Object e) => unawaited(
              _ipcLost(ipc, 'Connessione al backend interrotta: $e'),
            ),
            onDone: () =>
                unawaited(_ipcLost(ipc, 'Connessione al backend chiusa')),
          );
      _ipc!.write('${jsonEncode('Sync')}\n');
    } catch (e) {
      await _stop();
      enabled = false;
      error = e.toString();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('shared_input_enabled', false);
    } finally {
      busy = false;
      _lan!.universalControlActive = enabled;
      notifyListeners();
    }
  }

  Future<void> _ipcLost(Socket socket, String message) async {
    if (!identical(_ipc, socket)) return;
    await _stop();
    enabled = false;
    error = message;
    notifyListeners();
  }

  void _event(String line) {
    try {
      final event = jsonDecode(line);
      if (event is! Map) return;
      if (event['CaptureStatus'] != null) {
        captureReady = event['CaptureStatus'] == 'Enabled';
      }
      if (event['EmulationStatus'] != null) {
        emulationReady = event['EmulationStatus'] == 'Enabled';
      }
      if (event['PublicKeyFingerprint'] is String) {
        fingerprint = event['PublicKeyFingerprint'] as String;
        _publish(fingerprint);
      }
      if (event['Error'] is String) error = event['Error'] as String;
      if (captureReady && emulationReady && event['Error'] == null) {
        error = null;
      }
      notifyListeners();
    } catch (_) {
      error = 'Risposta non valida dal backend input';
      notifyListeners();
    }
  }

  void _publish(String? value) {
    _lan!.sharedInputMetadata = value == null
        ? null
        : {'fingerprint': value, 'port': port, 'engine': 'lan-mouse-0.11.0'};
    _lan!.broadcastDeviceMetadata();
  }

  Future<void> shutdown() async {
    _lan?.removeListener(_scheduleConfig);
    await _stop();
  }

  Future<void> _stop() async {
    _debounce?.cancel();
    _heartbeat?.cancel();
    _ipc?.destroy();
    _ipc = null;
    final child = _process;
    _process = null;
    if (child != null) {
      try {
        await child.stdin.close();
      } catch (_) {
        /* process already exited */
      }
      try {
        await child.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        child.kill(ProcessSignal.sigkill);
      }
    }
    captureReady = emulationReady = false;
    if (_lan != null) _publish(null);
  }
}
