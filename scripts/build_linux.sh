#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist/linux"
[ ! -f "$HOME/.cargo/env" ] || source "$HOME/.cargo/env"
for tool in cargo flutter python3 git cmake ninja clang pkg-config; do
  command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
for package in gtk+-3.0 x11 xtst xkbcommon wayland-client dbus-1; do
  pkg-config --exists "$package" || { echo "Missing native development package: $package. See wiki/04-os-integration-and-constraints/03-linux-integration.md" >&2; exit 1; }
done
if ! pkg-config --exists ayatana-appindicator3-0.1 && ! pkg-config --exists appindicator3-0.1; then
  echo "Missing tray development library: install libayatana-appindicator3-dev" >&2
  exit 1
fi
cargo build --manifest-path "$ROOT_DIR/Cargo.toml" --workspace --release
TARGET_DIR="$(cargo metadata --manifest-path "$ROOT_DIR/Cargo.toml" --format-version 1 --no-deps | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
mkdir -p "$ROOT_DIR/target/release"
if [ "$(realpath "$TARGET_DIR")" != "$(realpath "$ROOT_DIR/target")" ]; then
  cp "$TARGET_DIR/release/libnexus_ffi.so" "$ROOT_DIR/target/release/"
fi
# Build both Rust executables BEFORE Flutter packages the application.
python3 "$ROOT_DIR/scripts/build_input_backend.py" --dest "$ROOT_DIR/target/input-engine"
(cd "$ROOT_DIR/apps/nexus_ui" && flutter pub get --enforce-lockfile && flutter build linux --release)
BUNDLE_DIR="$ROOT_DIR/apps/nexus_ui/build/linux/x64/release/bundle"
for binary in nexus_ui input-engine/lan-mouse input-engine/nexus-input-host; do
  test -x "$BUNDLE_DIR/$binary" || { echo "Incomplete Linux bundle: $binary" >&2; exit 1; }
done
mkdir -p "$DIST_DIR"
cp -a "$BUNDLE_DIR/." "$DIST_DIR/"
cp "$TARGET_DIR/release/nexus-daemon" "$DIST_DIR/"
printf '%s
' "$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || echo source-build)" > "$DIST_DIR/BUILD.txt"
echo "Complete Linux application: $DIST_DIR/nexus_ui"
