# Indice Generale della Wiki

Benvenuto nella Wiki ufficiale di sviluppo del progetto **Nexus / OpenContinuity**.
Questa documentazione è divisa in 5 sezioni principali:

## 🗺️ Mappa dei Flussi Operativi & Architettura di Sistema
- **[👉 Visualizza la Mappa Completa dei Flussi (SYSTEM_FLOWS.md)](../SYSTEM_FLOWS.md)**
  *(Contratto formale di tutti i flussi di dati, diagrammi di sequenza e protocolli dell'ecosistema)*

---

## 🧭 Navigazione Rapida

### [Sezione 1: Visione & Architettura Generale](./01-vision-and-architecture/)
1. [01. Visione del Sistema & Analisi Comparativa](./01-vision-and-architecture/01-system-vision.md)
   - Limiti di Apple Continuity e KDE Connect
   - I pilastri del nostro ecosistema universale
2. [02. Architettura a Micro-Plugin](./01-vision-and-architecture/02-microservices-plugin-architecture.md)
   - Modello "Capability Provider" (Chi sa fare cosa)
   - Topology dei nodi & Local Event Bus
   - Comunicazione tra Daemon di Background e Client UI
3. [03. Analisi Approfondita dello Stack Tecnologico](./01-vision-and-architecture/03-tech-stack-analysis.md)
   - Rust vs Go vs C++ per il Core Daemon
   - Flutter vs Tauri vs React Native per la UI
   - Benchmark teorici di consumo memoria & latenza
4. [04. Analisi Basi Esistenti: Fork vs Da Zero vs Approccio Ibrido](./01-vision-and-architecture/04-existing-projects-and-foundations.md)
   - Analisi di KDE Connect, LocalSend, Deskflow, Scream, RustDesk e Iroh
   - Strategia ibrida modulare a massime prestazioni
5. [05. Valutazione Architetturale: Microservizi vs Monolito Modulare vs Attori](./01-vision-and-architecture/05-architectural-paradigm-evaluation.md)
   - Trade-off su memoria, latenza in-process (<50ns vs >2000ns) e vincoli sandbox (iOS/Android)
   - Architettura a Monolito Modulare in Rust con Attori Tokio, Porte Esagonali e Sandbox WASM
6. [06. Moduli, Sottomoduli, Interconnessioni e Flussi Dati](./01-vision-and-architecture/06-modules-submodules-and-dataflow.md)
   - Mappa del Cargo Workspace (`nexus-core`, `nexus-transport`, plugin specifici)
   - Topologia a 3 canali del Tokio Event Bus (MPSC, Broadcast, RingBuffer)
   - Tabelle di input/output, strutture dati Rust e flussi end-to-end

---

### [Sezione 2: Protocolli, Networking & Crittografia](./02-protocols-and-networking/)
1. [01. Discovery & Pairing](./02-protocols-and-networking/01-discovery-and-pairing.md)
   - mDNS (Multicast DNS) su LAN & BLE Advertising in prossimità
   - Flusso di pairing via QR Code / PIN numerico (Ed25519)
2. [02. Protocolli di Trasporto & Formato Messaggi](./02-protocols-and-networking/02-transport-and-data-format.md)
   - QUIC (Datagrams & Multiplexed Streams) vs WebSockets
   - WebRTC DataChannels per streaming audio/video real-time
   - Schemi Protocol Buffers (Protobuf) e JSON-RPC
3. [03. Crittografia E2EE & Modello Permessi](./02-protocols-and-networking/03-security-and-encryption.md)
   - Noise Protocol Framework (XX Handshake)
   - Gestione delle chiavi e permessi granulari per plugin
4. [04. Studio dei Canali Fisici & Allocazione del Carico (Channel Matrix)](./02-protocols-and-networking/04-channel-allocation-and-benchmarks.md)
   - Confronto BLE vs Wi-Fi LAN vs Wi-Fi Direct vs USB
   - Matrice di instradamento per tipo di dato (Latenza < 5ms input, < 20ms audio)
   - Motore di switching dinamico multi-canale

---

### [Sezione 3: Specifiche Tecniche dei Plugin](./03-plugin-specifications/)
1. [01. Media Continuity & Smart Video Handoff](./03-plugin-specifications/01-media-continuity-handoff.md)
   - Rilevamento YouTube/Web tramite WebExtension
   - Sincronizzazione timestamp e prompt "Continua a guardare"
2. [02. Audio Relay a Bassa Latenza & Smart Bluetooth](./03-plugin-specifications/02-audio-relay-and-bluetooth.md)
   - Private Listening (PC -> Smartphone) con codec Opus (< 18ms latenza)
   - Architettura Lock-Free RingBuffer (stile Scream/PipeWire) & Jitter Buffer
   - Gestione automatica disconnessione/riconnessione auricolari Bluetooth
3. [03. Input Bridge & Remote Control](./03-plugin-specifications/03-input-and-remote-control.md)
   - Trackpad multitouch, tastiera remota, telecomando volume e puntatore giroscopico
4. [04. Smart Clipboard & Streaming File Transfer](./03-plugin-specifications/04-clipboard-and-files.md)
   - Appunti intelligenti E2E criptati con cronologia opzionale
   - Trasferimento file chunked e streaming diretto senza upload
5. [05. Sensor Bridge & Continuity Camera](./03-plugin-specifications/05-sensor-and-continuity-camera.md)
   - Smartphone come webcam HD e microfono per PC
6. [06. Proximity & Presence Detection](./03-plugin-specifications/06-proximity-and-presence.md)
   - Tracciamento RSSI BLE per auto-lock e auto-pause quando ci si allontana
7. [07. Notification Sync, Mirroring & Zero-Trust Privacy Gate](./03-plugin-specifications/07-notification-sync-and-mirroring.md)
   - Mirroring notifiche Windows WinRT, mascheramento segreti/PII e colori per dispositivo

---

### [Sezione 4: Integrazione Nativa & Vincoli OS](./04-os-integration-and-constraints/)
1. [01. Integrazione Windows](./04-os-integration-and-constraints/01-windows-integration.md) (WASAPI Loopback, SMTC, WinRT BLE, Windows Service)
2. [02. Integrazione macOS & iOS](./04-os-integration-and-constraints/02-macos-ios-integration.md) (CoreAudio, CoreBluetooth, Live Activities, Sandbox)
3. [03. Integrazione Linux](./04-os-integration-and-constraints/03-linux-integration.md) (PipeWire, BlueZ, MPRIS, Wayland Portals vs X11 uinput)
4. [04. Integrazione Android](./04-os-integration-and-constraints/04-android-integration.md) (Foreground Service, Doze Mode, MediaSession, AAudio)

---

### [Sezione 5: Roadmap & Piano di Sviluppo](./05-roadmap-and-milestones/)
1. [01. Roadmap a Fasi & MVP Checklist](./05-roadmap-and-milestones/01-development-phases.md)
   - Da Fase 0 (Proof of Concept) a Release 1.0
