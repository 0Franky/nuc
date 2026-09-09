# 02. Protocolli di Trasporto & Formato Dati

Questo documento definisce l'architettura di rete a basso livello per lo scambio di messaggi, eventi e flussi multimediali in tempo reale.

---

## 🚀 1. Scelta dei Protocolli di Trasporto

Il sistema impiega due canali principali sulla rete locale:

```
                          NEXUS P2P SESSION
                                 │
         ┌───────────────────────┴───────────────────────┐
         ▼                                               ▼
 [QUIC Streams / TLS 1.3]                     [QUIC Datagrams / WebRTC]
 - Eventi di sistema                           - Coordinate Mouse & Gesti (<5ms)
 - Handshake & Scambio Capability              - Audio Opus Real-time (<25ms)
 - Trasferimento File & Appunti                - Flusso Video Webcam HD
 - Comandi RPC & Media Handoff
```

### Perché QUIC (RFC 9000) su UDP:
1. **Zero Head-of-Line Blocking**: Con TCP tradizionale, la perdita di un singolo pacchetto blocca tutti gli altri canali. Con QUIC, un file pesante che si trasferisce non rallenta i comandi del telecomando o la sincronizzazione della clipboard.
2. **Connessione Istantanea (0-RTT)**: I dispositivi accoppiati ripristinano la sessione sicura immediatamente senza round-trip aggiuntivi.
3. **Connection Migration**: Se lo smartphone passa dal Wi-Fi 5GHz al Wi-Fi 2.4GHz o cambia IP locale, la sessione QUIC rimane attiva senza disconnessioni o rinegoziazioni.

---

## 📦 2. Formato Dati: Protocol Buffers (Protobuf v3)

Tutti i messaggi scambiati tra i nodi sono serializzati in formato binario **Protobuf**, garantendo payload ultraleggeri (pochi byte) e retrocompatibilità tra versioni differenti dell'app.

### Envelope Generale (`nexus_packet.proto`):

```protobuf
syntax = "proto3";

package nexus.protocol;

// Busta principale di ogni messaggio
message NexusPacket {
  uint64 sequence_number = 1;
  string sender_id = 2;
  string target_id = 3;
  uint64 timestamp_utc_ms = 4;

  oneof payload {
    SystemMessage system = 10;
    MediaHandoffMessage media = 11;
    AudioRelayMessage audio = 12;
    InputMessage input = 13;
    ClipboardMessage clipboard = 14;
    FileTransferMessage file = 15;
    SensorMessage sensor = 16;
  }
}

// Messaggi di controllo del sistema
message SystemMessage {
  enum Type {
    PING = 0;
    PONG = 1;
    CAPABILITY_ANNOUNCE = 2;
    PAIRING_REQUEST = 3;
    PAIRING_RESPONSE = 4;
    DISCONNECT = 5;
  }
  Type type = 1;
  bytes payload = 2;
}
```

---

## 🎛️ 3. Struttura dei Canali Multiplexati (Stream Mapping)

Ogni sessione P2P attiva tra due dispositivi gestisce stream QUIC dedicati:

| Stream ID | Tipologia Stream | Plugin / Funzione | Garanzia di Consegna |
| :--- | :--- | :--- | :--- |
| **Stream 0** | Bidirezionale Affidabile | Control Plane & Handshake | Garanzia ordinata (Reliable) |
| **Stream 1** | Bidirezionale Affidabile | Sincronizzazione Appunti | Garanzia ordinata (Reliable) |
| **Stream 2** | Bidirezionale Affidabile | Media Handoff (URL & Timestamp) | Garanzia ordinata (Reliable) |
| **Stream 3** | Unidirezionale Affidabile | File Chunks Transfer | High Throughput Reliable |
| **Datagrams**| Non affidabile / Low Latency | Input (Mouse/Tasti/Giroscopio) | Latenza minima (Unreliable UDP) |
| **Audio Track**| WebRTC / QUIC Datagrams | Audio Relay (Frame Opus 10ms) | Jitter Buffer con priorità Real-Time |

---

## ⚡ 4. Esempio di Payload Binario: Media Handoff

```protobuf
message MediaHandoffMessage {
  enum Action {
    OFFER_HANDOFF = 0;      // Il dispositivo A dice "sto guardando questo"
    ACCEPT_HANDOFF = 1;     // Il dispositivo B dice "lo riprendo io"
    ACK_TRANSFER = 2;       // Il dispositivo A mette in pausa e cede il controllo
  }

  Action action = 1;
  string session_id = 2;
  string media_title = 3;
  string source_app = 4;    // es. "YouTube - Chrome", "Spotify", "VLC"
  string media_url = 5;     // es. "https://www.youtube.com/watch?v=..."
  uint64 position_ms = 6;   // Millisecondo esatto di riproduzione
  uint64 duration_ms = 7;
  bool is_playing = 8;
  string thumbnail_url = 9;
}
```

Grazie a questa serializzazione, un pacchetto di notifica di handoff video completo pesa meno di **200 byte**, consentendo una trasmissione istantanea (< 2 millisecondi in LAN).
