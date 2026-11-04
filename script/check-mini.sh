#!/bin/bash
# Offline code-health check. App builds and signed release packaging stay separate.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

for tool in python3 node; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 127; }
done
node -e 'if (Number(process.versions.node.split(".")[0]) < 22) { console.error("Node 22 or later is required for the offline store tests"); process.exit(1); }'

# The existing tests create their own fixture homes/state and mock provider calls.
for test in script/test-*; do
  echo "Running $test"
  case "$test" in
    *.py) python3 "$test" ;;
    *.js) node "$test" ;;
    *.sh) bash "$test" ;;
    *) echo "Unknown test type: $test" >&2; exit 1 ;;
  esac
done

if [ -f SOURCE-EXPORT.json ]; then
  [ ! -e site/build.mjs ] && [ ! -d store ] || { echo 'Refusing source-distribution mode with hosted services present' >&2; exit 1; }
  echo 'Source distribution: product checks only; hosted site and support operations are excluded'
else
  echo 'Checking site shared copy and offline site/store tests'
  node site/build.mjs --check
  node --test site/test/*.mjs store/test/*.mjs
  node store/scripts/check-local.mjs
fi

echo 'Checking helper, release and store script syntax and launchd plists'
python3 - <<'PY'
import ast
import plistlib
import subprocess
from pathlib import Path

for folder in ('bin', 'hooks', 'script', 'site', 'store/scripts', 'store/src'):
    for path in sorted(Path(folder).rglob('*')):
        if not path.is_file() or '__pycache__' in path.parts:
            continue
        if path.suffix not in ('', '.py', '.sh', '.js', '.mjs'):
            continue
        source = path.read_text()
        first = source.splitlines()[0] if source else ''
        if folder == 'bin' and not first.startswith('#!'):
            raise SystemExit(f'Missing shebang: {path}')
        if path.suffix == '.py' or 'python' in first:
            ast.parse(source, filename=str(path))
        elif path.suffix in ('.js', '.mjs') or 'node' in first:
            subprocess.run(['node', '--check', str(path)], check=True)
        elif path.suffix == '.sh' or first.startswith('#!'):
            subprocess.run(['bash' if 'bash' in first else 'sh', '-n', str(path)], check=True)
for path in [*sorted(Path('launchd').glob('*.plist')), Path('Resources/Info.plist')]:
    with path.open('rb') as stream:
        plistlib.load(stream)
PY

echo 'Mini check passed (no Swift build, signing identity, live providers or deployment)'
