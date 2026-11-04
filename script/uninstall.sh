#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

LABELS=(
  com.codexusagehud.app
  com.codexusagehud.codex-writer
  com.codexusagehud.claude-writer
  com.codexusagehud.grok-writer
  com.codexusagehud.refresh
  com.codexusagehud.live-scraper
  com.bloom.usage-hud
  com.bloom.usage-codex-writer
  com.bloom.usage-claude-writer
  com.bloom.usage-refresh
)

for label in "${LABELS[@]}"; do
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
done

pkill -x CodexUsageHUD >/dev/null 2>&1 || true
pkill -x BloomUsageHUD >/dev/null 2>&1 || true

rm -rf "$HOME/Applications/CodexUsageHUD.app"
rm -rf "$HOME/Applications/BloomUsageHUD.app"

BINARIES=(
  codex-usage-doctor
  codex-usage-write
  codex-usage-refresh
  codex-usage-live-scrape
  bloom-usage-capture.sh
  bloom-usage-statusline-tap
  bloom-usage-write-claude
  bloom-usage-fetch-claude-official
  bloom-usage-write-codex
  bloom-usage-fetch-gemini
  bloom-usage-write-gemini-agy
  bloom-usage-write-grok
  bloom-budget-update
  bloom-budget-notify
  bloom-node
)

for binary in "${BINARIES[@]}"; do
  rm -f "$HOME/.local/bin/$binary"
done

# Preserve user edits or another owner's replacement in the shared hooks directory.
GUARD_HOOK="$HOME/.claude/hooks/bloom-budget-guard.js"
if [ -f "$GUARD_HOOK" ] && cmp -s "$ROOT_DIR/hooks/bloom-budget-guard.js" "$GUARD_HOOK"; then
  rm -f "$GUARD_HOOK"
fi

# Remove only the tracker script this repo installs; the data files it
# writes (data.json, summary.json) and status.sh belong to the user, not
# to this repo, so leave them in place.

# The capture hook lives in a shared Claude hooks directory. Remove it only
# when it is still the exact copy this repo installed; preserve user edits or
# another owner's replacement.
CAPTURE_HOOK="$HOME/.claude/hooks/bloom-usage-capture.sh"
if [ -f "$CAPTURE_HOOK" ] && cmp -s "$ROOT_DIR/bin/bloom-usage-capture.sh" "$CAPTURE_HOOK"; then
  rm -f "$CAPTURE_HOOK"
fi

if [ "${REMOVE_STATE:-0}" = "1" ]; then
  rm -rf "$HOME/.codex-usage-hud"
  rm -rf "$HOME/Library/Application Support/Codex Usage HUD"
fi

echo "Usage HUD uninstalled. State preserved unless REMOVE_STATE=1 was set."
