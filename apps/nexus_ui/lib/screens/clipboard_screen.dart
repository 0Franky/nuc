import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/lan_sync_service.dart';
import '../services/nexus_ffi_bridge.dart';
import '../theme/nexus_theme.dart';
import '../widgets/nexus_card.dart';
import '../widgets/nexus_button.dart';
import '../widgets/target_device_selector.dart';

class ClipboardScreen extends StatefulWidget {
  const ClipboardScreen({super.key});

  @override
  State<ClipboardScreen> createState() => _ClipboardScreenState();
}

class _ClipboardScreenState extends State<ClipboardScreen> {
  Timer? _pollTimer;
  StreamSubscription<String>? _clipSub;
  StreamSubscription<Map<String, dynamic>>? _announceSub;
  StreamSubscription<Map<String, dynamic>>? _revealSub;
  final List<Map<String, dynamic>> _history = [];
  final TextEditingController _inputCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _fetchHistory();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => _fetchHistory());

    _clipSub = LanSyncService.instance.onClipboardSync.listen((text) {
      if (mounted) {
        final targetPeer = LanSyncService.instance.selectedTargetPeer;
        final sender = targetPeer?['name'] as String? ?? 'Dispositivo LAN';
        setState(() {
          _history.insert(0, {
            'text': text,
            'hint_type': 'Sincronizzato LAN',
            'source_device': '$sender (LAN)',
            'is_locked': false,
          });
        });
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('📋 Appunti ricevuti da $sender: $text'), duration: const Duration(seconds: 3)),
        );
      }
    });

    _announceSub = LanSyncService.instance.onSecretAnnounce.listen((json) {
      if (!mounted) return;
      final entryId = json['entry_id'] as String? ?? '';
      final secretType = json['secret_type'] as String? ?? 'Segreto';
      final maskedPreview = json['masked_preview'] as String? ?? '••••••';
      final src = json['source_device'] as String? ?? 'Dispositivo Remoto';

      setState(() {
        _history.removeWhere((h) => h['id'] == entryId);
        _history.insert(0, {
          'id': entryId,
          'text': maskedPreview,
          'hint_type': secretType,
          'source_device': src,
          'is_locked': true,
          'secret_type': secretType,
        });
      });

      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('⚠️ Questo messaggio contiene dei segreti da $src. Tocca "Rivela" per vederlo.'),
          duration: const Duration(seconds: 4),
        ),
      );
    });

    _revealSub = LanSyncService.instance.onSecretRevealed.listen((json) {
      if (!mounted) return;
      final entryId = json['entry_id'] as String? ?? '';
      final text = json['text'] as String? ?? '';
      setState(() {
        final idx = _history.indexWhere((h) => h['id'] == entryId);
        if (idx != -1) {
          _history[idx]['text'] = text;
          _history[idx]['is_locked'] = false;
          _history[idx]['hint_type'] = 'Segreto Rivelato (E2EE)';
        }
      });
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: NexusTheme.successGreen,
          content: Text('🔓 Messaggio completo rivelato e copiato negli appunti: $text'),
          duration: const Duration(seconds: 4),
        ),
      );
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _clipSub?.cancel();
    _announceSub?.cancel();
    _revealSub?.cancel();
    _inputCtrl.dispose();
    super.dispose();
  }

  void _fetchHistory() {
    final state = NexusFfiBridge.instance.getState();
    final history = (state['clipboard_history'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    if (mounted && history.isNotEmpty) {
      setState(() {
        for (final item in history) {
          final id = item['id']?.toString() ?? '';
          final existingIdx = _history.indexWhere((h) => h['id'] == id && id.isNotEmpty);
          if (existingIdx == -1) {
            _history.add(item);
          }
        }
      });
    }
  }

  void _showAddClipDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NexusTheme.surfaceCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(NexusTheme.radiusModal)),
        title: const Text('Invia Testo agli Appunti E2EE'),
        content: TextField(
          controller: _inputCtrl,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Scrivi o incolla testo da inviare a tutti i dispositivi...',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
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
            onPressed: () {
              if (_inputCtrl.text.isNotEmpty) {
                final t = _inputCtrl.text;
                NexusFfiBridge.instance.syncClipboard(t);
                Clipboard.setData(ClipboardData(text: t));
                setState(() {
                  _history.insert(0, {
                    'text': t,
                    'hint_type': 'Inviato',
                    'source_device': 'Questo Dispositivo',
                    'is_locked': false,
                  });
                });
                _inputCtrl.clear();
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).hideCurrentSnackBar();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Testo inviato via E2EE: $t')),
                );
              }
            },
            child: const Text('Invia'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final gateActive = LanSyncService.instance.clipboardPrivacyGate;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Universal Clipboard (E2EE)'),
        actions: [
          IconButton(
            icon: Icon(
              gateActive ? Icons.shield_rounded : Icons.shield_outlined,
              color: gateActive ? NexusTheme.successGreen : NexusTheme.textTertiary,
            ),
            tooltip: gateActive
                ? 'Zero-Trust Gate: ATTIVO (Segreti e OTP protetti)'
                : 'Zero-Trust Gate: DISATTIVO (Auto-condividi tutto)',
            onPressed: () {
              setState(() {
                LanSyncService.instance.clipboardPrivacyGate = !gateActive;
              });
              NexusFfiBridge.instance.setClipboardPrivacyGate(LanSyncService.instance.clipboardPrivacyGate);
              ScaffoldMessenger.of(context).hideCurrentSnackBar();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(LanSyncService.instance.clipboardPrivacyGate
                      ? '🛡️ Protezione Segreti & PII (Zero-Trust Gate) ATTIVATA'
                      : '⚠️ Protezione Segreti DISATTIVATA: i contenuti verranno condivisi senza filtro'),
                  duration: const Duration(seconds: 2),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.sync_rounded),
            tooltip: 'Sincronizza subito testo',
            onPressed: () => _showAddClipDialog(context),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TargetDeviceSelector(
              compact: true,
              title: "Invia Appunti a Dispositivo",
              onDeviceSelected: (_) {
                setState(() {});
              },
            ),
          ),
          Expanded(
            child: _history.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: NexusTheme.accentIndigo.withAlpha(25),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.content_paste_outlined, size: 48, color: NexusTheme.accentIndigo),
                          ),
                          const SizedBox(height: 16),
                          const Text('Nessun elemento negli appunti', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          const SizedBox(height: 6),
                          const Text('Copia del testo su qualsiasi dispositivo per sincronizzarlo istantaneamente via E2EE.',
                              textAlign: TextAlign.center, style: TextStyle(color: NexusTheme.textSecondary, fontSize: 12.5)),
                          const SizedBox(height: 18),
                          NexusButton(
                            label: 'Sincronizza Testo E2EE',
                            icon: Icons.add_rounded,
                            style: NexusButtonStyle.primary,
                            onPressed: () => _showAddClipDialog(context),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    itemCount: _history.length,
                    itemBuilder: (ctx, i) {
                final item = _history[i];
                final text = item['text']?.toString() ?? '';
                final hint = item['hint_type']?.toString() ?? 'Testo';
                final src = item['source_device']?.toString() ?? 'Dispositivo Locale';
                final isLocked = item['is_locked'] == true;
                final secretType = item['secret_type']?.toString() ?? 'Segreto';
                final entryId = item['id']?.toString() ?? '';

                if (isLocked) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Card(
                      margin: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(NexusTheme.radiusCard),
                        side: const BorderSide(color: NexusTheme.warningAmber, width: 1.5),
                      ),
                      color: NexusTheme.warningAmberMuted,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.warning_amber_rounded, size: 20, color: Color(0xFFFBBF24)),
                                const SizedBox(width: 8),
                                const Expanded(
                                  child: Text(
                                    'Questo messaggio contiene dei segreti',
                                    style: TextStyle(
                                      color: Color(0xFFFBBF24),
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.amber.withAlpha(40),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    secretType,
                                    style: const TextStyle(color: Color(0xFFFBBF24), fontSize: 10, fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.black.withAlpha(90),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: Colors.amber.withAlpha(50)),
                              ),
                              child: Text(
                                text,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                  color: Colors.white,
                                  letterSpacing: 0.3,
                                  height: 1.4,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'I dati sensibili sono stati censurati alla fonte. Tocca "Rivela" per recuperare il messaggio completo via E2EE.',
                              style: TextStyle(color: Colors.white70, fontSize: 11),
                            ),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFFF59E0B),
                                foregroundColor: Colors.black,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                              onPressed: () {
                                if (entryId.isNotEmpty) {
                                  LanSyncService.instance.requestSecretReveal(entryId);
                                  ScaffoldMessenger.of(context).hideCurrentSnackBar();
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Richiesta "Rivela" inviata via E2EE...')),
                                  );
                                }
                              },
                              icon: const Icon(Icons.visibility_rounded, size: 18),
                              label: const Text(
                                'Rivela',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }

                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: NexusCard(
                    title: hint,
                    subtitle: src,
                    icon: Icons.content_paste_rounded,
                    iconColor: NexusTheme.accentIndigo,
                    trailing: NexusButton(
                      label: 'Copia & Invia',
                      icon: Icons.copy_rounded,
                      style: NexusButtonStyle.ghost,
                      height: 32,
                      onPressed: () {
                        NexusFfiBridge.instance.syncClipboard(text);
                        Clipboard.setData(ClipboardData(text: text));
                        ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Appunti sincronizzati: $text')),
                        );
                      },
                    ),
                    child: Text(
                      text,
                      style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: NexusTheme.textPrimary, height: 1.35),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
