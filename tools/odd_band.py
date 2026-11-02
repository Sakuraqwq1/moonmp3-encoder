#!/usr/bin/env python3
"""Calibrate the odd-subband line map against the decoder, then keep the winner.

The analysis filterbank is a pseudo-QMF: odd subbands come out spectrally
reversed inside their band, so a 1000 Hz tone lands near bin 10 of subband 1
where it belongs at bin 8. Undoing that is a line-domain permutation, but the
exact map is not obvious from the standard's text — the reversal axis and the
half-bin offset both have to be right, and getting one of them wrong still
decodes *at the right frequency* while destroying the waveform.

So it is measured. Each candidate map is written into `odd_band_value`, the
encoder is rebuilt, and a 1000 Hz and an 8000 Hz tone (both in odd subbands) are
decoded and scored on SNR. The best map wins and the calibration is recorded
here so a later reader knows the numbers were measured, not guessed.

    python tools/odd_band.py            # try every candidate, report, keep best
    python tools/odd_band.py --report   # only score what is checked in
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import snr
from mp3lab import ROOT, ToolError, decode_mp3, extract_payload, run_cli

ANALYSIS = os.path.join(ROOT, "src", "mp3", "analysis.mbt")
MARKER_START = "fn odd_band_value(spectrum : Array[Double], subband : Int32, line : Int32) -> Double {"
MARKER_END = "\n}\n"

CANDIDATES = {
    "identity": "  let _ = subband\n  spectrum[line]",
    "reverse17": "  if subband % 2 == 0 {\n    return spectrum[line]\n  }\n  spectrum[17 - line]",
    "reverse17_alt": (
        "  if subband % 2 == 0 {\n    return spectrum[line]\n  }\n"
        "  let value = spectrum[17 - line]\n"
        "  if line % 2 == 1 {\n    return -value\n  }\n  value"
    ),
    "reverse17_alt_even": (
        "  if subband % 2 == 0 {\n    return spectrum[line]\n  }\n"
        "  let value = spectrum[17 - line]\n"
        "  if line % 2 == 0 {\n    return -value\n  }\n  value"
    ),
    "reverse18": (
        "  if subband % 2 == 0 {\n    return spectrum[line]\n  }\n"
        "  if line == 0 {\n    return 0.0\n  }\n  spectrum[18 - line]"
    ),
    "reverse18_alt": (
        "  if subband % 2 == 0 {\n    return spectrum[line]\n  }\n"
        "  if line == 0 {\n    return 0.0\n  }\n"
        "  let value = spectrum[18 - line]\n"
        "  if line % 2 == 1 {\n    return -value\n  }\n  value"
    ),
}


def _body_bounds(text: str) -> tuple[int, int]:
    """Span of the function body: after the opening brace, before its match."""
    start = text.index(MARKER_START) + len(MARKER_START)
    depth = 1
    index = start
    while index < len(text):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return start, index
        index += 1
    raise SystemExit("unterminated odd_band_value")


def install(body: str) -> None:
    with open(ANALYSIS, encoding="utf-8") as handle:
        text = handle.read()
    start, end = _body_bounds(text)
    with open(ANALYSIS, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text[:start] + "\n" + body + "\n" + text[end:])


def current_body() -> str:
    with open(ANALYSIS, encoding="utf-8") as handle:
        text = handle.read()
    start, end = _body_bounds(text)
    return text[start:end].strip("\n")


def score(freq: int, frames: int = 39) -> dict:
    payload = extract_payload(run_cli("sine", str(frames), str(freq), "50", "1"))
    data, rate = decode_mp3(payload)
    count = frames * 1152
    index = np.arange(count)
    reference = np.round(0.5 * 32767 * np.sin(2 * np.pi * freq * index / 44100.0))
    reference = reference.astype(np.int16)
    reference_path = os.path.join(ROOT, "target", "odd_ref.wav")
    candidate_path = os.path.join(ROOT, "target", "odd_cand.mp3")
    import soundfile as sf

    sf.write(reference_path, reference, 44100, subtype="PCM_16")
    with open(candidate_path, "wb") as handle:
        handle.write(payload)
    result = snr.measure(reference_path, candidate_path)
    report = {
        "freq": freq,
        "snr_db": round(float(result["overall_snr_db"]), 2),
        "delay": int(result["delay_samples"]),
    }
    spectrum_slice = data[2304:, 0].astype(np.float64)
    window = min(16384, spectrum_slice.size)
    segment = spectrum_slice[:window] - spectrum_slice[:window].mean()
    power = np.abs(np.fft.rfft(segment * np.hanning(window)))
    frequencies = np.fft.rfftfreq(window, 1 / rate)
    peak = float(frequencies[int(np.argmax(power[1:])) + 1])
    report["dominant_hz"] = round(peak, 1)
    return report


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--report", action="store_true", help="score only the checked-in map")
    args = parser.parse_args()

    original = current_body()
    results = []
    try:
        for name, body in (CANDIDATES.items() if not args.report else [("checked-in", original)]):
            if not args.report:
                install(body)
            rows = [score(freq) for freq in (1000, 8000, 440)]
            mean = round(sum(row["snr_db"] for row in rows) / len(rows), 2)
            worst = min(row["snr_db"] for row in rows)
            results.append((name, mean, worst, rows))
            print(
                f"{name:20s} mean {mean:7.2f} dB  worst {worst:7.2f} dB  "
                + "  ".join(f'{row["freq"]}Hz:{row["snr_db"]:+.2f}/{row["dominant_hz"]:.0f}' for row in rows)
            )
    finally:
        if not args.report:
            install(original)

    if not args.report:
        best = max(results, key=lambda item: (item[2], item[1]))
        print(f"\nbest by worst-case SNR: {best[0]} (mean {best[1]} dB, worst {best[2]} dB)")
        print("re-run with the winning map installed; the choice is recorded in analysis.mbt")
    return 0


if __name__ == "__main__":
    sys.exit(main())
