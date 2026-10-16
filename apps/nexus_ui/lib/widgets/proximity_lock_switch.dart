import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/lan_sync_service.dart';
import '../theme/nexus_theme.dart';

/// Guardia sicura anche su Flutter Web (dart:io Platform lancerebbe UnsupportedError).
bool get _isDesktopPlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// Testi di [ProximityLockSwitch] raccolti in un unico punto (#73).
/// Il progetto non ha ancora un sistema l10n (ARB/flutter_localizations):
/// per tradurre il widget basta passare un'istanza diversa a [ProximityLockSwitch.strings].
class ProximityLockStrings {
  const ProximityLockStrings({
    this.title = 'Blocca questo computer per allontanamento',
    this.notDesktop =
        'Attiva questa opzione nelle impostazioni di ciascun computer che vuoi bloccare.',
    this.ready =
        'Solo se attivo: dispositivo scelto e calibrato, oltre soglia per 10 secondi. Non blocca gli altri computer.',
    this.notReady = 'Prima scegli un dispositivo connesso e calibralo a 1 metro.',
    this.saveError = 'Impossibile salvare l\'impostazione',
  });

  final String title;
  final String notDesktop;
  final String ready;
  final String notReady;
  final String saveError;
}

class ProximityLockSwitch extends StatelessWidget {
  const ProximityLockSwitch({
    super.key,
    this.service,
    this.strings = const ProximityLockStrings(),
  });

  /// Testi visualizzati; sostituibili per la localizzazione.
  final ProximityLockStrings strings;

  /// Servizio da usare; se null si usa [LanSyncService.instance].
  /// Permette di iniettare un servizio finto nei test.
  final LanSyncService? service;

  Future<void> _toggle(
    BuildContext context,
    LanSyncService lan,
    bool enabled,
  ) async {
    try {
      await lan.setAutoLockOnWalkAway(enabled);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('${strings.saveError}: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final lan = service ?? LanSyncService.instance;
    final desktop = _isDesktopPlatform;
    return ListenableBuilder(
      listenable: lan,
      builder: (context, _) {
        final ready =
            lan.hasProximityPeer && lan.proximity.referenceRssi != null;
        // Si puo' sempre disattivare; si attiva solo con peer connesso e calibrato.
        final canToggle = desktop && (ready || lan.autoLockOnWalkAway);
        final explanation = !desktop
            ? strings.notDesktop
            : ready
            ? strings.ready
            : strings.notReady;
        final error = lan.proximityLockError;
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(strings.title),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(explanation),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    error,
                    style: const TextStyle(color: NexusTheme.errorRed),
                  ),
                ),
            ],
          ),
          value: lan.autoLockOnWalkAway,
          onChanged: canToggle ? (v) => _toggle(context, lan, v) : null,
        );
      },
    );
  }
}
