import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/lan_sync_service.dart';
import '../services/nexus_ffi_bridge.dart';
import '../theme/nexus_theme.dart';
import 'target_device_selector.dart';

/// Modal bottom sheet for remote typing and macro shortcuts sent to the PC.
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

  String get _targetPeerId =>
      LanSyncService.instance.selectedTargetDeviceId ??
      (LanSyncService.instance.discoveredPeers.isNotEmpty
          ? LanSyncService.instance.discoveredPeers.first['id'] as String
          : "");

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
              const Icon(Icons.keyboard_rounded, color: NexusTheme.accentIndigo, size: 22),
              const SizedBox(width: 8),
              const Text(
                'Tastiera Remota & Macro PC',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 20, color: NexusTheme.textSecondary),
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
                    hintText: 'Scrivi qui il testo da inviare al PC...',
                    hintStyle: const TextStyle(color: NexusTheme.textTertiary, fontSize: 12),
                    filled: true,
                    fillColor: NexusTheme.background,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: NexusTheme.borderCard),
                    ),
                  ),
                  onSubmitted: (text) {
                    if (text.isNotEmpty) {
                      NexusFfiBridge.instance.sendTextInput(text, targetPeerId: _targetPeerId);
                      textCtrl.clear();
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).hideCurrentSnackBar();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('⌨️ Testo digitato su PC: $text'),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () {
                  final text = textCtrl.text;
                  if (text.isNotEmpty) {
                    NexusFfiBridge.instance.sendTextInput(text, targetPeerId: _targetPeerId);
                    textCtrl.clear();
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('⌨️ Testo digitato su PC: $text'),
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.send_rounded, size: 16),
                label: const Text('Invia'),
                style: FilledButton.styleFrom(
                  backgroundColor: NexusTheme.accentIndigo,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          ),
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
              _buildMacroChip(context, 'Ctrl + C', ['Control', 'C'], 'Copia'),
              _buildMacroChip(context, 'Ctrl + V', ['Control', 'V'], 'Incolla'),
              _buildMacroChip(context, 'Ctrl + Z', ['Control', 'Z'], 'Annulla'),
              _buildMacroChip(context, 'Win + D', ['Win', 'D'], 'Desktop'),
              _buildMacroChip(context, 'Alt + Tab', ['Alt', 'Tab'], 'Cambia App'),
              _buildSingleKeyChip(context, 'Invio ↵', 'Enter'),
              _buildSingleKeyChip(context, 'Backspace ⌫', 'Backspace'),
              _buildSingleKeyChip(context, 'Canc ⌦', 'Delete'),
              _buildSingleKeyChip(context, 'Spazio ␣', 'Space'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMacroChip(BuildContext context, String label, List<String> combo, String tooltip) {
    return ActionChip(
      backgroundColor: NexusTheme.accentIndigoMuted,
      side: BorderSide(color: NexusTheme.accentIndigo.withAlpha(120), width: 0.8),
      avatar: const Icon(Icons.flash_on_rounded, size: 14, color: Color(0xFF818CF8)),
      label: Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white)),
      tooltip: tooltip,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(NexusTheme.radiusPill)),
      onPressed: () {
        HapticFeedback.lightImpact();
        NexusFfiBridge.instance.sendKeyboardCombo(combo, targetPeerId: _targetPeerId);
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        final targetName = LanSyncService.instance.targetDeviceDisplayName;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('⚡ Macro eseguita: $label ($tooltip) -> $targetName'),
            duration: const Duration(milliseconds: 700),
            backgroundColor: NexusTheme.accentIndigo,
          ),
        );
      },
    );
  }

  Widget _buildSingleKeyChip(BuildContext context, String label, String key) {
    return ActionChip(
      backgroundColor: NexusTheme.surfaceSecondary,
      side: BorderSide(color: NexusTheme.borderCard, width: 0.8),
      label: Text(label, style: const TextStyle(fontSize: 11, color: NexusTheme.textPrimary)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(NexusTheme.radiusPill)),
      onPressed: () {
        HapticFeedback.lightImpact();
        NexusFfiBridge.instance.sendKeyboardKey(key, targetPeerId: _targetPeerId);
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        final targetName = LanSyncService.instance.targetDeviceDisplayName;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('⌨️ Tasto $label inviato al PC ($targetName)'),
            duration: const Duration(milliseconds: 600),
            backgroundColor: NexusTheme.accentIndigo,
          ),
        );
      },
    );
  }
}
