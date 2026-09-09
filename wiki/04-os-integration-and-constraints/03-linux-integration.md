# 03. Integrazione Nativa Linux

Su distribuzioni Linux moderne (Ubuntu, Fedora, Arch, Debian), il supporto alle tecnologie di nuova generazione come **PipeWire** e **Wayland** è prioritario.

---

## 🎵 1. Audio Subsystem (PipeWire & PulseAudio)

* **PipeWire Nativo**: Creazione di un nodo virtuale di cattura (*Stream Node*) collegato al target `Sink.monitor` per catturare l'audio di tutte le applicazioni con latenza sub-millisecondo.
* **PulseAudio Fallback**: Connessione al monitor source predefinito (`pacat` / `libpulse-simple`).

---

## 🖱️ 2. Simulazione Input: Wayland vs X11

Una delle difficoltà storiche su Linux è l'impossibilità su Wayland di iniettare input tramite `XTestFakeKeyEvent`. Il nostro approccio adotta due soluzioni robuste:

1. **Kernel `uinput` (Soluzione Primaria a Prestazioni Massime)**:
   - Il daemon crea un device virtuale `/dev/uinput` a livello kernel (configurato tramite regola udev in `/etc/udev/rules.d/99-nexus-input.rules`).
   - Funziona in modo trasparente e identico sia su **X11** che su **Wayland (GNOME, KDE Plasma, Sway, Hyprland)**.
2. **XDG Desktop Portal (Fallback)**:
   - Invocazione dell'interfaccia D-Bus `org.freedesktop.portal.RemoteDesktop` per sessioni sandbox Flatpak.

---

## 📺 3. Controllo Multimediale (D-Bus MPRIS2)

Linux dispone del miglior standard di controllo multimediale al mondo (**MPRIS2**). Il plugin monitora i servizi D-Bus:
* `org.mpris.MediaPlayer2.*` (VLC, Spotify, Firefox, Chromium, MPV, Rhythmbox).
* Permette di leggere la proprietà `org.mpris.MediaPlayer2.Player.Metadata` e catturare URL, artista, traccia e la posizione esatta con il metodo `Position`.

---

## ⚙️ 4. Gestione Servizio Utente (systemd)

Il daemon viene gestito tramite un'unità systemd utente:

```ini
# ~/.config/systemd/user/nexus-daemon.service
[Unit]
Description=Nexus Universal Continuity Core Daemon
After=network.target sound.target

[Service]
ExecStart=/usr/bin/nexus-daemon --headless
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
```
Abilitabile con `systemctl --user enable --now nexus-daemon`.
