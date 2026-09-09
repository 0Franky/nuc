# 04. Analisi Basi Esistenti: Fork vs Partire da Zero vs Approccio Ibrido

Prima di scrivere codice, è fondamentale valutare lo stato dell'arte open source per evitare di reinventare la ruota, comprendendo se convenga effettuare un **fork** di un progetto esistente, partire **da zero**, oppure adottare un **approccio ibrido modulare**.

---

## 🔍 1. Analisi dei Progetti Open Source Esistenti

| Progetto | Stack Principale | Punti di Forza | Limiti Decisivi per il Nostro Obiettivo | Valutazione |
| :--- | :--- | :--- | :--- | :--- |
| **KDE Connect** | C++ / Qt (Desktop), Java/Kotlin (Android), Swift (iOS) | Ecosistema maturo, ampia varietà di plugin, protocollo TLS locale. | Codice monolitico e frammentato in 4 linguaggi diversi. Prestazioni scarse su iOS/macOS. Nessun audio relay low-latency o video handoff intelligente. | ❌ **Non conviene forkarlo** (debito tecnico troppo alto). |
| **LocalSend** | Dart / Flutter | UI eccellente e moderna, UX di discovery pulita, vera multipiattaforma. | Architettura basata su HTTP/REST standard; non supporta stream UDP, socket persistenti low-latency, audio capture né iniezione input OS. | ❌ **Non adatto come base streaming** (solo per ispirazione UI). |
| **Deskflow** *(Erede di Synergy/Barrier)* | C++ | Leader per la condivisione mouse/tastiera (KVM software), supporto Wayland e Win32. | Monotematico (solo input/clipboard). Nessuna modularità per audio, fotocamera o video handoff. | 💡 **Ottimo come riferimento logico** per l'Input Bridge. |
| **RustDesk** | Rust + Flutter | Remote Desktop completo, NAT traversal, WebRTC video/audio, virtual display. | Troppo pesante per un background daemon sempre attivo; orientato al controllo remoto a schermo intero (VNC), non all'integrazione fluida e invisibile. | 💡 **Ottimo riferimento per i driver virtuali**. |
| **Scream / ScreamRouter** | C / C++ / Rust | Cattura audio a bassissima latenza (WASAPI/PipeWire) su rete locale UDP unicast/multicast. | Non è un'app utente; è solo un driver virtuale/protocollo audio grezzo senza UI, pairing o sicurezza E2EE. | 💡 **Architettura audio ideale da integrare**. |
| **Iroh (`iroh.computer`)** | Rust | Libreria P2P moderna: basata su **QUIC**, dial-by-public-key (Ed25519), UDP hole punching nativo, multiplexing e binding per Dart/Kotlin/Swift. | È una libreria di networking puro, non un'applicazione finita. | ⭐ **LA BASE FOUDNATIONALE DI TRASPORTO PERFETTA**. |

---

## ⚖️ 2. La Decisione Strategica: L'Approccio Ibrido Modulare

Partire al 100% da zero (scrivendo da zero persino lo stack QUIC, l'encoder Opus, i parser HID e i binding BLE) richiederebbe anni di lavoro. Forkare un'app monolitica esistente (come KDE Connect) ci legherebbe a un'architettura obsoleta.

La strategia vincente è l'**Approccio Ibrido Modulare**:
Costruire un'architettura snella e proprietaria basata sulle **migliori librerie e crate specializzate al mondo**:

```
+-------------------------------------------------------------------------------+
|                       IL NOSTRO CLIENT CROSS-PLATFORM (Flutter)               |
+-------------------------------------------------------------------------------+
                                        ▲
                                        │ flutter_rust_bridge v2 (Zero-Copy)
                                        ▼
+-------------------------------------------------------------------------------+
|                        IL NOSTRO CORE DAEMON (Rust Tokio)                     |
|                                                                               |
|  [P2P & Transport Layer]   -->  Libreria Iroh / Quinn (QUIC + E2EE Noise)    |
|  [Audio Capture & Stream]  -->  CPAL + Audiopus + Lock-Free RingBuffer (Scream)|
|  [Input & OS Hooks]        -->  Enigo / Rdev + Linux uinput + Win32 API       |
|  [Bluetooth & Proximity]   -->  Btleplug + BlueZ/CoreBT/WinRT                 |
|  [Media Handoff Engine]    -->  Nostro Event Bus + Browser WebExtension       |
+-------------------------------------------------------------------------------+
```

---

## 🎯 3. Vantaggi dell'Approccio Ibrido

1. **Massima Manutenibilità**: Il codice di business logic dell'app rimane snello, pulito e moderno (Rust + Dart).
2. **Zero Debito Tecnico Legacy**: Nessuna dipendenza da framework C++ pesanti o protocolli TCP legacy.
3. **Prestazioni Native Pure**: Ogni sottosistema sfrutta le librerie Rust più veloci e testate dalla community globale.
4. **Time-to-Market Ridotto**: Permette di avere un prototipo funzionante di Handoff e Audio Relay in poche settimane invece che in mesi.
