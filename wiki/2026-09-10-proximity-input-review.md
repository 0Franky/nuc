# Revisione prossimità, identità BLE e input Wayland

## Stato del lavoro

Correzioni sottoposte a due giri di revisione e verifica integrata:
- 85 test Flutter Linux passati, zero saltati, su desktop/rete isolati.
- Analisi Flutter senza rilievi; test Rust/Kotlin e regressioni mirate passati.
- Build release Windows, APK e bundle Linux complete. Bundle Windows installato
  e riavviato; confronto hash di tutti i file della build e della FFI passato.
- Avvio a freddo del bundle Linux: finestra visibile, FFI caricata, companion input
  IPC/lifecycle verificati in Xvfb. Log di validazione `nexus-review-bundle-smoke.log`.
- Artefatti in `dist/windows`, `dist/android`, `dist/linux` e archivio Linux.
- Android non installato: `adb devices -l` non rileva dispositivi collegati.

Non dichiarare verificato il movimento fisico su Wayland né l'attraversamento
Windows→Linux senza test sul compositor reale. La diagnostica ora consente di
separare autorizzazione, disponibilità dei backend e collegamento input.

## Segnalazioni e cause nel codice

- RSSI di dispositivi estranei accettati ignorando `is_nexus`; indirizzi radio
  trasformati in peer online “Peer BLE”. Un filtro globale mescolava dispositivi
  differenti. Regressione originale: 100 annunci estranei producono 100 peer.
- Formula precedente: `10^((-59-RSSI)/22)`. Con -71.24 dBm restituisce circa 3,6 m,
  anche se il valore -59 non era calibrato per i due dispositivi. Non misura una
  distanza geometrica certa. Rimossa anche la falsa promessa UI ±0.15m.
- Dart auto-lock ON di default, comando emesso ogni 12 s oltre soglia; aggiornamenti
  remoti non identificavano la coppia misurata e riattivavano decisioni su altri PC.
- Rust conteneva un secondo blocco automatico legato alla zona Far fissa a 3,5 m;
  il receiver accettava LOCK_WORKSTATION senza consenso locale. Sono bypass
  confermati nel codice, non una traccia che identifichi quale ha agito sul laptop.
- Il rilevamento radio Rust su Linux restituiva sempre false e non esisteva uno
  scanner desktop capace di osservare gli annunci Nexus del telefono.
- Touchpad mobile→Wayland dipendeva da ydotool/ydotoold non predisposti; è un
  percorso diverso da LAN Mouse usato dal passaggio fra bordi dei PC.

## Policy attuale

- Un solo decisore locale Dart: opt-in nuovo OFF anche migrando il vecchio default,
  peer LAN online scelto esplicitamente, UUID nell'annuncio BLE, calibrazione a 1 m.
- Android pubblica service data 0x2847: byte versione 1 + 16 byte UUID networkorder.
  Nessun MAC/nome inferito; altri annunci non entrano nella lista peer.
- Scanner reale btleplug desktop, identità filtrate e buffer con scadenza; Windows
  eventi di advertising, Linux aggiornamentiRSSI BlueZ. GetterFFI dedicato.
- Mediana in finestre temporali; dati scaduti invalidati, nessuna distanza numerica
  prima della calibrazione. Calibrazione richiede almeno5 campioni stabili in 2 s.
- Serve prima osservare il dispositivo vicino; poi almeno 10 s oltre soglia.
  Un solo blocco fino al ritorno vicino. OFF, dati assenti e picchi non bloccano.
- Il batch radio viene incorporato interamente prima della decisione; l'ultima
  osservazione vicina annulla il timer anche se la mediana è ancora lontana.
- Nessun lock automatico remoto: FFI locale con gate consenso; erroreOS visibile.
- BLE non sostituisce la disposizione manuale/sincronizzata degli schermi.

## Input e permessi

