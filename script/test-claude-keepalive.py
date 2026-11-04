#!/usr/bin/env python3
"""Hermetic regressions for bin/bloom-usage-write-claude (package C: keepalive).

Covers the three behaviors the keepalive writer owns:
  1. Stale-official refetch: spawn bloom-usage-fetch-claude-official --mode api
     when the official reading is old, debounced by a cooldown file and an
     attempt stamp.
  2. Honest health: a failed official status does not override a live tap
     event newer than 15 minutes.
  3. Lost-update guard: a concurrent rewrite of claude-usage.json between this
     writer's read and its atomic rename is detected and recovered with one
     retry instead of silently clobbered.

No network, no Keychain, no launchd. Every test uses a temp HOME and state
dir and a stub in place of the real fetch binary.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parent.parent
WRITER = ROOT / "bin/bloom-usage-write-claude"
NODE = shutil.which("node")
if not NODE:
    raise SystemExit("node is required")


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def clean_env(home: Path, state: Path, extra: dict[str, str] | None = None) -> dict[str, str]:
    env = {
        "HOME": str(home),
        "CODEX_USAGE_HUD_STATE_DIR": str(state),
        "BLOOM_USAGE_DIR": str(state),
        "PATH": f"{Path(NODE).parent}:/usr/bin:/bin",
    }
    if extra:
        env.update(extra)
    return env


def run_node(args: list[str], env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [NODE, str(WRITER), *args],
        text=True,
        capture_output=True,
        timeout=30,
        env=env,
        check=False,
    )


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n")


def read_json(path: Path) -> dict:
    return json.loads(path.read_text())


def wait_for_file(path: Path, timeout: float = 2.0) -> bool:
    # The refetch spawn is detached and unref'd on purpose (the writer must not
    # block waiting on it), so the stub's log write can land a beat after the
    # writer process has already exited. Poll briefly instead of asserting
    # immediately.
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            return True
        time.sleep(0.02)
    return path.exists()


def write_executable(path: Path, body: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body)
    path.chmod(0o755)


def make_stub_fetch(path: Path, log_path: Path) -> None:
    # Records its own argv, one per line, so a test can assert exactly which
    # flags the writer spawned it with. FETCH_STUB_LOG is a test-only
    # convention, not part of the writer's contract.
    write_executable(
        path,
        f"""#!/bin/sh
