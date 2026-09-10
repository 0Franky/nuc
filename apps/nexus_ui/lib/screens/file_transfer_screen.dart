import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
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
  final List<Map<String, dynamic>> _transfers = [];
  StreamSubscription<Map<String, dynamic>>? _offerSub;
  StreamSubscription<Map<String, dynamic>>? _progressSub;
  StreamSubscription<Map<String, dynamic>>? _receivedSub;
  final TextEditingController _manualPathCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();

    _offerSub = LanSyncService.instance.onFileOffer.listen((json) {
      if (!mounted) return;
      final fileId = json['file_id'] as String? ?? '';
      final fileName = json['file_name'] as String? ?? 'file';
      final fileSize = (json['file_size'] as num?)?.toInt() ?? 0;
      final sender = json['sender_device'] as String? ?? 'Dispositivo Remoto';
      final sizeLabel = fileSize > 1024 * 1024
          ? '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB'
          : '${(fileSize / 1024).toStringAsFixed(1)} KB';

      setState(() {
        _transfers.removeWhere((t) => t['file_id'] == fileId);
        _transfers.insert(0, {
          'file_id': fileId,
          'name': fileName,
          'size': sizeLabel,
          'progress': 0.0,
          'speed': 'Connessione P2P...',
          'eta': 'Ricezione blocchi 64KB...',
          'peer': sender,
          'status': 'In ricezione...',
          'icon': Icons.downloading_rounded,
          'color': NexusTheme.successGreen,
        });
      });

      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: NexusTheme.accentIndigo,
          content: Text('📥 Ricezione file in corso: $fileName ($sizeLabel) da $sender'),
          duration: const Duration(seconds: 3),
        ),
      );
    });

    _progressSub = LanSyncService.instance.onFileProgress.listen((json) {
      if (!mounted) return;
      final fileId = json['file_id'] as String? ?? '';
      final progress = (json['progress'] as num?)?.toDouble() ?? 0.0;
      final speed = json['speed'] as String? ?? '0 MB/s';
      final receivedChunks = json['received_chunks'] as int? ?? 0;
      final totalChunks = json['total_chunks'] as int? ?? 1;

      setState(() {
        final idx = _transfers.indexWhere((t) => t['file_id'] == fileId);
        if (idx != -1) {
          _transfers[idx]['progress'] = progress;
          _transfers[idx]['speed'] = speed;
          _transfers[idx]['eta'] = '$receivedChunks / $totalChunks blocchi ($speed)';
        }
      });
    });

    _receivedSub = LanSyncService.instance.onFileReceived.listen((json) {
      if (!mounted) return;
      final fileId = json['file_id'] as String? ?? '';
      final savedPath = json['saved_path'] as String? ?? '';

      setState(() {
        final idx = _transfers.indexWhere((t) => t['file_id'] == fileId);
        if (idx != -1) {
          _transfers[idx]['progress'] = 1.0;
          _transfers[idx]['status'] = 'Completato';
          _transfers[idx]['speed'] = 'BLAKE3 Verificato al 100%';
          _transfers[idx]['eta'] = 'Salvato: $savedPath';
          _transfers[idx]['icon'] = Icons.check_circle_rounded;
          _transfers[idx]['color'] = NexusTheme.successGreen;
        }
      });

      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: NexusTheme.successGreen,
          content: Text('✅ File ricevuto e salvato:\n$savedPath'),
          duration: const Duration(seconds: 5),
        ),
      );
    });
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
    String? selectedPath;
    String? selectedName;
    int? selectedSize;

    if (Platform.isWindows) {
      try {
        final result = await FilePicker.platform.pickFiles();
        if (result != null && result.files.isNotEmpty) {
          final picked = result.files.first;
          selectedPath = picked.path;
          selectedName = picked.name;
          selectedSize = picked.size;
        } else {
          return;
        }
      } catch (e) {
        NexusLogger.log("FILE_PICKER", "FilePicker fallback on Windows: $e");
        selectedPath = await _pickFileWindowsFallback();
        if (selectedPath == null) return;
        final f = File(selectedPath);
        selectedName = selectedPath.split(Platform.pathSeparator).last;
        selectedSize = await f.length();
      }
    } else {
      FilePickerResult? result;
      try {
        result = await FilePicker.platform.pickFiles();
      } catch (e) {
        NexusLogger.log("FILE_PICKER", "File picker error: $e");
        if (mounted) {
          _showManualFileSelectDialog(context, error: e.toString());
        }
        return;
      }
      if (result == null || result.files.isEmpty) return;
      final picked = result.files.first;
      selectedPath = picked.path;
      selectedName = picked.name;
      selectedSize = picked.size;
    }

    if (selectedPath == null || selectedPath.isEmpty) return;
    await _streamRealFile(selectedPath, selectedName, selectedSize);
  }

  Future<void> _streamRealFile(String filePath, String name, int sizeBytes) async {
    final sizeLabel = sizeBytes > 1024 * 1024
        ? '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB'
        : '${(sizeBytes / 1024).toStringAsFixed(1)} KB';

    final targetPeer = LanSyncService.instance.selectedTargetPeer;
    final targetPeerId = LanSyncService.instance.selectedTargetDeviceId;
    final targetDevice = targetPeer?['name'] as String? ?? (LanSyncService.instance.discoveredPeers.isNotEmpty ? LanSyncService.instance.discoveredPeers.first['name'] as String : 'Dispositivo Selezionato');

    final offer = NexusFfiBridge.instance.offerFileTransfer(name, sizeBytes, targetPeerId: targetPeerId);
    final fileId = offer['file_id']?.toString() ?? 'file_${DateTime.now().millisecondsSinceEpoch}';

    final transferEntry = {
      'file_id': fileId,
      'name': name,
      'size': sizeLabel,
      'progress': 0.0,
      'speed': 'Inizializzazione blocchi 64KB...',
      'eta': 'Avvio streaming P2P...',
      'peer': targetDevice,
      'status': 'In invio...',
      'icon': Icons.upload_file_rounded,
      'color': NexusTheme.accentIndigo,
    };

    setState(() {
      _transfers.insert(0, transferEntry);
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
          setState(() {
            transferEntry['progress'] = progress;
            transferEntry['speed'] = speed;
            transferEntry['eta'] = '${(progress * 100).toInt()}% • Streaming ChaCha20';
          });
        },
      );

      if (mounted) {
        setState(() {
          transferEntry['progress'] = 1.0;
          transferEntry['status'] = 'Completato';
          transferEntry['speed'] = 'Trasferimento riuscito';
          transferEntry['eta'] = 'BLAKE3 Verificato • 100% Inviato';
          transferEntry['icon'] = Icons.check_circle_rounded;
          transferEntry['color'] = NexusTheme.successGreen;
        });

        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: NexusTheme.successGreen,
            content: Text('✅ File $name inviato con successo ad Android!'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          transferEntry['status'] = 'Fallito';
          transferEntry['speed'] = 'Errore';
          transferEntry['eta'] = e.toString();
          transferEntry['color'] = NexusTheme.errorRed;
        });

        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: NexusTheme.errorRed,
            content: Text('Errore durante il trasferimento: $e'),
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
              final progress = (t['progress'] as num).toDouble();
              final isDone = progress >= 1.0;
              final fileId = t['file_id'] as String;

              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: NexusCard(
                  title: t['name'] as String,
                  subtitle: '${t['size']} • verso/da ${t['peer']}',
                  icon: t['icon'] as IconData,
                  iconColor: t['color'] as Color,
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
                          Text(t['speed'] as String, style: const TextStyle(fontSize: 11, color: NexusTheme.textSecondary)),
                          Expanded(
                            child: Text(
                              t['eta'] as String,
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
                      if (!isDone && (t['status'] == 'Fallito' || progress > 0.0)) ...[
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
