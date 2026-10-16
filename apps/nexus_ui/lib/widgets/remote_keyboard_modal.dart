import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/lan_sync_service.dart';
import '../services/nexus_ffi_bridge.dart';
import '../theme/nexus_theme.dart';
import 'target_device_selector.dart';

/// Modal bottom sheet for remote typing and macro shortcuts sent to the selected target device.
class RemoteKeyboardModal extends StatefulWidget {
  const RemoteKeyboardModal({super.key});

  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: NexusTheme.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => const RemoteKeyboardModal(),
    );
  }

  @override
  State<RemoteKeyboardModal> createState() => _RemoteKeyboardModalState();
}

class _RemoteKeyboardModalState extends State<RemoteKeyboardModal> {
  final textCtrl = TextEditingController();
  bool _sending = false;
  String? _sendError;

  Future<void> _sendText() async {
    final text = textCtrl.text;
    if (_sending || text.isEmpty) return;
    final target = _targetPeerId;
    setState(() {
      _sending = true;
      _sendError = null;
    });
    final error = await LanSyncService.instance.sendTextInputConfirmed(
      text,
      targetPeerId: target,
    );
    if (!mounted) return;
    setState(() {
      _sending = false;
      _sendError = error;
    });
    if (error != null) return;
    textCtrl.clear();
    ScaffoldMessenger.of(context).showSnackBar(
      // #82: nome del target invece di "PC" fisso.
      SnackBar(
        content: Text(
          'Digitazione confermata da '
          '${LanSyncService.instance.targetDeviceDisplayName}',
        ),
      ),
    );
  }

  String get _targetPeerId =>
      LanSyncService.instance.selectedTargetDeviceId ??
      (LanSyncService.instance.discoveredPeers.isNotEmpty
          ? (LanSyncService.instance.discoveredPeers.first['id'] as String? ?? '')
          : '');

  /// OS del target (#77): su macOS la scorciatoia primaria e' Cmd (Meta), non Ctrl,
  /// e Win + D non ha senso fuori da Windows.
  /// L'OS segue lo stesso peer di _targetPeerId: senza selezione esplicita il target
  /// ricade sul primo peer scoperto, quindi anche l'OS va letto da quel peer.
  String get _targetOs {
    final service = LanSyncService.instance;
    Object? os = service.selectedTargetPeer?['os'];
    final id = _targetPeerId;
    if (os == null && id.isNotEmpty) {
      for (final p in service.discoveredPeers) {
        if (p['id'] == id) {
          os = p['os'];
          break;
        }
      }
    }
    return (os is String ? os : '').toLowerCase();
  }
  bool get _targetIsMac =>
      _targetOs.contains('mac') || _targetOs.contains('darwin');
  bool get _targetIsWindows =>
      _targetOs.isEmpty || _targetOs.contains('win');

