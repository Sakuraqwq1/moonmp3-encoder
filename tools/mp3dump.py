#!/usr/bin/env python3
"""Frame-level dump of an MP3 stream.

Walks an MP3 file and reports, per frame: the byte offset, every header field,
the frame size, the side information (main_data_begin and each granule's
part2_3_length / big_values / global_gain / scalefac_compress / block info)
and whether the frame carries a Xing or Info tag.

This is the reference against which the encoder's own output is checked:
LAME-produced files show the real layout (Xing position, padding pattern,
side-info offsets), and the summary pins the frame grid.

Usage:
    python tools/mp3dump.py <file.mp3> [--first N] [--verbose]
    python tools/mp3dump.py <file.mp3> --json
    python tools/mp3dump.py <file.mp3> --strict

Exit codes: 0 clean, 1 unreadable input, 2 --strict saw a warning.
"""

import argparse
import json
import os
import struct
import sys

MPEG1_LAYER3_BITRATES = [
    0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0,
]
MPEG1_RATES = [44100, 48000, 32000]
VERSION_NAMES = {0: "2.5", 1: "reserved", 2: "2", 3: "1"}
MODE_NAMES = ["stereo", "joint", "dual", "mono"]


class Bits:
    """MSB-first reader over the side-information bytes."""

    def __init__(self, data):
        self.data = data
        self.pos = 0

    def read(self, count):
        value = 0
        for _ in range(count):
            byte = self.data[self.pos >> 3]
            bit = (byte >> (7 - (self.pos & 7))) & 1
            value = (value << 1) | bit
            self.pos += 1
        return value


def parse_header(data, offset):
    if offset + 4 > len(data):
        return None
    b0, b1, b2, b3 = data[offset:offset + 4]
    if b0 != 0xFF or (b1 & 0xE0) != 0xE0:
        return None
    version = (b1 >> 3) & 3
    layer = (b1 >> 1) & 3
    if layer != 1 or version not in (0, 2, 3):
        return None
    bitrate_idx = (b2 >> 4) & 0xF
    samplerate_idx = (b2 >> 2) & 3
    if bitrate_idx in (0, 15) or samplerate_idx == 3:
        return None
    mode = (b3 >> 6) & 3
    channels = 1 if mode == 3 else 2
    if version == 3:
        bitrate = MPEG1_LAYER3_BITRATES[bitrate_idx] * 1000
        samplerate = MPEG1_RATES[samplerate_idx]
    else:
        # MPEG-2/2.5 halve the samplerate and use a different bitrate table.
        samplerate = MPEG1_RATES[samplerate_idx] // (2 if version == 2 else 4)
        table2 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0]
        bitrate = table2[bitrate_idx] * 1000
    padding = (b2 >> 1) & 1
    # 144 bytes per kbit-sample at Layer III (1152 samples per frame, 8 bits).
    size = 144 * bitrate // samplerate + padding
    return {
        "version": version,
        "version_name": VERSION_NAMES[version],
        "protection": b1 & 1,
        "bitrate_index": bitrate_idx,
        "bitrate": bitrate,
        "samplerate_index": samplerate_idx,
        "samplerate": samplerate,
        "padding": padding,
        "private": b2 & 1,
        "mode": mode,
        "mode_name": MODE_NAMES[mode],
        "channels": channels,
        "mode_ext": (b3 >> 4) & 3,
        "copyright": (b3 >> 3) & 1,
        "original": (b3 >> 2) & 1,
        "emphasis": b3 & 3,
        "size": size,
        "side_size": 17 if channels == 1 else 32,
    }


