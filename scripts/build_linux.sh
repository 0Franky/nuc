#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist/linux"

cargo build --manifest-path "$ROOT_DIR/Cargo.toml" --workspace --release
(cd "$ROOT_DIR/apps/nexus_ui" && flutter build linux --release)
BUNDLE_DIR="$ROOT_DIR/apps/nexus_ui/build/linux/x64/release/bundle"
test -f "$BUNDLE_DIR/nexus_ui"
test -f "$ROOT_DIR/target/release/libnexus_ffi.so"
mkdir -p "$DIST_DIR/lib"
cp -a "$BUNDLE_DIR/." "$DIST_DIR/"
cp "$ROOT_DIR/target/release/nexus-daemon" "$DIST_DIR/"
cp "$ROOT_DIR/target/release/libnexus_ffi.so" "$DIST_DIR/lib/"
python3 "$ROOT_DIR/scripts/build_input_backend.py" --dest "$DIST_DIR/input-engine"

echo "Linux build available in $DIST_DIR"
echo "Before remote input, run: $ROOT_DIR/scripts/check_linux_input.sh"