  @override
  void dispose() {
    textCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.keyboard_rounded,
                color: NexusTheme.accentIndigo,
                size: 22,
              ),
              const SizedBox(width: 8),
              const Text(
                'Tastiera Remota & Macro',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(
                  Icons.close_rounded,
                  size: 20,
                  color: NexusTheme.textSecondary,
                ),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 6),
          TargetDeviceSelector(
            compact: true,
            filterType: 'Desktop',
            title: "Destinazione Input",
            onDeviceSelected: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          const Text(
            'Digita o incolla testo da inviare direttamente alla finestra attiva del computer:',
            style: TextStyle(color: NexusTheme.textSecondary, fontSize: 11),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: textCtrl,
                  autofocus: true,
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText:
                        'Scrivi qui il testo da inviare a '
                        '${LanSyncService.instance.targetDeviceDisplayName}...',
                    hintStyle: const TextStyle(
                      color: NexusTheme.textTertiary,
                      fontSize: 12,
                    ),
                    filled: true,
                    fillColor: NexusTheme.background,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: NexusTheme.borderCard),
                    ),
                  ),
                  enabled: !_sending,
                  onSubmitted: (_) => _sendText(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _sending ? null : _sendText,
                icon: const Icon(Icons.send_rounded, size: 16),
                label: Text(_sending ? 'Attendi…' : 'Invia'),
                style: FilledButton.styleFrom(
                  backgroundColor: NexusTheme.accentIndigo,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ],
          ),
          if (_sendError != null) ...[
            const SizedBox(height: 8),
            Text(
              _sendError!,
              style: const TextStyle(color: NexusTheme.errorRed),
            ),
          ],
          const SizedBox(height: 16),
          const Text(
            'Macro Rapide & Scorciatoie:',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
              color: NexusTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildMacroChip(context, '$_primaryLabel + C', [_primaryKey, 'C'], 'Copia'),
              _buildMacroChip(context, '$_primaryLabel + V', [_primaryKey, 'V'], 'Incolla'),
              _buildMacroChip(context, '$_primaryLabel + Z', [_primaryKey, 'Z'], 'Annulla'),
              if (_targetIsWindows)
                _buildMacroChip(context, 'Win + D', ['Win', 'D'], 'Desktop'),
              _buildMacroChip(
                context,
                _targetIsMac ? 'Cmd + Tab' : 'Alt + Tab',
                [_targetIsMac ? 'Meta' : 'Alt', 'Tab'],
                'Cambia App',
              ),
              _buildSingleKeyChip(context, 'Invio ↵', 'Enter'),
              _buildSingleKeyChip(context, 'Backspace ⌫', 'Backspace'),
              _buildSingleKeyChip(context, 'Canc ⌦', 'Delete'),
              _buildSingleKeyChip(context, 'Spazio ␣', 'Space'),
            ],
          ),
          if (!_hasReachableTarget) ...[
            const SizedBox(height: 8),
            const Text(
              'Nessun dispositivo target raggiungibile: macro e tasti disattivati.',
              style: TextStyle(fontSize: 12, color: NexusTheme.errorRed),
            ),
          ] else if (_keyFeedback != null) ...[
            const SizedBox(height: 8),
            Text(
              _keyFeedback!,
              style: const TextStyle(
                fontSize: 12,
                color: NexusTheme.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String get _primaryKey => _targetIsMac ? 'Meta' : 'Control';
  String get _primaryLabel => _targetIsMac ? 'Cmd' : 'Ctrl';

  // Feedback inline (#76): una SnackBar dello Scaffold sottostante finirebbe sotto il modale.
  String? _keyFeedback;
  DateTime? _lastKeySendAt;
  static const Duration _keyThrottle = Duration(milliseconds: 250);

  bool get _hasReachableTarget {
    final service = LanSyncService.instance;
    final id = _targetPeerId;
    return id.isNotEmpty
        ? service.socketForDevice(id) != null
        : service.targetSocket != null;
  }

  /// Azione comune a macro e tasti singoli (#79). Null (chip disattivato) durante un invio
  /// o senza target raggiungibile (#75); throttle breve contro le raffiche (#81).
  /// sendKeyboard* restituiscono void: il feedback dice "richiesta inviata", non "eseguita" (#74).
  VoidCallback? _keyAction(String description, void Function() send) {
    if (_sending || !_hasReachableTarget) return null;
    return () {
      final now = DateTime.now();
      final last = _lastKeySendAt;
      if (last != null && now.difference(last) < _keyThrottle) return;
      _lastKeySendAt = now;
      HapticFeedback.lightImpact();
      send();
      final targetName = LanSyncService.instance.targetDeviceDisplayName;
      setState(
        () => _keyFeedback = '$description: richiesta inviata a $targetName',
      );
    };
  }

  Widget _buildMacroChip(
    BuildContext context,
    String label,
    List<String> combo,
    String tooltip,
  ) {
    return ActionChip(
      backgroundColor: NexusTheme.accentIndigoMuted,
      side: BorderSide(
        color: NexusTheme.accentIndigo.withAlpha(120),
        width: 0.8,
      ),
      avatar: const Icon(
        Icons.flash_on_rounded,
        size: 14,
        color: NexusTheme.accentIndigoLight,
      ),
      label: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: NexusTheme.textPrimary,
        ),
      ),
      tooltip: tooltip,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NexusTheme.radiusPill),
      ),
      onPressed: _keyAction(
        'Macro $label ($tooltip)',
        () => NexusFfiBridge.instance.sendKeyboardCombo(
          combo,
          targetPeerId: _targetPeerId,
        ),
      ),
    );
  }

  Widget _buildSingleKeyChip(BuildContext context, String label, String key) {
    return ActionChip(
      backgroundColor: NexusTheme.surfaceSecondary,
      side: BorderSide(color: NexusTheme.borderCard, width: 0.8),
      label: Text(
        label,
        style: const TextStyle(fontSize: 11, color: NexusTheme.textPrimary),
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NexusTheme.radiusPill),
      ),
      onPressed: _keyAction(
        'Tasto $label',
        () => NexusFfiBridge.instance.sendKeyboardKey(
          key,
          targetPeerId: _targetPeerId,
        ),
      ),
    );
  }
}
