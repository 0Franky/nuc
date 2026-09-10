import 'package:flutter/material.dart';
import '../services/lan_sync_service.dart';
import '../services/shared_input_service.dart';

class SharedInputPanel extends StatelessWidget {
  const SharedInputPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final input = SharedInputService.instance;
    final lan = LanSyncService.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([input, lan]),
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Mouse e tastiera condivisi'),
            subtitle: Text(
              input.supported
                  ? input.status
                  : 'Disponibile sui PC Windows e Linux',
            ),
            value: input.enabled,
            onChanged: !input.supported || input.busy ? null : input.setEnabled,
          ),
          if (input.enabled || input.trusted.isNotEmpty) ...[
            const Text(
              'Disponi i PC sul canvas e attiva la condivisione su entrambi. Autorizza ogni PC per abilitare il passaggio al suo bordo.',
            ),
            if (input.fingerprint != null)
              ExpansionTile(
                title: Text('Identità input di ${lan.deviceName}'),
                children: [SelectableText(input.fingerprint!)],
              ),
            for (final peer in lan.discoveredPeers.where(
              LanSyncService.isDesktopPeer,
            ))
              Builder(
                builder: (context) {
                  final id = peer['id'] as String;
                  final metadata = peer['shared_input'];
                  final fingerprint = metadata is Map
                      ? metadata['fingerprint'] as String?
                      : null;
                  final savedApproval = input.trusted.containsKey(id);
                  final approved =
                      fingerprint != null && input.trusted[id] == fingerprint;
                  final positioned = lan.customDeviceOffsets.containsKey(id);
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(peer['name'] as String? ?? 'PC'),
                    subtitle: Text(
                      peer['online'] != true
                          ? 'Non connesso'
                          : fingerprint == null
                          ? 'Attiva input condiviso anche su questo PC'
                          : !positioned
                          ? 'Disponi questo PC sul canvas'
                          : approved
                          ? 'Autorizzato per input condiviso'
                          : 'Autorizzazione necessaria',
                    ),
                    trailing: TextButton(
                      onPressed:
                          input.busy ||
                              (!savedApproval &&
                                  (fingerprint == null || !positioned))
                          ? null
                          : () async {
                              if (savedApproval) {
                                await input.revoke(id);
                                return;
                              }
                              if (fingerprint == null) return;
                              final allow = await showDialog<bool>(
                                context: context,
                                builder: (dialogContext) => AlertDialog(
                                  title: Text('Autorizza ${peer['name']}'),
                                  content: SingleChildScrollView(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Text(
                                          'Confronta questa impronta con “Identità input” sul PC indicato. Autorizzandolo potrà controllare mouse e tastiera di questo dispositivo.',
                                        ),
                                        const SizedBox(height: 12),
                                        SelectableText(fingerprint),
                                      ],
                                    ),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(dialogContext, false),
                                      child: const Text('Annulla'),
                                    ),
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(dialogContext, true),
                                      child: const Text(
                                        'Corrisponde, autorizza',
                                      ),
                                    ),
                                  ],
                                ),
                              );
                              if (allow == true) {
                                try {
                                  await input.authorize(id, fingerprint);
                                } catch (e) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('$e')),
                                    );
                                  }
                                }
                              }
                            },
                      child: Text(savedApproval ? 'Revoca' : 'Autorizza'),
                    ),
                  );
                },
              ),
            for (final id in input.trusted.keys.where(
              (id) => !lan.discoveredPeers.any((p) => p['id'] == id),
            ))
              ListTile(
                title: Text(
                  'PC autorizzato ${id.length > 8 ? id.substring(0, 8) : id}',
                ),
                subtitle: const Text('Non rilevato in questa sessione'),
                trailing: TextButton(
                  onPressed: input.busy ? null : () => input.revoke(id),
                  child: const Text('Revoca'),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