- Touchpad telefono→Linux: portale RemoteDesktop Rust/ashpd. Primo evento apre il
  consenso sul desktop Linux; sessione persistente per movimento/pulsanti/scroll/
  tastiera. Rifiuto/errore stabile richiede riavvio dell'app per riprovare, senza
  riaprire un dialogo a ogni delta. X11 usa XTest diretto per il puntatore.
- Condivisione PC: LAN Mouse separato, attivare su entrambi, autorizzare le impronte
  reciprocamente e concedere i permessi OS. Cattura pronta sul mittente, ricezione
  pronta sul destinatario. Una fiducia salvata non prova che il backend sia pronto.
- Metadata di readiness reali, bordi esclusi se ricezione non pronta/ignota;
  crash/IPC perso spengono lo stato attivo. Diagnostica visibile nel pannello.
- Per liberare il puntatore: Ctrl+Alt+Shift+Win di sinistra contemporaneamente.
- Configurazione Windows controllata: Linux sul bordo left, porta 4243 distinta da discovery.
  Nessuna causa runtime conclusiva per il fallimento Windows→Linux riportato:
  al controllo i processi LAN Mouse non erano attivi, log senza prova sufficiente.

## Verifiche finora

- Regressioni originali default OFF e100 radio estranee rosse prima, verdi dopo.
- 21 test Flutter prossimità/UI passati, incluse soglia 6 m contro 3,6 m, 20 Hz,
  dati invalidi/persi, ritorno nel batch, consenso persistente e legacy ignorato.
- Rust:7 test proximity gate,1 test allowlist comando,3 BLE Windows e3 BLE Linux passati.
- Kotlin:3 test protocollo passati, compilazione nativa riuscita.
- Input: X11 reale Xvfb+PATH vuoto passato; Wayland senza portale errore stabile
  passato;10 test Rust input passati;8 test Dart shared input passati.
- Build release FFI e daemon Windows/Linux riuscite; getter/export smoke passati.
- Le verifiche finali e la disponibilità degli artefatti sono riportate nello stato iniziale.

## Limiti da verificare sul desktop reale

RSSI resta sensibile a ostacoli/orientamento anche dopo calibrazione. Non attribuire
precisione garantita o latenza misurata. Movimento effettivo Wayland, consenso del
compositor e attraversamento fisico fra PC richiedono la prova Windows/laptop Linux.
Usare la nuova diagnostica di entrambi se il bordo resta fermo, senza ripetere
ciecamente le autorizzazioni già concesse.

## Secondo giro di revisione

- Suite Flutter Linux completa: 81 test passati, zero saltati prima degli ultimi
  miglioramenti alla tastiera e ripulitura degli indirizzi BLE nella topologia.
- Il testo remoto ora attende un ACK correlato alla richiesta e al destinatario.
  Errori del portale conservano il testo; assenza di ACK non viene presentata come
  digitazione riuscita. Test socket ACK errato/negativo/positivo e modal passati.
- Rimossi i vecchi indirizzi radio dal canvas salvato e ignorati negli annunci LAN.
- Il budget della digitazione Wayland è separato da quello del movimento: limite
  4096 caratteri, timeout esplicito e avviso che un timeout può lasciare testo parziale.

- Rimosso il vecchio radar di topologia e il relativo listener accelerometro: tre
  letture software identiche non sono una prova di posizionamento fisico.
- Cambio destinazione durante gesture: pulsanti/modificatori rilasciati sul vecchio
  UUID, eventi successivi ignorati; due regressioni widget passate.
- Limite distinto ancora aperto: perdita improvvisa del socket durante un tasto
  tenuto richiede cleanup nativo per proprietario. Non applicare un rilascio globale
  che interferisca con altri peer; la correzione di cambio destinazione non copre
  questa interruzione di rete.


## Follow-up 11 settembre: motore pronto ma bordo inattivo

- Evidenza runtime Windows: il file TOML contiene un client sul bordo sinistro,
  ma una richiesta IPC `Sync` al processo attivo restituisce `Enumerate: []` con
  cattura e ricezione Enabled. Non basta verificare il file o i permessi.