def parse_side_info(data, offset, channels):
    size = 17 if channels == 1 else 32
    if offset + size > len(data):
        raise ValueError("side information extends past the file")
    bits = Bits(data[offset:offset + size])
    info = {"main_data_begin": bits.read(9)}
    bits.read(5 if channels == 1 else 3)  # private bits
    info["scfsi"] = [bits.read(4) for _ in range(channels)]
    granules = []
    for _gr in range(2):
        for _ch in range(channels):
            g = {
                "part2_3_length": bits.read(12),
                "big_values": bits.read(9),
                "global_gain": bits.read(8),
                "scalefac_compress": bits.read(4),
            }
            wsf = bits.read(1)
            g["window_switching"] = wsf
            if wsf:
                g["block_type"] = bits.read(2)
                g["mixed_block"] = bits.read(1)
                g["table_select"] = [bits.read(5), None, bits.read(5)]
                g["subblock_gain"] = [bits.read(3), bits.read(3), bits.read(3)]
            else:
                g["block_type"] = 0
                g["mixed_block"] = 0
                g["table_select"] = [bits.read(5), bits.read(5), bits.read(5)]
                g["subblock_gain"] = [0, 0, 0]
                g["region0_count"] = bits.read(4)
                g["region1_count"] = bits.read(3)
            g["preflag"] = bits.read(1)
            g["scalefac_scale"] = bits.read(1)
            g["count1table_select"] = bits.read(1)
            granules.append(g)
    info["granules"] = granules
    return info


def parse_vbr_tag(data, offset, end):
    """Parse a Xing/Info header when one starts at `offset`."""
    if offset + 8 > end:
        return None
    kind = data[offset:offset + 4]
    if kind not in (b"Xing", b"Info"):
        return None
    flags = struct.unpack(">I", data[offset + 4:offset + 8])[0]
    tag = {"kind": kind.decode("ascii"), "flags": flags}
    cursor = offset + 8
    if flags & 0x1 and cursor + 4 <= end:
        tag["frames"] = struct.unpack(">I", data[cursor:cursor + 4])[0]
        cursor += 4
    if flags & 0x2 and cursor + 4 <= end:
        tag["bytes"] = struct.unpack(">I", data[cursor:cursor + 4])[0]
        cursor += 4
    if flags & 0x4 and cursor + 100 <= end:
        tag["toc_entries"] = 100
        cursor += 100
    if flags & 0x8 and cursor + 4 <= end:
        tag["quality"] = struct.unpack(">I", data[cursor:cursor + 4])[0]
    return tag


def analyze(path):
    """Parse an MP3 file into a JSON-serialisable report."""
    with open(path, "rb") as handle:
        data = handle.read()
    report = {
        "path": os.path.abspath(path),
        "bytes": len(data),
        "id3v2": None,
        "id3v1": False,
        "frames": [],
        "warnings": [],
    }
    offset = 0
    if data[:3] == b"ID3" and len(data) >= 10:
        flags = data[5]
        size = 0
        for byte in data[6:10]:
            size = (size << 7) | (byte & 0x7F)
        footer = 10 if flags & 0x10 else 0
        total = size + 10 + footer
        report["id3v2"] = {
            "version": f"{data[3]}.{data[4]}",
            "flags": flags,
            "size": total,
        }
        offset = total
    end = len(data)
    if data[-128:-125] == b"TAG":
        report["id3v1"] = True
        end -= 128

    while offset + 4 <= end:
        header = parse_header(data, offset)
        if header is None:
            report["warnings"].append(f"no sync at offset {offset}, stopping")
            break
        if header["size"] < 4 + header["side_size"]:
            report["warnings"].append(f"frame {len(report['frames'])} at {offset}: impossible size")
            break
        side_offset = offset + 4 + (0 if header["protection"] else 2)
        try:
            info = parse_side_info(data, side_offset, header["channels"])
        except (IndexError, ValueError) as exc:
            report["warnings"].append(f"frame {len(report['frames'])} at {offset}: {exc}")
            break
        if offset + header["size"] > end:
            report["warnings"].append(
                f"frame {len(report['frames'])} at {offset}: frame extends past end"
            )
            break
        body_offset = side_offset + header["side_size"]
        tag = parse_vbr_tag(data, body_offset, end)
        report["frames"].append(
            {
                "index": len(report["frames"]),
                "offset": offset,
                "header": header,
                "side_info": info,
                "vbr_tag": tag,
            }
        )
        offset += header["size"]
    else:
        if offset != end:
            report["warnings"].append(f"{end - offset} trailing byte(s) after the last frame")

    if not report["frames"]:
        report["warnings"].append("no MPEG frames found")
    frames = report["frames"]
    bitrates = sorted({frame["header"]["bitrate"] for frame in frames})
    rates = sorted({frame["header"]["samplerate"] for frame in frames})
    channels = sorted({frame["header"]["channels"] for frame in frames})
    total_bytes = sum(frame["header"]["size"] for frame in frames)
    samples = len(frames) * 1152
    report["summary"] = {
        "frames": len(frames),
        "bytes": total_bytes,
        "samples_per_channel": samples,
        "seconds_at_first_rate": round(samples / rates[0], 6) if rates else 0.0,
        "bitrates": bitrates,
        "samplerates": rates,
        "channels": channels,
        "constant_bitrate": len(bitrates) == 1,
        "constant_samplerate": len(rates) == 1,
    }
    return report


