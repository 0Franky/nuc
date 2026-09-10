# 01. Roadmap di Sviluppo & Stato di Implementazione dei Flussi

> **Stato Aggiornato al**: Settembre 2026  
> **Test Suite**: 58/58 Test Rust superati (100%) | 8/8 Test Flutter E2E superati (100%)

---

## 📊 Tabella Stato dei Flussi e Moduli di Sistema

| ID Flusso | Modulo / Funzionalità | Stato Operativo | Tecnologia & Note |
| :--- | :--- | :---: | :--- |
| **Flusso 1** | **Discovery mDNS LAN (`5353` / `42420`)** | ✅ **Operativo** | Discovery Zero-Conf mDNS + socket UDP P2P (`nexus-transport`). |
| **Flusso 1** | **WebSocket Router LAN (`28471`)** | ✅ **Operativo** | Connessione live bidirezionale client/desktop (`nexus-plugin-media`). |
| **Flusso 1** | **Scambio Metadati & Topologia** | ✅ **Operativo** | Payload `PEER_METADATA` e `PEER_ANNOUNCE` (OS, tipo device, risoluzione). |
| **Flusso 1** | **Pairing BLE Automatico di Prossimità** | ⏳ *Pianificato* | Integrazione BLE Advertising hardware via WinRT/CoreBluetooth. |
| **Flusso 2** | **Video Handoff PC ➔ Mobile** | ✅ **Operativo** | Cattura automatica YouTube/HTML5 con apertura a timestamp esatto `&t=...`. |
| **Flusso 2** | **Auto-Pause su PC dopo Handoff** | ✅ **Operativo** | Iniezione remota `PAUSE` verso il browser PC per fermare la riproduzione locale. |
| **Flusso 2** | **Video Handoff Mobile ➔ PC** | ✅ **Operativo** | Invio link dal telefono con apertura istantanea su browser PC e pausa mobile. |
| **Flusso 2** | **Player Video Nativo In-App Flutter** | ⏳ *Pianificato* | Attualmente la continuazione apre il browser o app esterna (YouTube/Chrome). |
| **Flusso 3** | **Trackpad Touch (Pan 1 Dito & Balistica)** | ✅ **Operativo** | Gesture smoothing + iniezione Win32 `SendInput` / `mouse_event`. |
| **Flusso 3** | **Doppio Tap + Drag & Selezione Testo** | ✅ **Operativo** | Double-tap & hold attiva `LEFT DOWN`, movimento subpixel, rilascio `LEFT UP`. |
| **Flusso 3** | **Click Sinistro (Tap 1 Dito / Tasto SX)** | ✅ **Operativo** | `TOUCHPAD_CLICK` Left con debounce temporale. |
| **Flusso 3** | **Click Destro (Tap 2 Dita / Tasto DX)** | ✅ **Operativo** | `TOUCHPAD_CLICK` Right nativo hardware e tap simultaneo a due dita. |
| **Flusso 3** | **Scroll Verticale (Pan 2 Dita)** | ✅ **Operativo** | `TOUCHPAD_SCROLL` con moltiplicatore fluido ruota mouse. |
| **Flusso 3** | **Puntatore ad Aria Giroscopico (Laser)** | ✅ **Operativo** | Sensori orientamento mobile proiettati su schermo PC in tempo reale. |
| **Flusso 3** | **Tastiera Remota, Macro & Digitazione Testo** | ✅ **Operativo** | Tasti speciali (Esc, Tab, Ctrl, Alt, Win), macro veloci e modale digitazione Unicode. |
| **Flusso 4** | **Topologia Spaziale Draggable (2D Canvas)** | ✅ **Operativo** | Quadrati interattivi trascinabili per riordinare display e descrizioni traiettoria. |
| **Flusso 4** | **Salto Cursore Bordo Schermo (Edge Hop)** | ⏳ *Da completare e verificare* | Requisiti bidirezionali e prove reali nel [TODO input condiviso](02-shared-input-and-extended-display.md). |
| **Flusso 4** | **Streaming Delta Continuo Cursore Mouse** | ⏳ *Da completare e verificare* | Includere tastiera fisica, cambio sorgente, ritorno locale e guasti di connessione; vedi [TODO](02-shared-input-and-extended-display.md). |
| **Flusso 4** | **Drag & Drop File Cross-Screen tra PC** | ⏳ *Pianificato* | Trasferimento file trascinando icone oltre il bordo dello schermo. |
| **Flusso 5** | **Filtro di Kalman RSSI & Stima Distanza** | ✅ **Operativo** | `KalmanRssiFilter` 1D antirumore e classificazione zone (`Near`/`Far`). |
| **Flusso 5** | **Rilevamento Movimento (`Approaching`/`MovingAway`)** | ✅ **Operativo** | Analisi del trend di velocità di allontanamento o avvicinamento. |
| **Flusso 5** | **Walk-Away Auto-Lock PC (`LockWorkStation`)** | ✅ **Operativo** | Blocco di sicurezza Windows (con bypass automatico durante i test). |
| **Flusso 6** | **Cattura Audio di Sistema (WASAPI Loopback)** | ✅ **Operativo** | Cattura reale a basso livello di tutto l'audio PC a 48 kHz 16-bit Stereo. |
| **Flusso 6** | **⚡ Modalità Tempo Reale (~15ms)** | ✅ **Operativo** | Stream binario WebSocket PCM + Web Audio API per sincronia video/gaming. |
| **Flusso 6** | **💎 Modalità Alta Fedeltà con Buffer** | ✅ **Operativo** | Stream continuo WAV (`/stream.wav`) con buffer regolabile 500ms - 3s. |
| **Flusso 6** | **Mute Fisico Casse PC (Solo Cuffie)** | ✅ **Operativo** | Silenziamento altoparlanti della stanza con audio attivo sullo smartphone. |
| **Flusso 6** | **Player Audio Nativo Integrato in Flutter (ExoPlayer)**| ⏳ *Pianificato* | Attualmente gestito con Web Player mobile ad alte prestazioni. |
| **Flusso 7** | **Sincronizzazione Appunti Testo & Zero-Trust** | ✅ **Operativo** | Censura selettiva segreti, box ambra, tasto Rivela E2EE, OS watcher. |
| **Flusso 7** | **Smart Parser (OTP, Link URL, Colori HEX)** | ✅ **Operativo** | Riconoscimento contestuale ed estrazione rapida codici. |
| **Flusso 7** | **Sincronizzazione Immagini & Bitmap Appunti** | ⏳ *Pianificato* | Supporto a `image/png` e rich content negli appunti. |
| **Flusso 8** | **File Transfer Nativo & Zero Mock** | ✅ **Operativo** | Fallback Windows OpenFileDialog / Android SAF, elenco pulito all'avvio. |
| **Flusso 8** | **Trasferimento File Chunked 64KB** | ✅ **Operativo** | Segmentazione e invio su canale ad alta velocità. |
| **Flusso 8** | **Integrità Crittografica SHA-256 / BLAKE3** | ✅ **Operativo** | Hash cumulativo e validazione prima del salvataggio su disco. |
| **Flusso 8** | **Resume Trasferimenti Interrotti** | ✅ **Operativo** | Tracciamento chunk e recupero mirato su disconnessione Wi-Fi. |
| **Flusso 9** | **Telephony & Call Continuity (Notifica Chiamate & Risposta Remota)** | 🟡 **In Sviluppo (Roadmap / TODO)** | **Fase 1**: Broadcast notifica chiamata da Android a tutti i PC (`NOTIFICATION_SYNC`).<br>**Fase 2 (TODO)**: Risposta remota dal PC con instradamento microfoni locali via Opus/UDP al cellulare e reinserimento audio nella chiamata telefonica. |
| **Extra** | **Centro Notifiche Multi-Dispositivo** | ✅ **Operativo** | Notifiche sanitizzate bidirezionali, filtro mittente e sblocco segreti. |
| **Extra** | **Continuity Camera (Webcam HD Wireless per PC)** | ⏳ *Pianificato* | Streaming video H.264 dal telefono a driver virtuale webcam Windows. |

