import 'dart:io';

import 'package:flutter/material.dart';

import '../services/lan_sync_service.dart';

class ProximityLockSwitch extends StatelessWidget {
  const ProximityLockSwitch({super.key});
  @override
  Widget build(BuildContext context) {
    final lan = LanSyncService.instance;
    final desktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    return ListenableBuilder(
      listenable: lan,
      builder: (context, _) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Blocca questo computer per allontanamento'),
        subtitle: Text(
          lan.proximityLockError ?? (desktop
              ? 'Solo se attivo: dispositivo scelto e calibrato, oltre soglia per 10 secondi. Non blocca gli altri computer.'
              : 'Attiva questa opzione nelle impostazioni di ciascun computer che vuoi bloccare.'),
        ),
        value: lan.autoLockOnWalkAway,
        onChanged: desktop ? lan.setAutoLockOnWalkAway : null,
      ),
    );
  }
}