printf '%s\\n' "$@" >> "{log_path}"
exit 0
""",
    )


def base_snapshot(week_fable_captured_at: str | None, official_usage: dict | None = None) -> dict:
    future = iso(now_utc() + timedelta(hours=2))
    snapshot: dict = {
        "schemaVersion": 1,
        "provider": "claude",
        "displayName": "Claude Code",
        "currentSession": {
            "label": "Current session",
            "usedPct": 32,
            "resetAt": future,
            "resetLabel": "2:20 AM",
        },
        "week": {
            "label": "Current week (all models)",
            "usedPct": 7,
            "resetAt": future,
            "resetLabel": "Sep 9 4 PM",
        },
        "contributors": [],
        "skills": [],
    }
    if week_fable_captured_at is not None:
        snapshot["weekFable"] = {
            "label": "Fable weekly",
            "usedPct": 8,
            "resetAt": future,
            "resetLabel": "Sep 9 4 PM",
            "capturedAt": week_fable_captured_at,
        }
    if official_usage is not None:
        snapshot["officialUsage"] = official_usage
    return snapshot


def stamp_path(state: Path) -> Path:
    return state / ".claude-official-last-attempt"


def cooldown_path(state: Path) -> Path:
    return state / ".claude-official-rate-limited-until"


def test_stale_official_reading_spawns_once_and_debounces() -> None:
    with tempfile.TemporaryDirectory(prefix="usage-claude-keepalive-stale-") as raw:
        root = Path(raw)
        home = root / "home"
        state = root / "state"
        usage = state / "claude-usage.json"
        stub_log = root / "fetch-args.log"
        stub = root / "bloom-usage-fetch-claude-official-stub"
        make_stub_fetch(stub, stub_log)

        write_json(usage, base_snapshot(iso(now_utc() - timedelta(minutes=11))))
        env = clean_env(
            home,
            state,
            {
                "BLOOM_USAGE_OUT": str(usage),
                "BLOOM_CLAUDE_OFFICIAL_FETCH_BIN": str(stub),
            },
        )

        first = run_node([], env)
        assert first.returncode == 0, first.stderr or first.stdout
        assert wait_for_file(stub_log), "expected the stub fetch to have been spawned"
        assert stub_log.read_text().splitlines() == ["--mode", "api"]
        assert stamp_path(state).exists(), "expected the attempt stamp to be written"

        # A second run inside the 120s debounce window must not spawn again.
        second = run_node([], env)
        assert second.returncode == 0, second.stderr or second.stdout
        time.sleep(0.2)  # let any wrongly-spawned second attempt land before checking
        assert stub_log.read_text().splitlines() == ["--mode", "api"], "spawned a second time within the debounce window"


def test_fresh_official_reading_does_not_spawn() -> None:
    with tempfile.TemporaryDirectory(prefix="usage-claude-keepalive-fresh-") as raw:
        root = Path(raw)
        home = root / "home"
        state = root / "state"
        usage = state / "claude-usage.json"
        stub_log = root / "fetch-args.log"
        stub = root / "bloom-usage-fetch-claude-official-stub"
        make_stub_fetch(stub, stub_log)

        write_json(usage, base_snapshot(iso(now_utc() - timedelta(minutes=2))))
        env = clean_env(
            home,
            state,
            {
                "BLOOM_USAGE_OUT": str(usage),
                "BLOOM_CLAUDE_OFFICIAL_FETCH_BIN": str(stub),
            },
        )

        result = run_node([], env)
        assert result.returncode == 0, result.stderr or result.stdout
        time.sleep(0.2)  # let a wrongly-triggered spawn land before checking
        assert not stub_log.exists(), "a fresh official reading must not trigger a refetch"
        assert not stamp_path(state).exists()


def test_cooldown_in_future_prevents_spawn() -> None:
    with tempfile.TemporaryDirectory(prefix="usage-claude-keepalive-cooldown-") as raw:
        root = Path(raw)
        home = root / "home"
        state = root / "state"
        usage = state / "claude-usage.json"
        stub_log = root / "fetch-args.log"
        stub = root / "bloom-usage-fetch-claude-official-stub"
        make_stub_fetch(stub, stub_log)

        write_json(usage, base_snapshot(iso(now_utc() - timedelta(minutes=11))))
        state.mkdir(parents=True, exist_ok=True)
        cooldown_path(state).write_text(str(int(time.time()) + 1800))
        env = clean_env(
            home,
            state,
            {
                "BLOOM_USAGE_OUT": str(usage),
                "BLOOM_CLAUDE_OFFICIAL_FETCH_BIN": str(stub),
            },
        )

        result = run_node([], env)
        assert result.returncode == 0, result.stderr or result.stdout
        time.sleep(0.2)  # let a wrongly-triggered spawn land before checking
        assert not stub_log.exists(), "an active cooldown must prevent the refetch spawn"
        assert not stamp_path(state).exists()


def test_official_usage_capturedat_outranks_weekfable() -> None:
    # officialUsage.capturedAt is the primary signal; a stale weekFable next to
    # a fresh officialUsage must not trigger a refetch.
    with tempfile.TemporaryDirectory(prefix="usage-claude-keepalive-priority-") as raw:
        root = Path(raw)
        home = root / "home"
        state = root / "state"
        usage = state / "claude-usage.json"
        stub_log = root / "fetch-args.log"
        stub = root / "bloom-usage-fetch-claude-official-stub"
        make_stub_fetch(stub, stub_log)

        snapshot = base_snapshot(
            week_fable_captured_at=iso(now_utc() - timedelta(hours=3)),
            official_usage={"capturedAt": iso(now_utc() - timedelta(minutes=1))},
        )
        write_json(usage, snapshot)
        env = clean_env(
            home,
            state,
            {
                "BLOOM_USAGE_OUT": str(usage),
                "BLOOM_CLAUDE_OFFICIAL_FETCH_BIN": str(stub),
            },
        )

        result = run_node([], env)
        assert result.returncode == 0, result.stderr or result.stdout
        time.sleep(0.2)  # let a wrongly-triggered spawn land before checking
        assert not stub_log.exists(), "a fresh officialUsage.capturedAt must outrank a stale weekFable.capturedAt"


def test_stale_official_refetch_survives_active_tap_grace() -> None:
    # An active session has the tap writing every few seconds, so
    # shouldSkipDueToTapGrace fires on almost every keepalive tick. The stale
    # -official refetch decision must not live behind that early return, or an
    # active session would suppress the 10-minute Fable refetch indefinitely.
    with tempfile.TemporaryDirectory(prefix="usage-claude-keepalive-tapgrace-refetch-") as raw:
        root = Path(raw)
        home = root / "home"
        state = root / "state"
        usage = state / "claude-usage.json"
        stub_log = root / "fetch-args.log"
        stub = root / "bloom-usage-fetch-claude-official-stub"
        make_stub_fetch(stub, stub_log)

        snapshot = base_snapshot(week_fable_captured_at=None, official_usage={"capturedAt": iso(now_utc() - timedelta(minutes=20))})
        snapshot["source"] = "claude-code-statusline-tap + token tracker"
        snapshot["updatedAt"] = iso(now_utc() - timedelta(seconds=20))
        write_json(usage, snapshot)
        before_bytes = usage.read_bytes()

        env = clean_env(
            home,
            state,
            {
                "BLOOM_USAGE_OUT": str(usage),
                "BLOOM_CLAUDE_OFFICIAL_FETCH_BIN": str(stub),
            },
        )

        result = run_node([], env)
        assert result.returncode == 0, result.stderr or result.stdout
        assert wait_for_file(stub_log), "expected the stub fetch to have been spawned despite tap grace"
        assert stub_log.read_text().splitlines() == ["--mode", "api"]
        assert stamp_path(state).exists(), "expected the attempt stamp to be written"
        assert usage.read_bytes() == before_bytes, (
            "tap grace must still leave a tap-fresh snapshot byte-for-byte untouched"
        )


def test_health_honors_recent_tap_event_over_failed_official_status() -> None:
    # "offline" is a transient failure (network hiccup, DNS blip), not a
    # durable one, so the fresh-tap bypass still applies to it.
    with tempfile.TemporaryDirectory(prefix="usage-claude-keepalive-health-fresh-") as raw:
        root = Path(raw)
        home = root / "home"
        state = root / "state"
        usage = state / "claude-usage.json"
        status = state / "claude-official-status.json"

        snapshot = base_snapshot(week_fable_captured_at=None, official_usage={"capturedAt": iso(now_utc())})
        snapshot["eventAt"] = iso(now_utc() - timedelta(minutes=1))
        snapshot["providerHealth"] = {"status": "stale warning from a previous run"}
        write_json(usage, snapshot)
        write_json(
            status,
            {
                "schemaVersion": 1,
                "status": "offline",
                "message": "could not reach the usage endpoint",
                "updatedAt": iso(now_utc()),
            },
        )
        env = clean_env(
            home,
            state,
            {"BLOOM_USAGE_OUT": str(usage), "BLOOM_CLAUDE_USAGE_STATUS": str(status)},
        )

        result = run_node([], env)
        assert result.returncode == 0, result.stderr or result.stdout
        written = read_json(usage)
        assert written["health"]["verdict"] == "fresh"
        assert "providerHealth" not in written
        assert written["officialUsageStatus"]["status"] == "offline"


def test_health_stays_degraded_for_durable_status_despite_fresh_tap() -> None:
    # unauthorized and no_credential are durable failures that need a human
    # (re-open Claude Code / re-auth). A fresh tap event must not paper over
    # that with a "fresh" verdict the way it does for transient failures.
    for durable_status in ("unauthorized", "no_credential"):
        with tempfile.TemporaryDirectory(prefix="usage-claude-keepalive-health-durable-") as raw:
            root = Path(raw)
            home = root / "home"
            state = root / "state"
            usage = state / "claude-usage.json"
            status = state / "claude-official-status.json"

            snapshot = base_snapshot(week_fable_captured_at=None, official_usage={"capturedAt": iso(now_utc())})
            snapshot["eventAt"] = iso(now_utc() - timedelta(minutes=1))
            write_json(usage, snapshot)
            write_json(
                status,
                {
                    "schemaVersion": 1,
                    "status": durable_status,
                    "message": "open Claude Code once to refresh the token",
                    "updatedAt": iso(now_utc()),
                },
            )
            env = clean_env(
                home,
                state,
                {"BLOOM_USAGE_OUT": str(usage), "BLOOM_CLAUDE_USAGE_STATUS": str(status)},
            )

            result = run_node([], env)
            assert result.returncode == 0, result.stderr or result.stdout
            written = read_json(usage)
            assert written["health"]["verdict"] == "degraded", durable_status
            assert written["providerHealth"]["status"] == durable_status
            assert written["health"]["reason"] == "open Claude Code once to refresh the token", durable_status


def test_health_degrades_when_tap_event_is_old() -> None:
    with tempfile.TemporaryDirectory(prefix="usage-claude-keepalive-health-stale-") as raw:
        root = Path(raw)
        home = root / "home"
        state = root / "state"
        usage = state / "claude-usage.json"
        status = state / "claude-official-status.json"

        snapshot = base_snapshot(week_fable_captured_at=None, official_usage={"capturedAt": iso(now_utc())})
        snapshot["eventAt"] = iso(now_utc() - timedelta(hours=2))
        write_json(usage, snapshot)
        write_json(
            status,
            {
                "schemaVersion": 1,
                "status": "unauthorized",
                "message": "open Claude Code once to refresh the token",
                "updatedAt": iso(now_utc()),
            },
        )
        env = clean_env(
            home,
            state,
            {"BLOOM_USAGE_OUT": str(usage), "BLOOM_CLAUDE_USAGE_STATUS": str(status)},
        )

        result = run_node([], env)
        assert result.returncode == 0, result.stderr or result.stdout
        written = read_json(usage)
        assert written["health"]["verdict"] == "degraded"
        assert written["providerHealth"]["status"] == "unauthorized"


def test_tap_grace_matches_tap_plus_suffix_source() -> None:
    # The tap persists source "claude-code-statusline-tap + token tracker",
    # not the bare TAP_SOURCE constant. shouldSkipDueToTapGrace must match on
    # the prefix, or the guard never fires and every 60s tick re-labels a
    # snapshot the tap only just wrote.
    with tempfile.TemporaryDirectory(prefix="usage-claude-keepalive-tapgrace-") as raw:
        root = Path(raw)
        home = root / "home"
        state = root / "state"
        usage = state / "claude-usage.json"

        snapshot = base_snapshot(week_fable_captured_at=None, official_usage={"capturedAt": iso(now_utc())})
        snapshot["source"] = "claude-code-statusline-tap + token tracker"
        snapshot["updatedAt"] = iso(now_utc() - timedelta(seconds=30))
        write_json(usage, snapshot)
        before_bytes = usage.read_bytes()

        env = clean_env(home, state, {"BLOOM_USAGE_OUT": str(usage)})
        result = run_node([], env)
        assert result.returncode == 0, result.stderr or result.stdout
        assert usage.read_bytes() == before_bytes, (
            "a tap-sourced snapshot 30s old must be left byte-for-byte untouched"
        )


def test_tap_grace_expires_after_five_minutes() -> None:
    with tempfile.TemporaryDirectory(prefix="usage-claude-keepalive-tapgrace-expired-") as raw:
        root = Path(raw)
        home = root / "home"
        state = root / "state"
        usage = state / "claude-usage.json"

        snapshot = base_snapshot(week_fable_captured_at=None, official_usage={"capturedAt": iso(now_utc())})
        snapshot["source"] = "claude-code-statusline-tap + token tracker"
        snapshot["updatedAt"] = iso(now_utc() - timedelta(minutes=5))
        write_json(usage, snapshot)

        env = clean_env(home, state, {"BLOOM_USAGE_OUT": str(usage)})
        result = run_node([], env)
        assert result.returncode == 0, result.stderr or result.stdout
        written = read_json(usage)
        assert written["source"] == "claude usage keepalive writer", (
            "a tap-sourced snapshot 5 minutes old must be re-stamped by the keepalive"
        )


def test_attempt_stamp_content_is_unix_epoch_seconds() -> None:
    # The stamp file is shared by the statusline tap, this writer, and
    # bin/bloom-usage-capture.sh (which writes `date +%s`). Every reader
    # throttles on the file's mtime, but the content itself must match the
    # other two writers' format so nothing downstream misparses it.
    with tempfile.TemporaryDirectory(prefix="usage-claude-keepalive-stamp-") as raw:
        root = Path(raw)
        home = root / "home"
        state = root / "state"
        usage = state / "claude-usage.json"
        stub_log = root / "fetch-args.log"
        stub = root / "bloom-usage-fetch-claude-official-stub"
        make_stub_fetch(stub, stub_log)

        write_json(usage, base_snapshot(iso(now_utc() - timedelta(minutes=11))))
        env = clean_env(
            home,
            state,
            {
                "BLOOM_USAGE_OUT": str(usage),
                "BLOOM_CLAUDE_OFFICIAL_FETCH_BIN": str(stub),
            },
        )

        before = time.time()
        result = run_node([], env)
        after = time.time()
        assert result.returncode == 0, result.stderr or result.stdout
        assert wait_for_file(stub_log), "expected the stub fetch to have been spawned"
        content = stamp_path(state).read_text().strip()
        assert content.isdigit(), f"expected unix epoch seconds, got {content!r}"
        stamp_value = int(content)
        assert int(before) - 1 <= stamp_value <= int(after) + 1, (
            "attempt stamp content should be roughly now(), in epoch seconds"
        )


def test_expired_window_pushes_sentence_and_bare_key() -> None:
    # FableDisplay.shouldShow checks snapshot.rateLimitExpired for the exact
    # string "weekFable"; the detail card wants the human sentence too. Both
    # must land, de-duplicated, when a window's reset has passed.
    with tempfile.TemporaryDirectory(prefix="usage-claude-keepalive-expired-") as raw:
        root = Path(raw)
        home = root / "home"
        state = root / "state"
        usage = state / "claude-usage.json"

        past = iso(now_utc() - timedelta(minutes=5))
        snapshot = base_snapshot(week_fable_captured_at=None, official_usage={"capturedAt": iso(now_utc())})
        snapshot["weekFable"] = {
            "label": "Fable weekly",
            "usedPct": 98,
            "resetAt": past,
            "resetLabel": past,
        }
        write_json(usage, snapshot)

        env = clean_env(home, state, {"BLOOM_USAGE_OUT": str(usage)})
        result = run_node([], env)
        assert result.returncode == 0, result.stderr or result.stdout
        written = read_json(usage)
        expired = written.get("rateLimitExpired", [])
        assert "weekFable" in expired, "expected the bare key for the app's exact-string check"
        assert any(item.startswith("Fable weekly reset") for item in expired), (
            "expected the human-readable sentence alongside the bare key"
        )
        assert "weekFable" not in written, "an expired window must still be deleted from the snapshot"
        assert len(expired) == len(set(expired)), "rateLimitExpired must be de-duplicated"


def test_lost_update_guard_recovers_concurrent_rewrite() -> None:
    with tempfile.TemporaryDirectory(prefix="usage-claude-keepalive-race-") as raw:
        root = Path(raw)
        home = root / "home"
        state = root / "state"
        usage = state / "claude-usage.json"

        snapshot = base_snapshot(week_fable_captured_at=None, official_usage={"capturedAt": iso(now_utc())})
        write_json(usage, snapshot)
        env = clean_env(
            home,
            state,
            {
                "BLOOM_USAGE_OUT": str(usage),
                "BLOOM_KEEPALIVE_TEST_DELAY_MS": "1000",
            },
        )

        proc = subprocess.Popen(
            [NODE, str(WRITER)],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            # Give the writer time to complete its initial read (trivial sync
            # I/O; this happens in well under 100ms) before it enters the
            # 1000ms test delay, then rewrite the file underneath it.
            time.sleep(0.25)
            rewritten = base_snapshot(week_fable_captured_at=None, official_usage={"capturedAt": iso(now_utc())})
            rewritten["currentSession"]["usedPct"] = 91
            rewritten["raceMarker"] = "rewritten-during-delay"
            write_json(usage, rewritten)

            stdout, stderr = proc.communicate(timeout=5)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.communicate()

        assert proc.returncode == 0, stderr or stdout
        written = read_json(usage)
        assert written.get("raceMarker") == "rewritten-during-delay", (
            "lost-update guard did not pick up the concurrent rewrite"
        )
        assert written["currentSession"]["usedPct"] == 91
        assert written["source"] == "claude usage keepalive writer"


def test_missing_snapshot_spawns_official_fetch() -> None:
    # Zip-only buyers have no statusline tap and no prior claude-usage.json.
    # The keepalive must still spawn the official fetch so the launchd writer
    # can fill the lane without editing ~/.claude/settings.json.
    with tempfile.TemporaryDirectory(prefix="usage-claude-keepalive-empty-") as raw:
        root = Path(raw)
        home = root / "home"
        state = root / "state"
        state.mkdir(parents=True)
        stub_log = root / "fetch-args.log"
        stub = root / "bloom-usage-fetch-claude-official-stub"
        make_stub_fetch(stub, stub_log)

        env = clean_env(
            home,
            state,
            {
                "BLOOM_USAGE_OUT": str(state / "claude-usage.json"),
                "BLOOM_CLAUDE_OFFICIAL_FETCH_BIN": str(stub),
            },
        )
        result = run_node([], env)
        assert result.returncode == 0, result.stderr or result.stdout
        assert wait_for_file(stub_log), "expected the stub fetch to have been spawned with no snapshot"
        assert stub_log.read_text().splitlines() == ["--mode", "api"]
        assert stamp_path(state).exists()
        assert not (state / "claude-usage.json").exists(), "keepalive must not invent a snapshot; the fetch writes it"


TESTS = [
    test_missing_snapshot_spawns_official_fetch,
    test_stale_official_reading_spawns_once_and_debounces,
    test_fresh_official_reading_does_not_spawn,
    test_cooldown_in_future_prevents_spawn,
    test_official_usage_capturedat_outranks_weekfable,
    test_stale_official_refetch_survives_active_tap_grace,
    test_health_honors_recent_tap_event_over_failed_official_status,
    test_health_stays_degraded_for_durable_status_despite_fresh_tap,
    test_health_degrades_when_tap_event_is_old,
    test_tap_grace_matches_tap_plus_suffix_source,
    test_tap_grace_expires_after_five_minutes,
    test_attempt_stamp_content_is_unix_epoch_seconds,
    test_expired_window_pushes_sentence_and_bare_key,
    test_lost_update_guard_recovers_concurrent_rewrite,
]


def main() -> int:
    failures = 0
    for test in TESTS:
        try:
            test()
            print(f"ok  - {test.__name__}")
        except Exception as error:  # noqa: BLE001 - compact standalone harness
            failures += 1
            print(f"FAIL - {test.__name__}: {error}")
    print(f"{len(TESTS) - failures} passed, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
