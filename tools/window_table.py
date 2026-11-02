#!/usr/bin/env python3
"""Reproduce `src/mp3/window.mbt` from its upstream source and verify it.

The 512-coefficient analysis window is normative data from ISO/IEC 11172-3
(Annex B); it cannot be derived, so it has to be transcribed from a source whose
licence allows redistribution.  This project takes the numbers from
`hajimehoshi/go-mp3`, which is Apache-2.0 (the same licence as this module) and,
unlike several other implementations, prints the table in the canonical
index order 0..511 rather than in a decoder-specific permutation.

Only the numbers are taken.  The filterbank structure in `analysis.mbt` is
written from the normative description of the folding and matrixing stages; no
code is copied from that repository.

    python tools/window_table.py --check     # verify the checked-in table
    python tools/window_table.py --write     # regenerate src/mp3/window.mbt
    python tools/window_table.py --fetch     # refresh the cached upstream copy

The upstream blob is pinned by the git blob id and by the SHA-256 of the whole
file, so a silent upstream edit cannot slip in unnoticed.
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
TARGET = os.path.join(ROOT, "src", "mp3", "window.mbt")
CACHE = os.path.join(ROOT, "target", "ref", "internal_frame_frame.go")

REPO = "hajimehoshi/go-mp3"
PATH = "internal/frame/frame.go"
BLOB = "3532e6c549b5dcc6409d3a2c8b8e16b67b0369b5"
FILE_SHA256 = "e0b901f2291c89ff44fa904299eaf23e9141f0a8d54fe0f04f55189c3e0bdf1d"
VARIABLE = "synthDtbl"
COUNT = 512


def fetch() -> bytes:
    url = f"https://api.github.com/repos/{REPO}/contents/{PATH}"
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "moonmp3-encoder-window-table/1.0",
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


def upstream_values(text: str) -> list[str]:
    """The 512 decimal literals, verbatim, in canonical order."""
    start = text.index(f"var {VARIABLE} = [{COUNT}]float32{{")
    end = text.index("}", start)
    body = text[start:end]
    literals = re.findall(r"-?\d+\.\d+", body)
    if len(literals) != COUNT:
        raise SystemExit(f"expected {COUNT} coefficients, parsed {len(literals)}")
    return literals


def checked_in_values() -> list[str]:
    with open(TARGET, encoding="utf-8") as handle:
        text = handle.read()
    return re.findall(r"-?\d+\.\d+", text.split("analysis_window", 1)[1])


def digest(values: list[float]) -> str:
    return hashlib.sha256("".join(f"{v:.9f}" for v in values).encode()).hexdigest()


def render(literals: list[str]) -> str:
    width = max(len(lit) for lit in literals)
    lines = []
    for index in range(0, COUNT, 8):
        rows = ", ".join(lit.rjust(width) for lit in literals[index:index + 8])
        lines.append(f"  {rows},")
    body = "\n".join(lines)
    return f'''// moonmp3-encoder — pure MoonBit MP3 encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

// The 512-coefficient prototype window of the Layer I/II/III polyphase
// filterbank, ISO/IEC 11172-3 Annex B. The same table drives the analysis
// folding in `analysis.mbt` and, in a decoder, the synthesis windowing: it is
// antisymmetric about the half-sample point, C[i] = -C[511 - i], and peaks at
// C[256] = 1.144989014. Generating it is not possible — it is a designed
// equiripple prototype — so it is transcribed, not computed.
//
// Source: {REPO}, `{PATH}`, variable `{VARIABLE}`.
//   git blob  {BLOB}
//   file      sha256 {FILE_SHA256}
//   licence   Apache License 2.0 (compatible with this module)
// Only the numbers are used; see docs/provenance.md and tools/window_table.py,
// which reproduces and verifies this file.
//
// Do not edit by hand: `python tools/window_table.py --write`.

///|
/// The 512 analysis-window coefficients, in canonical index order.
let analysis_window : Array[Double] = [
{body}
]
'''


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--check", action="store_true", help="verify the checked-in table")
    group.add_argument("--write", action="store_true", help="regenerate src/mp3/window.mbt")
    group.add_argument("--fetch", action="store_true", help="refresh the cached upstream file")
    args = parser.parse_args()

    text = load(fresh=args.fetch)
    upstream = upstream_values(text)
    values = [float(v) for v in upstream]
    report = {
        "count": COUNT,
        "peak": max(values),
        "peak_index": values.index(max(values)),
        "min": min(values),
        "antisymmetry_max": round(
            max(abs(values[i] + values[COUNT - 1 - i]) for i in range(COUNT)), 9
        ),
        "table_sha256": digest(values),
    }

    if args.fetch:
        print(json.dumps(report, indent=2))
        return 0

    if args.write:
        with open(TARGET, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(render(upstream))
        print(f"wrote {os.path.relpath(TARGET, ROOT)}")
        print(json.dumps(report, indent=2))
        return 0

    local = checked_in_values()
    if len(local) != COUNT:
        print(f"FAIL: checked-in table has {len(local)} coefficients", file=sys.stderr)
        return 1
    mismatched = [i for i, (a, b) in enumerate(zip(local, upstream)) if float(a) != float(b)]
    if mismatched:
        print(f"FAIL: {len(mismatched)} coefficients differ, first at {mismatched[0]}", file=sys.stderr)
        return 1
    print(f"ok: {COUNT} coefficients match {REPO}@{BLOB[:7]}")
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
