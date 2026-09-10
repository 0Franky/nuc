# Topologia, dipendenze e pacchetto Linux — stato operativo

> Aggiornamento successivo: [prossimità e input Wayland](2026-09-10-proximity-input-review.md).

## Stato verificato prima del push

- Canvas comune con tutti i nodi trascinabili, locale incluso. Test mouse/touch a
  spostamento breve e burst di eventi, conservazione coordinate e sincronizzazione.
- Tutte le dipendenze Flutter dirette aggiornate alle ultime risolvibili; migrazione
  Android completata e APK release compilato con AGP 9.1.1 / Gradle 9.3.1 / API 37.
- **62 test Flutter Linux passati, zero saltati**, su rete e desktop isolati.
- Build Windows e APK release riuscite; Windows aggiornato e riavviato da dist.
- Bundle Linux completo compilato. `nexus-run` avvia una finestra reale, carica la
  FFI confermata dai log e sostituisce il vecchio daemon di questo stesso checkout.
- Backend Linux: IPC, emulazione X11 e arresto EOF/crash verificati. Cattura X11
  non disponibile; non è una prova fisica Windows ↔ laptop Linux o una misura di latenza.
- Artefatti in `dist/windows`, `dist/android`, `dist/linux`, `dist/nexus-linux-x64.tar.gz`.
- Revisione indipendente conclusa: corretti orientamento dopo drag e controllo positivo
  della FFI nello smoke test. Nessun ulteriore rilievo concreto.
- Installazione Android finale non eseguita: dispositivo scomparso da ADB, riconnessione scaduta e discovery mDNS vuota. APK verificato in dist/android; ripetere install -r quando il telefono torna collegato.

Le sezioni successive conservano cause e passaggi intermedi per ricostruire il lavoro.

## Compatibilità compilazione tray Linux — 10 settembre 2026

- Valutata la proposta di modificare `linux/flutter/ephemeral/.plugin_symlinks/tray_manager/linux/CMakeLists.txt`:
  quel percorso punta alla cache Pub e non costituisce una correzione versionata.
- Il progetto applica `-Wall -Werror` anche al plugin. Nel CMake Linux del repository,
  dopo l'inclusione dei plugin generati, ora solo `tray_manager_plugin` riceve
  `-Wno-error=deprecated-declarations`: gli avvisi restano visibili, gli altri errori
  restano bloccanti. Non viene modificata la cache né disabilitato globalmente `-Werror`.
- Verifica: build Linux release riuscita in Ubuntu 22.04 con tray_manager 0.5.3;
  comando reale Ninja/Clang controllato, contiene l'opzione sul target del tray.
- Limite: il testo ricevuto era “Test Clipboard 123”, senza diagnostico C++.
  Il problema originale sul Linux dell'utente resta da confermare con le righe
  `error:`; questa modifica copre gli avvisi di deprecazione promossi a errore,
  non librerie mancanti, simboli rimossi o problemi di avvio del daemon.

## Richieste e cause verificate

- Tutti i quadrati devono essere spostabili, incluso il dispositivo locale. Il vecchio
  canvas fissava il locale al centro e proiettava gli altri rispetto a esso: viste diverse
  tra telefono e PC. Ora il canvas usa le coordinate globali e un solo widget per tutti.
- Drag breve e diretto: il vecchio codice usava delta catturati nel build, moltiplicatore
  1.4 e adattamento della scala. Ora usa posizione assoluta del puntatore, cattura immediata
  sul nodo e viewport stabile. Test di 3–5 pixel, touch, mouse e pacchetti multipli passati.
- Lo script personale `nexus-run` compilava solo daemon e FFI, avviava il daemon con nohup
  e poi flutter run. Non costruiva LAN Mouse né nexus-input-host. È la causa del messaggio
  “Backend input assente nel pacchetto” riportato dall’utente.
- Rust resta il linguaggio di entrambi gli eseguibili. Python è solo il builder che
  applica la patch revisionata e distribuisce binari, licenza e sorgente GPL.

## Interventi correnti

- `scripts/nexus-run`: versione portabile del launcher, root dal percorso dello script o
  NEXUS_DIR, aggiornamento fast-forward, build completa, avvio del bundle. Nessun pkill
  generico, nessuna cancellazione della cache, nessun demone duplicato in background.
  `--no-update` usa sorgenti locali; `--no-build` avvia il pacchetto già pronto.
- `scripts/build_linux.sh`: costruisce prima tutti i componenti Rust, poi Flutter.
  Controlla i prerequisiti nativi. CMake include input-engine anche nel bundle di sviluppo.
- Tutte le dipendenze Flutter dirette aggiornate alle ultime risolvibili. Flutter 3.47.2 /
  Dart 3.13.2 come riferimento esplicito. Tre transitive restano ai vincoli SDK/upstream;
  non sono stati applicati dependency_overrides forzati.
