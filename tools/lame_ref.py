#!/usr/bin/env python3
"""Reproducible benchmark: compare this encoder against LAME 128 kbps mono CBR.

Encodes identical 0.18 s PCM slices (the CLI argument limit) through both:
  - This encoder (MoonBit native / CLI `encode`) at delay 1057
  - LAME 128 kbps mono CBR (via PyAV `libmp3lame`) aligned by signed correlation

Both are decoded by libsndfile and compared against the uncompressed reference.

Usage:
    python tools/lame_ref.py
    python tools/lame_ref.py --json
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys

import av
import numpy as np
import soundfile as sf

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mp3lab import ROOT, decode_mp3, extract_payload, run_cli  # noqa: E402

PROBES = [
    ("440 Hz 正弦", "sine440_mono_1s", False),
    ("multitone", "multitone_mono_1s", False),
    ("扫频", "chirp_mono_500ms", False),
    ("白噪声", "noise_mono_500ms", False),
    ("满幅 99 % 正弦", "fullscale_mono_1s", True),
]

CODEC_DELAY = 1057
MAX_DELAY = 2200
SLICE_SEC = 0.18


def encode_lame(wav_path: str, mp3_path: str, bitrate: int = 128000) -> str:
    """Black-box encode through PyAV's libmp3lame."""
    with av.open(mp3_path, "w") as container:
        stream = container.add_stream("libmp3lame", rate=44100)
        stream.layout = "mono"
        stream.bit_rate = bitrate
        with av.open(wav_path) as source:
            for frame in source.decode(audio=0):
                frame.pts = None
                for packet in stream.encode(frame):
                    container.mux(packet)
            for packet in stream.encode(None):
                container.mux(packet)
    return mp3_path


def align_signed(reference: np.ndarray, decoded: np.ndarray, max_delay: int = MAX_DELAY):
    """Find delay using signed cross-correlation, preventing half-cycle phase lock."""
    length = min(reference.size, decoded.size) - max_delay
    ref = reference[:length]
    best = (-1e18, 0)
    for delay in range(max_delay):
        cand = decoded[delay:delay + length]
        val = np.dot(cand, ref) / np.sqrt(np.dot(cand, cand) * np.dot(ref, ref) + 1e-30)
        if val > best[0]:
            best = (val, delay)
    cand = decoded[best[1]:best[1] + length]
    res = ref - cand
    snr = 10.0 * np.log10(np.dot(ref, ref) / max(np.dot(res, res), 1e-30))
    return snr, best[1], float(best[0])


def snr_at_delay(reference: np.ndarray, decoded: np.ndarray, delay: int, length: int):
    """Compute raw SNR and gain-fitted SNR at a fixed delay."""
    ref = reference[:length]
    cand = decoded[delay:delay + length]
    res = ref - cand
    snr_raw = 10.0 * np.log10(np.dot(ref, ref) / max(np.dot(res, res), 1e-30))
    # Optimal gain fit: argmin_g ||ref - g * cand||^2
    gain = float(np.dot(cand, ref) / max(np.dot(cand, cand), 1e-30))
    res_fit = ref - gain * cand
    snr_fit = 10.0 * np.log10(np.dot(ref, ref) / max(np.dot(res_fit, res_fit), 1e-30))
    return snr_raw, snr_fit, gain


def run_benchmark(fixtures_dir: str | None = None) -> list[dict]:
    fix_dir = fixtures_dir or os.path.join(ROOT, "target", "fixtures")
    target_dir = os.path.join(ROOT, "target", "lame_ref")
    os.makedirs(target_dir, exist_ok=True)

    keep = int(44100 * SLICE_SEC)
    results = []

    for label, fixture_name, is_fullscale in PROBES:
        wav_file = os.path.join(fix_dir, fixture_name + ".wav")
        if not os.path.isfile(wav_file):
            raise FileNotFoundError(f"Fixture not found: {wav_file}; run tools/gen_fixtures.py")

        data, rate = sf.read(wav_file, always_2d=True, dtype="float64")
        if rate != 44100:
            raise ValueError(f"Expected 44.1 kHz, got {rate}")
        reference = data[:keep, 0]
        pcm16 = np.round(reference * 32767.0).astype("<i2")

        # 1. Our encoder
        payload = extract_payload(
            run_cli("encode", base64.b64encode(pcm16.tobytes()).decode(), "1")
        )
        ours_decoded, _ = decode_mp3(payload)
        ours = ours_decoded[:, 0].astype(np.float64)

        # 2. LAME
        src_wav = os.path.join(target_dir, f"{fixture_name}_src.wav")
        sf.write(src_wav, pcm16, 44100, subtype="PCM_16")
        lame_mp3 = os.path.join(target_dir, f"{fixture_name}_lame.mp3")
        encode_lame(src_wav, lame_mp3)
        lame_decoded, _ = sf.read(lame_mp3, always_2d=True, dtype="float64")
        lame = lame_decoded[:, 0]

        # 3. Metrics (common evaluation length = keep - MAX_DELAY = 5738 samples)
        eval_length = min(reference.size, ours.size, lame.size) - MAX_DELAY
        ours_snr, ours_fit, ours_gain = snr_at_delay(reference, ours, CODEC_DELAY, eval_length)
        lame_snr, lame_delay, lame_corr = align_signed(reference, lame, MAX_DELAY)

        entry = {
            "name": fixture_name,
            "label": label,
            "ours_snr": round(ours_snr, 2),
            "ours_delay": CODEC_DELAY,
            "lame_snr": round(lame_snr, 2),
            "lame_delay": lame_delay,
            "lame_corr": round(lame_corr, 4),
            "is_fullscale": is_fullscale,
        }
        if is_fullscale:
            entry["ours_gain_fitted_snr"] = round(ours_fit, 2)
            entry["ours_gain"] = round(ours_gain, 4)

        results.append(entry)

    return results


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="output JSON")
    parser.add_argument("--fixtures", type=str, default=None, help="path to fixtures dir")
    args = parser.parse_args()

    results = run_benchmark(args.fixtures)

    if args.json:
        doc = {
            "rate": 44100,
            "bitrate_kbps": 128,
            "channels": 1,
            "slice_seconds": SLICE_SEC,
            "codec_delay": CODEC_DELAY,
            "probes": results,
        }
        print(json.dumps(doc, indent=2, ensure_ascii=False))
        return 0

    print("=" * 72)
    print(f"{'探针':<16} | {'本编码器':>10} | {'LAME 128k':>10} | {'差异':>8} | 说明")
    print("-" * 72)
    for r in results:
        diff = r["ours_snr"] - r["lame_snr"]
        sign = "+" if diff >= 0 else ""
        diff_str = f"{sign}{diff:5.2f} dB"
        if r.get("is_fullscale"):
            note = f"防削顶余量 (归一化后 {r['ours_gain_fitted_snr']:.2f} dB)"
        else:
            note = "优于 LAME" if diff > 0 else "落后"
        print(f"{r['label']:<16} | {r['ours_snr']:7.2f} dB | {r['lame_snr']:7.2f} dB | {diff_str:>8} | {note}")
    print("=" * 72)
    return 0


if __name__ == "__main__":
    sys.exit(main())
