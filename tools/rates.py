#!/usr/bin/env python3
"""Verify MP3 encoding across MPEG-1 sample rates and bitrates.

Covers 3 sample rates (32000, 44100, 48000 Hz) x 14 bitrates (32..320 kbps)
x mono/stereo channels (1, 2) = 84 combinations.

For each combination, encode a tone, check every frame's MPEG version,
CBR padding and channel mode, then check the rate, channels, sample count
and finite non-silent output with both mpg123 and FFmpeg.

Usage:
    python tools/rates.py
    python tools/rates.py --json
    python tools/rates.py --frames 4
"""

from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np

from crossdecode import decode_with_ffmpeg
from mp3dump import parse_header, parse_side_info
from mp3lab import (
    MP3_FRAME_SAMPLES, ToolError, decode_mp3, expected_encoded_frames, extract_payload, run_cli,
)

RATES = [32000, 44100, 48000]
BITRATES = [
    32000, 40000, 48000, 56000, 64000, 80000, 96000, 112000, 128000, 160000,
    192000, 224000, 256000, 320000,
]
CHANNELS = [1, 2]
DEFAULT_FRAMES = 4


def test_combination(rate: int, bitrate: int, channels: int, frames: int = DEFAULT_FRAMES) -> dict:
    encoded_frames = expected_encoded_frames(frames * MP3_FRAME_SAMPLES)
    expected_bytes = encoded_frames * 144 * bitrate // rate
    expected_samples = encoded_frames * MP3_FRAME_SAMPLES

    case = {
        "rate": rate,
        "bitrate": bitrate,
        "channels": channels,
        "input_frames": frames,
        "frames": encoded_frames,
        "flush_frames": encoded_frames - frames,
        "expected_bytes": expected_bytes,
        "bytes": 0,
        "decoded_frames": 0,
        "decoded_samples": 0,
        "status": "FAIL",
        "detail": "",
    }

    try:
        payload = extract_payload(
            run_cli("gen", str(rate), str(bitrate), str(channels), str(frames), "440")
        )
        case["bytes"] = len(payload)
        if len(payload) != expected_bytes:
            raise ToolError(f"byte count {len(payload)} != expected {expected_bytes}")

        offset = 0
        area_start = 0
        previous_data_end = 0
        mode = 3 if channels == 1 else 0
        for frame in range(encoded_frames):
            header = parse_header(payload, offset)
            end = (frame + 1) * 144 * bitrate // rate
            if (
                header is None
                or header["version"] != 3
                or header["bitrate"] != bitrate
                or header["samplerate"] != rate
                or header["mode"] != mode
                or header["size"] != end - offset
            ):
                raise ToolError(f"frame {frame}: invalid MPEG-1 CBR header at byte {offset}")
            side_offset = offset + 4 + (0 if header["protection"] else 2)
            side = parse_side_info(payload, side_offset, channels)
            data_start = (area_start - side["main_data_begin"]) * 8
            area_start += end - side_offset - header["side_size"]
            data_end = data_start + sum(g["part2_3_length"] for g in side["granules"])
            if data_start < previous_data_end or data_end > area_start * 8:
                raise ToolError(f"frame {frame}: main data exceeds its reservoir bounds")
            previous_data_end = data_end
            offset = end

        for name, decode in (("mpg123", decode_mp3), ("FFmpeg", decode_with_ffmpeg)):
            try:
                data, dec_rate = decode(payload)
            except Exception as exc:
                raise ToolError(f"{name} decode error: {exc}") from exc
            if dec_rate != rate or data.shape != (expected_samples, channels):
                raise ToolError(f"{name}: decoded {dec_rate} Hz and shape {data.shape}")
            if not np.isfinite(data).all() or not np.any(data):
                raise ToolError(f"{name}: decoded tone is non-finite or silent")
        case["decoded_samples"] = expected_samples
        case["decoded_frames"] = encoded_frames
    except ToolError as exc:
        case["detail"] = str(exc)
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

    if args.frames < 1:
        parser.error("--frames must be at least 1")

    results = run_matrix(frames=args.frames)

    passed = sum(1 for r in results if r["status"] == "PASS")
    failed = len(results) - passed

    if args.json:
        report = {
            "total": len(results),
            "passed": passed,
            "blocked_by_count1": 0,
            "failed": failed,
            "results": results,
        }
        print(json.dumps(report, indent=2))
    else:
        print_table(results)
        print("-" * 75)
        print(f"Summary: {len(results)} total | {passed} passed | 0 blocked-by-count1 | {failed} failed")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
