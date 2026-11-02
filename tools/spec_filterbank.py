#!/usr/bin/env python3
"""ISO/IEC 11172-3 32-band polyphase analysis filterbank - spec-structure numpy reference.

This is the encoder-side filterbank written exactly in the structure of the
standard (Annex C.1.3, Figure C.4 "Analysis subband filter"), quoted verbatim
in publicly published descriptions (IBM RC J. Research implementation paper on
the MPEG encoder; MPEG-2 analysis-filter patents CN1144357C/CN1241843A that
reproduce the ISO algebra; clean-room write-ups of the standard text):

    per step: 32 PCM samples in -> 32 subband samples out (rate fs/32)

    1. Input shift register (512 samples, most recent at X[0]):
           for i = 511 downto 32:  X[i] = X[i-32]
           for i = 31  downto 0:   X[i] = next input sample
    2. Window:                    Z[i] = C[i] * X[i],  i = 0..511
    3. Folding (8 taps -> 1):     Y[k] = sum_{j=0..7} Z[k + 64*j],  k = 0..63
    4. Matrixing (32x64):         S[m] = sum_{k=0..63} M[m][k] * Y[k]
           M[m][k] = cos((2m+1) * (k - 16) * pi / 64)

Why the matrix is that one and not cos((16+k)(2m+1)pi/64): the latter is the
*synthesis* (decoder) matrix N of ISO 2.4.3.2, where the 64-long index is the
matrixing output. Using it on the analysis side makes the modulation a
double-sideband one (carrier x block-parity square wave -> responses in band m
and band m+1 with the wrong relative phase), which leaks neighbouring bands and
mirrors the odd subbands' in-band spectrum. The analysis form
cos((2m+1)(k-16)pi/64) is single-sideband by construction.

Layer III orientation: the raw spec filterbank above is LTI, so decimating by
32 folds any tone to |f - 1378.125*round(f/1378.125)| Hz inside its subband:
even subbands come out as (f - m*689.0625), odd subbands mirrored as
((m+1)*689.0625 - f). Layer III compensates this on the decode side between
IMDCT and synthesis by negating every other sample of every odd subband
(minimp3's L3_change_sign; the same operation the standard's decoder applies).
The encoder must pre-apply the identical flip so the MDCT sees the unmirrored
representation. This module therefore exposes the flip as an explicit final
step (`layer3_inversion`, on by default); `analyze(..., layer3_inversion=False)`
gives the raw Layer I/II view.

Tables: the 512 synthesis-window coefficients D are the checked-in
src/mp3/window.mbt (verified against go-mp3, Apache-2.0, numbers only - see
tools/window_table.py). The analysis window is C = D/32, the relation stated
in the standard (the ISO analysis table C.1 is D/32; peaks 0.035780907 * 32 =
1.144989014). Only numpy is used.

    python tools/spec_filterbank.py --self     # run every check, print numbers
    python tools/spec_filterbank.py --probe    # variant comparison table
"""

from __future__ import annotations

import argparse
import math
import os
import re
import sys

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WINDOW_MBT = os.path.join(ROOT, "src", "mp3", "window.mbt")

FS = 44100
SUBBAND_RATE = FS / 32.0  # 1378.125 Hz
SUBBAND_WIDTH = FS / 64.0  # 689.0625 Hz


def load_tables() -> tuple[np.ndarray, np.ndarray]:
    """Return (C, D): the 512 analysis coefficients and the synthesis window."""
    with open(WINDOW_MBT, encoding="utf-8") as handle:
        text = handle.read()
    literals = re.findall(r"-?\d+\.\d+", text.split("analysis_window", 1)[1])
    if len(literals) != 512:
        raise SystemExit(f"expected 512 window coefficients, found {len(literals)}")
    D = np.array([float(v) for v in literals])
    return D / 32.0, D


class AnalysisFilterbank:
    """Figure C.4 verbatim, plus the Layer III odd-subband inversion switch."""

    def __init__(
        self,
        window: np.ndarray,
        matrix: str = "spec",
        layer3_inversion: bool = True,
    ):
        self.window = window
        self.X = np.zeros(512)  # X[0] newest, X[511] oldest
        m = np.arange(32)
        k = np.arange(64)
        if matrix == "spec":
            # M[m][k] = cos((2m+1)(k-16)pi/64), (k-16) signed
            self.M = np.cos((2 * m[:, None] + 1) * (k[None, :] - 16) * np.pi / 64.0)
        elif matrix == "synth-form":
            # The decoder's N matrix misused on the analysis side. This is what
            # src/mp3/analysis.mbt shipped before this reference existed; it is
            # kept here only to measure the difference.
            self.M = np.cos((16 + k[None, :]) * (2 * m[:, None] + 1) * np.pi / 64.0)
        else:
            raise SystemExit(f"unknown matrix form: {matrix}")
        self.layer3_inversion = layer3_inversion
        self.step_index = 0

    def step(self, pcm32: np.ndarray) -> np.ndarray:
        """Consume 32 samples (pcm32[0] oldest, pcm32[31] newest), return S[0..31]."""
        if pcm32.shape != (32,):
            raise SystemExit(f"analysis step needs exactly 32 samples, got {len(pcm32)}")
        # X[i] = X[i-32] for i=511..32, then the 32 new samples, newest at X[0]
        self.X = np.concatenate((pcm32[::-1], self.X[:480]))
        Z = self.window * self.X
        # Folding: Y[k] = sum_j Z[k + 64j] - taps k, k+64, ..., k+448
        Y = Z.reshape(8, 64).sum(axis=0)
        S = self.M @ Y
        if self.layer3_inversion and (self.step_index & 1):
            S[1::2] = -S[1::2]  # (-1)^n on odd subbands
        self.step_index += 1
        return S


