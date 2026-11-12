#!/bin/bash
# Sign an app bundle inside out, in the order Sparkle's docs give
# (sparkle-project.org/documentation/sandboxing/#code-signing):
#   Sparkle's XPC services, Autoupdate, Updater.app, Sparkle.framework, then the app.
# No --deep: it would re-sign the Downloader XPC service without its own
# entitlements, and Apple discourages it for signing.
#
# usage: script/sign_app.sh <App.app> [identity]
#   identity empty or "-"  ad-hoc, no hardened runtime (local builds; an
#                           ad-hoc app with library validation cannot load Sparkle)
#   otherwise              hardened runtime + secure timestamp (Developer ID)
#   SIGN_TIMESTAMP=none     skip the timestamp server (fast local Developer ID builds)
set -euo pipefail

APP="${1:?usage: $0 <App.app> [identity]}"
IDENTITY="${2:-}"
[ -d "$APP" ] || { echo "sign_app: no bundle at $APP" >&2; exit 1; }

if [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; then
  FLAGS=(--force --sign -)
else
  if [ "${SIGN_TIMESTAMP:-}" = "none" ]; then
    TS=(--timestamp=none)
  else
    TS=(--timestamp)
  fi
  FLAGS=(--force --options runtime "${TS[@]}" --sign "$IDENTITY")
fi

sign() { /usr/bin/codesign "${FLAGS[@]}" "$@"; }

# Resource forks, Finder info and ._ files make codesign's strict check fail.
"$(dirname "${BASH_SOURCE[0]}")/strip_detritus.sh" "$APP"

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  V="$SPARKLE/Versions/B"
  [ -d "$V" ] || { echo "sign_app: unexpected Sparkle layout (no Versions/B)" >&2; exit 1; }
  [ -e "$V/XPCServices/Installer.xpc" ] && sign "$V/XPCServices/Installer.xpc"
  # Sparkle >= 2.6: keep the Downloader service's own entitlements.
  [ -e "$V/XPCServices/Downloader.xpc" ] && sign --preserve-metadata=entitlements "$V/XPCServices/Downloader.xpc"
  sign "$V/Autoupdate"
  sign "$V/Updater.app"
  sign "$SPARKLE"
fi

# Developer ID builds carry the iCloud key-value entitlement (Show on my iPhone
# and iPad) and the provisioning profile that allows it. Ad-hoc builds skip both:
# a restricted entitlement without a matching profile stops the app launching.
# Profiles stay out of git; USAGE_HUD_PROFILE overrides the release Mac's copy.
RES="$(cd "$(dirname "${BASH_SOURCE[0]}")/../Resources" && pwd)"
PROFILE="${USAGE_HUD_PROFILE:-$HOME/.appstoreconnect/profiles/UsageHUD-DeveloperID.provisionprofile}"
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ] && [ -f "$PROFILE" ]; then
  cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
  sign --entitlements "$RES/UsageHUD.entitlements" "$APP"
else
  rm -f "$APP/Contents/embedded.provisionprofile"
  sign "$APP"
fi