def _human_tag(tag):
    if not tag:
        return ""
    parts = [f"{tag['kind']}(flags={tag['flags']:#x}"]
    if "frames" in tag:
        parts.append(f" frames={tag['frames']}")
    if "bytes" in tag:
        parts.append(f" bytes={tag['bytes']}")
    parts.append(")")
    return "".join(parts)


def dump(path, first, verbose, report=None):
    report = report if report is not None else analyze(path)
    id3v2 = report["id3v2"]
    if id3v2:
        print(f"ID3v2: version {id3v2['version']}, {id3v2['size']} bytes")
    if report["id3v1"]:
        print("ID3v1: 128-byte trailer")
    for warning in report["warnings"]:
        print(f"WARNING: {warning}")
    for frame in report["frames"]:
        if first >= 0 and frame["index"] >= first:
            break
        header = frame["header"]
        info = frame["side_info"]
        base = (
            f"frame {frame['index']:4d} @ {frame['offset']:7d} "
            f"MPEG-{header['version_name']} Layer III "
            f"{header['bitrate'] // 1000:3d}kbps {header['samplerate']:5d}Hz "
            f"{header['mode_name']:6s} "
            f"pad={header['padding']} size={header['size']:3d} "
            f"mdb={info['main_data_begin']:3d}"
        )
        tag = _human_tag(frame["vbr_tag"])
        if verbose or tag:
            base += f" {tag}"
        print(base)
        if verbose:
            for gi, g in enumerate(info["granules"]):
                ch = gi % header["channels"]
                gr = gi // header["channels"]
                print(
                    f"    gr{gr}ch{ch} part2_3={g['part2_3_length']:4d} "
                    f"big_values={g['big_values']:3d} gain={g['global_gain']:3d} "
                    f"sfc={g['scalefac_compress']:2d} wsf={g['window_switching']} "
                    f"tables={g['table_select']}"
                )
    summary = report["summary"]
    print(
        f"summary: {summary['frames']} frames, {summary['bytes']} bytes, "
        f"{summary['samples_per_channel']} samples/channel "
        f"({summary['seconds_at_first_rate']:.3f}s at 44.1kHz), "
        f"bitrates={[value // 1000 for value in summary['bitrates']]}kbps, "
        f"constant={summary['constant_bitrate']}"
    )
    return 2 if report["warnings"] else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("file")
    parser.add_argument("--first", type=int, default=10, help="print at most N frames; -1 for all")
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--json", action="store_true", help="print the full report as JSON")
    parser.add_argument("--strict", action="store_true", help="exit 2 when any warning is found")
    args = parser.parse_args()
    if args.first < -1:
        parser.error("--first must be -1 or non-negative")
    if not os.path.exists(args.file):
        print(f"no such file: {args.file}", file=sys.stderr)
        return 1
    try:
        report = analyze(args.file)
    except OSError as exc:
        print(f"cannot read {args.file}: {exc}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
        return 2 if args.strict and report["warnings"] else 0
    return dump(args.file, args.first, args.verbose, report)


if __name__ == "__main__":
    sys.exit(main())
