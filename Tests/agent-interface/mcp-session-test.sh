#!/bin/sh
# Scripted MCP stdio session against the built binary: pipes a full
# session (legacy initialize → tools/list → tools/call, then modern
# 2026-07-28 stateless requests and error cases) through `<binary> mcp`
# with fixture state, and checks every reply. macOS tools only (plutil).
#
# Usage: Tests/agent-interface/mcp-session-test.sh [path-to-binary]
#   default binary: .build/debug/CodexUsageHUD (run `swift build` first)
# Needs the AgentCLI hook at the top of main() in App.swift.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${1:-$ROOT/.build/debug/CodexUsageHUD}"
fail=0

if ! grep -q 'AgentCLI.runIfRequested' "$ROOT/Sources/CodexUsageHUD/App.swift"; then
  echo "FAIL: App.swift main() does not call AgentCLI.runIfRequested(); the binary would start the menu-bar app."
  exit 1
fi
[ -x "$BIN" ] || { echo "FAIL: no binary at $BIN (run swift build)"; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/usage-hud-mcp.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
STATE="$WORK/state"
mkdir -p "$STATE"

with_timeout() {
  secs=$1; shift
  "$@" & pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) & watcher=$!
  wait "$pid"; rc=$?
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  return $rc
}

at() { date -u -v"$1" +%Y-%m-%dT%H:%M:%SZ; }
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Fixture: Claude 85% of its week with 3 days left (running hot), Codex 20%.
cat > "$STATE/claude-usage.json" <<EOF
{"schemaVersion":1,"provider":"claude","displayName":"Claude Code","sourceKind":"statusline_event","confidence":"high",
 "capturedAt":"$NOW","updatedAt":"$NOW","eventAt":"$NOW","sourcePath":"/Users/example/.claude/.credentials.json",
 "currentSession":{"label":"Current session","usedPct":12,"resetAt":"$(at +3H)","eventAt":"$NOW"},
 "week":{"label":"Claude weekly","usedPct":85,"resetAt":"$(at +3d)","eventAt":"$NOW"}}
EOF
cat > "$STATE/codex-usage.json" <<EOF
{"schemaVersion":1,"provider":"codex","displayName":"Codex","sourceKind":"official_app_server","confidence":"official",
 "capturedAt":"$NOW","updatedAt":"$NOW","eventAt":"$NOW",
 "week":{"label":"Codex weekly","usedPct":20,"resetAt":"$(at +4d)","eventAt":"$NOW"}}
EOF
cat > "$STATE/provider-preferences.json" <<EOF
{"found":[],"missing":[],"connected":["claude","codex"],"shown":["claude","codex"]}
EOF
export CODEX_USAGE_HUD_STATE_DIR="$STATE"

with_timeout 10 "$BIN" --version > "$WORK/version.txt" 2>&1
grep -q '^Usage HUD ' "$WORK/version.txt" || { echo "FAIL: --version did not answer:"; cat "$WORK/version.txt"; exit 1; }

META='"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"io.modelcontextprotocol/clientInfo":{"name":"session-test","version":"1"}}'
cat > "$WORK/in.jsonl" <<EOF
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"session-test","version":"1"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"usage_status","arguments":{}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"which_plan_has_room","arguments":{}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"lane_detail","arguments":{"provider":"claude"}}}
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"lane_detail","arguments":{"provider":"nope"}}}
{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"nope","arguments":{}}}
{"jsonrpc":"2.0","id":8,"method":"ping"}
{"jsonrpc":"2.0","id":9,"method":"resources/list"}
{"jsonrpc":"2.0","id":10,"method":"server/discover","params":{$META}}
{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"which_plan_has_room","arguments":{},$META}}
this is not json
EOF

with_timeout 20 sh -c 'exec "$0" mcp < "$1" > "$2" 2> "$3"' "$BIN" "$WORK/in.jsonl" "$WORK/out.jsonl" "$WORK/err.txt"
rc=$?

check() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; fail=1; fi
}
reply() {  # reply <id> → file with that response line
  grep -F "\"id\":$1,\"jsonrpc\"" "$WORK/out.jsonl" | head -1 > "$WORK/r$1.json"
  echo "$WORK/r$1.json"
}
get() { plutil -extract "$2" raw -o - "$1" 2>/dev/null; }

check "server exits 0 at EOF" "$rc" "0"
check "one reply per request, none for the notification" "$(wc -l < "$WORK/out.jsonl" | tr -d ' ')" "12"
check "no carriage returns on stdout" "$(grep -c "$(printf '\r')" "$WORK/out.jsonl")" "0"

