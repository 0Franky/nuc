# TODO: input condiviso ed estensione schermo Windows/Linux

Richiesta del 2026-09-10. Stato: pianificato, da implementare e verificare sui dispositivi reali. Questo documento definisce i casi d'uso richiesti; non attesta che le funzioni siano già operative.

## 1. Mouse e tastiera condivisi secondo la topologia

Dopo aver disposto i dispositivi nell'app, usare il mouse fisico di Windows per raggiungere il bordo associato al portatile Linux. Il cursore passa sullo schermo Linux e la tastiera di Windows controlla Linux. Attraversando il bordo di ritorno, il controllo torna su Windows.

Il funzionamento deve essere bidirezionale: prendendo il portatile, anche lontano dalla scrivania ma ancora collegato, il suo trackpad e la sua tastiera devono poter controllare Windows. Nessun computer deve essere permanentemente la sorgente obbligatoria degli input.

- [ ] Usare identità stabili e una topologia condivisa; gestire posizione, bordi adiacenti, più monitor, risoluzioni e scale diverse.
- [ ] Catturare mouse/trackpad e tastiera fisici sul computer in uso; il passaggio deve funzionare sul desktop intero, anche fuori dalla finestra Nexus.
- [ ] Trasferire il cursore al bordo corrispondente del display remoto, mantenendo una posizione coerente; consentire il ritorno in entrambe le direzioni.
- [ ] Far seguire alla tastiera il computer controllato: testo, scorciatoie, modificatori, pressione/rilascio, click, trascinamento e scroll.
- [ ] Gestire il cambio della sorgente fisica: dopo aver usato il mouse Windows, prendere il trackpad Linux deve permettere di riprendere il controllo senza riconfigurare la topologia.
- [ ] Definire arbitraggio per input simultanei; evitare rimbalzi ai bordi, duplicazione locale/remota e reinoltro degli eventi sintetizzati.
- [ ] Fornire un comando immediato per tornare al controllo locale. In caso di disconnessione rilasciare tasti/pulsanti remoti e ripristinare gli input locali senza perdere il controllo del dispositivo.
- [ ] Mostrare chiaramente dispositivo sorgente, destinazione attiva e indisponibilità del controllo. Esporre i permessi/requisiti mancanti su Windows e sulle sessioni Linux X11/Wayland.

### Prove di accettazione

1. Windows -> bordo configurato -> desktop Linux: movimento, click, scroll e tastiera; quindi ritorno a Windows.
2. Linux -> trackpad e tastiera del portatile -> desktop Windows; quindi ritorno a Linux.
3. Alternare mouse Windows e trackpad Linux nella stessa sessione senza riassociare dispositivi o perdere la topologia.
4. Provare monitor con DPI/risoluzioni differenti e un terzo dispositivo: nessun salto sul nodo sbagliato.
5. Interrompere la rete durante un trascinamento o con un modificatore premuto: nessun tasto bloccato e controllo locale recuperabile.

## 2. Usare il portatile Linux come display esteso di Windows

Nell'app Linux scegliere **Estendi schermo**, selezionare **Win** come sorgente e avviare la sessione. Windows deve disporre di un monitor aggiuntivo del proprio desktop; lo schermo del portatile visualizza quel monitor, sul quale spostare finestre indipendenti dal monitor principale. Il requisito è un vero desktop esteso.

- [ ] Definire creazione/rimozione e ciclo di vita del display aggiuntivo sul computer sorgente; valutare il componente nativo necessario prima di scegliere l'architettura.
- [ ] Realizzare il flusso Linux: Estendi schermo -> scelta sorgente -> connessione -> visualizzazione -> interruzione.
- [ ] Integrare il display aggiuntivo con la topologia e con il controllo mouse/tastiera, distinguendo il desktop Linux dal display Windows ospitato sul portatile.
- [ ] Negoziare risoluzione, scala e frequenza; gestire ridimensionamento, sospensione e riconnessione.
- [ ] Progettare cattura, codifica, trasporto, decodifica e presentazione per la minima latenza praticabile sull'hardware disponibile.
- [ ] Gestire la fine sessione senza lasciare finestre irraggiungibili su un monitor non più disponibile.

### Prove di accettazione

1. Da Linux selezionare Win: Windows riconosce il display aggiuntivo e consente di trascinarvi una finestra; sul portatile compare quella finestra.
2. Interagire con il display esteso tramite gli input condivisi, verificando coordinate, focus e tastiera.
3. Disconnettere e riconnettere il portatile: desktop e finestre restano recuperabili.

## Latenza e ordine di lavoro

Priorità: prima input condiviso bidirezionale, poi display esteso. La latenza deve essere la minore possibile e misurata sui due computer reali: input-to-pointer per il controllo e input-to-visible-frame per il display. Raccogliere almeno mediana, p95 e jitter, su Ethernet e Wi-Fi; definire soglie verificabili dopo la misura iniziale, senza promettere valori non dimostrati. Preservare click e transizioni dei tasti anche se si riducono i campioni di movimento o si scartano frame video vecchi.

