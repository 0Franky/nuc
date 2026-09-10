#!/usr/bin/env bash
# Run in a disposable X11 session, e.g. xvfb-run -a dbus-run-session -- bash this-script.
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="${1:-$ROOT_DIR/dist/linux}"
: "${DISPLAY:?Run in an isolated X11 session with xvfb-run}"
WORK="$(mktemp -d /var/tmp/nexus-bundle-check.XXXXXX)"
export XDG_CONFIG_HOME="$WORK/config" XDG_DATA_HOME="$WORK/data" XDG_RUNTIME_DIR="$WORK/runtime"
export XDG_SESSION_TYPE=x11
unset WAYLAND_DISPLAY
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
for binary in nexus_ui lib/libnexus_ffi.so input-engine/lan-mouse input-engine/nexus-input-host; do
  test -f "$BUNDLE/$binary" || { echo "Missing: $binary"; exit 1; }
  if ldd "$BUNDLE/$binary" | grep -q 'not found'; then echo "Unresolved libraries: $binary"; exit 1; fi
done
python3 "$ROOT_DIR/scripts/check_input_backend.py" "$BUNDLE/input-engine" "$WORK"
if [ "$BUNDLE" = "$ROOT_DIR/dist/linux" ]; then
  NEXUS_DIR="$ROOT_DIR" bash "$ROOT_DIR/scripts/nexus-run" --no-update --no-build > "$WORK/app.log" 2>&1 &
else
  "$BUNDLE/nexus_ui" > "$WORK/app.log" 2>&1 &
fi
APP_PID=$!
trap 'kill "$APP_PID" 2>/dev/null || true; wait "$APP_PID" 2>/dev/null || true' EXIT
VISIBLE=0
for attempt in $(seq 1 80); do
  if ! kill -0 "$APP_PID" 2>/dev/null; then cat "$WORK/app.log"; exit 1; fi
  if xdotool search --onlyvisible --pid "$APP_PID" >/dev/null 2>&1; then VISIBLE=1; break; fi
  sleep 0.1
done
if [ "$VISIBLE" != 1 ]; then cat "$WORK/app.log"; echo "No visible application window"; exit 1; fi
sleep 2
kill -0 "$APP_PID"
if grep -E 'Unhandled Exception|Failed to load.*libnexus|Native FFI init non-fatal|Native DLL not available|Could not load' "$WORK/app.log"; then exit 1; fi
if ! grep -F '[FFI] Successfully loaded native library' "$WORK/app.log"; then
  cat "$WORK/app.log"; echo "Native FFI loading was not confirmed"; exit 1
fi
echo "PASS: Linux bundle libraries, backend IPC/lifecycle, visible Flutter window. Logs: $WORK"
