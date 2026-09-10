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
              '1. Disponi Linux a sinistra e Windows a destra, poi sincronizza la topologia.\n'
              '2. Attiva questo switch su entrambi i PC.\n'
              '3. Autorizza reciprocamente i PC confrontando le impronte.\n'
              '4. Su Linux accetta il consenso del desktop: per Windows → Linux servono cattura pronta su Windows e ricezione pronta su Linux.\n'
              '5. Porta il puntatore al bordo sinistro di Windows. Per liberarlo, premi insieme Ctrl + Alt + Shift + Win di sinistra.\n\n'
              'Il touchpad del telefono è separato: seleziona il PC nella schermata Touchpad; su Wayland la prima azione richiede un proprio consenso RemoteDesktop. Non richiede questo switch.',
            ),
            ExpansionTile(
              title: const Text('Diagnostica mouse e tastiera'),
              children: [SelectableText(input.diagnosticReport)],
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
                          : approved &&
                                metadata is Map &&
                                metadata['emulation_ready'] == false
                          ? 'Autorizzato, ma questo PC non può ancora ricevere input: completa il consenso del desktop'
                          : approved &&
                                metadata is Map &&
                                metadata['emulation_ready'] == true
                          ? 'Autorizzato • Ricezione pronta • Cattura ${metadata['capture_ready'] == true ? 'pronta' : 'non pronta'}'
                          : approved
                          ? 'Autorizzato • Stato del backend remoto non disponibile: aggiorna questo PC'
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
