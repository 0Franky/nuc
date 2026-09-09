# Regole e Vincoli di Sviluppo Workspace Nexus

## 1. Regola Assoluta "Zero Mock / Zero Fittizio"
- **MAI generare o inserire codice mock, simulato, vuoto o fittizio**.
- Qualsiasi funzionalità, componente o driver implementato (Flutter, Rust, plugin o FFI) deve essere **reale, pienamente operativo, integrato e pronto all'esecuzione**.
- Ogni binding verso il sistema operativo (WASAPI, Win32 SendInput, ALSA, PulseAudio, PipeWire pactl, playerctl, D-Bus, Android Service, ecc.) deve effettuare chiamate e controlli reali.

## 2. Privacy e Igiene PII (Personal Identifiable Information)
- **Nessuna informazione sensibile o PII** deve essere presente nel codice sorgente, commit, documentazione o payload di rete.
- Vietato l'inserimento di nomi utente di sistema locali, percorsi utente assoluti, credenziali, token API o chiavi private.
- Usare percorsi relativi o costruttori runtime generici.

## 3. Handshake e Discovery di Rete
- Durante le fasi di handshake, discovery e sincronizzazione LAN (UDP beacon 42420, WebSocket router 28471, HTTP 28472):
  - Inviare **esclusivamente i dati minimali necessari**:
    - id / device_id: identificativo univoco UUID stabile del nodo
    - 
ame: nome amichevole del dispositivo
    - device_type: tipologia hardware (Desktop, Mobile)
    - os: sistema operativo (windows, linux, ndroid, ios, macos)
    - spatial_position: coordinate o quadrante topologico (Left, Right, Center, Above, Below)
  - **Zero PII**: non trasmettere nomi account, indirizzi fisici MAC sensibili o dati utente.
  - **Self-filter**: un nodo non deve mai registrare se stesso né le proprie interfacce di rete locali o bridge virtuali (irbr*, docker*, 192.168.122.x) tra i dispositivi remoti controllabili.
