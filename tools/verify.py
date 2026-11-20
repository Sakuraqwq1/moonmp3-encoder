#!/usr/bin/env python3
"""Reproducible verification for moonmp3-encoder.

structure   Emit silence through the CLI and decode it independently with
            libsndfile (mpg123) and FFmpeg (PyAV).
            Decode to 1152 zero samples per encoded frame, including the flush
            frame and the extra probing frame for short input.

Later stages add `matrix` (SNR against the source PCM), `benchmark` (size
against LAME at the same CBR rate) and `perf`.

Requirements: the MoonBit toolchain on PATH (or MOON set to the binary) and
`soundfile` + `numpy` for Python. Run from anywhere; paths are resolved
against the repository root.
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from crossdecode import decode_with_ffmpeg
from mp3lab import MP3_FRAME_SAMPLES, ToolError, decode_mp3, encode_silence, expected_encoded_frames


def structure():
    """The frame grid check: silence in, exact-length silence out."""
    import numpy as np

    cases = []
    for samples in (1, 1151, 1152, 1153, 2304, 4095, 4096, 4097, 44100):
        for channels in (1, 2):
            mp3 = encode_silence(samples, channels)
            frames = expected_encoded_frames(samples)
            expected = frames * MP3_FRAME_SAMPLES
            results = {}
            for name, decode in (("mpg123", decode_mp3), ("ffmpeg", decode_with_ffmpeg)):
                data, rate = decode(mp3)
                peak = float(np.max(np.abs(data))) if data.size else 0.0
                results[name] = {
                    "decoded": int(data.shape[0]),
                    "peak": peak,
                    "ok": rate == 44100 and data.shape == (expected, channels) and peak == 0.0,
                }
            cases.append(
                {
                    "samples": samples,
                    "channels": channels,
                    "frames": frames,
                    "decoded": results["mpg123"]["decoded"],
                    "peak": results["mpg123"]["peak"],
                    "decoders": results,
                    "ok": all(result["ok"] for result in results.values()),
                }
            )
    return cases


def print_cases(cases, quiet=False):
    failures = 0
    for case in cases:
        status = "ok" if case["ok"] else "FAIL"
        if not quiet:
            print(
                f"{status}: samples={case['samples']:5d} ch={case['channels']} "
                f"frames={case['frames']} decoded={case['decoded']} peak={case['peak']:.6f}"
            )
        if not case["ok"]:
            failures += 1
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("check", choices=["structure"])
    parser.add_argument("--json", action="store_true", help="emit a machine-readable report")
    args = parser.parse_args()
    try:
        cases = structure()
    except ToolError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    failures = print_cases(cases, quiet=args.json)
    report = {"check": "structure", "passed": len(cases) - failures, "failed": failures, "cases": cases}
    if args.json:
        print(json.dumps(report, indent=2))
    if failures:
        if not args.json:
            print(f"\n{failures} case(s) failed")
        return 1
    if not args.json:
        print("\nall checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
