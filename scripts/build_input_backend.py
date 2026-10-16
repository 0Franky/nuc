#!/usr/bin/env python3
"""Build and bundle the pinned, separate LAN Mouse input process (no GTK)."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile

REVISION = "00c5eee8d8f8fa8ff0138fc4d9c9731d06e82456"
URL = "https://github.com/feschber/lan-mouse.git"
ROOT = Path(__file__).resolve().parents[1]


def run(*args, cwd=None):
    subprocess.run(args, cwd=cwd, check=True)



def apply_reviewed_patches(source, patches):
    """Upgrade only exact reviewed patch prefixes, without discarding local work."""
    if subprocess.check_output(["git", "diff", "--cached"], cwd=source):
        raise SystemExit("Unexpected staged changes in input-engine source")
    if subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard"], cwd=source).strip():
        raise SystemExit("Unexpected untracked files in input-engine source")
    def diff(*extra, env=None):
        return subprocess.check_output(
            ["git", "diff", "--no-ext-diff", "--no-textconv", "--binary", "--full-index", *extra, "HEAD"],
            cwd=source, env=env).replace(b"\r\n", b"\n")
    actual = diff()
    prefixes = []
    with tempfile.TemporaryDirectory(prefix="nexus-patch-index-") as directory:
        env = dict(os.environ, GIT_INDEX_FILE=str(Path(directory) / "index"))
        subprocess.run(["git", "read-tree", "HEAD"], cwd=source, env=env, check=True)
        prefixes.append(diff("--cached", env=env))
        for patch in patches:
            subprocess.run(["git", "apply", "--cached", str(patch)], cwd=source, env=env, check=True)
            prefixes.append(diff("--cached", env=env))
    if actual not in prefixes:
        raise SystemExit("Input-engine source differs from the reviewed Nexus patch series; local changes preserved")
    applied = prefixes.index(actual)
    for patch in patches[applied:]:
        run("git", "apply", "--check", str(patch), cwd=source)
        run("git", "apply", str(patch), cwd=source)
    if diff() != prefixes[-1]:
        raise SystemExit("Input-engine patch verification failed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="Existing checkout of the exact pinned revision")
    parser.add_argument("--dest", type=Path, required=True, help="Destination input-engine directory")
    parser.add_argument("--prepare-only", action="store_true", help="Verify/apply reviewed patches without compiling")
    args = parser.parse_args()
    source = args.source or ROOT / "target" / "input-engine-source"
    if not source.exists():
        run("git", "clone", "--no-checkout", URL, str(source))
        run("git", "checkout", "--detach", REVISION, cwd=source)
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if revision != REVISION:
        raise SystemExit("Unexpected input-engine revision; refusing an unpinned build")
    patches = [ROOT / "scripts/patches" / name for name in (
        "lan-mouse-destination-pin.patch", "lan-mouse-runtime.patch",
    )]
    apply_reviewed_patches(source, patches)
    if args.prepare_only:
        print("Input-engine checkout matches the reviewed patch series")
        return
    cargo = os.environ.get("NEXUS_CARGO", "cargo")
    command = [cargo, "build", "--release", "--locked", "--no-default-features"]
    if sys.platform.startswith("linux"):
        command += ["--features", "layer_shell_capture,libei_capture,wlroots_emulation,libei_emulation,rdp_emulation,x11_emulation"]
    elif sys.platform != "win32":
        raise SystemExit("This package currently targets Windows and Linux")
    run(*command, cwd=source)
    args.dest.mkdir(parents=True, exist_ok=True)
    binary = "lan-mouse.exe" if sys.platform == "win32" else "lan-mouse"
    source_target = Path(json.loads(subprocess.check_output(
        [cargo, "metadata", "--format-version", "1", "--no-deps"], cwd=source))["target_directory"])
    shutil.copy2(source_target / "release" / binary, args.dest / binary)
    supervisor = "nexus-input-host.exe" if sys.platform == "win32" else "nexus-input-host"
    run(cargo, "build", "--release", "--bin", "nexus-input-host", cwd=ROOT)
    root_target = Path(json.loads(subprocess.check_output(
        [cargo, "metadata", "--format-version", "1", "--no-deps"], cwd=ROOT))["target_directory"])
    shutil.copy2(root_target / "release" / supervisor, args.dest / supervisor)
    shutil.copy2(source / "LICENSE", args.dest / "LICENSE-LAN-MOUSE")
    tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=source).decode().split("\0")
    with zipfile.ZipFile(args.dest / "lan-mouse-source.zip", "w", zipfile.ZIP_DEFLATED) as archive:
        for name in filter(None, tracked):
            if (source / name).is_file():
                archive.write(source / name, name)
        for patch in patches:
            archive.write(patch, f"NEXUS-PATCHES/{patch.name}")
    (args.dest / "SOURCE.txt").write_text(f"LAN Mouse 0.11.0\n{URL}\nRevision: {REVISION} + Nexus destination-pin and runtime patches (NEXUS-PATCHES in source archive)\nGPL-3.0-or-later; separate process managed by Nexus.\nBuild: cargo build --release --locked --no-default-features\nLinux: enable layer_shell_capture,libei_capture,wlroots_emulation,libei_emulation,rdp_emulation,x11_emulation.\n", encoding="utf-8")
    print(f"Input engine available at {args.dest}")


if __name__ == "__main__":
    main()