class SynthesisFilterbank:
    """The normative decoder filterbank (ISO 2.4.3.2, Figure A.2), for round trips."""

    def __init__(self, synth_window: np.ndarray):
        self.D = synth_window
        self.V = np.zeros(1024)
        i = np.arange(64)
        k = np.arange(32)
        self.N = np.cos((16 + i[:, None]) * (2 * k[None, :] + 1) * np.pi / 64.0)

    def step(self, S: np.ndarray) -> np.ndarray:
        """Consume 32 subband samples, produce 32 PCM samples."""
        # V[i] = V[i-64] for i=1023..64, then V[0..63] = N @ S
        self.V = np.concatenate((self.N @ S, self.V[:960]))
        # Folding: U[64i+j] = V[128i+j], U[64i+32+j] = V[128i+96+j]
        blocks = self.V.reshape(8, 128)
        U = np.empty((8, 64))
        U[:, :32] = blocks[:, :32]
        U[:, 32:] = blocks[:, 96:]
        W = U.reshape(512) * self.D
        # out[j] = sum_{i=0..15} W[j + 32i]
        return W.reshape(16, 32).sum(axis=0)


def analyze(
    pcm: np.ndarray,
    window: np.ndarray,
    matrix: str = "spec",
    layer3_inversion: bool = True,
) -> np.ndarray:
    """Full stream -> (32, n_steps) subband matrix, S[subband, step]."""
    if len(pcm) % 32:
        raise SystemExit("analyze() needs a whole number of 32-sample steps")
    bank = AnalysisFilterbank(window, matrix=matrix, layer3_inversion=layer3_inversion)
    steps = len(pcm) // 32
    out = np.empty((32, steps))
    for step in range(steps):
        out[:, step] = bank.step(pcm[32 * step : 32 * step + 32])
    return out


def synthesize(S: np.ndarray, synth_window: np.ndarray) -> np.ndarray:
    """(32, n_steps) subband matrix -> PCM stream."""
    bank = SynthesisFilterbank(synth_window)
    out = np.empty(S.shape[1] * 32)
    for step in range(S.shape[1]):
        out[32 * step : 32 * step + 32] = bank.step(S[:, step])
    return out


def dominant_peak(signal: np.ndarray) -> float:
    """FFT peak frequency with parabolic interpolation, in Hz of the signal's rate."""
    spectrum = np.abs(np.fft.rfft(signal))
    freqs = np.fft.rfftfreq(len(signal), 1.0 / SUBBAND_RATE)
    index = int(np.argmax(spectrum))
    if index == 0 or index == len(spectrum) - 1:
        return float(freqs[index])
    a, b, c = (np.log(spectrum[index + delta] + 1e-30) for delta in (-1, 0, 1))
    delta = 0.5 * (a - c) / (a - 2.0 * b + c)
    return float(freqs[index] + delta * (freqs[1] - freqs[0]))


TONE_CASES = (
    # (input Hz, expected subband, user's stated in-band value)
    (440.0, 0, 441.0),
    (1000.0, 1, 311.0),
    (3000.0, 4, 244.0),
    (8000.0, 11, 420.0),
)


def tone_case(
    freq: float,
    window: np.ndarray,
    matrix: str = "spec",
    layer3_inversion: bool = True,
    steps: int = 400,
    keep: int = 200,
) -> dict:
    """The acceptance protocol: 400 steps, FFT the last 200 of every subband."""
    n = steps * 32
    pcm = 0.5 * np.sin(2.0 * np.pi * freq * np.arange(n) / FS)
    S = analyze(pcm, window, matrix=matrix, layer3_inversion=layer3_inversion)
    S = S[:, steps - keep :]
    energy = (S**2).sum(axis=1)
    subband = int(np.argmax(energy))
    share = float(energy[subband] / energy.sum())
    return {
        "subband": subband,
        "in_band_hz": dominant_peak(S[subband]),
        "energy_share": share,
    }


def round_trip_case(window: np.ndarray, synth_window: np.ndarray, steps: int = 1200) -> dict:
    """Analysis -> synthesis must reconstruct the input delayed (no Layer III flip)."""
    rng = np.random.default_rng(7)
    pcm = rng.uniform(-0.5, 0.5, steps * 32)
    S = analyze(pcm, window, layer3_inversion=False)
    out = synthesize(S, synth_window)
    best = None
    for delay in range(384, 640):
        n = len(pcm) - delay
        error = out[delay : delay + n] - pcm[:n]
        rms = float(np.sqrt(np.mean(error[2000:] ** 2)))
        if best is None or rms < best[1]:
            best = (delay, rms)
    return {"delay": best[0], "rms": best[1]}


