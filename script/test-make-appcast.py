#!/usr/bin/env python3
"""Checks script/make_appcast.py: adds items newest first, keeps older ones,
replaces a re-run of the same build, and never touches the input when --output
is given. Uses --ed-signature so no Keychain key is needed."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "script" / "make_appcast.py"
NS = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
SP = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def run(*args: str) -> None:
    subprocess.run([sys.executable, str(SCRIPT), *args], check=True, capture_output=True, text=True)


def items(path: Path) -> list[ET.Element]:
    return ET.parse(path).getroot().findall("channel/item")


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        appcast = tmp_path / "appcast.xml"
        # Release history changes independently of this hermetic fixture.
        appcast.write_text('<rss version="2.0"><channel><title>Usage HUD</title></channel></rss>')
        zip_a = tmp_path / "a.zip"
        zip_a.write_bytes(b"a" * 100)
        zip_b = tmp_path / "b.zip"
        zip_b.write_bytes(b"b" * 250)

        run("--appcast", str(appcast), "--archive", str(zip_a), "--version", "8", "--short-version", "1.3.0",
            "--ed-signature", "SIGA==", "--length", "100")
        run("--appcast", str(appcast), "--archive", str(zip_b), "--version", "9", "--short-version", "1.3.1",
            "--ed-signature", "SIGB==", "--length", "250", "--description", "Fixes.")
        # Re-running build 9 replaces it rather than duplicating it.
        run("--appcast", str(appcast), "--archive", str(zip_b), "--version", "9", "--short-version", "1.3.1",
            "--ed-signature", "SIGB2==", "--length", "250")

        got = items(appcast)
        versions = [i.findtext("sparkle:version", namespaces=NS) for i in got]
        assert versions == ["9", "8"], versions
        newest = got[0]
        enc = newest.find("enclosure")
        assert enc is not None
        assert enc.get("url") == "https://github.com/Thalia-Bloom/usage-hud/releases/download/v1.3.1/UsageHUD.zip", enc.get("url")
        assert enc.get(SP + "edSignature") == "SIGB2==", enc.attrib
        assert enc.get("length") == "250"
        assert newest.findtext("sparkle:shortVersionString", namespaces=NS) == "1.3.1"
        assert newest.findtext("sparkle:minimumSystemVersion", namespaces=NS) == "14.0"
        assert newest.findtext("pubDate")
        text = appcast.read_text()
        assert 'xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"' in text
        assert "ns0:" not in text, "namespace prefix lost"

        # A length that does not match the archive is refused.
        bad = subprocess.run([sys.executable, str(SCRIPT), "--appcast", str(appcast), "--archive", str(zip_a),
                              "--version", "10", "--short-version", "1.4.0", "--ed-signature", "X==", "--length", "5"],
                             capture_output=True, text=True)
        assert bad.returncode != 0 and "does not match" in bad.stderr, bad.stderr

        # --output leaves the source appcast alone.
        before = appcast.read_text()
        preview = tmp_path / "preview.xml"
        run("--appcast", str(appcast), "--output", str(preview), "--archive", str(zip_a), "--version", "10",
            "--short-version", "1.4.0", "--ed-signature", "SIGC==", "--length", "100")
        assert appcast.read_text() == before
        assert [i.findtext("sparkle:version", namespaces=NS) for i in items(preview)] == ["10", "9", "8"]

    print("make_appcast: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
