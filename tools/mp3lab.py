#!/usr/bin/env python3
"""Shared plumbing for the Python-side encoder lab.

Everything in `tools/` needs the same three things: run the MoonBit CLI,
pull the base64 payload out of its stdout, and decode an MP3 without leaving
Python. Keeping that in one module means the verification scripts cannot
drift apart in how they invoke the encoder.

No encoder logic lives here, and none of this is used by the MoonBit package
at build time.
"""

from __future__ import annotations

import base64
import os
import shutil
import subprocess
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class ToolError(RuntimeError):
    """A lab tool could not complete its job."""


def find_moon() -> str:
    """Locate the MoonBit CLI without requiring it to be on PATH."""
    override = os.environ.get("MOON")
    if override:
        if os.path.isfile(override):
            return override
        raise ToolError(f"MOON points to a missing file: {override}")
    found = shutil.which("moon")
    if found:
        return found
    candidate = os.path.expanduser(os.path.join("~", ".moon", "bin", "moon"))
    if os.name == "nt" and not candidate.lower().endswith(".exe"):
        candidate += ".exe"
    if os.path.isfile(candidate):
        return candidate
    raise ToolError("MoonBit CLI not found; put moon on PATH or set MOON")


def run_cli(*args: str, timeout: int = 180) -> str:
    """Run `moon run cmd/main -- <args>` from the repository root."""
    command = [find_moon(), "run", "cmd/main", "--", *args]
    try:
        proc = subprocess.run(
            command,
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise ToolError(f"CLI timed out after {timeout}s: {' '.join(args)}") from exc
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout).strip().splitlines()
        tail = " | ".join(detail[-3:]) if detail else "no output"
        raise ToolError(f"CLI failed ({proc.returncode}) for {' '.join(args)}: {tail}")
    return proc.stdout


def extract_payload(stdout: str, marker: str = "MP3BEGIN") -> bytes:
    """Return the base64 payload printed after `marker`."""
    lines = [line.strip() for line in stdout.splitlines()]
    try:
        index = lines.index(marker)
    except ValueError as exc:
        raise ToolError(f"CLI output did not contain {marker}") from exc
    encoded = "".join(line for line in lines[index + 1:] if line)
    if not encoded:
        raise ToolError(f"no base64 payload after {marker}")
    try:
        return base64.b64decode(encoded, validate=True)
    except ValueError as exc:
        raise ToolError("CLI payload is not valid base64") from exc


def encode_silence(samples: int, channels: int = 1) -> bytes:
    """Ask the CLI for `samples` samples per channel of digital silence."""
    return extract_payload(run_cli("silent", str(samples), str(channels)))


def decode_mp3(payload: bytes):
    """Decode MP3 bytes with libsndfile; return (float32[frames, channels], rate)."""
    try:
        import numpy as np
        import soundfile as sf
    except ImportError as exc:
        raise ToolError("decode_mp3 needs numpy and soundfile") from exc

    with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as handle:
        handle.write(payload)
        path = handle.name
    try:
        data, rate = sf.read(path, always_2d=True, dtype="float32")
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass
    return np.asarray(data), int(rate)


def read_audio(path: str):
    """Read a WAV/FLAC/etc. into (float32[frames, channels], rate)."""
    try:
        import numpy as np
        import soundfile as sf
    except ImportError as exc:
        raise ToolError("read_audio needs numpy and soundfile") from exc
    data, rate = sf.read(path, always_2d=True, dtype="float32")
    return np.asarray(data), int(rate)


def decibels(ratio: float) -> float:
    """Convert a power ratio to dB, with a stable floor for digital silence."""
    import math

    return 10.0 * math.log10(max(ratio, 1e-30))