def table_sanity(C: np.ndarray, D: np.ndarray) -> list[str]:
    lines = []
    peak = float(np.max(np.abs(C)))
    lines.append(f"C peak |C|max = {peak:.9f} at i={int(np.argmax(np.abs(C)))} "
                 f"(ISO value 0.035780907 at i=256)")
    # oxideav-documented symmetry: C[512-i] = +C[i] if i%64==0 else -C[i]
    worst = 0.0
    for i in range(1, 512):
        expected = C[i] if i % 64 == 0 else -C[i]
        worst = max(worst, abs(C[512 - i] - expected))
    lines.append(f"C symmetry C[512-i] = +/-C[i] (ISO rule): max deviation {worst:.3e}")
    lines.append(f"D = 32*C max deviation {float(np.max(np.abs(D - 32*C))):.3e}")
    return lines


def run_self() -> int:
    C, D = load_tables()
    print("== table sanity ==")
    for line in table_sanity(C, D):
        print("  " + line)

    print("== analysis->synthesis round trip (raw filterbank, no Layer III flip) ==")
    rt = round_trip_case(C, D)
    print(f"  best delay = {rt['delay']} samples (spec pair documented at 481)")
    print(f"  steady-state rms error = {rt['rms']:.3e}")

    print("== tone acceptance, Layer III view (spec matrix + odd-subband inversion) ==")
    failures = 0
    for freq, subband, stated in TONE_CASES:
        result = tone_case(freq, C)
        expected_hz = freq - subband * SUBBAND_WIDTH
        ok = (
            result["subband"] == subband
            and abs(result["in_band_hz"] - expected_hz) < 2.0
            and result["energy_share"] > 0.95
        )
        failures += 0 if ok else 1
        print(
            f"  {freq:7.1f} Hz -> subband {result['subband']:2d} "
            f"(expect {subband:2d}), in-band {result['in_band_hz']:8.3f} Hz "
            f"(expect {expected_hz:8.3f}, user stated ~{stated}), "
            f"energy share {result['energy_share']:.4f} "
            f"{'ok' if ok else 'FAIL'}"
        )

    print("== same protocol, raw spec filterbank (before the Layer III flip) ==")
    for freq, subband, _stated in TONE_CASES:
        result = tone_case(freq, C, layer3_inversion=False)
        mirror = (subband + 1) * SUBBAND_WIDTH - freq
        print(
            f"  {freq:7.1f} Hz -> subband {result['subband']:2d}, "
            f"in-band {result['in_band_hz']:8.3f} Hz "
            f"(even band: {freq - subband * SUBBAND_WIDTH:8.3f}, "
            f"odd-band mirror: {mirror:8.3f}), "
            f"energy share {result['energy_share']:.4f}"
        )

    rt_ok = rt["rms"] < 1e-3
    print(f"round trip: {'ok' if rt_ok else 'FAIL'}")
    return 0 if failures == 0 and rt_ok else 1


def run_probe() -> int:
    C, D = load_tables()
    print("variant comparison on the 1000 Hz and 8000 Hz cases")
    print("(expected in-band: 310.9375 and 420.3125; mirrors: 378.125 and 268.75)")
    variants = (
        ("spec matrix + L3 inversion (this reference)", "spec", True),
        ("spec matrix, raw", "spec", False),
        ("synth-form matrix, raw (old src/mp3/analysis.mbt)", "synth-form", False),
        ("synth-form matrix + L3 inversion", "synth-form", True),
    )
    for name, matrix, flip in variants:
        for freq, subband in ((1000.0, 1), (8000.0, 11)):
            result = tone_case(freq, C, matrix=matrix, layer3_inversion=flip)
            print(
                f"  {name:52s} {freq:7.1f} Hz -> subband {result['subband']:2d}, "
                f"in-band {result['in_band_hz']:8.3f} Hz, share {result['energy_share']:.4f}"
            )

    print("== analysis->synthesis round trip per matrix form (no flip) ==")
    rng = np.random.default_rng(7)
    pcm = rng.uniform(-0.5, 0.5, 1200 * 32)
    ref = float(np.sqrt(np.mean(pcm**2)))
    for name, matrix in (("spec", "spec"), ("synth-form (old analysis.mbt)", "synth-form")):
        out = synthesize(analyze(pcm, C, matrix=matrix, layer3_inversion=False), D)
        best = None
        for delay in range(384, 640):
            n = len(pcm) - delay
            rms = float(np.sqrt(np.mean((out[delay : delay + n] - pcm[:n])[2000:] ** 2)))
            if best is None or rms < best[1]:
                best = (delay, rms)
        print(
            f"  {name:34s} delay {best[0]}, rms {best[1]:.3e} "
            f"({20 * math.log10(best[1] / ref):+.1f} dB)"
        )
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--self", action="store_true", help="run every check")
    group.add_argument("--probe", action="store_true", help="variant comparison")
    args = parser.parse_args(argv)
    if args.probe:
        return run_probe()
    return run_self()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
