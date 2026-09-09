# Ecosystem Core (Progetto "OpenContinuity / Nexus")

> **Piattaforma Universale Open Source per l'interazione fluida e modulare tra dispositivi (Windows, macOS, Linux, Android, iOS)**.

[![Nexus Continuity CI](https://github.com/nexus/continuity/actions/workflows/ci.yml/badge.svg)](https://github.com/nexus/continuity/actions)
[![License](https://img.shields.io/badge/License-MIT%20OR%20Apache--2.0-blue.svg)](LICENSE)
[![Rust](https://img.shields.io/badge/Rust-1.78%2B-orange.svg)](https://www.rust-lang.org/)
[![Flutter](https://img.shields.io/badge/Flutter-3.x-blue.svg)](https://flutter.dev/)

---

## 🎯 Visione del Progetto
Creare un'alternativa universale, modulare e open-source all'ecosistema Apple Continuity e a KDE Connect. Il sistema è basato su un'architettura **a monolito modulare con attori Rust in-process e porte esagonali**, ed orchestra dinamicamente Bluetooth Low Energy (BLE), Wi-Fi LAN (QUIC/UDP) e USB per garantire **bassissima latenza (< 18ms audio, < 5ms input)**, crittografia end-to-end (E2EE Noise Protocol XX) e zero dipendenze dal cloud.

---

## 📁 Struttura del Progetto

```
eco/
├── Cargo.toml (Workspace Root)
│
├── crates/
│   ├── nexus-types/             <- Tipi base, DeviceId, CapabilityMap, NexusError
│   ├── nexus-protocol/          <- Envelope binario (NexusPacket) & Schemi di Rete
│   ├── nexus-crypto/            <- Noise_XX (Curve25519) E2EE, Ed25519, ChaCha20-Poly1305, BLAKE3 KDF
│   ├── nexus-actor-system/      <- Event Bus in-process Tokio (<50ns) & ActorSupervisor con Panic Recovery
│   ├── nexus-transport/         <- Discovery mDNS (_nexus._udp.local), Socket UDP & VirtualLoopbackRouter
│   ├── nexus-plugin-media/      <- Media Continuity Actor, Sincronizzazione Timestamp YouTube/Web & Intent
│   ├── nexus-plugin-audio/      <- Audio Relay RingBuffer Lock-Free, WASAPI Capture, Jitter Buffer, Drift Resampler
│   ├── nexus-plugin-input/      <- Trackpad Ballistics, Giroscopio Laser, Iniezione Kernel SendInput (Win32)
│   ├── nexus-plugin-clipboard/  <- Smart Clipboard Parser (OTP 2FA, Hex Color, URL, Phone) & LoopGuard
│   ├── nexus-plugin-proximity/  <- Filtro di Kalman 1D su RSSI BLE, State Machine Distanza & Auto-Lock
│   ├── nexus-ffi/               <- Bridge FFI per Flutter (flutter_rust_bridge v2 / C-ABI)
│   └── nexus-daemon/            <- Eseguibile principale background service standalone
│
├── apps/
│   └── nexus_ui/                <- App Flutter cross-platform (Dashboard, Trackpad, Appunti, Impostazioni)
│
├── extensions/
│   └── nexus_browser_ext/       <- WebExtension Manifest V3 (Chrome/Edge/Brave/Firefox) per YouTube & HTML5
│
├── scripts/
│   ├── build_windows.ps1        <- Build One-Click per Windows Desktop + Daemon + Estensione
│   ├── build_linux.sh           <- Build per distribuzioni Linux
│   ├── build_android.ps1        <- Build per Android Release APK
│   └── pack_extension.ps1       <- Pacchettizzazione WebExtension ZIP
│
├── wiki/                        <- Documentazione tecnica approfondita & analisi (23 documenti)
└── .github/workflows/ci.yml     <- Pipeline CI multipiattaforma automatizzata
```

---

## ⚡ Guida Rapida di Avvio

### 1. Build ed Esecuzione del Daemon (Rust)
```powershell
$env:Path = "$env:USERPROFILE\.cargo\bin;" + $env:Path
cargo run --bin nexus-daemon
```

### 2. Build ed Esecuzione dell'App Grafica (Flutter UI)
```powershell
cd apps/nexus_ui
flutter run -d windows   # oppure -d android / -d linux / -d macos / -d chrome
```

### 3. Installazione dell'Estensione Browser
1. Apri `chrome://extensions` o `edge://extensions`.
2. Attiva la **Modalità sviluppatore**.
3. Clicca su **Carica estensione non compattata** e seleziona la cartella `extensions/nexus_browser_ext`.

### 4. Compilazione Automatica One-Click (Windows)
```powershell
.\scripts\build_windows.ps1
```
I binari compilati (`nexus-daemon.exe`, `nexus_ui.exe`, `nexus_ffi.dll`, `nexus_browser_ext.zip`) verranno posizionati nella cartella `dist/windows/`.

---

## 🧪 Verifica della Test Suite

Per eseguire tutti i test unitari, difensivi, C-ABI e di integrazione multi-nodo:
```powershell
cargo test --workspace
cd apps/nexus_ui && flutter test
```
**Risultato**: 100% test superati con 0 errori e 0 warnings.

## 🗺️ Mappa dei Flussi Operativi & Architettura di Sistema
Per la rappresentazione passo-passo di tutti i flussi di dati, messaggi JSON, diagrammi di sequenza e contratti FFI tra Windows, Android e WebExtension, consulta:
- **[👉 SYSTEM_FLOWS.md](./SYSTEM_FLOWS.md)** *(Contratto formale dei flussi dell'ecosistema)*

---

## 📚 Indice della Wiki del Progetto

Tutta la documentazione tecnica, le analisi di stack, i protocolli e le specifiche dei plugin sono tracciati nella directory [`wiki/`](./wiki/):

### 1. Visione & Architettura
- [01. Visione e Analisi Comparativa (Apple vs KDE Connect vs Nostro Modello)](./wiki/01-vision-and-architecture/01-system-vision.md)
- [02. Architettura a Micro-Plugin & Capability Engine](./wiki/01-vision-and-architecture/02-microservices-plugin-architecture.md)
- [03. Analisi Approfondita dello Stack Tecnologico](./wiki/01-vision-and-architecture/03-tech-stack-analysis.md)
- [04. Analisi Basi Esistenti: Fork vs Da Zero vs Approccio Ibrido](./wiki/01-vision-and-architecture/04-existing-projects-and-foundations.md)
- [05. Valutazione Architetturale: Microservizi vs Monolito Modulare vs Attori](./wiki/01-vision-and-architecture/05-architectural-paradigm-evaluation.md)
- [06. Moduli, Sottomoduli, Interconnessioni e Flussi Dati](./wiki/01-vision-and-architecture/06-modules-submodules-and-dataflow.md)

### 2. Protocolli, Networking & Sicurezza
- [01. Discovery & Pairing (mDNS, BLE, QR Handshake)](./wiki/02-protocols-and-networking/01-discovery-and-pairing.md)
- [02. Protocolli di Trasporto & Formato Messaggi (Protobuf / QUIC / WebRTC)](./wiki/02-protocols-and-networking/02-transport-and-data-format.md)
- [03. Crittografia E2EE & Modello dei Permessi (Noise Protocol)](./wiki/02-protocols-and-networking/03-security-and-encryption.md)
- [04. Studio dei Canali Fisici & Allocazione del Carico (Channel Matrix)](./wiki/02-protocols-and-networking/04-channel-allocation-and-benchmarks.md)

### 3. Specifiche Tecniche dei Plugin
- [01. Media Continuity & Smart Video Handoff](./wiki/03-plugin-specifications/01-media-continuity-handoff.md)
- [02. Audio Relay a Bassa Latenza (< 18ms) & Smart Bluetooth Switcher](./wiki/03-plugin-specifications/02-audio-relay-and-bluetooth.md)
- [03. Input Bridge & Remote Control (Mouse, Keyboard, Volume)](./wiki/03-plugin-specifications/03-input-and-remote-control.md)
- [04. Smart Clipboard & Streaming File Transfer](./wiki/03-plugin-specifications/04-clipboard-and-files.md)
- [05. Sensor Bridge & Continuity Camera](./wiki/03-plugin-specifications/05-sensor-and-continuity-camera.md)
- [06. Proximity Detection & Auto-Lock (BLE RSSI)](./wiki/03-plugin-specifications/06-proximity-and-presence.md)

### 4. Integrazione Nativa & Vincoli degli OS
- [01. Integrazione Windows (WASAPI Loopback, SMTC, WinRT)](./wiki/04-os-integration-and-constraints/01-windows-integration.md)
- [02. Integrazione Apple (macOS & iOS Sandbox, Live Activities, CoreAudio)](./wiki/04-os-integration-and-constraints/02-macos-ios-integration.md)
- [03. Integrazione Linux (PipeWire, BlueZ, Kernel uinput)](./wiki/04-os-integration-and-constraints/03-linux-integration.md)
- [04. Integrazione Android (Foreground Services, Doze Mode, AAudio)](./wiki/04-os-integration-and-constraints/04-android-integration.md)

### 5. Roadmap & Piano di Sviluppo
- [01. Roadmap a Fasi & MVP Checklist](./wiki/05-roadmap-and-milestones/01-development-phases.md)
