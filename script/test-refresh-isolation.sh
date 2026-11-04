#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

HOME_DIR="$TMP_DIR/home"
STATE_DIR="$TMP_DIR/state"
CALL_LOG="$TMP_DIR/calls.log"
FAKE_NODE="$TMP_DIR/fake-node"
mkdir -p "$HOME_DIR/.local/bin" "$STATE_DIR"
touch "$CALL_LOG"

printf '%s\n' \
  '#!/bin/bash' \
  'printf "%s\n" "$*" >> "$CALL_LOG"' \
  'if [ "${BLOOM_TEST_FAIL_GROK:-0}" = "1" ] && [ "$(basename "$1")" = "bloom-usage-write-grok" ]; then exit 1; fi' \
  'exit 0' > "$FAKE_NODE"
chmod +x "$FAKE_NODE"
export CALL_LOG

run_refresh() {
  env \
    HOME="$HOME_DIR" \
    CODEX_USAGE_HUD_STATE_DIR="$STATE_DIR" \
    BLOOM_USAGE_NODE_BIN="$FAKE_NODE" \
    "$@" \
    bash "$ROOT_DIR/bin/bloom-budget-update"
}

wait_for_call() {
  local pattern="$1"
  for _ in $(seq 1 40); do
    grep -Eq "$pattern" "$CALL_LOG" && return 0
    sleep 0.05
  done
  return 1
}

# The default refresh runs exactly the meter writers and the notifier. The
# Claude lane is owned by its own launchd job and stays out unless opted in.
run_refresh
wait_for_call 'bloom-budget-notify'
grep -Eq 'bloom-usage-write-codex' "$CALL_LOG"
grep -Eq 'bloom-usage-write-gemini-agy' "$CALL_LOG"
grep -Eq 'bloom-usage-write-grok' "$CALL_LOG"
if grep -Eq 'bloom-usage-write-claude' "$CALL_LOG"; then
  echo 'default HUD refresh ran the Claude writer without opt-in' >&2
  exit 1
fi
# Only product helpers may be invoked from the refresh path.
if grep -Ev 'bloom-usage-write-codex|bloom-usage-write-gemini-agy|bloom-usage-write-grok|bloom-budget-notify' "$CALL_LOG" | grep -q .; then
  echo 'HUD refresh invoked an unexpected helper:' >&2
  grep -Ev 'bloom-usage-write-codex|bloom-usage-write-gemini-agy|bloom-usage-write-grok|bloom-budget-notify' "$CALL_LOG" >&2
  exit 1
fi

# A second refresh while one is already running must not duplicate work; a
# foreground request learns about the skip through exit 75.
: > "$CALL_LOG"
mkdir -p "$STATE_DIR/bloom-budget-update.lock"
echo "$$" > "$STATE_DIR/bloom-budget-update.lock/pid"
if run_refresh CODEX_USAGE_HUD_MANUAL_REFRESH=1; then
  echo 'manual refresh did not report the skipped duplicate' >&2
  exit 1
else
  rc=$?
  [ "$rc" -eq 75 ] || { echo "expected exit 75 for a busy lock, got $rc" >&2; exit 1; }
fi
rm -rf "$STATE_DIR/bloom-budget-update.lock"
if grep -q . "$CALL_LOG"; then
  echo 'a locked refresh still ran writers' >&2
  exit 1
fi

# A crashed refresh must not leave the next refresh permanently locked out.
# Reap a real child so the dead-pid fixture does not assume an unused pid.
(exit 0) &
dead_pid=$!
wait "$dead_pid"
if kill -0 "$dead_pid" 2>/dev/null; then
  echo 'stale-lock fixture pid is still alive' >&2
  exit 1
fi
for stale_pid in "$dead_pid" ''; do
  : > "$CALL_LOG"
  mkdir "$STATE_DIR/bloom-budget-update.lock"
  printf '%s' "$stale_pid" > "$STATE_DIR/bloom-budget-update.lock/pid"
  run_refresh > "$TMP_DIR/stale.stdout" 2> "$TMP_DIR/stale.stderr"
  wait_for_call 'bloom-budget-notify'
  for writer in codex gemini-agy grok; do
    [ "$(grep -c "bloom-usage-write-$writer$" "$CALL_LOG")" -eq 1 ] || {
      echo "stale lock did not run $writer exactly once (pid='$stale_pid')" >&2
      exit 1
    }
  done
  [ ! -d "$STATE_DIR/bloom-budget-update.lock" ] || {
    echo 'reclaimed lock was not cleaned up' >&2
    exit 1
  }
done

# One failed provider must leave the other writers running and report failure
# honestly, rather than printing a completion message for a partial refresh.
: > "$CALL_LOG"
if run_refresh BLOOM_TEST_FAIL_GROK=1 > "$TMP_DIR/failure.stdout" 2> "$TMP_DIR/failure.stderr"; then
  echo 'refresh reported success after the Grok writer failed' >&2
  exit 1
else
  rc=$?
  [ "$rc" -eq 1 ] || { echo "expected exit 1 for a failed writer, got $rc" >&2; exit 1; }
fi
wait_for_call 'bloom-budget-notify'
grep -q 'grok-writer' "$TMP_DIR/failure.stderr"
if grep -q 'usage refresh complete' "$TMP_DIR/failure.stdout" "$TMP_DIR/failure.stderr"; then
  echo 'failed refresh printed a completion message' >&2
  exit 1
fi
for writer in codex gemini-agy grok; do
  [ "$(grep -c "bloom-usage-write-$writer$" "$CALL_LOG")" -eq 1 ] || {
    echo "partial refresh did not run $writer exactly once" >&2
    exit 1
  }
done

echo 'refresh isolation: pass'
