#!/usr/bin/env python3
"""Reproduce `src/mp3/huffman_tables.mbt` from its upstream source.

The 15 big_values Huffman tables of ISO/IEC 11172-3 Table B.7 are normative
data, not derivable, so they are transcribed. The source is
`hajimehoshi/go-mp3` (Apache-2.0, same licence as this module) which stores them
in the compact binary-tree form that decoders use: one `uint16` per node, a leaf
when the high byte is zero (`x = bits 7..4`, `y = bits 3..0`), otherwise a pair
of byte offsets to the left (high byte) and right (low byte) child, with values
of 250 and above chaining to a further node.

Turning that tree into the encoder-side `(x, y) -> (length, code)` map is a
deterministic walk, and the walk is checked three ways before the table is
written out:

  * every table must be a complete prefix code: `sum 2^-len == 1` (Kraft);
  * no symbol may appear twice, and no two symbols may share a code word;
  * the `(x, y)` extents must match the table's documented role: tables 1, 2 and
    3 only reach x, y <= 1 / 2, and tables 5..15 cover the full 0..15 square.

Only the numbers are used. The encoder in `huffman.mbt` is written from the
bitstream definition; no decoding code is copied. See docs/provenance.md.

    python tools/huffman_tables.py --report    # verify and summarise
    python tools/huffman_tables.py --write     # regenerate the MoonBit table
    python tools/huffman_tables.py --fetch     # refresh the cached upstream file
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGET = os.path.join(ROOT, "src", "mp3", "huffman_tables.mbt")
CACHE = os.path.join(ROOT, "target", "ref", "internal_huffman_huffman.go")

REPO = "hajimehoshi/go-mp3"
PATH = "internal/huffman/huffman.go"
BLOB = "abc30058a5cb0e8a75ea40aed2aa88dd02f2c96e"
FILE_SHA256 = "6ffbac45b10aabb6cd1a5e37736743ec84ddb8c145fbdd22b2638f1a66cb6b1d"
TABLES = 34


def fetch() -> bytes:
    url = f"https://api.github.com/repos/{REPO}/contents/{PATH}"
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "moonmp3-encoder-huffman/1.0",
            "Accept": "application/vnd.github+json",
        },
    )
    meta = json.loads(urllib.request.urlopen(request, timeout=60).read())
    if meta["sha"] != BLOB:
        raise SystemExit(f"upstream blob moved: {meta['sha']} != {BLOB}")
    return base64.b64decode(meta["content"])


def load(fresh: bool) -> str:
    if fresh or not os.path.isfile(CACHE):
        blob = fetch()
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)
        with open(CACHE, "wb") as handle:
            handle.write(blob)
    with open(CACHE, "rb") as handle:
        blob = handle.read()
    digest = hashlib.sha256(blob).hexdigest()
    if digest != FILE_SHA256:
        raise SystemExit(f"cached upstream file hash mismatch: {digest}")
    return blob.decode("utf-8", "replace")


def block(text: str, marker: str) -> str:
    """Inner text between the first `{` after `marker` and its matching `}`."""
    start = text.index(marker) + len(marker)
    start = text.index("{", start) + 1
    depth = 1
    index = start
    while index < len(text):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[start:index]
        index += 1
    raise SystemExit(f"unterminated block after {marker}")


def parse_tables(text: str):
    """Return (tree, entries) where entries[i] = (offset, treelen, linbits)."""
    tree_body = block(text, "var huffmanTable = []uint16")
    tree = [int(v, 16) for v in re.findall(r"0x([0-9a-fA-F]{4})", tree_body)]

    entries = []
    for line in block(text, "var huffmanMain = [...]huffTables").splitlines():
        line = line.split("//")[0].strip()
        if not line.startswith("{"):
            continue
        match = re.search(
            r"\{huffmanTable(?:\[(\d+):\])?,\s*(\d+),\s*(\d+)\}", line
        )
        if match:
            entries.append(
                (int(match.group(1) or 0), int(match.group(2)), int(match.group(3)))
            )
        else:
            entries.append((0, 0, 0))
    if len(entries) != TABLES:
        raise SystemExit(f"expected {TABLES} tables, parsed {len(entries)}")
    return tree, entries


def walk(tree, offset, treelen):
    """Map (x, y) -> (code, length) by walking the packed tree."""
    codes: dict[tuple[int, int], tuple[int, int]] = {}

    def take(point: int, right: bool) -> int:
        """Follow one branch: a byte offset, chained while it is 250 or more."""
        shift = 0 if right else 8
        byte = (tree[offset + point] >> shift) & 0xFF
        while byte >= 250:
            point += byte
            if offset + point >= len(tree):
                raise SystemExit("branch ran past the end of the tree")
            byte = (tree[offset + point] >> shift) & 0xFF
        return point + byte

    def visit(point: int, code: int, length: int) -> None:
        if length > 24:
            raise SystemExit(f"tree deeper than 24 bits at {point}")
        value = tree[offset + point]
        if (value & 0xFF00) == 0:
            x = (value >> 4) & 0xF
            y = value & 0xF
            if (x, y) in codes:
                raise SystemExit(f"symbol {(x, y)} appears twice")
            codes[(x, y)] = (code, length)
            return
        left = take(point, False)
        right = take(point, True)
        if left >= treelen or right >= treelen:
            raise SystemExit(f"child out of range: {left}, {right} >= {treelen}")
        visit(left, code << 1, length + 1)
        visit(right, (code << 1) | 1, length + 1)

    visit(0, 0, 0)
    return codes


def verify(name: int, codes, linbits: int) -> dict:
    """Kraft sum, prefix-freedom and (x, y) extents."""
    kraft = sum(2.0 ** -length for _, length in codes.values())
    seen: dict[int, tuple[int, int]] = {}
    for (x, y), (code, length) in codes.items():
        key = (length << 16) | code
        if key in seen:
            raise SystemExit(f"table {name}: code collision {(x, y)} vs {seen[key]}")
        seen[key] = (x, y)
    max_x = max(x for x, _ in codes)
    max_y = max(y for _, y in codes)
    return {
        "table": name,
        "symbols": len(codes),
        "linbits": linbits,
        "max_x": max_x,
        "max_y": max_y,
        "kraft": round(kraft, 12),
        "max_len": max(length for _, length in codes.values()),
    }


def build(text: str):
    tree, entries = parse_tables(text)
    reports = []
    tables = {}
    for name, (offset, treelen, linbits) in enumerate(entries):
        if treelen == 0:
            continue
        codes = walk(tree, offset, treelen)
        report = verify(name, codes, linbits)
        if abs(report["kraft"] - 1.0) > 1e-9:
            raise SystemExit(f"table {name}: Kraft sum {report['kraft']} != 1")
        if name >= 32:
            # The count1 quad tables: the "symbol" is a four-bit non-zero mask,
            # so there is no square extent to check.
            reports.append(report)
            tables[name] = codes
            continue
        # The big_values tables are square: 2x2, 3x3, 4x4, 6x6, 8x8 or 16x16.
        if report["max_x"] != report["max_y"]:
            raise SystemExit(f"table {name}: non-square extent {report}")
        if report["max_x"] not in (1, 2, 3, 5, 7, 15):
            raise SystemExit(f"table {name}: unexpected extent {report['max_x']}")
        if report["symbols"] != (report["max_x"] + 1) ** 2:
            raise SystemExit(f"table {name}: {report['symbols']} symbols for extent {report['max_x']}")
        reports.append(report)
        tables[name] = codes
    return tables, reports


def digest(tables) -> str:
    chunks = []
    for name in sorted(tables):
        codes = tables[name]
        chunks.append(f"{name}:")
        for x in range(16):
            for y in range(16):
                entry = codes.get((x, y))
                chunks.append("--" if entry is None else f"{entry[1]}/{entry[0]}")
    return hashlib.sha256("|".join(chunks).encode()).hexdigest()


def render(tables, reports) -> str:
    by_name = {r["table"]: r for r in reports}
    lines = []
    for name in range(16):
        packed = []
        codes = tables.get(name, {})
        for x in range(16):
            for y in range(16):
                entry = codes.get((x, y))
                packed.append(0 if entry is None else (entry[1] << 16) | entry[0])
        for index in range(0, 256, 8):
            lines.append("  " + ", ".join(str(v) for v in packed[index:index + 8]) + ",")
        if name < 15:
            lines.append("")
    body = "\n".join(lines).rstrip("\n")
    linbits_line = ", ".join(
        str(by_name[n]["linbits"]) if n in by_name else "0" for n in range(16)
    )
    extent_line = ", ".join(
        str(by_name[n]["max_x"]) if n in by_name else "0" for n in range(16)
    )
    return f'''// moonmp3-encoder — pure MoonBit MP3 encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

// The big_values Huffman tables of ISO/IEC 11172-3 Table B.7, packed for the
// encoder as `(length << 16) | code` per symbol, with symbol = `x * 16 + y` and
// zero meaning "this table cannot represent that pair".
//
// Tables 0, 4 and 14 are empty by the standard: table 0 encodes only zero pairs,
// and 4 and 14 are not defined. Tables 1..3 cover only small values (their
// largest representable coefficient is listed in `huffman_table_extent`), so a
// table is only selectable for a region whose values fit it.
//
// Source: {REPO}, `{PATH}`.
//   git blob  {BLOB}
//   file      sha256 {FILE_SHA256}
//   licence   Apache License 2.0 (compatible with this module)
// The upstream stores a decoder-side binary tree; the encoder-side table here is
// the result of walking it, and the walk is checked for a complete prefix code
// (Kraft sum 1), for code collisions and for the documented (x, y) extents.
// `tools/huffman_tables.py` reproduces and verifies all of it.
// Do not edit by hand: `python tools/huffman_tables.py --write`.

///|
/// `(length << 16) | code` for every big_values table, 256 symbols each,
/// indexed by `table * 256 + x * 16 + y`. Zero means "not representable".
let huffman_codes : Array[Int32] = [
{body}
]

///|
/// Extra bits appended when `x` or `y` reaches 15, per table.
let huffman_linbits : Array[Int32] = [{linbits_line}]

///|
/// Largest coefficient each table can represent (0 for the empty tables).
let huffman_table_extent : Array[Int32] = [{extent_line}]
'''


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--report", action="store_true", help="verify and summarise")
    group.add_argument("--write", action="store_true", help="regenerate the MoonBit table")
    group.add_argument("--fetch", action="store_true", help="refresh the cached upstream file")
    args = parser.parse_args()

    tables, reports = build(load(fresh=args.fetch))
    table_digest = digest(tables)
    summary = {
        "tables": len(reports),
        "symbols": sum(r["symbols"] for r in reports),
        "table_sha256": table_digest,
        "per_table": reports,
    }
    if args.fetch:
        print(json.dumps(summary, indent=2))
        return 0
    if args.write:
        with open(TARGET, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(render(tables, reports))
        print(f"wrote {os.path.relpath(TARGET, ROOT)}")
        print(json.dumps({k: v for k, v in summary.items() if k != "per_table"}, indent=2))
        return 0
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
