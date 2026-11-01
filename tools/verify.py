#!/usr/bin/env python3
"""Reproducible verification for moonmp3-encoder.

structure   Emit silence through the CLI, decode it with libsndfile (through
            Python `soundfile`, i.e. LAME/mpg123, completely independent of the
            MoonBit ecosystem) and check the frame grid: the stream must decode
            to exactly frames * 1152 zero samples per channel.

Later stages add `matrix` (SNR against the source PCM), `benchmark` (size
against LAME at the same CBR rate) and `perf`.

Requirements: the MoonBit toolchain on PATH (or MOON set to the binary) and
`soundfile` + `numpy` for Python. Run from anywhere; paths are resolved
against the repository root.
"""

import argparse
import base64
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOON = os.environ.get("MOON") or os.path.expanduser("~/.moon/bin/moon")


def emit_silence(samples, channels):
    """Run the encoder's `silent` command and return the MP3 bytes."""
    proc = subprocess.run(
        [MOON, "run", "cmd/main", "--", "silent", str(samples), str(channels)],
        cwd=ROOT, capture_output=True, text=True,
    )
    lines = proc.stdout.splitlines()
    if "MP3BEGIN" not in lines:
        raise RuntimeError(f"encode failed: {proc.stderr.strip()[:200]}")
    return base64.b64decode(lines[lines.index("MP3BEGIN") + 1])


def decode(mp3):
    """Decode with libsndfile and return (samples, rate), always 2-D float."""
    import soundfile as sf

    with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as handle:
        handle.write(mp3)
        path = handle.name
    try:
        data, rate = sf.read(path, always_2d=True)
    finally:
        os.unlink(path)
    return data, rate


def structure():
    """The frame grid check: silence in, exact-length silence out."""
    import numpy as np

    failures = 0
    # libsndfile/mpg123 cannot open a one-frame MP3 stream (it reads the next
    # header to identify the format), so the decoder-side check starts at two
    # frames; one-frame streams are covered structurally by tools/mp3dump.py.
    for samples in (1153, 2304, 4095, 4096, 4097, 44100):
        for channels in (1, 2):
            mp3 = emit_silence(samples, channels)
            frames = (samples + 1151) // 1152
            data, rate = decode(mp3)
            peak = float(np.max(np.abs(data))) if data.size else 0.0
            expected = frames * 1152
            ok = rate == 44100 and data.shape[0] == expected and peak == 0.0
            status = "ok" if ok else "FAIL"
            print(
                f"{status}: samples={samples:5d} ch={channels} "
                f"frames={frames} decoded={data.shape[0]} peak={peak:.6f}"
            )
            if not ok:
                failures += 1
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("check", choices=["structure"])
    args = parser.parse_args()
    failures = structure()
    if failures:
        print(f"\n{failures} case(s) failed")
        return 1
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
