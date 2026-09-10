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
