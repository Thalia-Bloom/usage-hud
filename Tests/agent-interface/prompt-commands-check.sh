#!/bin/sh
# Runs the onboarding prompt's exact "Add:" commands against a throwaway
# HOME, so no real agent config (~/.claude*, ~/.codex, ~/.gemini) is
# touched. Copies the binary to a path with a space and a single quote to
# prove the prompt's quoting. Skips agent CLIs that are not installed.
#
# Usage: Tests/agent-interface/prompt-commands-check.sh [path-to-binary]
# Needs the AgentCLI hook in App.swift (main() must route CLI arguments).
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC_BIN="${1:-$ROOT/.build/debug/CodexUsageHUD}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/usage-hud-prompt.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
WORK=$(cd "$WORK" && pwd)   # drop the // a trailing-slash TMPDIR leaves

APPDIR="$WORK/Bob's Apps/Usage HUD.app/Contents/MacOS"
BIN="$APPDIR/CodexUsageHUD"
mkdir -p "$APPDIR"
cp "$SRC_BIN" "$BIN"

FAKEHOME="$WORK/home"
mkdir -p "$FAKEHOME/.codex" "$FAKEHOME/.gemini"
export CODEX_USAGE_HUD_STATE_DIR="${CODEX_USAGE_HUD_STATE_DIR:-$WORK/state}"
mkdir -p "$CODEX_USAGE_HUD_STATE_DIR"

fail=0
HOME="$FAKEHOME" "$BIN" prompt > "$WORK/prompt.txt" || { echo "FAIL: prompt exited non-zero"; exit 1; }
grep -q "Bob'\\\\''s Apps/Usage HUD.app" "$WORK/prompt.txt" || { echo "FAIL: prompt does not shell-quote the path"; fail=1; }

run_add() {
  tool=$1
  line=$(grep -E "^ +Add: $tool mcp add" "$WORK/prompt.txt" | sed -E 's/^ +Add: //')
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "skip: $tool not installed"
    return
  fi
  echo "run: $line"
  ( export HOME="$FAKEHOME" CODEX_HOME="$FAKEHOME/.codex"; cd "$FAKEHOME" && eval "$line" ) >"$WORK/$tool.log" 2>&1 \
    || { echo "FAIL: $tool add exited non-zero"; sed 's/^/  /' "$WORK/$tool.log"; fail=1; }
}
run_add claude
run_add codex
run_add gemini

if command -v claude >/dev/null 2>&1; then
  cmd=$(plutil -extract mcpServers.usage-hud.command raw -o - "$FAKEHOME/.claude.json" 2>/dev/null)
  [ "$cmd" = "$BIN" ] && echo "ok: Claude Code user config points at the binary" || { echo "FAIL: Claude Code config command is '$cmd'"; fail=1; }
  arg=$(plutil -extract mcpServers.usage-hud.args.0 raw -o - "$FAKEHOME/.claude.json" 2>/dev/null)
  [ "$arg" = "mcp" ] || { echo "FAIL: Claude Code args[0] is '$arg'"; fail=1; }
fi
if command -v codex >/dev/null 2>&1; then
  grep -q '^\[mcp_servers.usage-hud\]' "$FAKEHOME/.codex/config.toml" && grep -qF "$BIN" "$FAKEHOME/.codex/config.toml" \
    && echo "ok: Codex config.toml has [mcp_servers.usage-hud]" || { echo "FAIL: Codex config.toml"; cat "$FAKEHOME/.codex/config.toml"; fail=1; }
fi
if command -v gemini >/dev/null 2>&1; then
  cmd=$(plutil -extract mcpServers.usage-hud.command raw -o - "$FAKEHOME/.gemini/settings.json" 2>/dev/null)
  [ "$cmd" = "$BIN" ] && echo "ok: Gemini user settings point at the binary" || { echo "FAIL: Gemini settings command is '$cmd'"; fail=1; }
fi

# Each CLI's own health check launches the server from the config it wrote.
if command -v claude >/dev/null 2>&1; then
  ( export HOME="$FAKEHOME"; cd "$FAKEHOME" && claude mcp list ) >"$WORK/claude-list.log" 2>&1
  grep -i "usage-hud" "$WORK/claude-list.log" | grep -qi "connected" \
    && echo "ok: claude mcp list reports usage-hud connected" \
    || { echo "FAIL: claude mcp list"; sed 's/^/  /' "$WORK/claude-list.log"; fail=1; }
fi
if command -v gemini >/dev/null 2>&1; then
  ( export HOME="$FAKEHOME"; cd "$FAKEHOME" && gemini mcp list ) >"$WORK/gemini-list.log" 2>&1
  grep -i "usage-hud" "$WORK/gemini-list.log" | grep -qi "connected" \
    && echo "ok: gemini mcp list reports usage-hud connected" \
    || { echo "note: gemini mcp list did not report connected (Gemini starts servers only in trusted folders):"; sed 's/^/  /' "$WORK/gemini-list.log"; }
fi

[ $fail -eq 0 ] && echo "PASS: prompt commands" || echo "FAILED: prompt commands"
exit $fail
