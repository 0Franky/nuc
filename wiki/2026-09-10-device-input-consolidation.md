# Consolidamento dispositivi e input — 10 settembre 2026

## Correzioni

- Identità basata su UUID persistente: daemon e motore FFI condividono `identity.bin`; UI locale adotta la stessa identità. Le chiavi non vengono rigenerate se il file esistente è illeggibile o corrotto.
- Nome configurato persistente e metadati autorevoli prioritari rispetto al discovery. La dashboard usa lo stesso elenco LAN del selettore.
- Un IP non identifica un dispositivo: peer distinti annunciati dallo stesso router non si sovrascrivono. La sostituzione dell'ID provvisorio conserva la selezione.
- Snapshot iniziale dei peer, rinomina, riconnessioni e disconnessioni gestiti per UUID e percorso. Target mancante non sostituito silenziosamente da un altro PC.
- Touchpad e selettore condividono il target desktop effettivo. Input, tastiera e comandi media richiedono una connessione diretta al backend del PC; un peer visibile solo tramite relay non viene presentato come input riuscito.
- Inoltro dei messaggi con `target_device_id` al destinatario esplicito. I client che non supportano un comando ricevuto restituiscono un errore. La consegna via relay non implica supporto universale di tutti i comandi.
- Backend Linux X11 tramite xdotool e Wayland tramite ydotool >= 1.0/ydotoold; niente fallback XWayland che può dichiarare successo senza controllare il desktop. Movimento, click, tasti e scroll controllano l'esito del processo. Scroll zero non genera un click.
- Esito dell'input restituito al telefono e visualizzato nel touchpad. Piattaforme senza implementazione nativa restituiscono un errore anziché `Ok(())` fittizio.
- Ricerca della libreria nativa adatta alla piattaforma, inclusa la cartella `lib` del bundle Linux. Build Linux con percorsi assoluti derivati dal repository e libreria Rust inclusa obbligatoriamente.
- Rimossa la classe WASAPI inutilizzata che generava una sinusoide a 440 Hz. La cattura audio operativa nell'attore resta quella reale già esistente.
- Rimossi IP privati fissi dal tentativo iniziale di discovery e duplicazioni di comandi volume/media sul PC locale quando è selezionato un dispositivo remoto.

## Verifiche eseguite

- Suite Rust workspace: 66 test superati; 1 prova che inietta input sul desktop Windows è esplicitamente manuale.
- Flutter: 19 test selezionati UI/gesture/naming/rete superati; regressioni nuove prima rosse e poi verdi.
- Flutter analyzer: nessun problema rilevato.
- Compilazione release Windows, daemon/DLL e APK Android verificata. Il controllo di compilazione dell’intero workspace Linux è passato; restano avvisi nel plugin notifiche non modificato.
- Linux: test nativi di input/identità e test sul movimento reale del cursore in Xvfb.
- Linux WebSocket end-to-end: connessione di più client, snapshot, rinomina, consegna mirata, movimento effettivo del cursore, errore backend e disconnessione verificati.
- Non è stata verificata una sessione Wayland fisica né l'installazione sui dispositivi dell'utente. La suite Flutter completa include prove che dipendono da hardware/servizi locali; i test selezionati non equivalgono a tutta la suite.

## Uso su Linux

Eseguire il backend come utente della sessione grafica. Su X11 servono xdotool e accesso a DISPLAY; su Wayland servono ydotool >= 1.0, ydotoold attivo e accesso autorizzato al suo socket e a uinput. Il solo DISPLAY di XWayland non basta.

```sh
bash scripts/check_linux_input.sh
bash scripts/build_linux.sh
```

Per ripetere le prove isolate X11:

```sh
XDG_SESSION_TYPE=x11 WAYLAND_DISPLAY= xvfb-run -a -s '-screen 0 1024x768x24 -noreset' cargo test -p nexus-plugin-input --test linux_pointer -- --ignored
XDG_SESSION_TYPE=x11 WAYLAND_DISPLAY= xvfb-run -a -s '-screen 0 1024x768x24 -noreset' cargo test -p nexus-plugin-media --test lan_consolidation -- --ignored
```

La porta 28471 deve essere libera nell'ambiente del secondo test. I test non vanno eseguiti sulla sessione grafica di lavoro.

Aggiornare sia il client telefono sia il backend/app dei PC: i processi già avviati continuano a usare il codice precedente finché non vengono riavviati. Non è stato eseguito un deploy sui dispositivi reali; le modifiche già presenti nel repository sono state mantenute.

## Pacchetti

Lo ZIP Windows contiene app Flutter, plugin, DLL Rust e daemon compilati in release. L’app va avviata tramite `nexus_ui.exe`, dopo aver chiuso la vecchia istanza. L’APK aggiorna il client Android. Per Linux è necessario ricompilare il backend/app dal repository con lo script indicato: non è stato prodotto un pacchetto GUI Linux.
