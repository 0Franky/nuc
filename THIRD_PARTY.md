# Native input companion

Nexus runs LAN Mouse as a separate process for global mouse/keyboard capture, emulation and DTLS input transport. It is not linked into Nexus Rust or Dart libraries.

- Upstream: https://github.com/feschber/lan-mouse
- Base version: 0.11.0, revision `00c5eee8d8f8fa8ff0138fc4d9c9731d06e82456`.
- License: GPL-3.0-or-later. Preserve the bundled `LICENSE-LAN-MOUSE`, `SOURCE.txt` and `lan-mouse-source.zip` when distributing `input-engine`.
- Rebuild: `python scripts/build_input_backend.py --dest dist/windows/input-engine` (on Linux use `python3` and `dist/linux/input-engine`).
- Linux build dependencies and supported desktop environments: upstream README and source archive. This revision supports capture on supported Wayland compositors; X11 is receiving-only. Nexus reports backend failure instead of using the upstream dummy backend.

Keyboard/mouse data uses the companion's DTLS connection on UDP 4243. Nexus discovery is a separate channel and is not described as encrypted by this integration. Approve the displayed certificate fingerprint on each PC; an advertised fingerprint alone does not authorize input.

The reviewed Nexus patch in `scripts/patches/lan-mouse-destination-pin.patch` pins the outbound DTLS certificate to the approved destination endpoint before sending input. The distributed source archive includes the patched files and patch. `nexus-input-host` supervises process lifetime; keys are never logged or forwarded through Flutter.
