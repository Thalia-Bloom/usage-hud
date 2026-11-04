#!/usr/bin/env python3
"""Export a checked Git tree, without history or private operations."""
import argparse
import gzip
import io
import json
import subprocess
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FOLDERS = {"Sources", "Tests", "bin", "script", "launchd", "Resources", "hooks", "fixtures"}
FILES = {"Makefile", "Package.swift", "Package.resolved", "LICENSE", "README.md", "INSTALL.md",
         ".gitignore", "docs/AGENTS-INTEGRATION.md", "docs/LICENSE-CORE.md", "site/public/appcast.xml", "media/panel-hot.png"}
EXCLUDE = {"script/reel", "script/support-review.py", "script/test-support-review.py",
           "script/test-release-checklist.py"}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--ref", default="HEAD")
    parser.add_argument("--output", type=Path, default=ROOT / "dist/UsageHUD-source.tar.gz")
    args = parser.parse_args()
    tree = subprocess.check_output(["git", "rev-parse", "--verify", args.ref + "^{tree}"], cwd=args.root, text=True).strip()
    raw = subprocess.check_output(["git", "archive", "--format=tar", tree], cwd=args.root)
    selected = []
    with tarfile.open(fileobj=io.BytesIO(raw)) as source:
        for entry in source:
            name = entry.name
            if name not in FILES and name.split("/")[0] not in FOLDERS:
                continue
            if any(name == excluded or name.startswith(excluded + "/") for excluded in EXCLUDE):
                continue
            if entry.isdir():
                continue
            if not entry.isfile():
                raise SystemExit(f"Source export refuses links or special files: {name}")
            selected.append((name, source.extractfile(entry).read(), entry.mode & 0o755))
    names = {name for name, _, _ in selected}
    if not {"LICENSE", "Makefile", "README.md", "script/check-mini.sh"} <= names:
        raise SystemExit("Source export is missing its license, install instructions or checks")
    texts = [(name, data.decode("utf-8", errors="replace")) for name, data, _ in selected if b"\0" not in data]
    subprocess.run(["node", str(ROOT / "script/test-shipped-open-source.js"), "--stdin"],
                   input=json.dumps(texts), text=True, check=True)
    selected.append(("SOURCE-EXPORT.json", (json.dumps({"tree": tree, "format": 1}) + "\n").encode(), 0o644))
    result = io.BytesIO()
    with tarfile.open(fileobj=result, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for name, data, mode in sorted(selected):
            entry = tarfile.TarInfo("usage-hud/" + name)
            entry.size, entry.mode = len(data), mode
            archive.addfile(entry, io.BytesIO(data))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # No destination is opened until all source content passes the gate.
    args.output.write_bytes(gzip.compress(result.getvalue(), mtime=0))
    print(f"Source export: {len(selected)} files, tree {tree}, {args.output.name}")

if __name__ == "__main__":
    main()
