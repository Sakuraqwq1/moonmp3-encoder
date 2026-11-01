#!/usr/bin/env python3
"""Report the strongest spectral peaks of an audio file.

Stage 1 needs more than "the decoder produced non-zero samples": a 440 Hz
input must come back as a 440 Hz peak, and stereo channels must not be
swapped. This tool averages a Hann-windowed periodogram, finds local maxima
and interpolates each peak position.

Usage:
    python tools/spectrum.py decoded.wav
    python tools/spectrum.py decoded.mp3 --channel 1 --top 5
    python tools/spectrum.py decoded.mp3 --json

The output is a diagnostic, not an audio-quality metric.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mp3lab import ToolError, read_audio


def periodogram(samples: np.ndarray, rate: int, fft_size: int):
    """Return (frequencies, power, frames, effective_fft_size)."""
    samples = samples.astype(np.float64)
    samples = samples - samples.mean()
    if samples.size == 0:
        raise ToolError("empty audio")
    effective = min(fft_size, 1 << max(0, int(math.ceil(math.log2(max(samples.size, 2))))))
    if effective < 32:
        raise ToolError("audio is too short for a spectrum")
    window = np.hanning(effective)
    hop = max(1, effective // 2)
    power = np.zeros(effective // 2 + 1, dtype=np.float64)
    frames = 0
    if samples.size < effective:
        padded = np.zeros(effective)
        padded[: samples.size] = samples
        power += np.abs(np.fft.rfft(padded * window)) ** 2
        frames = 1
    else:
        for start in range(0, samples.size - effective + 1, hop):
            segment = samples[start:start + effective] * window
            power += np.abs(np.fft.rfft(segment)) ** 2
            frames += 1
    if frames == 0:
        raise ToolError("no complete analysis frame")
    power /= frames
    frequencies = np.fft.rfftfreq(effective, d=1.0 / rate)
    return frequencies, power, frames, effective


def find_peaks(frequencies: np.ndarray, power: np.ndarray, count: int, min_distance_hz: float = 20.0):
    """Return up to `count` interpolated local maxima, strongest first."""
    if power.size < 3 or not np.any(power > 0):
        return []
    reference = float(np.max(power))
    if reference <= 0:
        return []
    db = 10.0 * np.log10(np.maximum(power, reference * 1e-15) / reference)
    candidates = []
    for index in range(1, power.size - 1):
        if power[index] <= power[index - 1] or power[index] < power[index + 1]:
            continue
        if db[index] < -80.0:
            continue
        left, middle, right = db[index - 1], db[index], db[index + 1]
        denominator = left - 2.0 * middle + right
        offset = 0.0 if denominator == 0 else 0.5 * (left - right) / denominator
        offset = max(-0.5, min(0.5, offset))
        frequency = float(frequencies[index] + offset * (frequencies[1] - frequencies[0]))
        candidates.append((float(db[index]), frequency))
    candidates.sort(reverse=True)
    selected = []
    for level, frequency in candidates:
        if all(abs(frequency - other["frequency_hz"]) >= min_distance_hz for other in selected):
            selected.append({"frequency_hz": round(frequency, 3), "relative_db": round(level, 3)})
            if len(selected) >= count:
                break
    return selected


def analyze(path: str, channel: int, top: int, fft_size: int) -> dict:
    data, rate = read_audio(path)
    if channel < 0 or channel >= data.shape[1]:
        raise ToolError(f"channel {channel} out of range for {data.shape[1]} channel(s)")
    frequencies, power, frames, effective = periodogram(data[:, channel], rate, fft_size)
    peaks = find_peaks(frequencies, power, top)
    return {
        "path": os.path.abspath(path),
        "rate": rate,
        "channel": channel,
        "channels": int(data.shape[1]),
        "fft_size": effective,
        "frames": frames,
        "dominant_hz": peaks[0]["frequency_hz"] if peaks else None,
        "peaks": peaks,
    }


def print_report(report: dict) -> None:
    print(
        f"{os.path.basename(report['path'])}: {report['rate']} Hz, "
        f"channel {report['channel']}/{report['channels'] - 1}, "
        f"fft={report['fft_size']}, frames={report['frames']}"
    )
    if not report["peaks"]:
        print("  no spectral peak above the noise floor")
        return
    print(f"  dominant: {report['dominant_hz']:.3f} Hz")
    for index, peak in enumerate(report["peaks"]):
        print(f"  {index + 1}: {peak['frequency_hz']:10.3f} Hz  {peak['relative_db']:8.3f} dB")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("file")
    parser.add_argument("--channel", type=int, default=0)
    parser.add_argument("--top", type=int, default=8)
    parser.add_argument("--fft-size", type=int, default=4096)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    if args.top < 1:
        parser.error("--top must be positive")
    if args.fft_size < 32:
        parser.error("--fft-size must be at least 32")
    try:
        report = analyze(args.file, args.channel, args.top, args.fft_size)
    except (ToolError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print_report(report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
