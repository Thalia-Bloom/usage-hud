#!/bin/bash
# Build the drag-to-Applications installer for a signed (ideally notarized and
# stapled) "Usage HUD.app", sign the disk image, and optionally notarize it.
#
#   ./script/make_dmg.sh "dist/release/Usage HUD.app" dist/UsageHUD-1.3.0-8.dmg
#
# Env: DEVELOPER_ID_APPLICATION (sign), NOTARYTOOL_PROFILE (notarize + staple).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:?usage: make_dmg.sh <Usage HUD.app> <out.dmg>}"
OUT="${2:?usage: make_dmg.sh <Usage HUD.app> <out.dmg>}"
SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
NOTARY_PROFILE="${NOTARYTOOL_PROFILE:-}"

rm -f "$OUT"
uvx --from dmgbuild dmgbuild \
  -s "$ROOT_DIR/Resources/dmg/settings.py" \
  -D app="$APP" \
  -D background="$ROOT_DIR/Resources/dmg/background.png" \
  "Usage HUD" "$OUT"

if [ -n "$SIGN_IDENTITY" ]; then
  /usr/bin/codesign --force --timestamp --sign "$SIGN_IDENTITY" "$OUT"
fi

if [ -n "$NOTARY_PROFILE" ] && [ -n "$SIGN_IDENTITY" ]; then
  xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUT"
fi

# Strict gate on the image and the app inside it: a detritus failure stops here.
"$ROOT_DIR/script/verify_signature.sh" "$OUT"

/usr/bin/shasum -a 256 "$OUT" > "$OUT.sha256"
echo "$OUT"
