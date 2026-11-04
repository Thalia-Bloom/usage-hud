#!/bin/bash
# Stop hook: capture Claude Code rate_limit percentages via /usage scraper.
# Throttled to run at most once per 5 minutes. Non-blocking (background).
# Reads hook stdin (session_id JSON) but doesn't use it, only the trigger.

set -euo pipefail

STATE_DIR="${CODEX_USAGE_HUD_STATE_DIR:-${BLOOM_USAGE_DIR:-${HOME}/.codex-usage-hud}}"
THROTTLE_FILE="${STATE_DIR}/.usage-capture-last"
COOLDOWN_FILE="${STATE_DIR}/.claude-official-rate-limited-until"
LAST_ATTEMPT_FILE="${STATE_DIR}/.claude-official-last-attempt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${BLOOM_CLAUDE_OFFICIAL_FETCH_BIN:-}" ] && [ -x "$BLOOM_CLAUDE_OFFICIAL_FETCH_BIN" ]; then
  SCRAPER="$BLOOM_CLAUDE_OFFICIAL_FETCH_BIN"
elif [ -n "${BLOOM_USAGE_BIN_DIR:-}" ] && [ -x "$BLOOM_USAGE_BIN_DIR/bloom-usage-fetch-claude-official" ]; then
  SCRAPER="$BLOOM_USAGE_BIN_DIR/bloom-usage-fetch-claude-official"
elif [ -x "$SCRIPT_DIR/bloom-usage-fetch-claude-official" ]; then
  SCRAPER="$SCRIPT_DIR/bloom-usage-fetch-claude-official"
else
  SCRAPER="${HOME}/.local/bin/bloom-usage-fetch-claude-official"
fi
MIN_INTERVAL=300  # seconds between scrapes
SCRAPER_TIMEOUT=20  # seconds; the Stop hook must not stall the CLI on a slow fetch

run_scraper_with_timeout() {
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$SCRAPER_TIMEOUT" "$SCRAPER" --mode api 2>/dev/null || true
  else
    /usr/bin/perl -e '
      use strict;
      use warnings;
      use POSIX ":sys_wait_h";
      my ($timeout, @cmd) = @ARGV;
      my $pid = fork();
      exit 127 unless defined $pid;
      if ($pid == 0) {
        POSIX::setsid() or setpgrp(0, 0);
        exec @cmd;
        exit 127;
      }
      my $deadline = time + $timeout;
      while (1) {
        my $done = waitpid($pid, WNOHANG);
        exit 0 if $done == $pid;
        if (time >= $deadline) {
          kill "TERM", -$pid;
          my $term_deadline = time + 2;
          my $reaped = 0;
          while (time < $term_deadline) {
            $done = waitpid($pid, WNOHANG);
            $reaped = 1 if $done == $pid;
            select undef, undef, undef, 0.1;
          }
          kill "KILL", -$pid;
          waitpid($pid, 0) unless $reaped;
          exit 124;
        }
        select undef, undef, undef, 0.1;
      }
    ' "$SCRAPER_TIMEOUT" "$SCRAPER" --mode api 2>/dev/null || true
  fi
}

# Consume stdin so the hook doesn't hang
cat > /dev/null

# Skip if scraper doesn't exist
[ -x "$SCRAPER" ] || exit 0

now=$(date +%s)
if [ -f "$COOLDOWN_FILE" ]; then
  cooldown_until=$(cat "$COOLDOWN_FILE" 2>/dev/null || true)
  case "$cooldown_until" in
    ""|*[!0-9]*) cooldown_until=0 ;;
  esac
  if [ "$cooldown_until" -gt "$now" ]; then
    exit 0
  fi
  rm -f "$COOLDOWN_FILE"
fi

# Throttle check
if [ -f "$THROTTLE_FILE" ]; then
  last=$(cat "$THROTTLE_FILE" 2>/dev/null || echo 0)
  case "$last" in
    ""|*[!0-9]*) last=0 ;;
  esac
  elapsed=$((now - last))
  if [ "$elapsed" -lt "$MIN_INTERVAL" ]; then
    exit 0
  fi
fi

# Write throttle timestamps BEFORE spawning to prevent races. The same
# .claude-official-last-attempt stamp the statusline tap and the keepalive
# writer read keeps all three callers from double-firing the fetch.
mkdir -p "$(dirname "$THROTTLE_FILE")"
date +%s > "$THROTTLE_FILE"
date +%s > "$LAST_ATTEMPT_FILE"

# Run scraper in background, detached, with a timeout safety net.
(
  run_scraper_with_timeout
) >/dev/null 2>&1 </dev/null &
disown

exit 0
