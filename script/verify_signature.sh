#!/bin/bash
# Release gate: strict, deep signature check of an app bundle or a disk image.
# A detritus or seal failure exits non-zero, so the release stops.
#
# usage: script/verify_signature.sh <App.app | image.dmg>
#   For a .dmg: checks the image's own signature when it has one (local
#   unsigned images skip that part), then mounts it read-only and checks
#   every .app inside.
#   CODESIGN, HDIUTIL  override the tools (tests only)
set -euo pipefail

TARGET="${1:?usage: $0 <App.app | image.dmg>}"
CODESIGN="${CODESIGN:-/usr/bin/codesign}"
HDIUTIL="${HDIUTIL:-/usr/bin/hdiutil}"

verify() {
  if ! "$CODESIGN" --verify --deep --strict --verbose=2 "$1"; then
    echo "verify_signature: FAILED strict check: $1" >&2
    exit 1
  fi
  echo "verify_signature: ok $1"
}

case "$TARGET" in
  *.dmg)
    [ -f "$TARGET" ] || { echo "verify_signature: no disk image at $TARGET" >&2; exit 1; }
    if "$CODESIGN" --display "$TARGET" >/dev/null 2>&1; then
      verify "$TARGET"
    else
      echo "verify_signature: $TARGET is unsigned (local build); checking the app inside only"
    fi
    MOUNT="$(mktemp -d)"
    "$HDIUTIL" attach -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$TARGET" >/dev/null
    trap '"$HDIUTIL" detach "$MOUNT" >/dev/null 2>&1 || true; rmdir "$MOUNT" 2>/dev/null || true' EXIT
    found=0
    for app in "$MOUNT"/*.app; do
      [ -d "$app" ] || continue
      found=1
      verify "$app"
    done
    [ "$found" -eq 1 ] || { echo "verify_signature: no .app inside $TARGET" >&2; exit 1; }
    ;;
  *)
    [ -d "$TARGET" ] || { echo "verify_signature: no bundle at $TARGET" >&2; exit 1; }
    verify "$TARGET"
    ;;
esac
