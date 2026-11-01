#!/usr/bin/env python3
"""Preflight checks that do not require building the project.

Catches the release mistakes that are easy to make by hand:

- version mismatch between moon.mod, lib.mbt and CHANGELOG.md;
- missing repository files that the release process depends on;
- CI no longer covering check/test/build or the Python lab;
- an OSI licence field that changed accidentally;
- a hard-coded version in README.

Usage:
    python tools/check_release.py
    python tools/check_release.py --json
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")


def read(path: str) -> str:
    with open(os.path.join(ROOT, path), encoding="utf-8") as handle:
        return handle.read()


def parse_versions():
    moon_mod = read("moon.mod")
    moon_match = re.search(r'^version\s*=\s*"([^"]+)"', moon_mod, re.MULTILINE)
    moon_version = moon_match.group(1) if moon_match else None

    lib = read("lib.mbt")
    lib_match = re.search(
        r"pub\s+fn\s+version\s*\(\s*\)\s*->\s*String\s*\{\s*\"([^\"]+)\"",
        lib,
        re.DOTALL,
    )
    lib_version = lib_match.group(1) if lib_match else None

    changelog = read("CHANGELOG.md")
    entries = []
    for match in re.finditer(r"^## \[([^\]]+)\] - (\d{4}-\d{2}-\d{2})\s*$", changelog, re.MULTILINE):
        entries.append((match.group(1), match.group(2)))
    return moon_mod, moon_version, lib_version, entries


def check() -> dict:
    checks = []

    def add(name, ok, detail, blocking=True):
        checks.append({"name": name, "ok": bool(ok), "detail": detail, "blocking": blocking})

    required = [
        "LICENSE",
        "README.md",
        "moon.mod",
        "moon.pkg",
        "lib.mbt",
        "CHANGELOG.md",
        ".gitattributes",
        "CONTRIBUTING.md",
        "requirements-dev.txt",
        ".github/workflows/ci.yml",
        "tools/gen_fixtures.py",
        "tools/mp3dump.py",
        "tools/snr.py",
        "tools/spectrum.py",
        "tools/verify.py",
        "tools/selftest.py",
        "tools/doctor.py",
        "tools/check_release.py",
        "docs/stage1-handoff.md",
        "docs/tooling.md",
        "docs/acceptance.md",
        "docs/provenance.md",
    ]
    missing = [path for path in required if not os.path.isfile(os.path.join(ROOT, path))]
    add("required files", not missing, "all present" if not missing else "missing: " + ", ".join(missing))

    moon_mod, moon_version, lib_version, entries = parse_versions()
    add("moon.mod version", bool(moon_version and SEMVER.match(moon_version)), moon_version or "not found")
    add("lib version", bool(lib_version and SEMVER.match(lib_version)), lib_version or "not found")
    add(
        "version sync",
        bool(moon_version and moon_version == lib_version),
        f"moon.mod={moon_version} lib={lib_version}",
    )

    if entries:
        latest_version, latest_date = entries[0]
        add("changelog version", latest_version == moon_version, f"latest={latest_version} moon.mod={moon_version}")
        try:
            datetime.date.fromisoformat(latest_date)
            valid_date = True
        except ValueError:
            valid_date = False
        add("changelog date", valid_date, latest_date)
    else:
        add("changelog version", False, "no '## [x.y.z] - YYYY-MM-DD' entry")
        add("changelog date", False, "no dated entry")

    license_match = re.search(r'^license\s*=\s*"([^"]+)"', moon_mod, re.MULTILINE)
    license_name = license_match.group(1) if license_match else None
    add("licence field", license_name in {"Apache-2.0", "MIT", "BSD-3-Clause"}, license_name or "not found")

    ci = read(".github/workflows/ci.yml")
    for command in ("moon check --deny-warn", "moon test --deny-warn", "moon fmt --check"):
        add(f"CI {command}", command in ci, "present" if command in ci else "missing")
    for target in ("wasm-gc", "native"):
        marker = f"moon build --target {target}"
        add(f"CI build {target}", marker in ci, "present" if marker in ci else "missing")
    add("CI python tools", "tools/selftest.py" in ci, "present" if "tools/selftest.py" in ci else "missing")

    readme = read("README.md")
    hardcoded = sorted(set(re.findall(r"(?<![\w.])\d+\.\d+\.\d+(?![\w.])", readme)))
    add(
        "README version-free",
        not hardcoded,
        "no hard-coded version" if not hardcoded else "found: " + ", ".join(hardcoded),
        blocking=False,
    )

    blocking = [item for item in checks if item["blocking"] and not item["ok"]]
    warnings = [item for item in checks if not item["blocking"] and not item["ok"]]
    return {
        "version": moon_version,
        "checks": checks,
        "blocking": len(blocking),
        "warnings": len(warnings),
        "ok": not blocking,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    report = check()
    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        for item in report["checks"]:
            label = "ok  " if item["ok"] else ("FAIL" if item["blocking"] else "warn")
            print(f"[{label}] {item['name']}: {item['detail']}")
        print(
            f"\nversion={report['version']} blocking={report['blocking']} "
            f"warnings={report['warnings']}"
        )
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
