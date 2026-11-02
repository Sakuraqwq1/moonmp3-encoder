#!/usr/bin/env python3
"""A verified model of the reference decoder, and a closed-loop gate for analysis.

Two things this buys, both of which were missing and both of which cost a whole
session to notice:

1. `--verify` reproduces the reference decoder's chain stage by stage (antialias
   on the quantised lines, IMDCT plus overlap-add into subband samples, frequency
   inversion on odd bands, the cosine matrix and the two-term U build with the 512
   tap synthesis window) and compares it with libsndfile on the count1 tone probe.
   It agrees to about 127 dB, which is the int16 print limit, so this model *is*
   the decoder.

2. `--score` runs a candidate analysis through that decoder with no quantisation
   at all and reports the closed-loop SNR. A correct analysis reconstructs the
   tone; a mirrored odd band comes back at the mirrored frequency; a wrong
   transition band collapses near a subband boundary. This is the oracle the
   analysis work was missing: it turns "does this fold look right?" into a number,
   and it needs no MoonBit rebuild.

Why it matters: before the 2026-11-02 night fix the shipped analysis scored
35 dB at 440 Hz but 0.07 dB at 685 Hz *with no quantisation in the loop*, so the
boundary collapse was structural and not a bit-budget or quantiser problem. The
analysis now in `src/mp3/analysis.mbt` — spec matrix, window `C = D / 32`,
odd-band `(-1)^n`, 1/9 gain, antialias pre-compensation — scores 84.44 dB on
white noise and 96.66 dB at 685 Hz, at delay 1057 and gain 1.00000.

    python tools/decoder_ref.py --verify
    python tools/decoder_ref.py --score --freq 685
"""

from __future__ import annotations

import argparse
import os
import re
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mp3lab import ToolError, decode_mp3, extract_payload, run_cli  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WINDOW_FILE = os.path.join(ROOT, "src", "mp3", "window.mbt")

# antialias butterflies, ISO/IEC 11172-3 Table B.9 (as published by go-mp3)
CS = np.array([0.857493, 0.881742, 0.949629, 0.983315, 0.995518, 0.999161, 0.999899, 0.999993])
CA = np.array([-0.514496, -0.471732, -0.313377, -0.181913, -0.094574, -0.040966, -0.014199, -0.003700])

_tap = np.arange(64)
_band = np.arange(32)
MATRIX = np.cos((16 + _tap)[:, None] * (2 * _band + 1)[None, :] * np.pi / 64)  # (64, 32)
_p = np.arange(36)
_m = np.arange(18)
IMDCT_KERNEL = np.cos(np.pi / 72.0 * (2 * _p + 19)[:, None] * (2 * _m + 1)[None, :])  # (36, 18)
IMDCT_WINDOW = np.sin(np.pi / 36.0 * (_p + 0.5))


def load_synthesis_window() -> np.ndarray:
    with open(WINDOW_FILE, encoding="utf-8") as handle:
        text = handle.read()
    values = np.array([float(v) for v in re.findall(r"-?\d+\.\d+", text.split("analysis_window", 1)[1])])
    if values.size != 512:
        raise ToolError(f"window table has {values.size} coefficients")
    return values


SYNTH_WINDOW = load_synthesis_window()


def antialias(values: np.ndarray) -> np.ndarray:
    out = values.copy()
    for sb in range(1, 32):
        for i in range(8):
            li = 18 * sb - 1 - i
            ui = 18 * sb + i
            lower, upper = out[li], out[ui]
            out[li] = lower * CS[i] - upper * CA[i]
            out[ui] = upper * CS[i] + lower * CA[i]
    return out


def imdct_win(lines: np.ndarray) -> np.ndarray:
    return (IMDCT_KERNEL @ lines) * IMDCT_WINDOW


def synthesis_step(s_vec: np.ndarray, v: np.ndarray) -> np.ndarray:
    """One 32-sample step of the subband synthesis; `v` is mutated in place."""
    v[64:] = v[: 1024 - 64]
    v[:64] = MATRIX @ s_vec
    u = np.zeros(512)
    for i in range(0, 512, 64):
        u[i:i + 32] = v[2 * i: 2 * i + 32]
        u[i + 32:i + 64] = v[2 * i + 96: 2 * i + 128]
    u = u * SYNTH_WINDOW
    return u.reshape(16, 32).sum(axis=0)


def decode_granules(granules) -> np.ndarray:
    """A channel's 576-line granules -> time samples, exactly as the decoder does."""
    v = np.zeros(1024)
    store = np.zeros((32, 18))
    output = []
    for lines in granules:
        values = antialias(lines)
        subband = np.zeros(576)
        for sb in range(32):
            raw = imdct_win(values[sb * 18:(sb + 1) * 18])
            subband[sb * 18:(sb + 1) * 18] = raw[:18] + store[sb]
            store[sb] = raw[18:]
        for sb in range(1, 32, 2):
            subband[sb * 18 + 1:sb * 18 + 18:2] *= -1
        for t in range(18):
            s_vec = np.array([subband[i * 18 + t] for i in range(32)])
            output.extend(synthesis_step(s_vec, v))
    return np.array(output)


