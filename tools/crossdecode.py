#!/usr/bin/env python3
"""Decode the same stream with two independent decoders and compare them.

Stage 2 of docs/stage1-handoff.md asks for decoder agreement, and until now the
lab only had libsndfile (mpg123 underneath). PyAV brings ffmpeg's decoder, which
shares no code with mpg123, so a stream that decodes identically in both is
evidence about the stream rather than about one library's tolerance.

    python tools/crossdecode.py target/sine440.mp3
    python tools/crossdecode.py target/sine440.mp3 --json

The comparison is:
  * sample count per channel (decoders legitimately differ on the tail; report it),
  * per-channel correlation and difference level between the two outputs,
  * dominant frequency of each, so a channel swap or an octave error cannot hide.

Requires `av` (see requirements-dev.txt); `av` is a development-time oracle only
and never enters the MoonBit package.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mp3lab import ToolError, decode_mp3  # noqa: E402


def decode_with_ffmpeg(payload: bytes):
    """Decode to float32[frames, channels] with PyAV (ffmpeg)."""
    try:
        import av
    except ImportError as exc:
        raise ToolError("crossdecode needs PyAV: pip install -r requirements-dev.txt") from exc

    with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as handle:
        handle.write(payload)
        path = handle.name
    try:
        container = av.open(path)
        stream = container.streams.audio[0]
        rate = stream.rate
        chunks = []
        channels = None
        for frame in container.decode(stream):
            array = frame.to_ndarray()
            if array.ndim == 1:
                array = array[None, :]
            # PyAV gives planar or packed depending on the codec; normalise to
            # (frames, channels).
            if array.shape[0] <= 2 and array.shape[0] < array.shape[1]:
                array = array.T
            chunks.append(array.astype(np.float32))
            channels = array.shape[1]
        container.close()
        if not chunks:
            raise ToolError("ffmpeg produced no frames")
        data = np.concatenate(chunks, axis=0)
        return data, int(rate)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def dominant(data: np.ndarray, rate: int, channel: int) -> float:
    segment = data[:, channel].astype(np.float64)
    if segment.size < 64:
        return 0.0
    window = min(8192, segment.size)
    block = segment[:window] - segment[:window].mean()
    power = np.abs(np.fft.rfft(block * np.hanning(window)))
    grid = np.fft.rfftfreq(window, 1 / rate)
    return float(grid[int(np.argmax(power[1:])) + 1])


def compare(payload: bytes) -> dict:
    mpg123, rate_a = decode_mp3(payload)
    ffmpeg, rate_b = decode_with_ffmpeg(payload)
    frames = min(mpg123.shape[0], ffmpeg.shape[0])
    channels = min(mpg123.shape[1], ffmpeg.shape[1])
    report = {
        "rate": {"mpg123": rate_a, "ffmpeg": rate_b},
        "frames": {"mpg123": int(mpg123.shape[0]), "ffmpeg": int(ffmpeg.shape[0])},
        "channels": {"mpg123": int(mpg123.shape[1]), "ffmpeg": int(ffmpeg.shape[1])},
        "per_channel": [],
    }
    for channel in range(channels):
        a = mpg123[:frames, channel].astype(np.float64)
        b = ffmpeg[:frames, channel].astype(np.float64)
        denominator = np.sqrt(np.dot(a, a) * np.dot(b, b))
        correlation = float(np.dot(a, b) / denominator) if denominator > 0 else 0.0
        difference = a - b
        noise = float(np.dot(difference, difference))
        signal = float(np.dot(a, a))
        report["per_channel"].append(
            {
                "channel": channel,
                "correlation": round(correlation, 6),
                "difference_db": round(10 * np.log10(signal / max(noise, 1e-30)), 2),
                "dominant_hz": {
                    "mpg123": round(dominant(mpg123, rate_a, channel), 2),
                    "ffmpeg": round(dominant(ffmpeg, rate_b, channel), 2),
                },
            }
        )
    report["agree"] = (
        report["rate"]["mpg123"] == report["rate"]["ffmpeg"]
        and report["channels"]["mpg123"] == report["channels"]["ffmpeg"]
        and all(entry["correlation"] >= 0.9999 for entry in report["per_channel"])
    )
    return report


def print_report(report: dict, path: str) -> None:
    print(
        f"{os.path.basename(path)}: rate {report['rate']}, "
        f"frames mpg123={report['frames']['mpg123']} ffmpeg={report['frames']['ffmpeg']}, "
        f"channels {report['channels']['mpg123']}"
    )
    for entry in report["per_channel"]:
        print(
            f"  ch{entry['channel']}: correlation {entry['correlation']:.6f}, "
            f"difference {entry['difference_db']:.1f} dB, "
            f"dominant {entry['dominant_hz']['mpg123']:.1f} / "
            f"{entry['dominant_hz']['ffmpeg']:.1f} Hz"
        )
    print("ok: both decoders agree" if report["agree"] else "FAIL: decoders disagree")


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("file", help="an MP3 file")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--frames", type=int, default=0, help="clip the comparison to N frames")
    args = parser.parse_args()
    try:
        with open(args.file, "rb") as handle:
            payload = handle.read()
        report = compare(payload)
    except (ToolError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print_report(report, args.file)
    return 0 if report["agree"] else 1


if __name__ == "__main__":
    sys.exit(main())
