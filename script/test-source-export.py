#!/usr/bin/env python3
"""Exercise the source-distribution boundary, including untracked/private files."""
import io
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXPORT = ROOT / "script/export-source.py"

def run(*args, cwd=ROOT):
    return subprocess.run(args, cwd=cwd, text=True, capture_output=True)

with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    assert EXPORT.exists(), "source export command is missing"
    for name in ("Sources/app.swift", "LICENSE", "Makefile", "README.md",
                 "script/check-mini.sh", "site/public/appcast.xml", "hooks/guard.js",
                 "docs/ops/private.txt", "site/private.txt", "store/private.txt"):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("fixture\n")
    assert run("git", "init", "-q", cwd=root).returncode == 0
    assert run("git", "add", ".", cwd=root).returncode == 0
    tree = run("git", "write-tree", cwd=root).stdout.strip()
    (root / "Sources/untracked.swift").write_text("must stay private\n")
    out = root / "source.tar.gz"
    command = (sys.executable, str(EXPORT), "--root", str(root), "--ref", tree, "--output", str(out))
    result = run(*command)
    assert result.returncode == 0, result.stderr
    first = out.read_bytes()
    with tarfile.open(fileobj=io.BytesIO(first)) as archive:
        names = set(archive.getnames())
        assert {"usage-hud/LICENSE", "usage-hud/Makefile", "usage-hud/SOURCE-EXPORT.json"} <= names
        assert "usage-hud/hooks/guard.js" in names
        assert not any("private" in name or "untracked" in name or "/.git/" in name for name in names)
    assert run(*command).returncode == 0
    assert out.read_bytes() == first, "export must be reproducible"
    (root / "Sources/app.swift").write_text("token = " + "sk-" + "A" * 24 + "\n")
    run("git", "add", ".", cwd=root)
    bad_tree = run("git", "write-tree", cwd=root).stdout.strip()
    bad = run(sys.executable, str(EXPORT), "--root", str(root), "--ref", bad_tree, "--output", str(out))
    assert bad.returncode != 0, "secret-shaped content must stop export"
    assert "A" * 24 not in bad.stdout + bad.stderr, "never print matched content"
    assert out.read_bytes() == first, "failed export must preserve the prior artifact"
    (root / "Sources/app.swift").write_text("fixture\n")
    (root / "Sources/link.swift").symlink_to(root / "docs/ops/private.txt")
    run("git", "add", ".", cwd=root)
    linked_tree = run("git", "write-tree", cwd=root).stdout.strip()
    linked = run(sys.executable, str(EXPORT), "--root", str(root), "--ref", linked_tree, "--output", str(out))
    assert linked.returncode != 0, "links must never import files outside the distribution"
    assert out.read_bytes() == first
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    for name, content in {
        "script/check-mini.sh": (ROOT / "script/check-mini.sh").read_text(),
        "script/test-product.sh": "#!/bin/sh\necho PRODUCT_TEST_RAN\n",
        "Resources/Info.plist": '<?xml version="1.0"?><plist version="1.0"><dict/></plist>',
        "SOURCE-EXPORT.json": "{}\n",
    }.items():
        target = root / name; target.parent.mkdir(parents=True, exist_ok=True); target.write_text(content)
    assert run("git", "init", "-q", cwd=root).returncode == 0
    result = run("bash", "script/check-mini.sh", cwd=root)
    assert result.returncode == 0, result.stderr
    assert "PRODUCT_TEST_RAN" in result.stdout
    (root / "store").mkdir()
    assert run("bash", "script/check-mini.sh", cwd=root).returncode != 0
print("source export: tracked files, exclusions, reproducibility, public clone checks and safe rejection passed")
