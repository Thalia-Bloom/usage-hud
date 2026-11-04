#!/bin/bash
# Remove resource forks, Finder info and other extended attributes, plus
# AppleDouble (._*) and .DS_Store files, from a bundle before it is signed.
# codesign refuses such "detritus" ("resource fork, Finder information, or
# similar detritus not allowed"), and `codesign --verify --deep --strict`
# fails on it even when notarization passes.
#
# usage: script/strip_detritus.sh <App.app>
#   XATTR, DOT_CLEAN  override the tools (tests only)
set -euo pipefail

BUNDLE="${1:?usage: $0 <App.app>}"
[ -d "$BUNDLE" ] || { echo "strip_detritus: no bundle at $BUNDLE" >&2; exit 1; }
XATTR="${XATTR:-/usr/bin/xattr}"
DOT_CLEAN="${DOT_CLEAN:-/usr/sbin/dot_clean}"

# dot_clean -m folds any ._ files back into their owners and deletes them;
# xattr -cr clears removable extended attributes, including the folded ones.
# macOS may retain protected provenance metadata; strict codesign is the gate.
"$DOT_CLEAN" -m "$BUNDLE"
"$XATTR" -cr "$BUNDLE"
# Anything dot_clean left (a ._ file with no owner, Finder's .DS_Store).
find "$BUNDLE" \( -name '._*' -o -name '.DS_Store' \) -exec rm -rf {} +
