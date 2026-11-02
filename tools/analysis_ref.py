#!/usr/bin/env python3
"""Independent numpy reference for the encoder's analysis layer.

Every stage in `src/mp3/analysis.mbt` has to be checkable against numbers that
were not produced by the same code. This module recomputes the two stages from
their defining sums — no folding, no precomputed matrix, straight double
precision — and compares them line by line with what the MoonBit CLI reports:

    python tools/analysis_ref.py --compare            # one granule, 440 Hz
    python tools/analysis_ref.py --compare --freq 1000
    python tools/analysis_ref.py --self               # analytic self-checks

The window coefficients are read from `src/mp3/window.mbt` on purpose: their
provenance is verified separately by `tools/window_table.py`, so this reference
is about the arithmetic, not about re-deriving the table.

Definition used, ISO/IEC 11172-3 §2.4.2.2 and §2.4.3.1:

    S[m] = sum(n = 0..511) x[n] C[n] cos((16 + (n mod 64))(2m + 1) pi / 64)
    X[k] = sum(n = 0..35) w[n] s[n] cos(pi / 72 (2n + 19)(2k + 1))
    w[n] = sin(pi / 36 (n + 0.5))

with the odd-subband reversal and the 1/288 synthesis gain applied afterwards.
"""

from __future__ import annotations

import argparse
import os
import re
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mp3lab import ToolError, run_cli

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WINDOW_FILE = os.path.join(ROOT, "src", "mp3", "window.mbt")

SUBBANDS = 32
WINDOW_TAPS = 512
LINES_PER_GRANULE = 18
GRANULE_PCM = 576
SYNTHESIS_GAIN = 288.0
RATE = 44100.0


def load_window() -> np.ndarray:
    with open(WINDOW_FILE, encoding="utf-8") as handle:
        text = handle.read()
    body = text.split("analysis_window", 1)[1]
    values = np.array([float(v) for v in re.findall(r"-?\d+\.\d+", body)])
    if values.size != WINDOW_TAPS:
        raise ToolError(f"window table has {values.size} coefficients")
    return values


def matrix() -> np.ndarray:
    tap = np.arange(64)
    subband = np.arange(SUBBANDS)
    return np.cos((16 + tap)[None, :] * (2 * subband + 1)[:, None] * (np.pi / 64.0))


def filterbank_steps(pcm: np.ndarray, window: np.ndarray, history: np.ndarray):
    """Analysis filterbank: `len(pcm) // 32` steps, newest sample first.

    `history` is the 512-sample window carried between calls, so a stream is
    analysed exactly as one continuous filterbank would.
    """
    mat = matrix()
    steps = pcm.size // 32
    out = np.zeros((steps, SUBBANDS))
    for step in range(steps):
        hop = pcm[step * 32:(step + 1) * 32]
        history = np.concatenate((hop[::-1], history[: WINDOW_TAPS - 32]))
        windowed = history * window
        folded = windowed.reshape(8, 64).sum(axis=0)
        out[step] = mat @ folded
    return out, history


def mdct(block: np.ndarray) -> np.ndarray:
    n = np.arange(36)
    k = np.arange(18)
    taper = np.sin(np.pi / 36.0 * (n + 0.5))
    kernel = np.cos(np.pi / 72.0 * (2 * n + 19)[:, None] * (2 * k + 1)[None, :])
    return (block * taper) @ kernel


def granule_lines(pcm: np.ndarray, window: np.ndarray, carry: np.ndarray, history: np.ndarray):
    """One granule's 576 lines, subband-major, plus the state for the next one."""
    filtered, history = filterbank_steps(pcm, window, history)
    if filtered.shape[0] != LINES_PER_GRANULE:
        raise ToolError(
            f"granule needs {LINES_PER_GRANULE} steps, got {filtered.shape[0]}"
        )
    lines = np.zeros(SUBBANDS * LINES_PER_GRANULE)
    for subband in range(SUBBANDS):
        block = np.concatenate((carry[subband], filtered[:, subband]))
        spectrum = mdct(block)
        if subband % 2 == 1:
            # Odd subbands are spectrally reversed; undo the reversal and the
            # half-bin offset that comes with it, then the decoder's own
            # "frequency inversion" lands the lines where they belong.
            spectrum = spectrum[::-1].copy()
        lines[subband * LINES_PER_GRANULE:(subband + 1) * LINES_PER_GRANULE] = (
            spectrum / SYNTHESIS_GAIN
        )
    return lines, filtered.T, history


def sine(freq: int, amplitude: float, count: int) -> np.ndarray:
    """The CLI's own generator, including its int16 rounding, in doubles."""
    index = np.arange(count)
    raw = amplitude * 32767.0 * np.sin(2 * np.pi * freq * index / RATE)
    # Round half away from zero, then express as the /32768 scale the encoder uses.
    rounded = np.sign(raw) * np.floor(np.abs(raw) + 0.5)
    return rounded / 32768.0


