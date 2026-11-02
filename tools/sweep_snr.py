#!/usr/bin/env python3
"""Sweep SNR across the spectrum to size the analysis defect.

Spot-checking a few round frequencies hides it: 440, 880, 3000, 8000 and 12000 Hz
all look healthy, so the defect sits behind them. This walks a tone from 440 Hz
to 12 kHz, deliberately stepping close to the 689.0625 Hz subband boundaries, and
reports SNR and the decoded dominant frequency for each.

The result (recorded in docs/stage1-progress.md) is that reconstruction is only
healthy near subband *centres*: within roughly +-100 Hz of a boundary the SNR
collapses, so close to a third of the spectrum is affected. That is the open
analysis-filterbank defect, not a quantiser problem.

    python tools/sweep_snr.py
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
REF = os.path.join(ROOT, "target", "sweep_ref.wav")
CAND = os.path.join(ROOT, "target", "sweep.mp3")

BAND = 44100.0 / 64.0


def snr_at(freq: float) -> tuple[float, float, int]:
    payload = extract_payload(run_cli("sine", str(FRAMES), str(freq), "50", "1"))
    with open(CAND, "wb") as handle:
        handle.write(payload)
    reference = 0.5 * np.sin(2 * np.pi * freq * INDEX / 44100.0)
    sf.write(REF, np.round(reference * 32767).astype(np.int16), 44100, subtype="PCM_16")
    report = snr.measure(REF, CAND)
    data, rate = decode_mp3(payload)
    segment = data[2304:, 0].astype(np.float64)
    window = min(16384, segment.size)
    block = segment[:window] - segment[:window].mean()
    power = np.abs(np.fft.rfft(block * np.hanning(window)))
    grid = np.fft.rfftfreq(window, 1 / rate)
    dominant = float(grid[int(np.argmax(power[1:])) + 1])
    band = int(freq // BAND)
    return report["overall_snr_db"], dominant, band


FREQS = [440, 560, 620, 640, 655, 670, 685, 700, 720, 760, 880, 1000,
         1300, 1340, 1360, 1390, 1420, 2000, 3000, 4000, 6000, 8000,

         12000]
print(f"{'freq':>6} {'band':>4} {'SNR dB':>8} {'dominant':>9}  bar")
for freq in FREQS:
    value, dominant, band = snr_at(freq)
    bar = "#" * max(0, int(value)) if value > 0 else "-" * 4
    print(f"{freq:6d} {band:4d} {value:8.2f} {dominant:9.1f}  {bar}")
