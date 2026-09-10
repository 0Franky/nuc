#!/usr/bin/env python3
"""Exercise real companion IPC and supervisor shutdown without input clients."""
import argparse
import json
from pathlib import Path
import re
import socket
import subprocess
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("work", type=Path)
    args = parser.parse_args()
    bundle = args.bundle.resolve()
    work = args.work.resolve() / ("input-check-" + uuid.uuid4().hex)
    work.mkdir(parents=True)
    config = work / "config.toml"
    config.write_text('port = 4243\n[authorized_fingerprints]\n', encoding="utf-8")
    for crash in (False, True):
        try:
            existing = socket.create_connection(("127.0.0.1", 5252), timeout=.2)
        except OSError:
            pass
        else:
            existing.close()
            raise RuntimeError("An input engine is already running; no test started")
        process = subprocess.Popen([str(bundle / "nexus-input-host.exe"), str(bundle / "lan-mouse.exe"),
            "--config", str(config), "--cert-path", str(work / "identity.pem"), "daemon"],
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
            creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            process.stdin.write(b"\n"); process.stdin.flush()
            connection = None
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError(process.stderr.read().decode(errors="replace"))
                try:
                    connection = socket.create_connection(("127.0.0.1", 5252), timeout=.2)
                    break
                except OSError:
                    time.sleep(.1)
            assert connection is not None, "IPC did not start"
            connection.settimeout(6)
            connection.sendall(b'"Sync"\n')
            states = {}
            with connection, connection.makefile("r", encoding="utf-8") as events:
                while not all(k in states for k in ("PublicKeyFingerprint", "CaptureStatus", "EmulationStatus")):
                    line = events.readline()
                    assert line, "IPC closed before reporting state"
                    event = json.loads(line)
                    if isinstance(event, dict):
                        states.update(event)
                assert re.fullmatch(r"(?:[0-9a-f]{2}:){31}[0-9a-f]{2}", states["PublicKeyFingerprint"])
                # Enable events can arrive after the first sync snapshot.
                while states.get("CaptureStatus") != "Enabled" or states.get("EmulationStatus") != "Enabled":
                    event = json.loads(events.readline())
                    if isinstance(event, dict): states.update(event)
            if crash:
                process.kill()  # Windows job must also terminate the native child.
            else:
                process.stdin.close()  # Simulates Nexus closing or crashing.
            process.wait(timeout=5)
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                try:
                    probe = socket.create_connection(("127.0.0.1", 5252), timeout=.2)
                except OSError:
                    break
                probe.close(); time.sleep(.1)
            else:
                raise AssertionError("Input engine survived its supervisor")
            print("PASS: native IPC, capture/emulation readiness, " + ("supervisor crash cleanup" if crash else "parent EOF cleanup"))
        finally:
            if process.poll() is None:
                process.kill(); process.wait(timeout=5)


if __name__ == "__main__":
    main()
