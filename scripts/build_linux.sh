#!/usr/bin/env bash
set -e

echo "====================================================="
echo "   Nexus Universal Continuity - Linux Build Script   "
echo "====================================================="

# 1. Compile Rust Workspace in Release Mode
echo -e "\n[1/3] Compiling Rust Workspace in Release Mode..."
cargo build --workspace --release

# 2. Setup Distribution Directory
DIST_DIR="$(dirname "$0")/../dist/linux"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

cp "$(dirname "$0")/../target/release/nexus-daemon" "$DIST_DIR/"
cp "$(dirname "$0")/../target/release/libnexus_ffi.so" "$DIST_DIR/"

# 3. Compile Flutter Linux Application
echo -e "\n[2/3] Building Flutter Linux App..."
cd "$(dirname "$0")/../apps/nexus_ui"
flutter build linux --release

if [ -d "build/linux/x64/release/bundle" ]; then
    cp -r build/linux/x64/release/bundle/* "$DIST_DIR/"
    cp "$(dirname "$0")/../../target/release/libnexus_ffi.so" "$DIST_DIR/lib/"
fi

echo -e "\n[3/3] Build Completed Successfully!"
echo "Distribution directory: $DIST_DIR"
