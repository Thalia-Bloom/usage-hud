#!/usr/bin/env python3
"""Add or replace one release <item> in the Sparkle appcast.

script/package_release.sh calls this after notarizing and stapling. It signs
the release zip with Sparkle's sign_update (EdDSA key from the login Keychain;
the private key never leaves it), then writes the item. Items for other builds
are kept; an item for the same build is replaced so a re-run is safe.

  script/make_appcast.py --appcast site/public/appcast.xml \
      --archive dist/UsageHUD.zip --version 8 --short-version 1.3.0

Release notes: --notes-file NOTES.md (embedded as markdown), --release-notes-link
URL, or --description TEXT. Without any, a one-line description is written.
"""

from __future__ import annotations

import argparse
import email.utils
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC_NS = "http://purl.org/dc/elements/1.1/"
DEFAULT_SIGN_UPDATE = ROOT / ".build" / "artifacts" / "sparkle" / "Sparkle" / "bin" / "sign_update"
DOWNLOAD_URL = "https://github.com/Thalia-Bloom/usage-hud/releases/download/v{short}/UsageHUD.zip"
PRODUCT_URL = "https://hud.thaliabloom.com/"

ET.register_namespace("sparkle", SPARKLE_NS)
ET.register_namespace("dc", DC_NS)


def sp(tag: str) -> str:
    return f"{{{SPARKLE_NS}}}{tag}"


def sign_archive(sign_update: Path, archive: Path) -> tuple[str, int]:
    """Run sign_update and return (edSignature, length)."""
    if not sign_update.is_file():
        raise SystemExit(f"sign_update not found at {sign_update}; run `swift package resolve` first")
    proc = subprocess.run([str(sign_update), str(archive)], capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit(f"sign_update failed ({proc.returncode}): {proc.stderr.strip() or proc.stdout.strip()}")
    sig = re.search(r'sparkle:edSignature="([^"]+)"', proc.stdout)
    length = re.search(r'\blength="(\d+)"', proc.stdout)
    if not sig or not length:
        raise SystemExit(f"unexpected sign_update output: {proc.stdout.strip()}")
    return sig.group(1), int(length.group(1))


def load_appcast(path: Path) -> ET.ElementTree:
    if path.exists():
        parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
        return ET.parse(path, parser)
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Usage HUD"
    ET.SubElement(channel, "link").text = PRODUCT_URL
    ET.SubElement(channel, "description").text = "Usage HUD updates."
    ET.SubElement(channel, "language").text = "en"
    return ET.ElementTree(rss)


def build_item(args: argparse.Namespace, signature: str, length: int) -> ET.Element:
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Usage HUD {args.short_version}"
    ET.SubElement(item, "link").text = PRODUCT_URL
    ET.SubElement(item, sp("version")).text = str(args.version)
    ET.SubElement(item, sp("shortVersionString")).text = args.short_version
    ET.SubElement(item, sp("minimumSystemVersion")).text = args.minimum_system_version
    if args.release_notes_link:
        ET.SubElement(item, sp("releaseNotesLink")).text = args.release_notes_link
    elif args.notes_file:
        desc = ET.SubElement(item, "description", {sp("format"): "markdown"})
        desc.text = Path(args.notes_file).read_text().strip()
    else:
        text = args.description or f"Usage HUD {args.short_version} (build {args.version})."
        ET.SubElement(item, "description", {sp("format"): "plain-text"}).text = text
    ET.SubElement(item, "pubDate").text = args.pub_date or email.utils.formatdate(usegmt=True)
    ET.SubElement(item, "enclosure", {
        "url": args.url or DOWNLOAD_URL.format(short=args.short_version),
        "length": str(length),
        "type": "application/octet-stream",
        sp("edSignature"): signature,
    })
    return item


def item_version(item: ET.Element) -> str | None:
    node = item.find(sp("version"))
    if node is not None and node.text:
        return node.text.strip()
    enclosure = item.find("enclosure")
    return enclosure.get(sp("version")) if enclosure is not None else None


def upsert(tree: ET.ElementTree, item: ET.Element, version: str) -> None:
    channel = tree.getroot().find("channel")
    if channel is None:
        raise SystemExit("appcast has no <channel>")
    for old in channel.findall("item"):
        if item_version(old) == version:
            channel.remove(old)
    # Newest first: the new item goes above the existing ones.
    first_item = next((i for i, c in enumerate(channel) if c.tag == "item"), len(channel))
    channel.insert(first_item, item)


def write(tree: ET.ElementTree, path: Path) -> None:
    ET.indent(tree, space="  ")
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    body = ET.tostring(tree.getroot(), encoding="unicode")
    tmp.write_text('<?xml version="1.0" encoding="utf-8"?>\n' + body + "\n", encoding="utf-8")
    os.replace(tmp, path)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--appcast", required=True, type=Path, help="appcast to read (created if missing)")
    ap.add_argument("--output", type=Path, help="write here instead of --appcast")
    ap.add_argument("--archive", required=True, type=Path, help="the exact zip users will download")
    ap.add_argument("--version", required=True, help="CFBundleVersion (integer build)")
    ap.add_argument("--short-version", required=True, help="CFBundleShortVersionString")
    ap.add_argument("--minimum-system-version", default="14.0")
    ap.add_argument("--url", help="enclosure URL (default: GitHub release asset UsageHUD.zip)")
    ap.add_argument("--pub-date", help="RFC 2822 date (default: now)")
    notes = ap.add_mutually_exclusive_group()
    notes.add_argument("--release-notes-link")
    notes.add_argument("--notes-file", help="markdown release notes to embed")
    notes.add_argument("--description", help="short plain-text release note")
    ap.add_argument("--sign-update", type=Path, default=DEFAULT_SIGN_UPDATE)
    ap.add_argument("--ed-signature", help="skip sign_update and use this signature (needs --length)")
    ap.add_argument("--length", type=int)
    args = ap.parse_args(argv)

    if not re.fullmatch(r"\d+", str(args.version)):
        ap.error("--version must be the integer CFBundleVersion")
    if not args.archive.is_file():
        ap.error(f"archive not found: {args.archive}")

    size = args.archive.stat().st_size
    if args.ed_signature:
        if args.length is None:
            ap.error("--ed-signature needs --length")
        signature, length = args.ed_signature, args.length
    else:
        signature, length = sign_archive(args.sign_update, args.archive)
    if length != size:
        raise SystemExit(f"signed length {length} does not match {args.archive} size {size}")

    tree = load_appcast(args.appcast)
    upsert(tree, build_item(args, signature, length), str(args.version))
    out = args.output or args.appcast
    write(tree, out)
    print(f"appcast: {out} now offers {args.short_version} (build {args.version}), {length} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
