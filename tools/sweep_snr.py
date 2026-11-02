#!/usr/bin/env python3
"""Sweep SNR across the spectrum, at the codec's measured delay.

Spot-checking a few round frequencies hides defects: 440, 880, 3000, 8000 and
12000 Hz all look healthy, so a collapse sits behind them. This walks a tone from
440 Hz to 12 kHz, deliberately stepping close to the 689.0625 Hz subband
boundaries, and reports SNR and the decoded dominant frequency for each.

Alignment is not a detail here. The encoder's delay is the constant 1057
samples — 481 from the analysis/synthesis filterbank pair plus 576 from the
half-block overlap (a granule's MDCT covers the previous granule too) — and a
correlation search cannot recover a constant that is already known, because a
tone's autocorrelation has sidelobes almost as tall as its peak. Measured on the
2026-11-02 night build: `--correlate` reports 16.2 dB at 440 Hz where the true
delay gives 22.1 dB on the same stream. That is the project's own warning about
single-tone criteria, made concrete.

    python tools/sweep_snr.py
    python tools/sweep_snr.py --correlate   # old whole-signal correlation, for contrast
"""

import os
import sys

import numpy as np
import soundfile as sf

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from mp3lab import decode_mp3, extract_payload, run_cli  # noqa: E402
import snr  # noqa: E402

FRAMES = 39
COUNT = FRAMES * 1152
INDEX = np.arange(COUNT)

BAND = 44100.0 / 64.0
# 481 filterbank + 576 half-block overlap; see docs/handoff-2026-11-02-night.md.
DELAY = 1057
REF = os.path.join(ROOT, "target", "sweep_ref.wav")
CAND = os.path.join(ROOT, "target", "sweep.mp3")


def snr_at(freq: float, correlate: bool = False) -> tuple[float, float, int]:
    payload = extract_payload(run_cli("sine", str(FRAMES), str(freq), "50", "1"))
    with open(CAND, "wb") as handle:
        handle.write(payload)
    reference = 0.5 * np.sin(2 * np.pi * freq * INDEX / 44100.0)
    sf.write(REF, np.round(reference * 32767).astype(np.int16), 44100, subtype="PCM_16")
    report = snr.measure(REF, CAND, delay=None if correlate else DELAY)
    data, rate = decode_mp3(payload)
    segment = data[2304:, 0].astype(np.float64)
    window = min(16384, segment.size)
    block = segment[:window] - segment[:window].mean()
    power = np.abs(np.fft.rfft(block * np.hanning(window)))
    grid = np.fft.rfftfreq(window, 1 / rate)
    dominant = float(grid[int(np.argmax(power[1:])) + 1])
    return report["overall_snr_db"], dominant, int(freq // BAND)


FREQS = [440, 560, 620, 640, 655, 670, 685, 700, 720, 760, 880, 1000,
         1300, 1340, 1360, 1390, 1420, 2000, 3000, 4000, 6000, 8000,
         12000]


def main(argv: list[str]) -> int:
    correlate = "--correlate" in argv
    print(f"{'freq':>6} {'band':>4} {'SNR dB':>8} {'dominant':>9}  bar")
    worst = (1e9, 0.0)
    for freq in FREQS:
        value, dominant, band = snr_at(freq, correlate)
        bar = "#" * max(0, int(value)) if value > 0 else "-" * 4
        print(f"{freq:6d} {band:4d} {value:8.2f} {dominant:9.1f}  {bar}")
        if value < worst[0]:
            worst = (value, float(freq))
    print(f"worst: {worst[0]:6.2f} dB at {worst[1]:.0f} Hz")
    return 0 if worst[0] >= 20.0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
