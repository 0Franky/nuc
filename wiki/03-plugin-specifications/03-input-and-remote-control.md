# 03. Input Bridge & Remote Control

Il plugin **Input Bridge** trasforma qualsiasi smartphone o tablet in un controller remoto ad alta precisione e consente la condivisione trasparente di mouse e tastiera tra dispositivi diversi (simile ad *Apple Universal Control* e *Barrier/Synergy*).

---

## 🖱️ 1. Modalità Trackpad & Telecomando

La schermata dell'app mobile offre un trackpad virtuale ultra-reattivo con feedback aptico:

```
+-------------------------------------------------------------+
| [Esc]  [Tab]  [Ctrl]  [Alt]  [Win/Cmd]  [Fn]  [⌨️ Tastiera] |
+-------------------------------------------------------------+
|                                                             |
|                                                             |
|                    AREA TRACKPAD TOUCH                      |
|                                                             |
|  - 1 dito: Movimento puntatore fluido                       |
|  - Tap singolo: Click sinistro                              |
|  - Tap 2 dita: Click destro                                 |
|  - Swipe 2 dita: Scroll verticale / orizzontale             |
|  - Swipe 3 dita: Switch finestre (Alt+Tab / Task View)      |
|                                                             |
+-------------------------------------------------------------+
| 🔉 [ -- Slider Volume Master -- ] 🔊   [ ⏯️ ]  [ ⏹️ ]  [ ⏭️ ] |
+-------------------------------------------------------------+
```

### Protocollo Input a Bassa Latenza:
I pacchetti touch vengono inviati tramite **QUIC Unreliable Datagrams** per garantire una latenza inferiore a **3-5 millisecondi**:

```protobuf
message InputEventPacket {
  enum EventType {
    MOUSE_MOVE_RELATIVE = 0;
    MOUSE_SCROLL = 1;
    MOUSE_BUTTON = 2;
    KEY_EVENT = 3;
    MEDIA_COMMAND = 4;
  }
  
  EventType type = 1;
  int32 dx = 2;              // Spostamento X
  int32 dy = 3;              // Spostamento Y
  uint32 button_mask = 4;    // 1=Left, 2=Right, 4=Middle
  uint32 keycode = 5;        // Scancode tastiera
  bool is_down = 6;
}
```

---

## 🎯 2. Gyroscope Presentation Pointer (Puntatore Laser)

Utilizzando l'IMU (Accelerometro + Giroscopio a 6 assi) dello smartphone:
* Tenendo premuto un pulsante a schermo, muovere il telefono nello spazio muove un **puntatore laser virtuale semi-trasparente** proiettato sopra qualsiasi finestra su PC (PowerPoint, Keynote, browser, PDF).
* Include tasti rapidi: *Slide Successiva*, *Slide Precedente*, *Schermo Nero*.

---

## 🖥️ 3. Seamless Border Cursor (Universal Control Cross-Platform)

Simile ad Apple Universal Control ma compatibile tra **qualsiasi combinazione di OS (es. PC Windows <-> MacBook <-> Tablet Android)**:
1. Posizioni i monitor fisici e i dispositivi nella mappa virtuale delle impostazioni (es. Tablet Android a sinistra del monitor Windows).
2. Muovendo il mouse fisico del PC oltre il bordo sinistro del monitor, il cursore "esce" dallo schermo del PC e "entra" nello schermo del dispositivo adiacente.
3. La tastiera fisica del PC digita automaticamente sul dispositivo dove si trova il cursore.
