#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CodexUsageHUD"
# Buyers see the bundle's folder name in Finder and Launchpad, so the release
# ships as "Usage HUD.app". The executable, bundle ID and the developer
# install path (~/Applications/CodexUsageHUD.app via make) stay unchanged.
RELEASE_APP_NAME="Usage HUD"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
DIST_DIR="$ROOT_DIR/dist"
BUILT_BUNDLE="$DIST_DIR/$APP_NAME.app"
RELEASE_DIR="$DIST_DIR/release"
APP_BUNDLE="$RELEASE_DIR/$RELEASE_APP_NAME.app"
# Marketing version and build come from Resources/Info.plist (1.0.0 / 1).
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
ARCHIVE_BASENAME="UsageHUD-$VERSION-$BUILD"
ZIP_PATH="$DIST_DIR/$ARCHIVE_BASENAME.zip"
CHECKSUM_PATH="$ZIP_PATH.sha256"
# GitHub release asset name the appcast points at (same bytes as $ZIP_PATH).
SPARKLE_ZIP_PATH="$DIST_DIR/UsageHUD.zip"
MIN_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST")"
SITE_APPCAST="$ROOT_DIR/site/public/appcast.xml"
PREVIEW_APPCAST="$DIST_DIR/appcast.xml"
SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
NOTARY_PROFILE="${NOTARYTOOL_PROFILE:-}"
SKIP_NOTARY=0
NOTARIZED=0

for arg in "$@"; do
  case "$arg" in
    --skip-notary|--no-notary)
      SKIP_NOTARY=1
      ;;
    *)
      echo "usage: $0 [--skip-notary]" >&2
      exit 2
      ;;
  esac
done

cd "$ROOT_DIR"
make app
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"
/usr/bin/ditto "$BUILT_BUNDLE" "$APP_BUNDLE"

# Strip extended attributes (for example com.apple.provenance), resource forks and
# ._ files: ditto stores xattrs as AppleDouble entries that break the code seal when a
# buyer unzips with a different tool. sign_app.sh strips again right before signing.
"$ROOT_DIR/script/strip_detritus.sh" "$APP_BUNDLE"

# Sparkle's XPC services, Autoupdate and Updater.app, then Sparkle.framework,
# then the app: hardened runtime + secure timestamp with a Developer ID, no --deep.
"$ROOT_DIR/script/sign_app.sh" "$APP_BUNDLE" "$SIGN_IDENTITY"

"$ROOT_DIR/script/verify_signature.sh" "$APP_BUNDLE"
/usr/bin/spctl --assess --type execute "$APP_BUNDLE" >/dev/null 2>&1 || true

mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH" "$CHECKSUM_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
/usr/bin/shasum -a 256 "$ZIP_PATH" > "$CHECKSUM_PATH"

if [ "$SKIP_NOTARY" -eq 0 ] && [ -n "$NOTARY_PROFILE" ] && [ -n "$SIGN_IDENTITY" ]; then
  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_BUNDLE"
  rm -f "$ZIP_PATH" "$CHECKSUM_PATH"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
  /usr/bin/shasum -a 256 "$ZIP_PATH" > "$CHECKSUM_PATH"
  NOTARIZED=1
else
  echo "notarization skipped; set DEVELOPER_ID_APPLICATION and NOTARYTOOL_PROFILE to notarize"
fi

# Sparkle: the release asset users download is UsageHUD.zip, so sign exactly
# those bytes. Only a notarized build goes into the site's appcast; any other
# run writes a preview to dist/appcast.xml. sign_update reads the EdDSA private
# key from the login Keychain (generate_keys); without it, the step is skipped.
rm -f "$SPARKLE_ZIP_PATH" "$PREVIEW_APPCAST"
cp "$ZIP_PATH" "$SPARKLE_ZIP_PATH"
APPCAST_ARGS=(
  --archive "$SPARKLE_ZIP_PATH"
  --version "$BUILD"
  --short-version "$VERSION"
  --minimum-system-version "$MIN_SYSTEM"
)
if [ -n "${RELEASE_NOTES_FILE:-}" ]; then
  APPCAST_ARGS+=(--notes-file "$RELEASE_NOTES_FILE")
elif [ -n "${RELEASE_NOTES_URL:-}" ]; then
  APPCAST_ARGS+=(--release-notes-link "$RELEASE_NOTES_URL")
fi
if [ "$NOTARIZED" -eq 1 ]; then
  python3 "$ROOT_DIR/script/make_appcast.py" --appcast "$SITE_APPCAST" "${APPCAST_ARGS[@]}"
  echo "next: upload $SPARKLE_ZIP_PATH to GitHub release v$VERSION, then deploy the site"
elif python3 "$ROOT_DIR/script/make_appcast.py" --appcast "$SITE_APPCAST" --output "$PREVIEW_APPCAST" "${APPCAST_ARGS[@]}"; then
  echo "appcast preview (not notarized, site appcast untouched): $PREVIEW_APPCAST"
else
  echo "appcast skipped: no Sparkle signing key here (run generate_keys on the release Mac)"
fi

# The drag-to-Applications disk image is what people download; the zip
# stays for Sparkle and for anyone who prefers it.
DMG_PATH="$DIST_DIR/$ARCHIVE_BASENAME.dmg"
if [ "$NOTARIZED" -eq 1 ]; then
  "$ROOT_DIR/script/make_dmg.sh" "$APP_BUNDLE" "$DMG_PATH"
  cp "$DMG_PATH" "$DIST_DIR/UsageHUD.dmg"
  echo "next: upload $DIST_DIR/UsageHUD.dmg and $SPARKLE_ZIP_PATH to GitHub release v$VERSION"
else
  DEVELOPER_ID_APPLICATION="$SIGN_IDENTITY" NOTARYTOOL_PROFILE="" "$ROOT_DIR/script/make_dmg.sh" "$APP_BUNDLE" "$DMG_PATH"
fi

echo "$ZIP_PATH"
