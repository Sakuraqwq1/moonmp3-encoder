#!/usr/bin/env python3
"""Check that this machine can build, encode and verify the project.

Run this before a debugging session. It answers four questions:

1. Is the MoonBit toolchain reachable and which version is it?
2. Is the Python side present (numpy, soundfile, libsndfile)?
3. Does libsndfile expose an MP3 decoder?
4. Are the deterministic fixtures present?

Exit code 0 means no blocking problem; warnings do not fail the run.
"""

from __future__ import annotations

import importlib.metadata
import json
import os
import subprocess
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, TOOLS)

import mp3lab


def status(name: str, ok: bool, detail: str, blocking: bool = True) -> bool:
    label = "ok  " if ok else ("FAIL" if blocking else "warn")
    print(f"[{label}] {name}: {detail}")
    return ok or not blocking


def main() -> int:
    failures = 0
    warnings = 0

    print(f"repository: {ROOT}")
    print(f"python    : {sys.version.split()[0]}")

    try:
        moon = mp3lab.find_moon()
        if not status("moon path", True, moon):
            failures += 1
        try:
            proc = subprocess.run([moon, "version", "--all"], capture_output=True, text=True, timeout=60)
            detail = " | ".join(line.strip() for line in (proc.stdout or proc.stderr).splitlines() if line.strip())
            if not status("moon version", proc.returncode == 0, detail[:300]):
                failures += 1
        except (OSError, subprocess.TimeoutExpired) as exc:
            failures += 1
            print(f"[FAIL] moon version: {exc}")
        try:
            output = mp3lab.run_cli("version")
            if not status("CLI version", bool(output.strip()), output.strip()):
                failures += 1
        except mp3lab.ToolError as exc:
            failures += 1
            print(f"[FAIL] CLI version: {exc}")
    except mp3lab.ToolError as exc:
        failures += 1
        print(f"[FAIL] moon path: {exc}")

    try:
        import numpy

        if not status("numpy", True, numpy.__version__):
            failures += 1
    except ImportError:
        failures += 1
        print("[FAIL] numpy: not installed (python -m pip install -r requirements-dev.txt)")

    try:
        import soundfile

        detail = f"{soundfile.__version__} / libsndfile {soundfile.__libsndfile_version__}"
        if not status("soundfile", True, detail):
            failures += 1
        formats = soundfile.available_formats()
        if not status("MP3 format", "MP3" in formats, "available" if "MP3" in formats else "missing from libsndfile"):
            failures += 1
        if "MP3" in formats:
            subtypes = soundfile.available_subtypes("MP3")
            if not status(
                "MPEG Layer III subtype",
                "MPEG_LAYER_III" in subtypes,
                ", ".join(sorted(subtypes)) or "none",
            ):
                failures += 1
    except ImportError:
        failures += 1
        print("[FAIL] soundfile: not installed (python -m pip install -r requirements-dev.txt)")

    fixture_dir = os.path.join(ROOT, "target", "fixtures")
    manifest_path = os.path.join(fixture_dir, "manifest.json")
    if not os.path.isfile(manifest_path):
        warnings += 1
        print("[warn] fixtures: missing; run python tools/gen_fixtures.py")
    else:
        with open(manifest_path, encoding="utf-8") as handle:
            manifest = json.load(handle)
        entries = manifest.get("fixtures", [])
        missing = [entry["name"] for entry in entries if not os.path.isfile(os.path.join(fixture_dir, entry["wav"]))]
        if missing:
            warnings += 1
            print(f"[warn] fixtures: {len(missing)} WAV(s) missing; rerun gen_fixtures.py")
        else:
            print(f"[ok  ] fixtures: {len(entries)} in {fixture_dir}")

    if failures:
        print(f"\n{failures} blocking problem(s), {warnings} warning(s)")
        return 1
    print(f"\nready; {warnings} warning(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
