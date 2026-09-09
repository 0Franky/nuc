# 04. Studio dei Canali Fisici & Allocazione del Carico (Channel Matrix)

Per ottenere prestazioni superiori ad Apple Continuity, il sistema non si affida a un solo canale di trasmissione, ma orchestra dinamicamente **Bluetooth Low Energy (BLE)**, **Wi-Fi LAN (QUIC/UDP)**, **Wi-Fi Direct (P2P senza router)** e **USB Cable**.

---

## 📊 1. Analisi Comparativa dei Canali Fisici

| Canale Fisico / Protocollo | Throughput Reale | Latenza Tipica (RTT) | Consumo Energetico | Requisiti di Rete | Ideale Per |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Bluetooth Low Energy (BLE 5.x)** | 0.2 – 1.4 Mbps | 25 – 60 ms | **Bassissimo (< 10 mW)** | Nessuno (P2P Radio) | Presenza, Beacon, Risveglio da Standby, Handshake iniziale |
| **Wi-Fi LAN (QUIC Datagrams / UDP)** | 100 – 800+ Mbps | **1 – 4 ms** | Basso-Medio (30 – 80 mW)| Router Wi-Fi comune | **Audio Real-Time (Opus)**, **Input Cursore**, **Giroscopio** |
| **Wi-Fi LAN (QUIC Streams)** | 300 – 950 Mbps | 4 – 10 ms | Medio (50 – 120 mW) | Router Wi-Fi comune | **Trasferimento File**, **Appunti Cifrati**, **Media Handoff** |
| **Wi-Fi Direct / P2P Hotspot** | 150 – 500 Mbps | 5 – 12 ms | Medio-Alto | Nessuno (crea rete ad-hoc) | Uso in viaggio (treno, aereo, esterni senza Wi-Fi) |
| **USB Cable Bridge (WinUSB/ADB)** | 480 Mbps – 10 Gbps| **< 0.5 ms** | Ricarica attiva (Zero consumo) | Cavo fisico | **Webcam 4K 60FPS senza compressione**, **File giganteschi** |

---

## 🧭 2. Matrice di Allocazione del Carico (Channel Allocation Matrix)

Ogni tipologia di payload viene instradata automaticamente sul canale più efficiente per garantire il miglior compromesso tra **latenza minima**, **affidabilità** e **risparmio batteria**:

```
+---------------------------------------------------------------------------------------------------+
| TIPO DI CARICO / DATO       | CANALE PRIMARIO               | CANALE DI FALLBACK  | OBIETTIVO LATENZA|
+---------------------------------------------------------------------------------------------------+
| 1. Presence / Proximity RSSI| BLE Advertisements            | mDNS Ping           | Non critico (1s) |
| 2. Remote Wakeup (iOS/Andr) | BLE GATT Notification         | Apple APNs / FCM    | < 200 ms         |
| 3. Input Mouse / Touchpad   | Wi-Fi QUIC Datagrams (UDP)    | BLE HID Profile     | < 5 ms           |
| 4. Audio Relay (PC -> Phone)| Wi-Fi QUIC Datagrams (Opus)   | Wi-Fi Direct        | < 20 ms          |
| 5. Media Handoff (URL & Time| Wi-Fi QUIC Reliable Stream    | BLE L2CAP CoC       | < 15 ms          |
| 6. Smart Clipboard (Testo)  | Wi-Fi QUIC Reliable Stream    | BLE Characteristic  | < 10 ms          |
| 7. File Transfer & Video 4K | Wi-Fi QUIC Multi-Stream       | USB Cable (se coll.)| Max Throughput   |
| 8. Continuity Camera 4K     | WebRTC (Wi-Fi 5/6 GHz)        | USB Localhost Port  | < 30 ms          |
+---------------------------------------------------------------------------------------------------+
```

---

## 🔄 3. Motore di Switching Dinamico Multi-Canale

Il sistema implementa una macchina a stati per la gestione trasparente della connettività (*Smart Connection Orchestrator*):

```mermaid
stateDiagram-v2
    [*] --> Standby_BLE: Dispositivo a schermo spento
    
    Standby_BLE --> Proximity_Trigger: Utente si avvicina (BLE RSSI > -65dBm)
    Proximity_Trigger --> Wi-Fi_LAN_Active: Connessione Wi-Fi LAN rilevata (QUIC 0-RTT)
    
    state Wi-Fi_LAN_Active {
        [*] --> Audio_Input_HighPriority
        Audio_Input_HighPriority --> Stream_File_Transfer: File avviato (Multiplexed)
    }

    Wi-Fi_LAN_Active --> Wi-Fi_Direct_Fallback: Nessun router disponibile (Off-grid)
    Wi-Fi_LAN_Active --> USB_Turbo_Mode: Cavo USB collegato (Switch automatico a 0ms)
    
    Wi-Fi_LAN_Active --> Standby_BLE: Dispositivo va in sleep / utente si allontana
```

### Logica di Failover Intelligente:
1. **Fase di Standby**: I dispositivi mantengono solo la radio BLE attiva per consumare zero batteria (< 0.5% l'ora).
2. **Fase di Risveglio**: Quando l'utente sblocca il telefono o si avvicina alla postazione, un pacchetto BLE riattiva istantaneamente il socket QUIC su Wi-Fi (latenza di riattivazione < 50ms).
3. **Modalità Senza Rete (Off-Grid)**: Se l'utente è in treno o in hotel senza Wi-Fi condiviso, i nodi negoziano via BLE l'apertura di un hotspot **Wi-Fi Direct / Apple Multipeer**, consentendo la condivisione file e la continuità video anche senza connessione internet.
4. **Turbo USB**: Se lo smartphone viene collegato via cavo al PC per ricarica, il daemon rileva la porta locale (via ADB / WinUSB / Usbmuxd) e commuta automaticamente lo streaming fotocamera 4K su cavo, azzerando completamente la latenza di rete e liberando banda radio.