r=$(reply 1)
check "initialize echoes 2025-11-25" "$(get "$r" result.protocolVersion)" "2025-11-25"
check "serverInfo.name" "$(get "$r" result.serverInfo.name)" "usage-hud"
r=$(reply 2)
check "tools/list tool 0" "$(get "$r" result.tools.0.name)" "usage_status"
check "tools/list tool 1" "$(get "$r" result.tools.1.name)" "which_plan_has_room"
check "tools/list tool 2" "$(get "$r" result.tools.2.name)" "lane_detail"
check "tools are read-only" "$(get "$r" result.tools.0.annotations.readOnlyHint)" "true"
r=$(reply 3)
check "usage_status isError" "$(get "$r" result.isError)" "false"
check "usage_status schemaVersion" "$(get "$r" result.structuredContent.schemaVersion)" "1"
check "usage_status verdict" "$(get "$r" result.structuredContent.verdict.mode)" "WATCH"
check "usage_status lane 0" "$(get "$r" result.structuredContent.lanes.0.provider)" "claude"
check "usage_status Claude pace" "$(get "$r" result.structuredContent.lanes.0.pace)" "running_hot"
get "$r" result.content.1.text > "$WORK/r3text.json"
check "text block carries the same JSON" "$(get "$WORK/r3text.json" verdict.mode)" "WATCH"
if grep -q 'credentials' "$WORK/out.jsonl"; then echo "FAIL a snapshot path leaked into a reply"; fail=1; else echo "ok   no snapshot paths in replies"; fi
r=$(reply 4)
check "room: lane" "$(get "$r" result.structuredContent.roomNow.lane)" "codex"
check "room: sentence" "$(get "$r" result.structuredContent.verdict.sentence)" "Claude: running hot. Codex has room, 20% used."
r=$(reply 5)
check "lane_detail provider" "$(get "$r" result.structuredContent.lane.provider)" "claude"
check "lane_detail 5h window" "$(get "$r" result.structuredContent.lane.windows.0.window)" "5h"
r=$(reply 6)
check "lane_detail unknown provider is a tool error" "$(get "$r" result.isError)" "true"
r=$(reply 7)
check "unknown tool" "$(get "$r" error.code)" "-32602"
r=$(reply 8)
check "ping" "$(plutil -extract result json -o - "$r" 2>/dev/null)" "{}"
r=$(reply 9)
check "unknown method" "$(get "$r" error.code)" "-32601"
r=$(reply 10)
check "server/discover resultType" "$(get "$r" result.resultType)" "complete"
check "server/discover newest version" "$(get "$r" result.supportedVersions.0)" "2026-07-28"
check "server/discover cacheScope" "$(get "$r" result.cacheScope)" "public"
r=$(reply 11)
check "modern call resultType" "$(get "$r" result.resultType)" "complete"
check "modern call room" "$(get "$r" result.structuredContent.roomNow.lane)" "codex"
grep '"code":-32700' "$WORK/out.jsonl" | grep -q '"id":null' && echo "ok   parse error answers with id null" || { echo "FAIL parse error reply"; fail=1; }

# bin/usage-hud: placed inside a bundle whose path has a space, reached through a symlink.
BUNDLE="$WORK/My Apps/Usage HUD.app/Contents"
mkdir -p "$BUNDLE/MacOS" "$BUNDLE/Resources/bin" "$WORK/links"
cp "$BIN" "$BUNDLE/MacOS/CodexUsageHUD"
cp "$ROOT/bin/usage-hud" "$BUNDLE/Resources/bin/usage-hud"
ln -s "$BUNDLE/Resources/bin/usage-hud" "$WORK/links/usage-hud"
with_timeout 10 env -u USAGE_HUD_BIN "$WORK/links/usage-hud" room > "$WORK/wrapper.txt" 2>&1
wrc=$?
check "wrapper finds the bundle binary through a symlink" "$(cut -c1-34 "$WORK/wrapper.txt")" "Codex has the most room now: 20% o"
check "wrapper passes the exit code through" "$wrc" "0"
# Only when no Usage HUD app is installed system-wide: otherwise the wrapper
# would rightly exec the installed app, which may predate the CLI.
if [ ! -d "/Applications/Usage HUD.app" ] && [ ! -d "/Applications/CodexUsageHUD.app" ]; then
  with_timeout 10 env USAGE_HUD_BIN="$WORK/missing" HOME="$WORK/nohome" "$ROOT/bin/usage-hud" status > /dev/null 2>&1
  check "wrapper exits 127 without an app" "$?" "127"
fi

if [ $fail -eq 0 ]; then echo "PASS: MCP session"; else echo "FAILED: MCP session"; echo "--- stdout"; cat "$WORK/out.jsonl"; echo "--- stderr"; cat "$WORK/err.txt"; fi
exit $fail
