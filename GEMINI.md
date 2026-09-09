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
    - name: nome amichevole del dispositivo
    - device_type: tipologia hardware (Desktop, Mobile)
    - os: sistema operativo (windows, linux, android, ios, macos)
    - spatial_position: coordinate o quadrante topologico (Left, Right, Center, Above, Below)
  - **Zero PII**: non trasmettere nomi account, indirizzi fisici MAC sensibili o dati utente.
  - **Self-filter**: un nodo non deve mai registrare se stesso né le proprie interfacce di rete locali o bridge virtuali (virbr*, docker*, 192.168.122.x) tra i dispositivi remoti controllabili.

## 4. Golden Practices di Buona Programmazione e Ingegnerizzazione del Codice
- **SSOT (Single Source of Truth)**:
  - Ogni informazione di stato, configurazione, modello dati o parametro di rete deve avere una ed una sola sorgente di verità univoca e condivisa.
  - Vietata la duplicazione di stati paralleli disallineati (es. liste di peer separate, modelli parziali o logiche di routing duplicate).
- **DRY (Don't Repeat Yourself)**:
  - Centralizzare logiche comuni, widget condivisi, costanti, validatori e gestori di messaggi di rete in moduli riusabili.
  - Vietato creare pulsanti, dialoghi, funzioni o selettori ridondanti o con implementazioni alternative per la stessa operazione.
- **Principi SOLID & Clean Architecture**:
  - **Single Responsibility Principle (SRP)**: ogni file, classe o attore Rust/Flutter deve avere una responsabilità chiara e focalizzata. Niente classi monolitiche ingestibili.
  - Separazione netta tra Core Logic / Protocolli di Rete / Storage / Presentation Layer (UI).
  - Codice leggibile, auto-esplicativo, robusto alle eccezioni, manutenibile ed estensibile.
