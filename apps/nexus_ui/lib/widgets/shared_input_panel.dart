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
            // fix D #83: attende il Future e mostra l'errore invece di scartarlo.
            onChanged: !input.supported || input.busy
                ? null
                : (v) async {
                    try {
                      await input.setEnabled(v);
                    } catch (e) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            'Impossibile cambiare lo stato: ${_errorMessage(e)}',
                          ),
                        ),
                      );
                    }
                  },
          ),
          if (input.enabled || input.trusted.isNotEmpty) ...[
            // fix D #93: istruzioni generate dalla topologia reale.
            Text(
              setupInstructions(
                localName: lan.deviceName,
                peers: {
                  for (final p in lan.discoveredPeers)
                    if (LanSyncService.isDesktopPeer(p) && p['id'] is String)
                      p['id'] as String:
                          p['name'] is String ? p['name'] as String : 'PC',
                },
                offsets: lan.customDeviceOffsets,
              ),
            ),
            ExpansionTile(
              title: const Text('Diagnostica mouse e tastiera'),
              // fix D #91: il report si calcola solo quando il tile e' espanso.
              children: [
                Builder(
                  builder: (_) => SelectableText(input.diagnosticReport),
                ),
              ],
            ),
            if (input.fingerprint != null)
              ExpansionTile(
                title: Text('Identità input di ${lan.deviceName}'),
                children: [SelectableText(input.fingerprint!)],
              ),
            // fix D #85: salta i peer senza id valido.
            for (final peer in lan.discoveredPeers.where(
              (p) => LanSyncService.isDesktopPeer(p) && p['id'] is String,
            ))
              Builder(
                builder: (context) {
                  final id = peer['id'] as String;
                  final name = peer['name'] is String
                      ? peer['name'] as String
                      : 'PC';
                  final metadata = peer['shared_input'];
                  final fingerprint =
                      metadata is Map && metadata['fingerprint'] is String
                      ? metadata['fingerprint'] as String
                      : null;
                  final savedApproval = input.trusted.containsKey(id);
                  final approved =
                      fingerprint != null && input.trusted[id] == fingerprint;
                  final positioned = lan.customDeviceOffsets.containsKey(id);
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(name),
                    // fix D #86 #90: stato estratto in _peerStatus, con avviso
                    // esplicito se l'impronta di un PC autorizzato e' cambiata.
                    subtitle: Text(
                      _peerStatus(
                        online: peer['online'] == true,
                        metadata: metadata,
                        fingerprint: fingerprint,
                        positioned: positioned,
                        approved: approved,
                        savedApproval: savedApproval,
                      ),
                    ),
                    trailing: TextButton(
                      onPressed:
                          input.busy ||
                              (!savedApproval &&
                                  (fingerprint == null || !positioned))
                          ? null
                          : () async {
                              // fix D #89: niente dialog multipli con doppio tap.
                              if (_dialogOpen) return;
                              if (savedApproval) {
                                // fix D #84: conferma e gestione errori.
                                await _confirmRevoke(context, input, id, name);
                                return;
                              }
                              if (fingerprint == null) return;
                              _dialogOpen = true;
                              final allow = await showDialog<bool>(
                                context: context,
                                builder: (dialogContext) => AlertDialog(
                                  // fix D #88: stesso fallback del titolo.
                                  title: Text('Autorizza $name'),
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
                              ).whenComplete(() => _dialogOpen = false);
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
              // fix D #87: esclude solo i peer desktop gia' mostrati sopra.
              (id) => !lan.discoveredPeers
                  .where(
                    (p) => LanSyncService.isDesktopPeer(p) && p['id'] is String,
                  )
                  .any((p) => p['id'] == id),
            ))
              ListTile(
                title: Text(
                  'PC autorizzato ${id.length > 8 ? id.substring(0, 8) : id}',
                ),
                subtitle: const Text('Non rilevato in questa sessione'),
                trailing: TextButton(
                  onPressed: input.busy
                      ? null
                      : () => _confirmRevoke(
                          context,
                          input,
                          id,
                          'PC autorizzato ${id.length > 8 ? id.substring(0, 8) : id}',
                        ),
                  child: const Text('Revoca'),
                ),
              ),
          ],
        ],
      ),
    );
  }

  // fix D #89: impedisce di aprire due dialog con un doppio tap.
  static bool _dialogOpen = false;

  // fix D #84: la revoca chiede conferma e mostra eventuali errori.
  static Future<void> _confirmRevoke(
    BuildContext context,
    SharedInputService input,
    String id,
    String name,
  ) async {
    if (_dialogOpen) return;
    _dialogOpen = true;
    bool? ok;
    try {
      ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Revoca $name'),
          content: const Text(
            'Il PC non potrà più controllare mouse e tastiera di questo dispositivo finché non lo autorizzi di nuovo.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Annulla'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Revoca'),
            ),
          ],
        ),
      );
    } finally {
      _dialogOpen = false;
    }
    if (ok != true) return;
    try {
      await input.revoke(id);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Revoca non riuscita: ${_errorMessage(e)}')),
      );
    }
  }

  // fix D #93: testi delle istruzioni raccolti qui, pronti per l10n.
  static const _stepArrangeEmpty =
      '1. Disponi i PC sul canvas come sono sulla scrivania, poi sincronizza la topologia.';
  static const _stepEnable = '2. Attiva questo switch su tutti i PC coinvolti.';
  static const _stepAuthorize =
      '3. Autorizza reciprocamente i PC confrontando le impronte.';
  static const _stepConsent =
      '4. Sui PC Linux accetta il consenso del desktop: servono cattura pronta sul PC che controlla e ricezione pronta su quello controllato.';
  static const _stepEdgeEmpty =
      '5. Porta il puntatore al bordo dello schermo rivolto verso l\'altro PC.';
  static const _release =
      'Per liberarlo, premi insieme Ctrl + Alt + Shift + Win di sinistra.';
  static const _touchpadNote =
      'Il touchpad del telefono è separato: seleziona il PC nella schermata Touchpad; su Wayland la prima azione richiede un proprio consenso RemoteDesktop. Non richiede questo switch.';

  /// fix D #93: costruisce le istruzioni dalla posizione reale dei PC
  /// ([offsets] relativi a questo PC) invece di una disposizione fissa.
  @visibleForTesting
  static String setupInstructions({
    required String localName,
    required Map<String, String> peers,
    required Map<String, Offset> offsets,
  }) {
    final placed = <MapEntry<String, Offset>>[
      for (final e in peers.entries)
        if (offsets[e.key] != null) MapEntry(e.value, offsets[e.key]!),
    ];
    final buf = StringBuffer();
    if (placed.isEmpty) {
      buf.writeln(_stepArrangeEmpty);
    } else {
      final where = placed
          .map((p) => '${p.key} ${_sideLabel(p.value)}')
          .join(', ');
      buf.writeln(
        '1. Topologia attuale rispetto a $localName: $where. Se non corrisponde alla scrivania, correggila sul canvas e sincronizza.',
      );
    }
    buf
      ..writeln(_stepEnable)
      ..writeln(_stepAuthorize)
      ..writeln(_stepConsent);
    if (placed.isEmpty) {
      buf.writeln('$_stepEdgeEmpty $_release');
    } else {
      final edges = placed
          .map((p) => 'per ${p.key} usa il bordo ${_edgeLabel(p.value)}')
          .join('; ');
      buf.writeln('5. Da $localName $edges. $_release');
    }
    buf
      ..writeln()
      ..write(_touchpadNote);
    return buf.toString();
  }

  static bool _horizontal(Offset o) => o.dx.abs() >= o.dy.abs();

  static String _sideLabel(Offset o) => _horizontal(o)
      ? (o.dx < 0 ? 'a sinistra' : 'a destra')
      : (o.dy < 0 ? 'sopra' : 'sotto');

  static String _edgeLabel(Offset o) => _horizontal(o)
      ? (o.dx < 0 ? 'sinistro' : 'destro')
      : (o.dy < 0 ? 'superiore' : 'inferiore');

  // fix D #94: messaggio leggibile senza il prefisso "Exception:".
  static String _errorMessage(Object e) {
    final text = e.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }

  static String _peerStatus({
    required bool online,
    required Object? metadata,
    required String? fingerprint,
    required bool positioned,
    required bool approved,
    required bool savedApproval,
  }) {
    if (!online) return 'Non connesso';
    if (fingerprint == null) return 'Attiva input condiviso anche su questo PC';
    if (!positioned) return 'Disponi questo PC sul canvas';
    if (approved) {
      if (metadata is Map && metadata['emulation_ready'] == false) {
        return 'Autorizzato, ma questo PC non può ancora ricevere input: completa il consenso del desktop';
      }
      if (metadata is Map && metadata['emulation_ready'] == true) {
        return 'Autorizzato • Ricezione pronta • Cattura ${metadata['capture_ready'] == true ? 'pronta' : 'non pronta'}';
      }
      return 'Autorizzato • Stato del backend remoto non disponibile: aggiorna questo PC';
    }
    if (savedApproval) {
      return 'Attenzione: l\'impronta di questo PC è cambiata. Potrebbe essere un altro dispositivo: verifica l\'impronta prima di autorizzarlo di nuovo';
    }
    return 'Autorizzazione necessaria';
  }
}
