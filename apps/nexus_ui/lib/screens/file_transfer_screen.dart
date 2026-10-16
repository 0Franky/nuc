import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../models/transfer_item.dart';
import '../services/lan_sync_service.dart';
import '../services/logger_service.dart';
import '../services/nexus_ffi_bridge.dart';
import '../theme/nexus_theme.dart';
import '../widgets/nexus_card.dart';
import '../widgets/nexus_pill.dart';
import '../widgets/target_device_selector.dart';

class FileTransferScreen extends StatefulWidget {
  const FileTransferScreen({super.key});

  @override
  State<FileTransferScreen> createState() => _FileTransferScreenState();
}

class _FileTransferScreenState extends State<FileTransferScreen> {
  /// Immutable list of immutable items: every update replaces the list.
  List<TransferItem> _transfers = const [];
  StreamSubscription<Map<String, dynamic>>? _offerSub;
  StreamSubscription<Map<String, dynamic>>? _progressSub;
  StreamSubscription<Map<String, dynamic>>? _receivedSub;
  final TextEditingController _manualPathCtrl = TextEditingController();
  static const int _maxTransfers = 50;
  DateTime _lastProgressRebuild = DateTime.fromMillisecondsSinceEpoch(0);

  static String _formatBytes(int bytes) {
    const kb = 1024;
    const mb = kb * 1024;
    const gb = mb * 1024;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(1)} KB';
    return '$bytes B';
  }

  void _insertTransfer(TransferItem entry) {
    final next = <TransferItem>[entry, ..._transfers];
    _transfers = List.unmodifiable(
      next.length > _maxTransfers ? next.sublist(0, _maxTransfers) : next,
    );
  }

  /// Replaces the first item with [fileId] by a copy produced by [update].
  void _updateTransfer(String fileId, TransferItem Function(TransferItem) update) {
    final idx = _transfers.indexWhere((t) => t.fileId == fileId);
    if (idx < 0) return;
    final next = List<TransferItem>.of(_transfers);
    next[idx] = update(next[idx]);
    _transfers = List.unmodifiable(next);
  }

  void _removeTransfer(String fileId) {
    _transfers = List.unmodifiable(_transfers.where((t) => t.fileId != fileId));
  }

  TransferItem _incomingEntry(String fileId, Map<String, dynamic> json) {
    final rawSize = json['file_size'];
    return TransferItem(
      fileId: fileId,
      name: json['file_name']?.toString() ?? 'file',
      size: _formatBytes(rawSize is num ? rawSize.toInt() : 0),
      progress: 0.0,
      speed: 'Connessione P2P...',
      eta: '',
      peer: json['sender_device']?.toString() ?? 'Dispositivo Remoto',
      status: 'In ricezione...',
      icon: Icons.downloading_rounded,
      color: NexusTheme.successGreen,
    );
  }

  /// Rebuild at most every 150 ms while progress events flow.
  void _setStateThrottled(double progress, VoidCallback fn) {
    final now = DateTime.now();
    if (progress >= 1.0 || now.difference(_lastProgressRebuild) >= const Duration(milliseconds: 150)) {
      _lastProgressRebuild = now;
      setState(fn);
    } else {
      fn();
    }
  }

  void _onStreamError(String stream, Object error) {
    NexusLogger.log('FILE_TRANSFER', 'Errore stream $stream: $error');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: NexusTheme.errorRed,
        content: Text('Errore aggiornamento trasferimenti ($stream)'),
      ),
    );
  }

  @override
  void initState() {
    super.initState();

    _offerSub = LanSyncService.instance.onFileOffer.listen((json) {
      if (!mounted) return;
      final fileId = json['file_id'] as String? ?? '';
      final fileName = json['file_name'] as String? ?? 'file';
      final fileSize = (json['file_size'] as num?)?.toInt() ?? 0;
      final sender = json['sender_device'] as String? ?? 'Dispositivo Remoto';
      if (fileId.isEmpty) {
        NexusLogger.log('FILE_TRANSFER', 'Offerta file senza file_id ignorata');
        return;
      }
      final sizeLabel = _formatBytes(fileSize);

      setState(() {
        _removeTransfer(fileId);
        _insertTransfer(TransferItem(
          fileId: fileId,
          name: fileName,
          size: sizeLabel,
          progress: 0.0,
          speed: 'Connessione P2P...',
          eta: 'Ricezione blocchi 64KB...',
          peer: sender,
          status: 'In ricezione...',
          icon: Icons.downloading_rounded,
          color: NexusTheme.successGreen,
        ));
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: NexusTheme.accentIndigo,
          content: Text('📥 Ricezione file in corso: $fileName ($sizeLabel) da $sender'),
          duration: const Duration(seconds: 3),
        ),
      );
    }, onError: (Object e) => _onStreamError('offerte', e));

    _progressSub = LanSyncService.instance.onFileProgress.listen((json) {
      if (!mounted) return;
      final fileId = json['file_id'] as String? ?? '';
      if (fileId.isEmpty) {
        NexusLogger.log('FILE_TRANSFER', 'Progresso file senza file_id ignorato');
        return;
      }
      final progress = ((json['progress'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 1.0).toDouble();
      final speed = json['speed']?.toString() ?? '0 MB/s';
      final receivedChunks = (json['received_chunks'] as num?)?.toInt() ?? 0;
      final totalChunks = (json['total_chunks'] as num?)?.toInt() ?? 1;
      final isKnown = _transfers.any((t) => t.fileId == fileId);

      void apply() {
        if (!_transfers.any((t) => t.fileId == fileId)) {
          _insertTransfer(_incomingEntry(fileId, json));
        }
        _updateTransfer(
          fileId,
          (t) => t.copyWith(
            progress: progress,
            speed: speed,
            eta: '$receivedChunks / $totalChunks blocchi ($speed)',
          ),
        );
      }

      if (isKnown) {
        _setStateThrottled(progress, apply);
      } else {
        setState(apply);
      }
    }, onError: (Object e) => _onStreamError('progresso', e));

    _receivedSub = LanSyncService.instance.onFileReceived.listen((json) {
      if (!mounted) return;
      final fileId = json['file_id'] as String? ?? '';
      if (fileId.isEmpty) {
        NexusLogger.log('FILE_TRANSFER', 'Completamento file senza file_id ignorato');
        return;
      }
      final savedPath = json['saved_path'] as String? ?? '';
      final hashOk = json['hash_ok'] == true;

      setState(() {
        if (!_transfers.any((t) => t.fileId == fileId)) {
          _insertTransfer(_incomingEntry(fileId, json));
        }
        _updateTransfer(
          fileId,
          (t) => t.copyWith(
            progress: 1.0,
            status: 'Completato',
            speed: hashOk ? 'Integrità BLAKE3 verificata' : 'Ricezione completata',
            eta: 'Salvato: $savedPath',
            icon: Icons.check_circle_rounded,
            color: NexusTheme.successGreen,
          ),
        );
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: NexusTheme.successGreen,
          content: Text('✅ File ricevuto e salvato:\n$savedPath'),
          duration: const Duration(seconds: 5),
        ),
      );
    }, onError: (Object e) => _onStreamError('ricezione', e));
  }

  @override
  void dispose() {
    _offerSub?.cancel();
    _progressSub?.cancel();
    _receivedSub?.cancel();
    _manualPathCtrl.dispose();
    super.dispose();
  }

  Future<String?> _pickFileWindowsFallback() async {
    try {
      final script = '''
Add-Type -AssemblyName System.Windows.Forms
\$dlg = New-Object System.Windows.Forms.OpenFileDialog
\$dlg.Title = "Seleziona file reale da inviare con Nexus P2P"
\$dlg.Filter = "Tutti i file (*.*)|*.*"
if (\$dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    Write-Output \$dlg.FileName
}
''';
      final res = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', script]);
      final out = (res.stdout as String?)?.trim();
      if (out != null && out.isNotEmpty && File(out).existsSync()) {
        return out;
      }
    } catch (e) {
      NexusLogger.log("FILE_PICKER", "PowerShell Windows picker error: $e");
    }
    return null;
  }

  Future<void> _pickAndSendRealFile() async {
    PlatformFile? picked;
    try {
      picked = await FilePicker.pickFile();
    } catch (e) {
      NexusLogger.log('FILE_PICKER', 'File picker error: $e');
      if (Platform.isWindows) {
        final path = await _pickFileWindowsFallback();
        if (path == null) return;
        final size = await File(path).length();
        if (mounted) await _streamRealFile(path, path.split(Platform.pathSeparator).last, size);
      } else if (mounted) {
        _showManualFileSelectDialog(context, error: e.toString());
      }
      return;
    }
    if (picked == null) return;
    Directory? temporary;
    File? cached;
    try {
      var path = picked.path;
      if (path == null) {
        // SAF/content URIs need a bounded-memory local stream for the transport.
        temporary = await Directory.systemTemp.createTemp('nexus-picker-');
        cached = File('${temporary.path}/payload');
        await picked.readAsByteStream().cast<List<int>>().pipe(cached.openWrite());
        path = cached.path;
      }
      final size = await File(path).length();
      if (mounted) await _streamRealFile(path, picked.name, size);
    } catch (e) {
      if (mounted) _showManualFileSelectDialog(context, error: e.toString());
    } finally {
      if (cached != null && await cached.exists()) await cached.delete();
      if (temporary != null && await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> _streamRealFile(String filePath, String name, int sizeBytes) async {
    final sizeLabel = _formatBytes(sizeBytes);

    final targetPeer = LanSyncService.instance.selectedTargetPeer;
    final targetPeerId = LanSyncService.instance.selectedTargetDeviceId;
    final targetDevice = targetPeer?['name'] as String? ?? (LanSyncService.instance.discoveredPeers.isNotEmpty ? LanSyncService.instance.discoveredPeers.first['name'] as String : 'Dispositivo Selezionato');

    final offer = NexusFfiBridge.instance.offerFileTransfer(name, sizeBytes, targetPeerId: targetPeerId);
    final fileId = offer['file_id']?.toString() ?? 'file_${DateTime.now().millisecondsSinceEpoch}';

    final transferEntry = TransferItem(
      fileId: fileId,
      name: name,
      size: sizeLabel,
      progress: 0.0,
      speed: 'Inizializzazione blocchi 64KB...',
      eta: 'Avvio streaming P2P...',
      peer: targetDevice,
      status: 'In invio...',
      icon: Icons.upload_file_rounded,
      color: NexusTheme.accentIndigo,
    );

    setState(() {
      _insertTransfer(transferEntry);
    });

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('🚀 Streaming P2P avviato per $name verso $targetDevice')),
    );

    try {
      await LanSyncService.instance.sendRealFileStream(
        filePath,
        name,
        onProgress: (progress, speed) {
          if (!mounted) return;
          final p = progress.clamp(0.0, 1.0).toDouble();
          _setStateThrottled(p, () {
            _updateTransfer(
              fileId,
              (t) => t.copyWith(progress: p, speed: speed, eta: '${(p * 100).toInt()}% inviato'),
            );
          });
        },
      );

      if (mounted) {
        setState(() {
          _updateTransfer(
            fileId,
            (t) => t.copyWith(
              progress: 1.0,
              status: 'Completato',
              speed: 'Trasferimento riuscito',
              eta: '100% inviato',
              icon: Icons.check_circle_rounded,
              color: NexusTheme.successGreen,
            ),
          );
        });

        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: NexusTheme.successGreen,
            content: Text('✅ File $name inviato a $targetDevice'),
          ),
        );
      }
    } catch (e, st) {
      NexusLogger.log('FILE_TRANSFER', 'Invio di $name fallito: $e\n$st');
      if (mounted) {
        setState(() {
          _updateTransfer(
            fileId,
            (t) => t.copyWith(
              status: 'Fallito',
              speed: 'Errore',
              eta: 'Invio non riuscito',
              color: NexusTheme.errorRed,
            ),
          );
        });

        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: NexusTheme.errorRed,
            content: Text('Invio di $name non riuscito. Verifica la connessione con $targetDevice e riprova.'),
          ),
        );
      }
    }
  }

  void _showManualFileSelectDialog(BuildContext context, {String? error}) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NexusTheme.surfaceCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(NexusTheme.radiusModal)),
        title: const Text('Selezione File'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (error != null) ...[
              Text(
                'Nota dialog di sistema: $error',
                style: const TextStyle(color: NexusTheme.warningAmber, fontSize: 11),
              ),
              const SizedBox(height: 12),
            ],
            const Text(
              'Inserisci il percorso assoluto di un file esistente su disco:',
              style: TextStyle(fontSize: 13, color: NexusTheme.textSecondary),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _manualPathCtrl,
              decoration: InputDecoration(
                labelText: 'Percorso File',
                hintText: 'Es: C:\\Documenti\\file.pdf',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Annulla', style: TextStyle(color: NexusTheme.textSecondary)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: NexusTheme.accentIndigo,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () async {
              final path = _manualPathCtrl.text.trim();
              if (path.isNotEmpty) {
                final f = File(path);
                final fileExists = await f.exists();
                if (!ctx.mounted) return;
                if (fileExists) {
                  Navigator.pop(ctx);
                  final name = path.split(Platform.pathSeparator).last;
                  final len = await f.length();
                  if (!mounted) return;
                  await _streamRealFile(f.path, name, len);
                } else {
                  if (!ctx.mounted) return;
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(content: Text('Il percorso specificato non esiste!')),
                  );
                }
              }
            },
            child: const Text('Invia File'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('File Drop (AirDrop P2P)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.description_outlined),
            tooltip: 'Inserisci percorso o File di Test',
            onPressed: () => _showManualFileSelectDialog(context),
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline_rounded),
            tooltip: 'Scegli File da Inviare',
            onPressed: _pickAndSendRealFile,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          // Target Peer Selection
          TargetDeviceSelector(
            title: "Dispositivo Destinatario",
            onDeviceSelected: (_) {
              setState(() {});
            },
          ),
          const SizedBox(height: 12),

          // AirDrop Droptarget Hero Area
          GestureDetector(
            onTap: _pickAndSendRealFile,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
              decoration: BoxDecoration(
                color: NexusTheme.surfaceSecondary,
                borderRadius: BorderRadius.circular(NexusTheme.radiusCard),
                border: Border.all(color: NexusTheme.accentIndigo.withAlpha(90), width: 1.5),
              ),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: NexusTheme.accentIndigo.withAlpha(35),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.cloud_upload_outlined, size: 36, color: NexusTheme.accentIndigo),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Tocca per scegliere un file reale da inviare',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5, color: NexusTheme.textPrimary),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Streaming P2P 64KB/chunk • Crittografia ChaCha20-Poly1305 • Zero Cloud',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: NexusTheme.textSecondary, fontSize: 11.5),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Trasferimenti Attivi & Recenti',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: NexusTheme.textPrimary),
              ),
              NexusPill(
                label: '${_transfers.length} Elementi',
                style: NexusPillStyle.neutral,
              ),
            ],
          ),
          const SizedBox(height: 10),

          if (_transfers.isEmpty)
            Container(
              padding: const EdgeInsets.all(24),
              decoration: NexusTheme.cardDecoration(),
              child: const Center(
                child: Text(
                  'Nessun trasferimento in corso. Tocca sopra per selezionare un file.',
                  style: TextStyle(color: NexusTheme.textSecondary, fontSize: 12.5),
                ),
              ),
            )
          else
            ..._transfers.map((t) {
              final progress = t.progress;
              final isDone = progress >= 1.0;
              final fileId = t.fileId;

              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: NexusCard(
                  title: t.name,
                  subtitle: '${t.size} • verso/da ${t.peer}',
                  icon: t.icon,
                  iconColor: t.color,
                  trailing: NexusPill(
                    label: isDone ? 'Completato' : '${(progress * 100).toInt()}%',
                    style: isDone ? NexusPillStyle.success : NexusPillStyle.accent,
                    showDot: !isDone,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 5,
                          backgroundColor: NexusTheme.surfaceSecondary,
                          color: isDone ? NexusTheme.successGreen : NexusTheme.accentIndigo,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(t.speed, style: const TextStyle(fontSize: 11, color: NexusTheme.textSecondary)),
                          Expanded(
                            child: Text(
                              t.eta,
                              textAlign: TextAlign.end,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: isDone ? NexusTheme.successGreen : NexusTheme.textSecondary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (!isDone && (t.status == 'Fallito' || progress > 0.0)) ...[
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFF818CF8),
                              backgroundColor: NexusTheme.accentIndigoMuted,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              minimumSize: Size.zero,
                            ),
                            onPressed: () {
                              LanSyncService.instance.requestFileResume(fileId);
                              ScaffoldMessenger.of(context).hideCurrentSnackBar();
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('🔄 Richiesta di ripristino chunk mancanti inviata...')),
                              );
                            },
                            icon: const Icon(Icons.refresh_rounded, size: 15),
                            label: const Text(
                              'Ripristina / Recupera Chunk',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }
}
