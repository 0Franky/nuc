# 01. Visione del Sistema & Analisi Comparativa

## 🌟 La Visione

Gli utenti moderni utilizzano quotidianamente molteplici dispositivi con sistemi operativi eterogenei: un PC desktop Windows o Linux per lavoro/gaming, un MacBook portatile, uno smartphone Android o iPhone, e tablet. 

L'obiettivo di questo progetto è **creare un tessuto connettivo unificato, locale, ultra-performante e sicuro** che permetta a tutti i dispositivi di un utente di comportarsi come un unico super-computer distribuito.

---

## 🔍 Analisi Comparativa: Dove falliscono le soluzioni attuali

### 1. Apple Continuity (Ecosistema Chiuso)
* **Punti di Forza**: UX rifinita, transizioni trasparenti (Universal Clipboard, Handoff, Continuity Camera, AirDrop, Universal Control).
* **Limiti Critici**:
  * **Walled Garden Totale**: Funziona **solo** se l'utente acquista al 100% hardware Apple. Basta avere un PC Windows o un telefono Android per rompere l'esperienza.
  * **Degrado Qualitativo Recente**: Frequenti disconnessioni nel passaggio automatico delle cuffie (AirPods), ritardi nel clipboard sync, blocchi di AirDrop.
  * **Zero Personalizzazione**: Impossibile decidere la priorità di switch audio o personalizzare i trigger di handoff.
  * **Dipendenza dal Cloud**: Molte sincronizzazioni passano per server iCloud anche quando i dispositivi sono sulla stessa scrivania.

### 2. KDE Connect (Open Source ma Datato)
* **Punti di Forza**: Open source, architettura decentralizzata basata su TLS/LAN, supporto Linux eccellente.
* **Limiti Critici**:
  * **Esperienza Frammentata**: Su macOS e iOS è fortemente limitato e instabile a causa di un'architettura non ottimizzata per i sandbox moderni di Apple.
  * **Nessun Media Handoff Intelligente**: Non supporta il passaggio di flussi video da browser (es. YouTube al minuto esatto), ma solo comandi multimediali generici (Play/Pause).
  * **Nessun Audio Relay / Streaming a Bassa Latenza**: Non permette di catturare l'audio di sistema del PC e ascoltarlo sullo smartphone in cuffia.
  * **Interfaccia e UX Datata**: Poco intuitiva per l'utente comune, assenza di integrazione con Live Activities / Dynamic Island o moderni pop-up di sistema.

### 3. LocalSend (Ottimo ma Mono-Funzione)
* **Punti di Forza**: Multipiattaforma perfetto (Flutter), zero configurazione, codice pulito.
* **Limiti**: Fa esclusivamente trasferimento file in LAN, non gestisce input, audio, clipboard dinamico o handoff multimediale.

---

## 🏆 I 5 Pilastri del Nostro Sistema

```
+-------------------------------------------------------------------------------+
|                             I 5 PILASTRI FONDAMENTALI                         |
+-------------------------------------------------------------------------------+
| 1. ZERO-CLOUD & 100% LOCALE | LAN (Wi-Fi), BLE e P2P. Nessun dato sui server. |
| 2. VERO CROSS-PLATFORM      | Windows, macOS, Linux, Android, iOS alla pari.  |
| 3. ARCHITETTURA A CAPACITÀ  | Ogni nodo espone servizi; il richiedente non    |
|                             | conta. Modulare e orientato a plugin.           |
| 4. ULTRA-LOW LATENCY (<30ms)| Audio Opus e Input diretti via QUIC/WebRTC.     |
| 5. SMART PROXIMITY ENGINE   | Trigger basati su presenza fisica reale (BLE).  |
+-------------------------------------------------------------------------------+
```

1. **Privacy-First & Local-First**: Tutto il traffico viaggia crittografato (Noise Protocol E2EE) sulla rete locale e via Bluetooth. Nessun account cloud obbligatorio, nessun abbonamento.
2. **Mentalità a Capacità / Micro-Servizi**: Un'architettura basata su *Capability Providers*. Se un dispositivo dispone di uno schermo, registra la capacità `DisplaySink`; se ha altoparlanti, `AudioSink`; se ha tastiera/mouse, `InputSource`.
3. **Smart Presence**: Utilizzo combinato di Bluetooth Low Energy (RSSI) e segnale Wi-Fi per capire la vicinanza fisica dell'utente (es. se ti alzi dalla scrivania con lo smartphone, il PC lo sa istantaneamente).
4. **Continuity Universale dei Media**: Cattura intelligente di schede browser e player desktop con ripresa istantanea al millisecondo su mobile e viceversa.
5. **Private Listening & Audio Forwarding**: Possibilità di reindirizzare l'audio del computer sullo smartphone (o viceversa) con latenza impercettibile per l'ascolto notturno o in mobilità.
