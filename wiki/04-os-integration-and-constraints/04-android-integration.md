# 04. Integrazione Nativa Android

Android offre grande flessibilità per l'integrazione a basso livello, ma richiede strategie mirate per gestire il risparmio energetico (*Doze Mode*) e le restrizioni dei diversi produttori (Samsung, Xiaomi, Pixel).

---

## 🔋 1. Foreground Service & Ottimizzazione Batteria

Per evitare che il sistema operativo uccida il socket di sincronizzazione:
1. **Foreground Service Persistente**:
   - Avvio di un servizio di primo piano con notifica discreta e personalizzabile (mostra lo stato della connessione e il dispositivo attualmente accoppiato).
   - Richiesta dell'eccezione all'ottimizzazione della batteria (`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`).
2. **Supporto WakeLock Intelligente**: Acquisizione del `PARTIAL_WAKE_LOCK` solo durante il trasferimento attivo di file o lo streaming audio/video.

---

## 🎧 2. Audio Engine a Bassa Latenza (AAudio / Oboe)

* L'app Android integra la libreria nativa C++/Rust collegata al motore **AAudio** (o Google Oboe):
  - Modalità `AAUDIO_PERFORMANCE_MODE_LOW_LATENCY`.
  - Dimensione del buffer impostata al burst rate nativo dell'hardware (solitamente 96 o 192 campioni).
  - Questo garantisce una riproduzione dell'audio proveniente dal PC con **meno di 10ms di ritardo interno** all'hardware dello smartphone.

---

## 🔔 3. Accesso Notifiche & MediaSession

* **`NotificationListenerService`**:
  - Consente di leggere le notifiche in arrivo (es. messaggi WhatsApp o SMS) per visualizzarle sul PC con possibilità di risposta rapida inline.
* **`MediaSessionManager`**:
  - Rileva qualsiasi app multimediale attiva su Android (Spotify, YouTube Music, Pocket Casts) per consentire il controllo del volume e delle tracce direttamente dal PC.

---

## 🚀 4. Esecuzione Intent per Video Handoff

Quando dal PC si comanda l'apertura di un video sullo smartphone:
```kotlin
val intent = Intent(Intent.ACTION_VIEW, Uri.parse(videoUrl)).apply {
    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
}
// Se è un video YouTube, indirizza direttamente all'app ufficiale
if (videoUrl.contains("youtube.com") || videoUrl.contains("youtu.be")) {
    intent.`package` = "com.google.android.youtube"
}
context.startActivity(intent)
```
Se l'app ufficiale non è installata, il fallback apre automaticamente il browser predefinito.
