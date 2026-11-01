#!/usr/bin/env python3
"""Measure SNR between a reference recording and an encoded/decoded one.

MP3 codecs introduce a fixed delay and may return more samples than went in,
so a naive sample-by-sample comparison is meaningless. This tool first finds
the integer delay that maximises cross-correlation, aligns both signals, then
reports SNR per channel plus an overall power-weighted figure.

The reference is normally a WAV fixture from tools/gen_fixtures.py; the
candidate can be any format libsndfile reads, including MP3.

Usage:
    python tools/snr.py reference.wav candidate.mp3
    python tools/snr.py reference.wav candidate.mp3 --json
    python tools/snr.py reference.wav candidate.wav --max-delay 8192 --trim 1152

SNR is a development metric, not a perceptual quality score. Report the
reference, decoder, delay and trim alongside it.
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


def _next_power_of_two(value: int) -> int:
    return 1 << max(0, int(math.ceil(math.log2(max(value, 1)))))


def best_delay(reference: np.ndarray, candidate: np.ndarray, max_delay: int):
    """Return (lag, peak_score). A positive lag means the candidate is late."""
    channels = min(reference.shape[1], candidate.shape[1])
    if channels < 1:
        raise ToolError("signals have no channels")
    length = max(reference.shape[0], candidate.shape[0])
    nfft = _next_power_of_two(reference.shape[0] + candidate.shape[0] - 1)
    score = np.zeros(nfft, dtype=np.float64)
    for channel in range(channels):
        ref = reference[:, channel].astype(np.float64)
        cand = candidate[:, channel].astype(np.float64)
        ref = ref - ref.mean()
        cand = cand - cand.mean()
        if not np.any(ref) or not np.any(cand):
            continue
        spec = np.fft.rfft(cand, nfft) * np.conj(np.fft.rfft(ref, nfft))
        corr = np.fft.irfft(spec, nfft)
        scale = math.sqrt(float(np.dot(ref, ref)) * float(np.dot(cand, cand)))
        if scale > 0:
            score += corr / scale
    if not np.any(score):
        return 0, 0.0
    indices = np.arange(-max_delay, max_delay + 1)
    values = score[indices % nfft]
    best = int(np.argmax(values))
    return int(indices[best]), float(values[best])


def _align(reference: np.ndarray, candidate: np.ndarray, lag: int, trim: int):
    """Return aligned (ref, cand) views after applying lag and edge trim."""
    if lag >= 0:
        ref = reference[0:reference.shape[0]]
        cand = candidate[lag:lag + reference.shape[0]]
    else:
        ref = reference[-lag:]
        cand = candidate[0:ref.shape[0]]
    length = min(ref.shape[0], cand.shape[0])
    ref = ref[:length]
    cand = cand[:length]
    trim = max(0, min(trim, max(0, (length - 1) // 2)))
    if trim:
        ref = ref[trim:length - trim]
        cand = cand[trim:length - trim]
    return ref, cand


def _channel_metrics(ref: np.ndarray, cand: np.ndarray) -> dict:
    error = ref.astype(np.float64) - cand.astype(np.float64)
    signal_power = float(np.mean(np.square(ref.astype(np.float64))))
    noise_power = float(np.mean(np.square(error)))
    if signal_power <= 0.0:
        snr = None
    elif noise_power <= 0.0:
        snr = float("inf")
    else:
        snr = 10.0 * math.log10(signal_power / noise_power)
    if np.std(ref) > 0 and np.std(cand) > 0:
        correlation = float(np.corrcoef(ref, cand)[0, 1])
    else:
        correlation = None
    return {
        "snr_db": snr,
        "signal_rms": math.sqrt(signal_power),
        "noise_rms": math.sqrt(noise_power),
        "max_abs_error": float(np.max(np.abs(error))) if error.size else 0.0,
        "correlation": correlation,
    }


def measure(reference_path: str, candidate_path: str, max_delay: int = 4096, trim: int = 0) -> dict:
    reference, ref_rate = read_audio(reference_path)
    candidate, cand_rate = read_audio(candidate_path)
    if ref_rate != cand_rate:
        raise ToolError(f"sample rates differ: {ref_rate} vs {cand_rate}")
    if reference.shape[1] != candidate.shape[1]:
        raise ToolError(
            f"channel counts differ: {reference.shape[1]} vs {candidate.shape[1]}; "
            "compare matching mono/stereo outputs"
        )
    lag, score = best_delay(reference, candidate, max_delay)
    aligned_ref, aligned_cand = _align(reference, candidate, lag, trim)
    if aligned_ref.shape[0] == 0:
        raise ToolError("signals do not overlap after delay alignment")

    channels = []
    signal_energy = 0.0
    noise_energy = 0.0
    for channel in range(reference.shape[1]):
        metrics = _channel_metrics(aligned_ref[:, channel], aligned_cand[:, channel])
        metrics["channel"] = channel
        channels.append(metrics)
        count = aligned_ref.shape[0]
        if metrics["signal_rms"] > 0.0:
            signal_energy += (metrics["signal_rms"] ** 2) * count
            noise_energy += (metrics["noise_rms"] ** 2) * count

    if signal_energy <= 0:
        overall = None
    elif noise_energy <= 0:
        overall = float("inf")
    else:
        overall = 10.0 * math.log10(signal_energy / noise_energy)

    return {
        "reference": os.path.abspath(reference_path),
        "candidate": os.path.abspath(candidate_path),
        "rate": ref_rate,
        "channels": reference.shape[1],
        "reference_frames": int(reference.shape[0]),
        "candidate_frames": int(candidate.shape[0]),
        "delay_samples": lag,
        "delay_ms": round(lag * 1000.0 / ref_rate, 3),
        "correlation_score": round(score, 6),
        "trim_samples": trim,
        "overall_snr_db": overall,
        "per_channel": channels,
    }


def _format(value):
    if value is None:
        return "n/a"
    if isinstance(value, float) and math.isinf(value):
        return "inf"
    return f"{value:.3f}"


def print_report(report: dict) -> None:
    print(
        f"reference : {os.path.basename(report['reference'])} "
        f"({report['reference_frames']} frames, {report['channels']} ch @ {report['rate']} Hz)"
    )
    print(
        f"candidate : {os.path.basename(report['candidate'])} "
        f"({report['candidate_frames']} frames)"
    )
    print(
        f"alignment : delay={report['delay_samples']} samples "
        f"({report['delay_ms']:.3f} ms), score={report['correlation_score']:.4f}, "
        f"trim={report['trim_samples']}"
    )
    for channel in report["per_channel"]:
        print(
            f"  ch{channel['channel']}: SNR={_format(channel['snr_db'])} dB  "
            f"signal_rms={channel['signal_rms']:.6f}  noise_rms={channel['noise_rms']:.6f}  "
            f"max_err={channel['max_abs_error']:.6f}  corr={_format(channel['correlation'])}"
        )
    print(f"overall SNR: {_format(report['overall_snr_db'])} dB")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("reference", help="source WAV/PCM fixture")
    parser.add_argument("candidate", help="encoded/decoded file, e.g. MP3")
    parser.add_argument("--max-delay", type=int, default=4096, help="search +/- this many samples")
    parser.add_argument("--trim", type=int, default=0, help="discard this many samples at each edge after alignment")
    parser.add_argument("--json", action="store_true", help="emit JSON instead of a table")
    args = parser.parse_args()
    if args.max_delay < 0:
        parser.error("--max-delay must be non-negative")
    try:
        report = measure(args.reference, args.candidate, args.max_delay, args.trim)
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