---

## 🎯 Prossimi Obiettivi di Sviluppo (Sprint Corrente & Roadmap)

1. **Telephony & Call Continuity (Chiamate da Cellulare a PC)**:
   - **Fase 1**: Intercettazione notifiche di chiamata in arrivo su Android via `NotificationListenerService` / `TelephonyCallback` e broadcast a tutti i dispositivi connessi.
   - **Fase 2 (TODO)**: Risposta alla chiamata telefonica direttamente dal dispositivo in uso (PC Windows, Linux, Tablet), catturando l'audio dal microfono del computer e instradando lo stream via Opus/UDP verso il cellulare che lo reinietta nella chiamata telefonica attiva.
2. **Player Audio Nativo In-App Flutter**: Integrazione diretta di `just_audio` o streaming AAudio in-app per evitare l'apertura del browser esterno.
3. **Supporto Immagini negli Appunti**: Estendere `nexus-plugin-clipboard` per catturare screenshot e immagini PNG/JPEG.
4. **Resume Automatico File Transfer**: Implementare la ripresa dei trasferimenti file da disco (.part) su riallineamento socket.

## Prossime funzionalità richieste

- [ ] [Input condiviso bidirezionale Windows/Linux secondo la topologia](02-shared-input-and-extended-display.md#1-mouse-e-tastiera-condivisi-secondo-la-topologia).
- [ ] [Portatile Linux come display esteso di Windows a minima latenza](02-shared-input-and-extended-display.md#2-usare-il-portatile-linux-come-display-esteso-di-windows).
