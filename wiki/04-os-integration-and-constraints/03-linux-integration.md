# 03. Integrazione Nativa Linux

> Le sezioni architetturali sotto descrivono anche obiettivi progettuali, non una
> verifica di tutte le funzionalità implementate. Per lo stato effettivo e i test:
> [registro operativo](../2026-09-10-topology-linux-validation.md).

## Avvio desktop dal repository

Usare `bash scripts/nexus-run`. Il launcher non dipende da percorsi personali:
aggiorna con fast-forward, compila il pacchetto completo e avvia `dist/linux/nexus_ui`.
Per usare i sorgenti locali: `bash scripts/nexus-run --no-update`.
Per avviare senza ricompilare: `bash scripts/nexus-run --no-update --no-build`.
L’app incorpora già il core Rust tramite FFI: non avviare contemporaneamente il servizio
headless riportato come esempio più sotto. Il launcher segnala se quel servizio è attivo.

Prerequisiti Ubuntu/Debian per la build (oltre a Flutter >= 3.47.2, Rust/Cargo e Python 3):

```sh
sudo apt install git clang cmake ninja-build pkg-config libgtk-3-dev \
  libayatana-appindicator3-dev libx11-dev libxtst-dev libxkbcommon-dev \
  libwayland-dev libssl-dev
```

`input-engine/lan-mouse` e `input-engine/nexus-input-host` devono essere accanto
all’eseguibile Flutter. Lo script di build e CMake controllano e includono entrambi;
copiare il solo eseguibile o la sola libreria FFI produce un pacchetto incompleto.
Python serve in fase di build, non come demone runtime. Conservare sorgenti e licenza
inclusi nella cartella input-engine.

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

## Aggiornamento BLE e input Wayland

Lo scanner BlueZ richiede `libdbus-1-dev` per compilare. Per il touchpad Wayland serve
un portale desktop che implementi RemoteDesktop (GNOME/KDE); non serve ydotoold.
Vedi [revisione e test](../2026-09-10-proximity-input-review.md).
