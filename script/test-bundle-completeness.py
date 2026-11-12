#!/usr/bin/env python3
"""Fail if a runtime helper is missing from source or from the packaged app."""

from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIST_FILE = ROOT / "Resources" / "bundled-helpers.txt"
APP_BIN = ROOT / "dist" / "CodexUsageHUD.app" / "Contents" / "Resources" / "bin"
APP_LAUNCHD = ROOT / "dist" / "CodexUsageHUD.app" / "Contents" / "Resources" / "launchd"


def load_list() -> list[str]:
    names = [line.strip() for line in LIST_FILE.read_text().splitlines() if line.strip() and not line.startswith("#")]
    return names


def referenced_scripts() -> set[str]:
    names: set[str] = set()
    budget = (ROOT / "bin" / "bloom-budget-update").read_text()
    names.update(re.findall(r'helper ([a-z0-9.-]+)', budget))
    refresh = (ROOT / "bin" / "codex-usage-refresh").read_text()
    names.update(re.findall(r'bloom-budget-update', refresh) and ["bloom-budget-update"] or [])
    for plist in (ROOT / "launchd").glob("com.codexusagehud.*.plist"):
        text = plist.read_text()
        names.update(re.findall(r"%%BIN_DIR%%/([A-Za-z0-9._-]+)", text))
    write_claude = (ROOT / "bin" / "bloom-usage-write-claude").read_text()
    names.update(re.findall(r"siblingBin\('([^']+)'\)", write_claude))
    gemini = (ROOT / "bin" / "bloom-usage-write-gemini-agy").read_text()
    names.update(re.findall(r"siblingBin\('([^']+)'\)", gemini))
    return {n for n in names if n}


def main() -> int:
    failures: list[str] = []
    names = load_list()
    if not names:
        failures.append("Resources/bundled-helpers.txt is empty")

    for name in names:
        path = ROOT / "bin" / name
        if not path.is_file():
            failures.append(f"source missing: bin/{name}")

    expected = {
        "bloom-budget-notify",
        "bloom-budget-update",
        "bloom-node",
        "bloom-usage-capture.sh",
        "bloom-usage-fetch-claude-official",
        "bloom-usage-statusline-tap",
        "bloom-usage-write-claude",
        "bloom-usage-write-codex",
        "bloom-usage-write-gemini-agy",
        "bloom-usage-write-grok",
        "codex-usage-doctor",
        "codex-usage-refresh",
        "codex-usage-write",
    }
    unexpected = sorted(set(names) - expected)
    if unexpected:
        failures.append("bundled-helpers.txt lists helpers that are not product runtime: " + ", ".join(unexpected))
    missing_required = sorted(expected - set(names))
    if missing_required:
        failures.append("bundled-helpers.txt missing required scripts: " + ", ".join(missing_required))

    referenced = referenced_scripts()
    skip_refs: set[str] = set()
    missing_refs = sorted((referenced - set(names)) - skip_refs)
    if missing_refs:
        failures.append("runtime reference not bundled: " + ", ".join(missing_refs))

    # One version everywhere: Info.plist, AppInfo.swift, the update feed and the built app.
    info = plistlib.loads((ROOT / "Resources" / "Info.plist").read_bytes())
    want = (info["CFBundleShortVersionString"], info["CFBundleVersion"])
    swift = (ROOT / "Sources" / "CodexUsageHUD" / "AppInfo.swift").read_text()
    if tuple(re.findall(r'(?:marketingVersion|buildNumber) = "([^"]+)"', swift)) != want:
        failures.append(f"AppInfo.swift does not say {want}")
    feed = (ROOT / "site" / "public" / "appcast.xml").read_text()
    for b, v in re.findall(r"<sparkle:version>(\d+)</sparkle:version>\s*<sparkle:shortVersionString>([^<]+)<", feed):
        if int(b) > int(want[1]) or (v == want[0]) != (b == want[1]):
            failures.append(f"update feed item {v} (build {b}) disagrees with Info.plist {want}")
    if APP_BIN.is_dir():
        built = plistlib.loads((APP_BIN.parents[1] / "Info.plist").read_bytes())
        if (built["CFBundleShortVersionString"], built["CFBundleVersion"]) != want:
            failures.append(f"built app is not {want}")
        for name in names:
            if not (APP_BIN / name).is_file():
                failures.append(f"packaged app missing: Contents/Resources/bin/{name}")
            elif (APP_BIN / name).read_bytes() != (ROOT / "bin" / name).read_bytes():
                failures.append(f"packaged app has stale helper: {name}")
        for label in (
            "com.codexusagehud.app",
            "com.codexusagehud.codex-writer",
            "com.codexusagehud.claude-writer",
            "com.codexusagehud.grok-writer",
            "com.codexusagehud.refresh",
        ):
            if not (APP_LAUNCHD / f"{label}.plist").is_file():
                failures.append(f"packaged app missing launchd template: {label}.plist")
        print("packaged app checked")
    else:
        print("packaged app not present; source list checked")

    if failures:
        print("bundle completeness FAILED")
        for item in failures:
            print("  -", item)
        return 1
    print(f"bundle completeness: {len(names)} helpers ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
