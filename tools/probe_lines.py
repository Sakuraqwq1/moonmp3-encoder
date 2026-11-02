#!/usr/bin/env python3
"""Measure the bitstream-line -> output-frequency map.

Stage 1 needs a ruler before it needs a filterbank.  The 576 frequency lines of
a Layer III granule are ordered subband-major: line `k` belongs to subband
`k // 18` and is the `k % 18`-th MDCT bin inside it.  Every subband is
`44100 / 64 = 689.0625` Hz wide and holds 18 long-block bins, so the whole
mapping collapses to a single spacing of `44100 / 1152 = 38.28125` Hz per line.
That is the claim this tool measures rather than assumes.

Method: for each requested line, ask the CLI for a fixed-spectrum stream that
carries only that one count1 coefficient, decode it with libsndfile (mpg123),
and locate the decoded peak with a long FFT plus log-magnitude interpolation.
The earlier probe that produced two identical readings for lines 11 and 12 used
a 4096-point FFT; the resolution here is 4x finer and the estimate is reported
with its own uncertainty.

Usage:
    python tools/probe_lines.py                     # lines 0..31
    python tools/probe_lines.py --lines 0-35
    python tools/probe_lines.py --json docs/line-frequencies.json
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mp3lab import ToolError, decode_mp3, extract_payload, run_cli

LINE_HZ = 44100.0 / 1152.0
SUB_BAND_HZ = 44100.0 / 64.0


def parse_lines(text: str) -> list[int]:
    """Accept `0-31`, `0,3,7` or a mix of both."""
    lines: list[int] = []
    for part in text.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            low, high = part.split("-", 1)
            lines.extend(range(int(low), int(high) + 1))
        else:
            lines.append(int(part))
    return lines


def dominant_frequency(samples: np.ndarray, rate: int, fft_size: int = 16384) -> dict:
    """Peak frequency of a single-tone buffer, with log-parabolic interpolation."""
    samples = samples.astype(np.float64)
    samples = samples - samples.mean()
    if samples.size < fft_size:
        padded = np.zeros(fft_size)
        padded[: samples.size] = samples
        samples = padded
    else:
        samples = samples[:fft_size]
    spectrum = np.abs(np.fft.rfft(samples * np.hanning(samples.size)))
    magnitude = np.log(np.maximum(spectrum, 1e-30))
    index = int(np.argmax(magnitude[1:-1])) + 1
    left, middle, right = magnitude[index - 1], magnitude[index], magnitude[index + 1]
    denominator = left - 2.0 * middle + right
    offset = 0.0 if denominator == 0 else 0.5 * (left - right) / denominator
    offset = max(-0.5, min(0.5, offset))
    spacing = rate / float(samples.size)
    frequency = (index + offset) * spacing
    # Second-order uncertainty of a log-parabolic peak estimate is well below
    # one bin for a clean tone; report half a bin as the honest bound.
    return {
        "frequency_hz": round(float(frequency), 4),
        "bin": index,
        "bin_hz": round(float(spacing), 4),
        "uncertainty_hz": round(float(spacing) / 2.0, 4),
        "peak_linear": round(float(np.max(np.abs(samples))), 6),
    }


def probe(line: int, frames: int, gain: int) -> dict:
    payload = extract_payload(run_cli("tone", str(frames), str(line), str(gain), "1"))
    data, rate = decode_mp3(payload)
    if data.shape[1] != 1:
        raise ToolError(f"line {line}: expected mono, got {data.shape[1]} channels")
    measured = dominant_frequency(data[:, 0], rate)
    # A repeated single-line spectrum makes the subband signal periodic with a
    # period dividing 18, so all of its energy lands on multiples of
    # 1378.125 / 18 = 76.5625 Hz: every *even* multiple of the line spacing.
    # Line k therefore shows up at the next even line, not at its own centre.
    coarse = 2 * ((line + 1) // 2) * LINE_HZ
    centre = (line + 0.5) * LINE_HZ
    return {
        "line": line,
        "subband": line // 18,
        "bin_in_subband": line % 18,
        "bin_centre_hz": round(centre, 4),
        "predicted_hz": round(coarse, 4),
        "measured_hz": measured["frequency_hz"],
        "error_hz": round(measured["frequency_hz"] - coarse, 4),
        "uncertainty_hz": measured["uncertainty_hz"],
        "decoded_samples": int(data.shape[0]),
        "peak": measured["peak_linear"],
        "dc": line == 0,
    }


def top_peaks(samples: np.ndarray, rate: int, count: int, fft_size: int = 16384) -> list[float]:
    """The `count` strongest local maxima, separated by at least 15 Hz."""
    buffer = samples.astype(np.float64)
    buffer = buffer - buffer.mean()
    if buffer.size < fft_size:
        padded = np.zeros(fft_size)
        padded[: buffer.size] = buffer
        buffer = padded
    else:
        buffer = buffer[:fft_size]
    magnitude = np.log(np.maximum(np.abs(np.fft.rfft(buffer * np.hanning(buffer.size))), 1e-30))
    spacing = rate / float(buffer.size)
    peaks: list[float] = []
    for index in range(1, magnitude.size - 1):
        if magnitude[index] <= magnitude[index - 1] or magnitude[index] < magnitude[index + 1]:
            continue
        left, middle, right = magnitude[index - 1], magnitude[index], magnitude[index + 1]
        denominator = left - 2.0 * middle + right
        offset = 0.0 if denominator == 0 else 0.5 * (left - right) / denominator
        peaks.append((float(middle), float((index + max(-0.5, min(0.5, offset))) * spacing)))
    peaks.sort(reverse=True)
    selected: list[float] = []
    for _, frequency in peaks:
        if all(abs(frequency - other) >= 15.0 for other in selected):
            selected.append(round(frequency, 3))
            if len(selected) >= count:
                break
    return selected


def probe_pair(low: int, frames: int, gain: int, count: int = 3) -> dict:
    """Excite two adjacent lines and report where the energy lands.

    A repeated single-line spectrum can only produce a signal whose subband
    period divides 18, so its harmonics sit on a 76.5625 Hz grid and odd bins are
    invisible.  Exciting a neighbour does not fix that, but it does show whether
    the two bins remain individually identifiable in the output.
    """
    high = low + 1
    payload = extract_payload(
        run_cli("tone", str(frames), f"{low},{high}", str(gain), "1")
    )
    data, rate = decode_mp3(payload)
    peaks = top_peaks(data[:, 0], rate, count)
    return {
        "lines": [low, high],
        "predicted_hz": [round(low * LINE_HZ, 3), round(high * LINE_HZ, 3)],
        "peaks_hz": peaks,
        "peak": round(float(np.max(np.abs(data[:, 0]))), 6),
    }


def markdown_table(rows: list[dict]) -> str:
    head = (
        "| line | subband | bin | bin centre Hz | coarse-model Hz | measured Hz | error Hz | peak |\n"
        "| ---: | ------: | --: | ------------: | --------------: | ----------: | -------: | ---: |\n"
    )
    body = "".join(
        f"| {r['line']} | {r['subband']} | {r['bin_in_subband']} | "
        f"{r['bin_centre_hz']:.4f} | {r['predicted_hz']:.4f} | "
        f"{r['measured_hz']:.4f} | {r['error_hz']:+.4f} | {r['peak']:.4f} |\n"
        for r in rows
    )
    return head + body


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--lines", default="0-31", help="line list, e.g. 0-31 or 0,5,9")
    parser.add_argument("--frames", type=int, default=16, help="frames per probe stream")
    parser.add_argument("--gain", type=int, default=206, help="global_gain for the probe")
    parser.add_argument("--json", help="also write the raw rows to this path")
    parser.add_argument("--markdown", help="write the report table to this path")
    parser.add_argument(
        "--pairs",
        action="store_true",
        help="also probe adjacent line pairs (lines 0-1, 2-3, ...)",
    )
    args = parser.parse_args()
    if args.frames < 2:
        parser.error("--frames must be at least 2 (libsndfile needs a following header)")
    lines = parse_lines(args.lines)
    if not lines:
        parser.error("no lines selected")
    try:
        rows = []
        for line in lines:
            row = probe(line, args.frames, args.gain)
            rows.append(row)
            print(
                f"line {line:3d}  subband {row['subband']:2d} bin {row['bin_in_subband']:2d}  "
                f"predicted {row['predicted_hz']:9.3f}  measured {row['measured_hz']:9.3f}  "
                f"error {row['error_hz']:+8.3f} Hz  peak {row['peak']:.3f}"
            )
        pairs = []
        if args.pairs:
            print()
            for low in range(0, max(lines) + 1 - 1, 2):
                pair = probe_pair(low, args.frames, args.gain)
                pairs.append(pair)
                print(
                    f"lines {pair['lines']}  predicted {pair['predicted_hz']}  "
                    f"peaks {pair['peaks_hz']}"
                )
    except ToolError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    measured_rows = [r for r in rows if not r["dc"]]
    matched = [
        r for r in measured_rows if abs(r["error_hz"]) <= r["uncertainty_hz"]
    ]
    errors = [abs(r["error_hz"]) for r in matched]
    worst = max(errors) if errors else float("inf")
    tolerance = max(r["uncertainty_hz"] for r in rows)
    print(
        f"\n{len(matched)}/{len(measured_rows)} lines land on the predicted coarse-grid "
        f"frequency within {tolerance:.3f} Hz; worst |error| among those = {worst:.4f} Hz"
    )
    print(f"line spacing predicted = {LINE_HZ:.6f} Hz")
    if len(matched) != len(measured_rows):
        for row in measured_rows:
            if abs(row["error_hz"]) > row["uncertainty_hz"]:
                print(f"  line {row['line']}: {row['error_hz']:+.3f} Hz off", file=sys.stderr)
    if args.json:
        with open(args.json, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(
                {
                    "line_spacing_hz": LINE_HZ,
                    "subband_width_hz": SUB_BAND_HZ,
                    "frames_per_probe": args.frames,
                    "global_gain": args.gain,
                    "decoder": "libsndfile (mpg123)",
                    "rows": rows,
                    "pairs": pairs,
                },
                handle,
                indent=2,
            )
            handle.write("\n")
        print(f"wrote {args.json}")
    if args.markdown:
        with open(args.markdown, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(markdown_table(rows))
        print(f"wrote {args.markdown}")
    return 0 if len(matched) == len(measured_rows) else 1


if __name__ == "__main__":
    sys.exit(main())