def probe_lines(frames: int, line: int, gain: int) -> list:
    """The count1 test stream's granules, at the decoder's requantised scale."""
    value = 2 ** ((gain - 210) / 4.0)
    granules = []
    for _ in range(frames * 2):
        lines = np.zeros(576)
        lines[line] = value
        granules.append(lines)
    return granules


def verify(frames: int = 4, line: int = 12, gain: int = 206) -> float:
    """Agreement in dB between this model and libsndfile on the tone probe."""
    predicted = decode_granules(probe_lines(frames, line, gain))
    payload = extract_payload(run_cli("tone", str(frames), str(line), str(gain), "1"))
    decoded, _ = decode_mp3(payload)
    actual = decoded[:, 0].astype(np.float64)
    n = min(predicted.size, actual.size)
    best = (0, -1e18)
    for delay in range(0, 600):
        if delay + n > predicted.size:
            break
        chunk = predicted[delay:delay + n]
        score = np.dot(chunk, actual[:n]) ** 2 / max(np.dot(chunk, chunk), 1e-18)
        if score > best[1]:
            best = (delay, score)
    chunk = predicted[best[0]:best[0] + n]
    reference = actual[:n]
    gain_fit = np.dot(chunk, reference) / max(np.dot(chunk, chunk), 1e-18)
    residual = reference - gain_fit * chunk
    return 10 * np.log10(np.dot(reference, reference) / max(np.dot(residual, residual), 1e-30))


def shipped_analysis(samples: np.ndarray) -> list:
    """The analysis before the 2026-11-02 filterbank fix, kept as a fixed point.

    Synthesis-form matrix, window `D` instead of `D / 32`, odd-band line
    reversal, 1/288 gain. It scores 0.01 dB on white noise through this decoder,
    and the number is kept so the fix has a fixed reference to be compared with:
    `analysis_model` below is the replacement.
    """
    tap = np.arange(64)
    band = np.arange(32)
    matrix = np.cos((16 + tap)[None, :] * (2 * band + 1)[:, None] * np.pi / 64)
    n = np.arange(36)
    k = np.arange(18)
    kernel = np.cos(np.pi / 72.0 * (2 * n + 19)[:, None] * (2 * k + 1)[None, :])
    taper = np.sin(np.pi / 36.0 * (n + 0.5))
    granules = samples.size // 576
    history = np.zeros(512)
    carry = np.zeros((32, 18))
    out = []
    for g in range(granules):
        chunk = samples[g * 576:(g + 1) * 576]
        sub = np.zeros((32, 18))
        for step in range(18):
            hop = chunk[step * 32:(step + 1) * 32]
            history = np.concatenate((hop[::-1], history[:480]))
            sub[:, step] = matrix @ ((history * SYNTH_WINDOW).reshape(8, 64).sum(axis=0))
        lines = np.zeros(576)
        for sb in range(32):
            block = np.concatenate((carry[sb], sub[sb]))
            spectrum = (block * taper) @ kernel
            if sb % 2 == 1:
                spectrum = spectrum[::-1].copy()
            lines[sb * 18:(sb + 1) * 18] = spectrum / 288.0
        carry = sub
        out.append(lines)
    return out


def analysis_model(samples: np.ndarray) -> list:
    """The analysis as checked in since the 2026-11-02 night handoff.

    ISO/IEC 11172-3 Annex C.1.3 analysis matrix `cos((2m+1)(k-16)pi/64)`, the
    analysis window `C = D / 32`, the `(-1)^n` Layer III odd-band orientation,
    the 1/9 synthesis gain, and the transpose of the decoder's antialias stage.
    Deliberately written as a separate function from `src/mp3/analysis.mbt`, so
    `analysis_ref.py` and the MoonBit CLI can be compared against it.

    Measured through `decode_granules` with no quantisation, white noise:
    84.47 dB, delay 1057, fitted gain 1.00000. Without the antialias
    compensation the same chain gives 11.55 dB; without the odd-band sign,
    1.2 dB.
    """
    from spec_filterbank import AnalysisFilterbank

    window = SYNTH_WINDOW / 32.0
    bank = AnalysisFilterbank(window, matrix="spec", layer3_inversion=True)
    taper = np.sin(np.pi / 36.0 * (np.arange(36) + 0.5))
    kernel = np.cos(np.pi / 72.0 * (2 * np.arange(36) + 19)[:, None] * (2 * np.arange(18) + 1)[None, :])
    granules = samples.size // 576
    carry = np.zeros((32, 18))
    out = []
    for g in range(granules):
        chunk = samples[g * 576:(g + 1) * 576]
        sub = np.zeros((32, 18))
        for step in range(18):
            sub[:, step] = bank.step(chunk[step * 32:(step + 1) * 32])
        lines = np.zeros(576)
        for sb in range(32):
            block = np.concatenate((carry[sb], sub[sb]))
            lines[sb * 18:(sb + 1) * 18] = ((block * taper) @ kernel) / 9.0
        carry = sub
        out.append(antialias_compensation(lines))
    return out


