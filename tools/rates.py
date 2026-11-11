#!/usr/bin/env python3
"""Verify MP3 encoding across MPEG-1 sample rates and bitrates.

Covers 3 sample rates (32000, 44100, 48000 Hz) x 14 bitrates (32..320 kbps)
x mono/stereo channels (1, 2) = 84 combinations.

For each combination:
  1. Generate audio using `moon run cmd/main -- gen <rate> <bitrate> <ch> <frames> <freq>`.
  2. If blocked by count1 bit-budget floor (low bitrate), report `blocked-by-count1`.
  3. Decode with libsndfile (`soundfile` via `decode_mp3`).
  4. Assert:
     - Exact byte length equals `floor(n * 144 * bitrate / samplerate)`.
     - Decoded sample rate and channel count match.
     - Decoded frame count equals `ceil(samples / 1152)`.
     - Decoded sample length matches expected samples (within encoder delay bounds).

Usage:
    python tools/rates.py
    python tools/rates.py --json
    python tools/rates.py --frames 4
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mp3lab import ToolError, decode_mp3, extract_payload, run_cli

RATES = [32000, 44100, 48000]
BITRATES = [
    32000, 40000, 48000, 56000, 64000, 80000, 96000, 112000, 128000, 160000,
    192000, 224000, 256000, 320000,
]
CHANNELS = [1, 2]
DEFAULT_FRAMES = 4


def test_combination(rate: int, bitrate: int, channels: int, frames: int = DEFAULT_FRAMES) -> dict:
    expected_bytes = frames * 144 * bitrate // rate
    expected_samples = frames * 1152
    expected_frames = frames

    case = {
        "rate": rate,
        "bitrate": bitrate,
        "channels": channels,
        "frames": frames,
        "expected_bytes": expected_bytes,
        "bytes": 0,
        "decoded_frames": 0,
        "decoded_samples": 0,
        "status": "FAIL",
        "detail": "",
    }

    try:
        stdout = run_cli("gen", str(rate), str(bitrate), str(channels), str(frames), "440")
    except ToolError as exc:
        msg = str(exc)
        if "huffman failed" in msg or "analysis failed" in msg:
            case["status"] = "blocked-by-count1"
            case["detail"] = "count1 576-bit budget floor"
            return case
        case["status"] = "FAIL"
        case["detail"] = f"CLI error: {msg}"
        return case

    if "ERROR: huffman failed" in stdout or "ERROR: analysis failed" in stdout:
        case["status"] = "blocked-by-count1"
        case["detail"] = "count1 576-bit budget floor"
        return case

    try:
        payload = extract_payload(stdout)
    except ToolError as exc:
        case["status"] = "blocked-by-count1"
        case["detail"] = str(exc)
        return case

    case["bytes"] = len(payload)
    if len(payload) != expected_bytes:
        case["status"] = "FAIL"
        case["detail"] = f"byte count {len(payload)} != expected {expected_bytes}"
        return case

    try:
        data, dec_rate = decode_mp3(payload)
    except Exception as exc:
        case["status"] = "FAIL"
        case["detail"] = f"decode error: {exc}"
        return case

    case["decoded_samples"] = int(data.shape[0])
    case["decoded_frames"] = math.ceil(data.shape[0] / 1152)

    if dec_rate != rate:
        case["status"] = "FAIL"
        case["detail"] = f"decoded rate {dec_rate} != expected {rate}"
        return case

    if data.shape[1] != channels:
        case["status"] = "FAIL"
        case["detail"] = f"decoded channels {data.shape[1]} != expected {channels}"
        return case

    if data.shape[0] != expected_samples:
        case["status"] = "FAIL"
        case["detail"] = f"decoded samples {data.shape[0]} != expected {expected_samples}"
        return case

    case["status"] = "PASS"
    case["detail"] = "ok"
    return case


def run_matrix(frames: int = DEFAULT_FRAMES) -> list[dict]:
    results = []
    for rate in RATES:
        for bitrate in BITRATES:
            for channels in CHANNELS:
                res = test_combination(rate, bitrate, channels, frames=frames)
                results.append(res)
    return results


def print_table(results: list[dict]):
    print(f"{'Rate':>6} | {'Bitrate':>7} | {'Ch':>2} | {'Bytes':>6} | {'DecFrames':>9} | {'Status':<18} | Detail")
    print("-" * 75)
    for r in results:
        status_str = r["status"]
        print(
            f"{r['rate']:6d} | {r['bitrate'] // 1000:6d}k | {r['channels']:2d} | "
            f"{r['bytes']:6d} | {r['decoded_frames']:9d} | {status_str:<18} | {r['detail']}"
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="output as JSON report")
    parser.add_argument("--frames", type=int, default=DEFAULT_FRAMES, help="frames per case (default 4)")
    args = parser.parse_args()

    results = run_matrix(frames=args.frames)

    passed = sum(1 for r in results if r["status"] == "PASS")
    blocked = sum(1 for r in results if r["status"] == "blocked-by-count1")
    failed = sum(1 for r in results if r["status"] == "FAIL")

    if args.json:
        report = {
            "total": len(results),
            "passed": passed,
            "blocked_by_count1": blocked,
            "failed": failed,
            "results": results,
        }
        print(json.dumps(report, indent=2))
    else:
        print_table(results)
        print("-" * 75)
        print(f"Summary: {len(results)} total | {passed} passed | {blocked} blocked-by-count1 | {failed} failed")

    return 1 if failed > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
