# 01. Integrazione Nativa Windows

Questo documento specifica i punti di aggancio con le API di sistema di Windows 10/11 per garantire prestazioni native e affidabilità.

---

## 🔊 1. Audio Loopback (WASAPI)

Per catturare l'audio di sistema in tempo reale senza dover installare driver di terze parti (come *Virtual Audio Cable*):
* Utilizzo delle API **WASAPI (Windows Audio Session API)** in modalità **Loopback Capture**:
  ```cpp
  IAudioClient::Initialize(
      AUDCLNT_SHAREMODE_SHARED,
      AUDCLNT_STREAMFLAGS_LOOPBACK, // Cattura tutto ciò che va agli speaker
      100000,                       // Buffer 10ms
      0,
      pWaveFormat,
      NULL
  );
  ```
* I campioni PCM a 32-bit float vengono inviati direttamente all'encoder Opus in Rust con latenza < 3ms.

---

## 📺 2. Controllo Multimediale (Windows SMTC)

Windows espone il gestore globale delle sessioni multimediali tramite WinRT:
* **API**: `Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager`
* Permette di:
  - Ricevere eventi quando Spotify, Edge, Chrome, VLC o Apple Music cambiano traccia.
  - Leggere titolo, autore, album e copertina (thumbnail).
  - Inviare comandi remoti: `TryPlayAsync()`, `TryPauseAsync()`, `TrySkipNextAsync()`, `TryChangePlaybackPositionAsync()`.

---

## 🖱️ 3. Simulazione Input & Controllo Cursore

* **API**: `SendInput` (Win32 User32) con calcolo delle coordinate assolute rispetto al Virtual Screen Desktop (`GetSystemMetrics(SM_CXVIRTUALSCREEN)`).
* Gestione di accelerazione mouse, scroll ad alta risoluzione (`WHEEL_DELTA`), click destro/centrale e tasti modificatori (`VK_LCONTROL`, `VK_LMENU`, `VK_LWIN`).

---

## ⚙️ 4. Esecuzione in Background & Autostart

* **Architettura**:
  - `nexus_daemon.exe`: Processo di background leggero registrato nella chiave di registro `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` o come Windows Service utente.
  - Icona nell'Area di Notifica (System Tray) con menu contestuale per stato di connessione, switch rapido cuffie e pausa sincronizzazione.
* **Firewall Rules**: Lo script di installazione configura automaticamente l'apertura delle porte UDP/QUIC tramite `netsh advfirewall firewall add rule`.
