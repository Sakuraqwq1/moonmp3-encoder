#!/usr/bin/env python3
"""Frame-level dump of an MP3 stream.

Walks an MP3 file and prints, per frame: the byte offset, every header field,
the frame size, the side information (main_data_begin and each granule's
part2_3_length / big_values / global_gain / scalefac_compress / block info)
and whether the frame carries a Xing or Info tag.

The dump is the reference against which the encoder's own output is checked:
LAME-produced files show the real layout (Xing position, padding pattern,
side-info offsets), and the summary line pins the frame grid.

Usage: python tools/mp3dump.py <file.mp3> [--first N] [--verbose]
"""

import argparse
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
        "protection": b1 & 1,
        "bitrate": bitrate,
        "samplerate": samplerate,
        "padding": padding,
        "private": b2 & 1,
        "mode": mode,
        "channels": channels,
        "mode_ext": (b3 >> 4) & 3,
        "copyright": (b3 >> 3) & 1,
        "original": (b3 >> 2) & 1,
        "emphasis": b3 & 3,
        "size": size,
        "side_size": 17 if channels == 1 else 32,
    }


def parse_side_info(data, offset, channels):
    bits = Bits(data[offset:offset + (17 if channels == 1 else 32)])
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
                bits.read(5)  # table_select 0
                bits.read(5)  # table_select 2
                bits.read(9)  # subblock gains
            else:
                bits.read(15)  # three table_select fields
                bits.read(4)  # region0_count
                bits.read(3)  # region1_count
            bits.read(1)  # preflag
            bits.read(1)  # scalefac_scale
            bits.read(1)  # count1table_select
            granules.append(g)
    info["granules"] = granules
    return info


def dump(path, first, verbose):
    with open(path, "rb") as handle:
        data = handle.read()
    offset = 0
    if data[:3] == b"ID3":
        flags = data[5]
        size = 0
        for byte in data[6:10]:
            size = (size << 7) | (byte & 0x7F)
        footer = 10 if flags & 0x10 else 0
        print(f"ID3v2: version {data[3]}.{data[4]}, {size + 10 + footer} bytes")
        offset = size + 10 + footer
    end = len(data)
    if data[-128:-125] == b"TAG":
        print("ID3v1: 128-byte trailer")
        end -= 128
    frames = []
    while offset + 4 <= end:
        header = parse_header(data, offset)
        if header is None:
            print(f"WARNING: no sync at offset {offset}, stopping")
            break
        side_offset = offset + 4 + (0 if header["protection"] else 2)
        info = parse_side_info(data, side_offset, header["channels"])
        body_offset = side_offset + header["side_size"]
        tag = ""
        if data[body_offset:body_offset + 4] in (b"Xing", b"Info"):
            tag = data[body_offset:body_offset + 4].decode("ascii")
            flags = struct.unpack(">I", data[body_offset + 4:body_offset + 8])[0]
            tag += f"(flags={flags:#x})"
        frames.append((offset, header, info, tag))
        offset += header["size"]
    for index, (frame_offset, header, info, tag) in enumerate(frames):
        if first is not None and index >= first:
            break
        base = (
            f"frame {index:4d} @ {frame_offset:7d} "
            f"MPEG-{VERSION_NAMES[header['version']]} Layer III "
            f"{header['bitrate'] // 1000:3d}kbps {header['samplerate']:5d}Hz "
            f"{MODE_NAMES[header['mode']]:6s} "
            f"pad={header['padding']} size={header['size']:3d} "
            f"mdb={info['main_data_begin']:3d}"
        )
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
                    f"sfc={g['scalefac_compress']:2d} wsf={g['window_switching']}"
                )
    bitrates = {h["bitrate"] for _, h, _, _ in frames}
    samples = len(frames) * 1152
    print(
        f"summary: {len(frames)} frames, {sum(h['size'] for _, h, _, _ in frames)} bytes, "
        f"{samples} samples/channel ({samples / 44100:.3f}s at 44.1kHz), "
        f"bitrates={sorted(b // 1000 for b in bitrates)}kbps, "
        f"constant={len(bitrates) == 1}"
    )
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("file")
    parser.add_argument("--first", type=int, default=10)
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    if not os.path.exists(args.file):
        print(f"no such file: {args.file}", file=sys.stderr)
        return 1
    return dump(args.file, args.first, args.verbose)


if __name__ == "__main__":
    sys.exit(main())
