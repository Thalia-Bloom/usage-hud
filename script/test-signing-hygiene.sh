#!/bin/bash
# Tests for script/strip_detritus.sh and script/verify_signature.sh.
# Part 1 runs anywhere with stubbed tools. Part 2 uses the real codesign,
# xattr and dot_clean, so it runs on macOS only and skips elsewhere.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
CALL_LOG="$TMP_DIR/calls.log"
export CALL_LOG

fail() { echo "FAIL: $*" >&2; exit 1; }

stub() {  # stub <name> <exit status>
  printf '%s\n' '#!/bin/bash' "printf '%s %s\n' $1 \"\$*\" >> \"\$CALL_LOG\"" "exit $2" > "$TMP_DIR/$1"
  chmod +x "$TMP_DIR/$1"
}

# --- Part 1: stubbed tools -------------------------------------------------
stub xattr 0
stub dot_clean 0
APP="$TMP_DIR/Fake.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/sub"
touch "$APP/Contents/MacOS/Fake" "$APP/Contents/Resources/keep.txt" \
  "$APP/Contents/Resources/._keep.txt" "$APP/Contents/Resources/sub/._orphan" \
  "$APP/.DS_Store" "$APP/Contents/Resources/.DS_Store"

: > "$CALL_LOG"
XATTR="$TMP_DIR/xattr" DOT_CLEAN="$TMP_DIR/dot_clean" "$ROOT_DIR/script/strip_detritus.sh" "$APP"
grep -qx "dot_clean -m $APP" "$CALL_LOG" || fail "strip_detritus did not run dot_clean -m"
grep -qx "xattr -cr $APP" "$CALL_LOG" || fail "strip_detritus did not run xattr -cr"
[ "$(head -1 "$CALL_LOG" | cut -d' ' -f1)" = dot_clean ] || fail "dot_clean must run before xattr -cr"
left="$(find "$APP" \( -name '._*' -o -name '.DS_Store' \))"
[ -z "$left" ] || fail "detritus left behind: $left"
[ -f "$APP/Contents/Resources/keep.txt" ] || fail "strip_detritus removed a real file"

if XATTR="$TMP_DIR/xattr" DOT_CLEAN="$TMP_DIR/dot_clean" "$ROOT_DIR/script/strip_detritus.sh" "$TMP_DIR/missing.app" 2>/dev/null; then
  fail "strip_detritus accepted a missing bundle"
fi
stub xattr 1
if XATTR="$TMP_DIR/xattr" DOT_CLEAN="$TMP_DIR/dot_clean" "$ROOT_DIR/script/strip_detritus.sh" "$APP" 2>/dev/null; then
  fail "strip_detritus ignored an xattr failure"
fi

# verify_signature: passes when codesign passes, stops when it fails.
stub codesign 0
: > "$CALL_LOG"
CODESIGN="$TMP_DIR/codesign" "$ROOT_DIR/script/verify_signature.sh" "$APP" >/dev/null
grep -qx "codesign --verify --deep --strict --verbose=2 $APP" "$CALL_LOG" \
  || fail "verify_signature did not run a deep strict verify"
stub codesign 1
if CODESIGN="$TMP_DIR/codesign" "$ROOT_DIR/script/verify_signature.sh" "$APP" >/dev/null 2>&1; then
  fail "verify_signature passed although codesign failed"
fi
if CODESIGN="$TMP_DIR/codesign" "$ROOT_DIR/script/verify_signature.sh" "$TMP_DIR/missing.dmg" >/dev/null 2>&1; then
  fail "verify_signature accepted a missing disk image"
fi

# Wiring: strip before the first codesign, strict gate in package, dmg and release check.
SIGN="$ROOT_DIR/script/sign_app.sh"
strip_line="$(grep -n 'strip_detritus.sh' "$SIGN" | head -1 | cut -d: -f1)"
sign_line="$(grep -n '^sign "\|^  sign \|^  \[ -e .*\] && sign' "$SIGN" | head -1 | cut -d: -f1)"
[ -n "$strip_line" ] && [ -n "$sign_line" ] && [ "$strip_line" -lt "$sign_line" ] \
  || fail "sign_app.sh must strip detritus before signing"
grep -qF 'verify_signature.sh" "$APP_BUNDLE"' "$ROOT_DIR/script/package_release.sh" \
  || fail "package_release.sh lacks the strict verify gate"
grep -qF 'verify_signature.sh" "$OUT"' "$ROOT_DIR/script/make_dmg.sh" \
  || fail "make_dmg.sh lacks the strict verify gate"
grep -qF 'verify_signature.sh "dist/release/Usage HUD.app"' "$ROOT_DIR/script/release_check.sh" \
  || fail "release_check.sh lacks the strict verify gate on the app"
grep -qF 'verify_signature.sh "dist/UsageHUD-' "$ROOT_DIR/script/release_check.sh" \
  || fail "release_check.sh lacks the strict verify gate on the disk image"
echo "signing hygiene: stubbed checks passed"

# --- Part 2: real tools (macOS only) ---------------------------------------
if [ "$(uname -s)" != "Darwin" ]; then
  echo "SKIP signing hygiene live check: needs macOS (codesign, xattr, dot_clean); ran stubbed checks only"
  exit 0
fi

LIVE="$TMP_DIR/Live.app"
mkdir -p "$LIVE/Contents/MacOS" "$LIVE/Contents/Resources"
cp /usr/bin/true "$LIVE/Contents/MacOS/Live"
cat > "$LIVE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Live</string>
<key>CFBundleIdentifier</key><string>com.codexusagehud.signing-hygiene-test</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
echo hello > "$LIVE/Contents/Resources/note.txt"
# The audit's failure: Finder info and a resource fork on files in the bundle.
/usr/bin/xattr -wx com.apple.FinderInfo \
  "0000000000000000000000000000000000000000000000000000000000000000" "$LIVE/Contents/Resources/note.txt"
/usr/bin/xattr -w com.apple.ResourceFork fork "$LIVE/Contents/Resources/note.txt"
touch "$LIVE/Contents/Resources/._note.txt" "$LIVE/.DS_Store"

"$ROOT_DIR/script/sign_app.sh" "$LIVE" - >/dev/null
"$ROOT_DIR/script/verify_signature.sh" "$LIVE" >/dev/null 2>&1 \
  || fail "signed bundle did not pass the strict check after stripping"
# macOS can retain protected com.apple.provenance after xattr -cr. It does
# not invalidate the strict signature above. Require the signing detritus we
# planted to be absent rather than rejecting unrelated system metadata.
attrs="$(/usr/bin/xattr "$LIVE/Contents/Resources/note.txt")"
if printf '%s\n' "$attrs" | grep -Eq '^com\.apple\.(ResourceFork|FinderInfo)$'; then
  fail "signing detritus survived strip_detritus"
fi

# Detritus added after signing must stop the gate.
touch "$LIVE/Contents/Resources/._late"
if "$ROOT_DIR/script/verify_signature.sh" "$LIVE" >/dev/null 2>&1; then
  fail "strict check passed a bundle changed after signing"
fi
echo "signing hygiene: live macOS checks passed"