- Causa nella dipendenza LAN Mouse fissata alla revisione nota: notify Windows
  emette `Modify(Any)` per `FILE_ACTION_MODIFIED`, mentre `Config.changed()`
  accettava solo `Modify(Data(_))`. Il client aggiunto dopo l'avvio non entrava
  quindi nel motore. Patch dedicata per le modifiche generiche Windows.
- Emulazione upstream: rimosso il fallback automatico Dummy. Se nessun backend
  operativo si avvia, lo stato deve restare non pronto; un backend di prova non
  deve trasformare un errore del compositor in un successo.
- Flutter: richieste di avvio/arresto, perdita IPC e aggiornamenti configurazione
  serializzati. Le richieste durante un riavvio non vengono piu scartate; eventi
  del vecchio processo/socket non possono aggiornare il nuovo stato. Cleanup
  dello stato prima delle attese e attesa limitata dell'uscita del supervisore.
- Regressione con binari reali: disable durante restart falliva (enabled true)
  prima della correzione; passa dopo. Test anche di caricamento effettivo di un
  client inattivo da file, senza inviare eventi di input.
- Diagnostica: espone abilitazione/operazione in corso e destinazioni riportate
  dall'IPC, con bordo, attivazione e raggiungibilita. Nessun destinatario non viene
  piu presentato come condivisione pronta in uscita.
- Il report Linux ricevuto (motore e readiness true, stato disattivato) evidenzia
  un'incoerenza di lifecycle; non e stato riprodotto esattamente sul desktop
  dell'utente. La regressione sulle richieste sovrapposte prova un difetto collegato,
  non dimostra da sola che quella specifica sequenza abbia causato il report.
- Il warning wlroots indica un tentativo non disponibile; libei/RemoteDesktop
  possono seguire. Non identificare il backend vincente dal solo booleano ready.
- La prova fisica Windows -> Wayland e il touchpad Android -> Wayland restano
  necessari: suite isolate e readiness non provano da sole il movimento visibile.

- Seconda review: una sincronizzazione IPC non cancella piu un errore precedente
  senza prova di recupero; l'errore resta visibile fino al riavvio esplicito.
- Test nativi della patch: `windows_modify_any_reloads_and_removes_clients`
  falliva con timeout prima, passa dopo; emulazione senza backend reali falliva
  restituendo Dummy prima, passa restituendo NoAvailableBackend dopo.
- Builder: quattro test verificano upgrade clean/vecchia patch/serie completa,
  idempotenza e conservazione/rifiuto di modifiche locali, staged e untracked.
  Preparazione verificata sui checkout reali Windows e Linux.
- Suite Flutter completa 85/85 passata; nessun test saltato. Analisi statica pulita.


### Verifica live successiva: metadata cancellati dagli annunci

Il test Windows con binario finale ha passato il reload reale e il lifecycle.
Il primo tentativo era stato rifiutato per un motore gia attivo; dopo aver chiuso
l'installazione corretta, il test a freddo e passato. Non nascondere questo preflight.

Dopo il riavvio dell'app, il router annunciava il Linux prima con readiness true,
poi con shared_input null. Questa volta anche il file TOML risultava senza client:
non era piu un errore del watcher. In `nexus-plugin-media/src/actor.rs`, indicizzare
un campo JSON assente produceva Null e il relay lo reinseriva esplicitamente
nell'annuncio. Il ricevente interpretava correttamente quel null come spegnimento.
Il router deve conservare la distinzione fra campo assente (nessun aggiornamento)
e null esplicito (disattivazione), anche nella cache dei peer e nei metadata host.


Regressione WebSocket reale del relay: rossa prima (campo assente trasformato in
null), verde dopo. Copre annuncio, rinomina, cache di riconnessione, metadata host
e null esplicito. La correzione richiede aggiornare la FFI/daemon oltre alla UI e
al motore input: copiare soltanto lan-mouse non basta.
