#!/usr/bin/env bash
set -euo pipefail
if [[ "${XDG_SESSION_TYPE:-}" == "wayland" || -n "${WAYLAND_DISPLAY:-}" ]]; then
  command -v ydotool >/dev/null || { echo "Install ydotool >= 1.0 and configure ydotoold for your desktop user." >&2; exit 1; }
  ydotool mousemove -x 0 -y 0 || { echo "Check ydotoold, /dev/uinput permissions and YDOTOOL_SOCKET." >&2; exit 1; }
  echo "Wayland input backend reachable. Verify movement from the phone on the actual desktop."
elif [[ -n "${DISPLAY:-}" ]]; then
  command -v xdotool >/dev/null || { echo "Install xdotool for X11 input." >&2; exit 1; }
  xdotool getmouselocation >/dev/null
  echo "X11 input backend reachable."
else
  echo "No desktop session detected. Run Nexus as the logged-in desktop user with its display environment." >&2
  exit 1
fi