- File picker migrato all’API 12, con stream su file temporaneo per URI non locali.
- Icone tray dichiarate negli asset. Se il tray fallisce, chiudere la finestra termina
  l’app invece di lasciarla nascosta e irraggiungibile.
- Ricerca FFI in sviluppo: target/release precede dist obsoleti. Lo snapshot FFI usa
  l’ID inizializzato, non un UUID provvisorio differente del client LAN.

## Cronologia delle verifiche intermedie

- Test originale del nodo locale: fallito prima della modifica; passato dopo.
- 17 test mirati canvas/topologia/input/rete passati; analisi statica passata prima degli
  ultimi aggiornamenti a tray/script (da ripetere a fine lavoro).
- Prima suite completa: 57 passati, 1 saltato esplicitamente, 4 falliti. Cause: pulsante
  fuori viewport nel test, vecchia aspettativa banner, ID FFI incoerente, vecchio test
  Universal Control che confondeva inoltro con input reale. Correzioni dei quattro casi
  verificate con 6 test passati. Suite completa finale ancora da rieseguire.
- Rust FFI e primo bundle Flutter Linux compilati in Ubuntu 22.04 WSL con SDK Linux
  separato. Questa prima build non conteneva ancora input-engine: non è una consegna.
- Backend Linux completo in compilazione; avvio GUI e IPC da verificare prima della consegna.
- Windows e Android da ricompilare/installare sulle modifiche finali.
- Prova fisica Windows ↔ laptop Linux e latenza non ancora verificate. X11 non offre
  cattura fisica con questo backend; il supporto Wayland dipende dal compositor/portali.

## Ripresa del lavoro

Comandi di verifica: `flutter analyze`, `flutter pub outdated`, `flutter test`,
`bash scripts/build_linux.sh`, `bash scripts/nexus-run --no-update --no-build`.
Non scambiare build riuscita con avvio riuscito o con controllo fisico riuscito.
I test nativi devono usare una sessione grafica isolata, come documentato in
[consolidamento input](2026-09-10-device-input-consolidation.md).


## Risultati verificati della sessione

- Suite completa Linux in namespace di rete privato + Xvfb + D-Bus dedicato:
  **62 passati, 0 falliti, 0 saltati**. Comando Flutter `test --no-pub --concurrency=1`;
  `NEXUS_INPUT_TEST_ENGINE` sul motore compilato e `NEXUS_INPUT_TEST_EXPECT_CAPTURE=disabled`
  per X11. Non invia eventi alla sessione grafica o alla rete dell’utente.
- Lifecycle nativo Linux: IPC e impronta validi, emulazione Enabled, cattura Disabled
  (limite X11). Chiusura su EOF e morte del supervisore entrambe verificate.
- Pacchetto Linux completo: controllo ldd senza librerie mancanti, finestra Flutter
  visibile tramite xdotool, caricamento reale FFI e nessuna eccezione non gestita.
- Il test nativo Flutter ha scoperto che WARN di backend alternativi erano presentati
  come errore definitivo. Ora restano nei log; stato e fallimenti effettivi arrivano
  dall’IPC o dall’uscita del processo. X11 mostra esplicitamente cattura non disponibile.
- Il test Bluetooth ora attende la lettura asincrona e verifica che l’assenza hardware
  non cancelli la preferenza dell’utente.
- Nuovi controlli ripetibili: `scripts/check_linux_bundle.sh` e test IPC esteso a Linux.
  Esempio: `xvfb-run -a dbus-run-session -- bash scripts/check_linux_bundle.sh`.
  Per isolamento dalla LAN eseguire inoltre dentro un namespace di rete privato.

### Migrazione Android

permission_handler_android 14.1.0 richiede compileSdk 37 e minSdk 24. La vecchia
AGP 8.11.1 non riconosceva il nuovo formato SDK 37.0. Toolchain aggiornata a Gradle
9.3.1, AGP 9.1.1 e Kotlin integrato (Flutter 3.47); vecchia DSL mantenuta per i plugin.
Fonti: [compatibilità AGP/API](https://developer.android.com/build/releases/about-agp),
[migrazione Kotlin Flutter](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-app-developers).
Build APK release riuscita. L’ultimo tentativo ADB non ha trovato il dispositivo; vedere lo stato finale.


Il launcher arresta con SIGTERM soltanto processi dell’utente il cui eseguibile
appartiene a questo checkout (vecchio daemon dello script e precedente GUI). Non usa
pkill generico e non termina altre installazioni. Se un servizio systemd separato è
attivo, lo segnala e si ferma prima della build per evitare due core concorrenti.


Verifica finale launcher: test con vecchio daemon avviato dallo stesso checkout,
SIGTERM mirato, nuovo avvio GUI, caricamento FFI positivo e lifecycle input: passato.
Windows e APK confrontati via hash con i rispettivi output finali di compilazione.
