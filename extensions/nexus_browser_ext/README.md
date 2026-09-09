# Nexus Universal Continuity - Browser Extension (Manifest V3)

Estensione browser WebExtension per Google Chrome, Microsoft Edge, Brave, e Mozilla Firefox che permette la continuità video e multimediale istantanea tra computer, smartphone e tablet.

---

## 🎯 Funzionalità

* **Tracciamento Video YouTube & HTML5**: Intercetta automaticamente l'URL, il titolo e il timestamp esatto al millisecondo della riproduzione in corso.
* **Handoff Bidirezionale**: Consente di trasferire il video al telefono ("Riprendi su smartphone") o di riprendere sul PC un video avviato dal telefono.
* **Controllo Remoto**: Supporta comandi di Play, Pausa e Seek inviati a distanza dall'app Nexus.
* **Connessione Locale Sicura**: Comunica direttamente con il daemon locale Nexus via WebSocket su `127.0.0.1:28471/media` a zero latenza e senza cloud.

---

## 📦 Installazione Rapida

1. Apri il browser su `chrome://extensions` (Chrome/Brave) o `edge://extensions` (Edge).
2. Attiva la **Modalità sviluppatore** in alto a destra.
3. Clicca su **Carica estensione non compattata** (Load unpacked) e seleziona questa cartella:
   ```
   extensions/nexus_browser_ext
   ```
4. L'estensione sarà attiva e si collegherà automaticamente al background daemon Nexus.