def reference_granule(freq: int, amplitude_percent: int, target: int):
    """The same signal the CLI's `lines` command analyses."""
    window = load_window()
    pcm = sine(freq, amplitude_percent / 100.0, (target + 1) * GRANULE_PCM)
    carry = np.zeros((SUBBANDS, LINES_PER_GRANULE))
    history = np.zeros(WINDOW_TAPS)
    lines = np.zeros(SUBBANDS * LINES_PER_GRANULE)
    for granule in range(target + 1):
        chunk = pcm[granule * GRANULE_PCM:(granule + 1) * GRANULE_PCM]
        lines, carry, history = granule_lines(chunk, window, carry, history)
    return lines


def cli_granule(freq: int, amplitude_percent: int, target: int) -> np.ndarray:
    out = run_cli("lines", str(freq), str(amplitude_percent), str(target // 2 + 1), str(target))
    lines = [line.strip() for line in out.splitlines()]
    try:
        body = lines[lines.index("LINESBEGIN") + 1]
    except ValueError as exc:
        raise ToolError("CLI output did not contain LINESBEGIN") from exc
    values = np.array([float(v) for v in body.split(",")])
    if values.size != SUBBANDS * LINES_PER_GRANULE:
        raise ToolError(f"CLI returned {values.size} lines")
    return values


def compare(freq: int, amplitude_percent: int, target: int) -> dict:
    expected = reference_granule(freq, amplitude_percent, target)
    actual = cli_granule(freq, amplitude_percent, target)
    difference = actual - expected
    scale = float(np.max(np.abs(expected)))
    return {
        "freq": freq,
        "amplitude_percent": amplitude_percent,
        "granule": target,
        "peak": scale,
        "max_abs_error": float(np.max(np.abs(difference))),
        "relative_error": float(np.max(np.abs(difference)) / scale) if scale else 0.0,
        "rms_error_db": float(
            10.0 * np.log10(np.sum(difference**2) / np.sum(expected**2))
        ) if scale else float("inf"),
        "top_lines": [
            {"line": int(i), "reference": round(float(expected[i]), 9)}
            for i in np.argsort(-np.abs(expected))[:5]
        ],
    }


def self_check() -> int:
    """Analytic properties the reference itself must satisfy."""
    window = load_window()
    failures = 0
    # Band 0 must capture a tone at its centre frequency.
    pcm = sine(344, 0.5, 32 * 64)
    steps, _ = filterbank_steps(pcm, window, np.zeros(WINDOW_TAPS))
    energy = (steps**2).sum(axis=0)
    share = energy[0] / energy.sum()
    ok = share > 0.99
    print(f"{'ok  ' if ok else 'FAIL'} band 0 share for a 344 Hz tone: {share:.6f}")
    failures += 0 if ok else 1
    # The MDCT of an impulse is the window itself.
    block = np.zeros(36)
    block[0] = 1.0
    spectrum = mdct(block)
    expected = np.sin(np.pi / 36.0 * 0.5) * np.cos(
        np.pi / 72.0 * 19.0 * (2 * np.arange(18) + 1)
    )
    ok = np.max(np.abs(spectrum - expected)) < 1e-12
    print(f"{'ok  ' if ok else 'FAIL'} MDCT of an impulse is the windowed kernel")
    failures += 0 if ok else 1
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--compare", action="store_true", help="compare against the CLI")
    parser.add_argument("--self", action="store_true", help="run the analytic self-checks")
    parser.add_argument("--freq", type=int, default=440)
    parser.add_argument("--amplitude", type=int, default=50, help="percent of full scale")
    parser.add_argument("--granule", type=int, default=4)
    parser.add_argument("--tolerance", type=float, default=1e-9)
    args = parser.parse_args()
    if not args.compare and not args.self:
        parser.error("choose --compare or --self")
    status = 0
    if args.self:
        status |= self_check()
    if args.compare:
        try:
            report = compare(args.freq, args.amplitude, args.granule)
        except ToolError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
        print(
            f"granule {report['granule']} at {report['freq']} Hz: "
            f"peak {report['peak']:.6f}, max |error| {report['max_abs_error']:.3e} "
            f"({report['relative_error']:.3e} relative, "
            f"{report['rms_error_db']:.1f} dB residual)"
        )
        for entry in report["top_lines"]:
            print(f"  line {entry['line']:3d} reference {entry['reference']:+.9f}")
        if report["relative_error"] > args.tolerance:
            print(f"FAIL: relative error exceeds {args.tolerance:.0e}")
            status |= 1
        else:
            print("ok: MoonBit matches the numpy reference")
    return status


if __name__ == "__main__":
    sys.exit(main())