La base necessaria è una lista dispositivi con identità, nomi e stato di connessione affidabili. Verificare separatamente avvio dell'app/demone Linux e disponibilità del backend di input prima delle prove.

## Implementazione in corso: integrazione del motore input

Nexus gestisce un processo LAN Mouse 0.11.0 headless, su revisione fissata, tramite IPC locale. Il motore esegue cattura/emulazione native e trasporta gli eventi via DTLS direttamente fra i PC; Flutter gestisce topologia, consensi e stato. Le impronte approvate sono persistenti e distinte dalla discovery. La patch Nexus verifica anche il certificato del destinatario prima di inviare eventi. La topologia per ID viene salvata e la posizione reciproca è inviata al peer.

Il supervisore `nexus-input-host` riceve heartbeat da Nexus: EOF/timeout lo arrestano; su Windows un job termina il figlio anche se il supervisore viene ucciso, su Linux viene impostato il segnale alla morte del padre. Uscire da Nexus chiude il motore. I consensi possono essere revocati anche con peer assenti o condivisione spenta.

Uso previsto dopo aver aggiornato entrambe le app: in **Schermi & Prossimità** disporre i PC, attivare **Mouse e tastiera condivisi** su entrambi e confrontare/autorizzare le impronte. Ritorno locale: Ctrl sinistro + Alt sinistro + Shift sinistro + Win/Super sinistro. Un solo PC per bordo in questa integrazione: configurazioni ambigue sono rifiutate.

Verifiche eseguite su Windows: 22 test Flutter selezionati, incluso avvio/arresto del motore reale da Dart; analisi statica senza segnalazioni; 5 test del router media; test DTLS reale positivo e negativo; motore nativo senza client configurati con cattura/emulazione pronte; arresto su EOF e kill del supervisore. Compilazione del supervisore verificata anche su Linux tramite WSL. Queste prove non attestano ancora il passaggio fisico Windows/Linux né una latenza misurata.

**Limiti aperti:** Linux fisico non ancora disponibile per verifica (utente sta risolvendo avvio demone); il backend supporta cattura Wayland sui desktop supportati da upstream, mentre X11 è solo ricevente. Cattura X11, prove bidirezionali reali, DPI/multimonitor e misurazioni restano aperti. Lo schermo esteso non è implementato in questa fase.

Build: `scripts/build_windows.ps1` e `scripts/build_linux.sh` includono `input-engine`; il builder Python richiede Git, Cargo e le dipendenze native Linux elencate nell'upstream. Conservare la cartella completa `input-engine` con sorgenti/licenza. Dettagli in [THIRD_PARTY.md](../../THIRD_PARTY.md).


### Sincronizzazione della topologia (2026-09-10)

Il pulsante **Sincronizza topologia con gli altri dispositivi** pubblica la disposizione
corrente e abilita gli aggiornamenti automatici anche sui destinatari. La mappa usa
UUID e coordinate globali: ciascuna macchina proietta i peer rispetto alla propria
posizione. Le copie vengono conservate nelle preferenze e scambiate alla riconnessione.
Le vecchie disposizioni reciproche non sovrascrivono una mappa condivisa attiva.

Il protocollo `TOPOLOGY_SYNC` schema 1 usa revisioni logiche e UUID autore come
spareggio deterministico: in caso di modifiche simultanee prevale una disposizione
completa, senza fusione dei trascinamenti concorrenti. I duplicati non sono inoltrati.
Un dispositivo nuovo deve essere inserito nella disposizione e incluso premendo
nuovamente il pulsante. Tutti i destinatari devono avere questa versione aggiornata;
lo stato attivo indica la pubblicazione automatica, non una conferma di ricezione
universale. La sincronizzazione non concede autorizzazioni a mouse/tastiera.

Per ciascun bordo il motore sceglie il PC online autorizzato più vicino, con spareggio
per UUID: una fila di tre PC genera passaggi successivi. Il motore mantiene un solo
vicino per bordo; segmenti multipli sullo stesso bordo non sono ancora supportati.
Le verifiche fisiche sul laptop Linux restano in attesa della riparazione del demone.

Verifica della sincronizzazione: 13 test Flutter mirati superati (modello a tre
nodi, conflitti/duplicati, persistenza, WebSocket e riconnessione, selezione del
vicino, pulsante e canvas adattivo), 5 test Rust media superati, `flutter analyze`
senza segnalazioni. Revisione indipendente: corretti peer fuori dal canvas e
selezione di endpoint input non validi; seconda revisione senza ulteriori rilievi.
Il rilevamento BLE non sovrascrive la disposizione condivisa.