def antialias_compensation(lines: np.ndarray) -> np.ndarray:
    """Transpose of `antialias()`: what the encoder has to write so the decoder
    can rotate it back."""
    out = lines.copy()
    for sb in range(1, 32):
        for i in range(8):
            li = 18 * sb - 1 - i
            ui = 18 * sb + i
            lower, upper = out[li], out[ui]
            out[li] = lower * CS[i] + upper * CA[i]
            out[ui] = upper * CS[i] - lower * CA[i]
    return out


def score(analysis, freq: float, granules: int = 24, skip: int = 4, noise: bool = False) -> dict:
    """Closed-loop SNR of an analysis candidate: analyse, decode, compare.

    With `noise` the probe is white noise. That matters: a periodic probe lets the
    delay search lock onto a different cycle (204 samples for a 440 Hz tone is two
    periods), which turns a phase offset into a fake SNR. Measurements recorded
    before this was noticed are suspect; the noise probe has no such ambiguity.
    """
    count = 576 * granules
    index = np.arange(count)
    if noise:
        tone = np.random.default_rng(5).standard_normal(count)
    else:
        tone = np.sin(2 * np.pi * freq * index / 44100.0)
    rebuilt = decode_granules(analysis(tone))
    start = skip * 576
    # The whole loop is 1057 samples late: 481 from the filterbank, 576 from the
    # half-block overlap (a granule's MDCT covers the previous granule as well).
    max_delay = 1200
    n = min(rebuilt.size, tone.size) - start - max_delay
    reference = tone[start:start + n]
    best = (0, -1e18)
    for delay in range(0, max_delay):
        chunk = rebuilt[start + delay:start + delay + n]
        value = np.dot(chunk, reference) ** 2 / max(np.dot(chunk, chunk) * np.dot(reference, reference), 1e-18)
        if value > best[1]:
            best = (delay, value)
    chunk = rebuilt[start + best[0]:start + best[0] + n]
    gain = np.dot(chunk, reference) / max(np.dot(chunk, chunk), 1e-18)
    residual = reference - gain * chunk
    snr = 10 * np.log10(np.dot(reference, reference) / max(np.dot(residual, residual), 1e-30))
    window = np.hanning(n)
    power = np.abs(np.fft.rfft(chunk * window))
    grid = np.fft.rfftfreq(n, 1 / 44100.0)
    return {
        "freq": freq,
        "snr_db": round(float(snr), 2),
        "dominant_hz": round(float(grid[int(np.argmax(power[1:])) + 1]), 1),
        "delay": int(best[0]),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--verify", action="store_true", help="agree with libsndfile on the tone probe")
    parser.add_argument("--score", action="store_true", help="closed-loop score of the shipped analysis")
    parser.add_argument("--freq", type=float, default=0.0, help="one frequency, or all when omitted")
    parser.add_argument("--noise", action="store_true", help="also score white noise (no phase ambiguity)")
    args = parser.parse_args()
    if not args.verify and not args.score:
        parser.error("choose --verify or --score")
    status = 0
    if args.verify:
        agreement = verify()
        print(f"decoder model vs libsndfile: {agreement:.1f} dB")
        if agreement < 40.0:
            print("FAIL: the model does not reproduce the decoder")
            status |= 1
        else:
            print("ok: the model is the decoder (int16 limited)")
    if args.score:
        freqs = [args.freq] if args.freq else [440.0, 685.0, 1000.0, 1390.0, 3000.0, 8000.0]
        if args.noise:
            report = score(analysis_model, 0.0, noise=True)
            print(f"white noise: closed-loop {report['snr_db']:7.2f} dB "
                  f"(delay {report['delay']})")
            legacy = score(shipped_analysis, 0.0, noise=True)
            print(f"white noise, pre-fix analysis: {legacy['snr_db']:7.2f} dB "
                  f"(delay {legacy['delay']})")
        for freq in freqs:
            report = score(analysis_model, freq)
            print(
                f"{report['freq']:7.0f} Hz: closed-loop {report['snr_db']:7.2f} dB, "
                f"dominant {report['dominant_hz']:7.1f} Hz (delay {report['delay']})"
            )
    return status


if __name__ == "__main__":
    sys.exit(main())
