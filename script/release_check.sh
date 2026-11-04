#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

swift test

./script/check-mini.sh

bash ./script/package_release.sh --skip-notary >/dev/null
# Strict signature gate: a "resource fork, Finder information, or similar
# detritus" failure on the app or the disk image stops the release.
./script/verify_signature.sh "dist/release/Usage HUD.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
./script/verify_signature.sh "dist/UsageHUD-$VERSION-$BUILD.dmg"
python3 script/test-bundle-completeness.py

if [ "${CI:-}" = "true" ]; then
  echo "skipping codex-usage-doctor in CI; it requires local Codex sessions and launchd state"
else
  # The doctor reads this Mac's own install; its warnings (an old statusline tap,
  # a red budget) describe the Mac, not the candidate. Only failures stop the release.
  node bin/codex-usage-doctor || { rc=$?; [ "$rc" -eq 2 ] && echo "doctor warnings noted; not a release defect" || exit "$rc"; }
fi

echo "release check passed"
