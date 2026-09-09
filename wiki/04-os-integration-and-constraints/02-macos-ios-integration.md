# 02. Integrazione macOS & iOS (Sandbox & Vincoli Apple)

I sistemi operativi di Apple impongono rigide restrizioni di sicurezza (Sandbox, permessi di accessibilità e limiti di background su iOS). Questo documento descrive le strategie implementate per superare questi vincoli.

---

## 🍏 1. Integrazione macOS

### A. Permessi di Accessibilità per Controllo Cursore/Tastiera
* Su macOS, un'applicazione non può iniettare eventi di mouse o tastiera senza il consenso dell'utente.
* **Verifica**: `AXIsProcessTrustedWithOptions()`.
* **Iniezione Eventi**: `CGEventCreateMouseEvent()`, `CGEventPost(kCGHIDEventTap, event)`. Se il permesso non è concesso, l'app guida l'utente nelle *Preferenze di Sistema -> Privacy e Sicurezza -> Accessibilità*.

### B. Audio Capture su macOS
* A partire da macOS 13+, è possibile utilizzare l'API ufficiale **ScreenCaptureKit** (`SCStreamConfiguration.capturesAudio = true`) per catturare l'audio di sistema senza installare estensioni kext o driver virtuali terzi (come Soundflower o BlackHole).

### C. Gestione Background su macOS
* Il daemon viene registrato come `LaunchAgent` utente in `~/Library/LaunchAgents/com.nexus.daemon.plist`, assicurando l'avvio silenzioso al login.

---

## 📱 2. Integrazione iOS (Gestione dei Limiti di Background)

iOS sospende automaticamente le applicazioni in background dopo circa 30 secondi. Per mantenere la continuità attiva:

### A. Dynamic Island & Live Activities (ActivityKit)
* Quando sul PC o sulla TV è in riproduzione un video o un flusso audio, l'app iOS avvia una **Live Activity**:
  - La **Dynamic Island** mostra l'icona del video in riproduzione e il minutaggio.
  - Con un tap sulla Dynamic Island o dalla Lock Screen, l'utente può trasferire istantaneamente il video su iPhone o mettere in pausa il PC.

### B. Risveglio via BLE (CoreBluetooth State Restoration)
* L'app iOS registra il proprio `CBCentralManager` e `CBPeripheralManager` con chiavi di *State Restoration*.
* Quando il PC emette un beacon BLE di prossimità o di handoff urgente, iOS risveglia l'app in background per elaborare l'evento e notificare l'utente.

### C. Modalità Audio Background
* Durante la sessione di **Private Listening** (ascolto dell'audio del PC nelle cuffie dell'iPhone), l'app attiva la categoria `AVAudioSessionCategoryPlayback` con modalità `AVAudioSessionModeSpokenAudio/Default`, garantendo l'ascolto continuo a schermo spento senza interruzioni.
