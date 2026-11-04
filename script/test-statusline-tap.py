#!/usr/bin/env python3
"""Hermetic regressions for the Claude Code statusline tap and Stop hook.

Runs bin/bloom-usage-statusline-tap and bin/bloom-usage-capture.sh directly
against fixture payloads and stub scripts. No network, no Keychain, no
launchd, and no writes outside a per-test temp HOME/state dir.
"""

from __future__ import annotations

import datetime
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parent.parent
TAP = ROOT / "bin/bloom-usage-statusline-tap"
CAPTURE_HOOK = ROOT / "bin/bloom-usage-capture.sh"
NODE = shutil.which("node")
BASH = shutil.which("bash") or "/bin/bash"
if not NODE:
    raise SystemExit("node is required")


def clean_env(home: Path, state: Path, extra: dict | None = None) -> dict:
    env = {
        "HOME": str(home),
        "CODEX_USAGE_HUD_STATE_DIR": str(state),
        "BLOOM_USAGE_DIR": str(state),
        "BLOOM_USAGE_BIN_DIR": str(home / ".local/bin"),
        "PATH": f"{Path(NODE).parent}:/usr/bin:/bin",
    }
    if extra:
        env.update(extra)
    return env


def run_tap(payload_text: str, env: dict, timeout: float = 10) -> subprocess.CompletedProcess:
    return subprocess.run(
        [NODE, str(TAP)],
        input=payload_text,
        text=True,
        capture_output=True,
        timeout=timeout,
        env=env,
        check=False,
    )


def run_capture_hook(env: dict, timeout: float = 10) -> subprocess.CompletedProcess:
    return subprocess.run(
        [BASH, str(CAPTURE_HOOK)],
        input="{}",
        text=True,
        capture_output=True,
        timeout=timeout,
        env=env,
        check=False,
    )


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n")


def write_executable(path: Path, body: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body)
    path.chmod(0o755)


def argv_recording_stub(path: Path, log: Path) -> None:
    write_executable(path, f'#!/bin/sh\necho "$@" >> "{log}"\n')


def env_recording_stub(path: Path, log: Path, var_name: str) -> None:
    write_executable(path, f'#!/bin/sh\necho "${var_name}" >> "{log}"\n')


def wait_for(predicate, timeout: float = 3.0, interval: float = 0.05) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return predicate()


def make_home_state(root: Path) -> tuple[Path, Path]:
    home = root / "home"
    state = root / "state"
    home.mkdir()
    state.mkdir()
    # Never fall through to real detached helpers that outlive fixture cleanup.
    # Tests of helper behavior replace these with their own recording stubs.
    for helper in ("bloom-budget-update", "bloom-usage-fetch-claude-official"):
        write_executable(home / ".local/bin" / helper, "#!/bin/sh\nexit 0\n")
    return home, state


def test_tap_writes_windows_with_event_at_and_key_only_health() -> None:
    with tempfile.TemporaryDirectory(prefix="tap-basic-") as raw:
        home, state = make_home_state(Path(raw))
        future = int(time.time()) + 7200
        payload = {
            "rate_limits": {
                "five_hour": {"used_percentage": 32.5, "resets_at": future},
                "seven_day": {"used_percentage": 7, "resets_at": future},
            },
            "some_other_field": "value-should-not-leak",
        }
        result = run_tap(json.dumps(payload), clean_env(home, state))
        # The real statusline (~/.claude/hooks/bloom-statusline.js) does not
        # exist under this temp HOME; the tap must still exit 0.
        assert result.returncode == 0, result.stderr or result.stdout

        usage = json.loads((state / "claude-usage.json").read_text())
        for key in ("currentSession", "week"):
            window = usage[key]
            assert isinstance(window["usedPct"], (int, float))
            assert window["resetAt"]
            assert window["eventAt"]

        health_text = (state / "claude-statusline-tap.json").read_text()
        health = json.loads(health_text)
        assert sorted(health["payloadKeys"]) == ["rate_limits", "some_other_field"]
        assert health["rateLimitWindowKeys"]["five_hour"] == ["resets_at", "used_percentage"]
        assert health["rateLimitWindowKeys"]["seven_day"] == ["resets_at", "used_percentage"]
        # Keys only, never values: the payload's string value must not leak
        # into the health breadcrumb even though its key name does.
        assert "value-should-not-leak" not in health_text


def test_tap_keeps_higher_usedpct_within_same_window() -> None:
    """A repaint from an idle Claude Code session must not regress week/
    currentSession when its resets_at still lands in the same minute as the
    reading already on disk (the observed 15% -> 14% regression bug)."""
    with tempfile.TemporaryDirectory(prefix="tap-monotonic-") as raw:
        home, state = make_home_state(Path(raw))
        future = int(time.time()) + 7200
        reset_iso = datetime.datetime.fromtimestamp(future, tz=datetime.timezone.utc).isoformat().replace("+00:00", "Z")
        write_json(state / "claude-usage.json", {
            "schemaVersion": 1,
            "provider": "claude",
            "week": {
                "label": "Current week (all models)",
                "usedPct": 15,
                "resetAt": reset_iso,
                "eventAt": "2026-09-26T14:41:00.000Z",
                "source": "official",
            },
            "currentSession": {
                "label": "Current session",
                "usedPct": 40,
                "resetAt": reset_iso,
                "eventAt": "2026-09-26T14:41:00.000Z",
                "source": "official",
            },
        })
        payload = {
            "rate_limits": {
                "five_hour": {"used_percentage": 41, "resets_at": future},
                "seven_day": {"used_percentage": 14, "resets_at": future},
            },
        }
        result = run_tap(json.dumps(payload), clean_env(home, state))
        assert result.returncode == 0, result.stderr or result.stdout

        usage = json.loads((state / "claude-usage.json").read_text())
        # week regressed (15 -> 14) within the same window: the higher
        # existing reading is kept, along with its own eventAt/source.
        assert usage["week"]["usedPct"] == 15
        assert usage["week"]["eventAt"] == "2026-09-26T14:41:00.000Z"
        assert usage["week"]["source"] == "official"
        # currentSession went up (40 -> 41): the fresh candidate is accepted.
        assert usage["currentSession"]["usedPct"] == 41
        assert usage["currentSession"]["source"] == "statusline"


def test_tap_accepts_new_window_on_different_reset() -> None:
    """A different (later) resetAt is a new window: the fresh candidate wins
    outright even though its usedPct is numerically lower than a stale
    reading from the window that just rolled over."""
    with tempfile.TemporaryDirectory(prefix="tap-monotonic-rollover-") as raw:
        home, state = make_home_state(Path(raw))
        old_reset = int(time.time()) - 60
        new_reset = int(time.time()) + 7200
        write_json(state / "claude-usage.json", {
            "schemaVersion": 1,
            "provider": "claude",
            "week": {
                "label": "Current week (all models)",
                "usedPct": 98,
                "resetAt": datetime.datetime.fromtimestamp(old_reset, tz=datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
                "eventAt": "2026-09-23T20:00:00.000Z",
            },
        })
        payload = {"rate_limits": {"seven_day": {"used_percentage": 2, "resets_at": new_reset}}}
        result = run_tap(json.dumps(payload), clean_env(home, state))
        assert result.returncode == 0, result.stderr or result.stdout

        usage = json.loads((state / "claude-usage.json").read_text())
        assert usage["week"]["usedPct"] == 2
        assert usage["week"]["source"] == "statusline"


def _iso(ts: int) -> str:
    return datetime.datetime.fromtimestamp(ts, tz=datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _week_snapshot(reset: int, used_pct: float, event_iso: str, session_reset: int, source: str = "official") -> dict:
    """Snapshot with both windows present so the tap's dropped-window refetch
    (payload missing a window the snapshot had) stays out of these tests."""
    return {
        "schemaVersion": 1,
        "provider": "claude",
        "week": {
            "label": "Current week (all models)",
            "usedPct": used_pct,
            "resetAt": _iso(reset),
            "eventAt": event_iso,
            "source": source,
        },
        "currentSession": {
            "label": "Current session",
            "usedPct": 10,
            "resetAt": _iso(session_reset),
            "eventAt": event_iso,
            "source": source,
        },
    }


def _payload(reset: int, used_pct: float, session_reset: int) -> str:
    return json.dumps({
        "rate_limits": {
            "five_hour": {"used_percentage": 10, "resets_at": session_reset},
            "seven_day": {"used_percentage": used_pct, "resets_at": reset},
        },
    })


def test_tap_fresh_official_holds_against_stale_high_repaint_and_refetches() -> None:
    """After a mid-window account reset the official endpoint says 2%, but an
    idle session still paints the pre-reset 99% from its last response. A
    fresh official reading (< 10 min) holds against a jump of 20+ points,
    and the tap asks the official endpoint to arbitrate."""
    with tempfile.TemporaryDirectory(prefix="tap-official-authority-") as raw:
        root = Path(raw)
        home, state = make_home_state(root)
        argv_log = root / "official-argv.log"
        argv_log.write_text("")
        argv_recording_stub(home / ".local/bin/bloom-usage-fetch-claude-official", argv_log)

        now = int(time.time())
        reset, session_reset = now + 3 * 86400, now + 3600
        write_json(state / "claude-usage.json", _week_snapshot(reset, 2, _iso(now - 120), session_reset))
        result = run_tap(_payload(reset, 99, session_reset), clean_env(home, state))
        assert result.returncode == 0, result.stderr or result.stdout

        usage = json.loads((state / "claude-usage.json").read_text())
        assert usage["week"]["usedPct"] == 2
        assert usage["week"]["source"] == "official"
        assert wait_for(lambda: argv_log.read_text().strip() != ""), "disputed reading must trigger an official refetch"


def test_tap_small_growth_over_fresh_official_is_accepted() -> None:
    """Normal growth while working (2% -> 5%) is not a dispute: the live
    statusline number wins over a fresh official reading and no refetch is
    spawned."""
    with tempfile.TemporaryDirectory(prefix="tap-official-growth-") as raw:
        root = Path(raw)
        home, state = make_home_state(root)
        argv_log = root / "official-argv.log"
        argv_log.write_text("")
        argv_recording_stub(home / ".local/bin/bloom-usage-fetch-claude-official", argv_log)

        now = int(time.time())
        reset, session_reset = now + 3 * 86400, now + 3600
        write_json(state / "claude-usage.json", _week_snapshot(reset, 2, _iso(now - 120), session_reset))
        result = run_tap(_payload(reset, 5, session_reset), clean_env(home, state))
        assert result.returncode == 0, result.stderr or result.stdout

        usage = json.loads((state / "claude-usage.json").read_text())
        assert usage["week"]["usedPct"] == 5
        assert usage["week"]["source"] == "statusline"
        time.sleep(0.3)
        assert argv_log.read_text().strip() == ""


def test_tap_stale_official_yields_to_big_jump_but_refetches() -> None:
    """Once the official reading is older than 10 minutes a 20+ point jump is
    accepted (usage may genuinely have grown), but the disagreement still
    asks the official endpoint to confirm."""
    with tempfile.TemporaryDirectory(prefix="tap-official-stale-") as raw:
        root = Path(raw)
        home, state = make_home_state(root)
        argv_log = root / "official-argv.log"
        argv_log.write_text("")
        argv_recording_stub(home / ".local/bin/bloom-usage-fetch-claude-official", argv_log)

        now = int(time.time())
        reset, session_reset = now + 3 * 86400, now + 3600
        write_json(state / "claude-usage.json", _week_snapshot(reset, 2, _iso(now - 15 * 60), session_reset))
        result = run_tap(_payload(reset, 99, session_reset), clean_env(home, state))
        assert result.returncode == 0, result.stderr or result.stdout

        usage = json.loads((state / "claude-usage.json").read_text())
        assert usage["week"]["usedPct"] == 99
        assert usage["week"]["source"] == "statusline"
        assert wait_for(lambda: argv_log.read_text().strip() != "")


def test_tap_big_drop_is_held_but_refetches() -> None:
    """A statusline reading 20+ points BELOW the number on disk inside the
    same window never regresses it (monotonic guard), but it is a dispute:
    the official endpoint decides whether a reset happened."""
    with tempfile.TemporaryDirectory(prefix="tap-big-drop-") as raw:
        root = Path(raw)
        home, state = make_home_state(root)
        argv_log = root / "official-argv.log"
        argv_log.write_text("")
        argv_recording_stub(home / ".local/bin/bloom-usage-fetch-claude-official", argv_log)

        now = int(time.time())
        reset, session_reset = now + 3 * 86400, now + 3600
        write_json(state / "claude-usage.json", _week_snapshot(reset, 99, _iso(now - 600), session_reset, source="statusline"))
        result = run_tap(_payload(reset, 3, session_reset), clean_env(home, state))
        assert result.returncode == 0, result.stderr or result.stdout

        usage = json.loads((state / "claude-usage.json").read_text())
        assert usage["week"]["usedPct"] == 99
        assert wait_for(lambda: argv_log.read_text().strip() != "")


def test_tap_drops_dead_official_checked_at() -> None:
    with tempfile.TemporaryDirectory(prefix="tap-drop-officialcheckedat-") as raw:
        home, state = make_home_state(Path(raw))
        write_json(state / "claude-usage.json", {
            "provider": "claude",
            "officialCheckedAt": "2026-08-07T06:17:17.441041Z",
        })
        future = int(time.time()) + 7200
        payload = {"rate_limits": {"five_hour": {"used_percentage": 10, "resets_at": future}}}
        result = run_tap(json.dumps(payload), clean_env(home, state))
        assert result.returncode == 0, result.stderr or result.stdout
        usage = json.loads((state / "claude-usage.json").read_text())
        assert "officialCheckedAt" not in usage


def test_tap_prints_builtin_statusline_when_real_hook_missing() -> None:
    """A buyer who never wires statusLine.command at the optional
    ~/.claude/hooks/bloom-statusline.js path (INSTALL.md step 5) must still
    see a statusline instead of a permanently blank one."""
    with tempfile.TemporaryDirectory(prefix="tap-builtin-statusline-") as raw:
        home, state = make_home_state(Path(raw))
        future = int(time.time()) + 7200
        payload = {
            "model": {"id": "claude-sonnet-5", "display_name": "Sonnet 5"},
            "rate_limits": {
                "five_hour": {"used_percentage": 9, "resets_at": future},
                "seven_day": {"used_percentage": 15, "resets_at": future},
            },
        }
        result = run_tap(json.dumps(payload), clean_env(home, state))
        assert result.returncode == 0, result.stderr or result.stdout
        assert result.stdout.strip() == "Sonnet 5 · 5h 9% · wk 15%", result.stdout


def test_tap_survives_unparseable_stdin() -> None:
    with tempfile.TemporaryDirectory(prefix="tap-unparseable-") as raw:
        home, state = make_home_state(Path(raw))
        result = run_tap("not json at all", clean_env(home, state))
        assert result.returncode == 0, result.stderr or result.stdout
        health = json.loads((state / "claude-statusline-tap.json").read_text())
        assert health["parsed"] is False
        assert health["payloadKeys"] == []


def test_tap_stdin_timeout_forwards_whatever_arrived() -> None:
    # Simulate a hung Claude Code pipe: write a valid payload but never close
    # stdin. The tap's 3s timeout must fire tap()+forward() anyway.
    with tempfile.TemporaryDirectory(prefix="tap-stdin-timeout-") as raw:
        home, state = make_home_state(Path(raw))
        future = int(time.time()) + 7200
        payload = json.dumps({"rate_limits": {"five_hour": {"used_percentage": 12, "resets_at": future}}})
        # This test covers stdin, not detached budget updates or refetches.
        # Debounce both helpers so they cannot race TemporaryDirectory cleanup.
        stamps = [state / name for name in (".budget-update-last", ".claude-official-last-attempt")]
        for stamp in stamps:
            stamp.write_text(str(int(time.time())))
        stamp_mtimes = [stamp.stat().st_mtime_ns for stamp in stamps]
        env = clean_env(home, state)
        proc = subprocess.Popen(
            [NODE, str(TAP)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        started = time.time()
        proc.stdin.write(payload)
        proc.stdin.flush()
        # Deliberately do not close stdin: the pipe stays open like a stalled hook.
        returncode = proc.wait(timeout=8)
        elapsed = time.time() - started
        assert returncode == 0
        assert [stamp.stat().st_mtime_ns for stamp in stamps] == stamp_mtimes, "stdin test must not launch background writers"
        assert 2.5 <= elapsed <= 7.5, f"expected the ~3s stdin timeout to fire, took {elapsed:.1f}s"
        usage = json.loads((state / "claude-usage.json").read_text())
        assert usage["currentSession"]["usedPct"] == 12


def test_tap_expired_window_triggers_official_refetch_once() -> None:
    with tempfile.TemporaryDirectory(prefix="tap-refetch-expired-") as raw:
        root = Path(raw)
        home, state = make_home_state(root)
        argv_log = root / "official-argv.log"
        argv_log.write_text("")
        argv_recording_stub(home / ".local/bin/bloom-usage-fetch-claude-official", argv_log)

        past = int(time.time()) - 60
        write_json(
            state / "claude-usage.json",
            {
                "schemaVersion": 1,
                "provider": "claude",
                "week": {
                    "label": "Current week (all models)",
                    "usedPct": 50,
                    "resetAt": "2020-01-01T00:00:00.000Z",
                },
            },
        )
        payload = json.dumps({"rate_limits": {"seven_day": {"used_percentage": 99, "resets_at": past}}})

        result = run_tap(payload, clean_env(home, state))
        assert result.returncode == 0, result.stderr or result.stdout

        usage = json.loads((state / "claude-usage.json").read_text())
        assert "week" not in usage
        expired = usage.get("rateLimitExpired") or []
        assert expired
        # UsageView.swift checks snapshot.rateLimitExpired for the exact bare
        # key string, not just a human sentence mentioning it.
        assert "week" in expired

        assert wait_for(lambda: argv_log.read_text().strip() != "")
        stamp_path = state / ".claude-official-last-attempt"
        assert stamp_path.exists()
        first_stamp = stamp_path.read_text().strip()
        assert first_stamp.isdigit()

        # Second run inside the 120s cooldown must not spawn the refetch again.
        result2 = run_tap(payload, clean_env(home, state))
        assert result2.returncode == 0, result2.stderr or result2.stdout
        time.sleep(0.3)
        assert len(argv_log.read_text().strip().splitlines()) == 1
        assert stamp_path.read_text().strip() == first_stamp


def test_tap_dropped_window_with_live_reset_does_not_refetch() -> None:
    # A payload that never carries rate_limits at all (API-key auth,
    # pre-first-response renders) must not spawn a refetch every 120s for
    # the whole life of the session just because it is silent this time --
    # only when a cached window is actually no longer trustworthy. Here both
    # cached windows' resetAt are still two days out, so the keepalive's
    # 10-minute refresh already covers freshness; the tap must do nothing.
    with tempfile.TemporaryDirectory(prefix="tap-refetch-dropped-live-") as raw:
        root = Path(raw)
        home, state = make_home_state(root)
        argv_log = root / "official-argv.log"
        argv_log.write_text("")
        argv_recording_stub(home / ".local/bin/bloom-usage-fetch-claude-official", argv_log)

        future_reset = (
            datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=2)
        ).strftime("%Y-%m-%dT%H:%M:%S.000Z")
        write_json(
            state / "claude-usage.json",
            {
                "schemaVersion": 1,
                "provider": "claude",
                "currentSession": {
                    "label": "Current session",
                    "usedPct": 5,
                    "resetAt": future_reset,
                },
                "week": {
                    "label": "Current week (all models)",
                    "usedPct": 9,
                    "resetAt": future_reset,
                },
            },
        )
        payload = json.dumps({})
        result = run_tap(payload, clean_env(home, state))
        assert result.returncode == 0, result.stderr or result.stdout

        usage = json.loads((state / "claude-usage.json").read_text())
        # Both still-live windows are carried forward untouched.
        assert usage["currentSession"]["usedPct"] == 5
        assert usage["week"]["usedPct"] == 9

        time.sleep(0.3)
        assert argv_log.read_text().strip() == "", "a still-future resetAt must not trigger a refetch"
        assert not (state / ".claude-official-last-attempt").exists()


def test_tap_dropped_window_with_past_reset_triggers_refetch() -> None:
    # Same silent payload, but the cached week window's own resetAt is
    # already behind us -- that value is no longer usable, so the gap must
    # trigger a refetch even though this is the dropped-window path, not
    # the anyExpired path (the payload never carried rate_limits to expire
    # anything from).
    with tempfile.TemporaryDirectory(prefix="tap-refetch-dropped-past-") as raw:
        root = Path(raw)
        home, state = make_home_state(root)
        argv_log = root / "official-argv.log"
        argv_log.write_text("")
        argv_recording_stub(home / ".local/bin/bloom-usage-fetch-claude-official", argv_log)

        past_reset = (
            datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=1)
        ).strftime("%Y-%m-%dT%H:%M:%S.000Z")
        write_json(
            state / "claude-usage.json",
            {
                "schemaVersion": 1,
                "provider": "claude",
                "week": {
                    "label": "Current week (all models)",
                    "usedPct": 9,
                    "resetAt": past_reset,
                },
            },
        )
        payload = json.dumps({})
        result = run_tap(payload, clean_env(home, state))
        assert result.returncode == 0, result.stderr or result.stdout

        assert wait_for(lambda: argv_log.read_text().strip() != "")
        assert argv_log.read_text().strip() == "--mode api"
        assert (state / ".claude-official-last-attempt").exists()


def test_tap_budget_update_debounced_with_node_bin_env() -> None:
    with tempfile.TemporaryDirectory(prefix="tap-budget-debounce-") as raw:
        root = Path(raw)
        home, state = make_home_state(root)
        call_log = root / "budget-calls.log"
        call_log.write_text("")
        env_recording_stub(home / ".local/bin/bloom-budget-update", call_log, "BLOOM_USAGE_NODE_BIN")

        future = int(time.time()) + 7200
        payload = json.dumps({"rate_limits": {"five_hour": {"used_percentage": 1, "resets_at": future}}})
        result = run_tap(payload, clean_env(home, state))
        assert result.returncode == 0, result.stderr or result.stdout

        assert wait_for(lambda: call_log.read_text().strip() != "")
        stamp_path = state / ".budget-update-last"
        assert stamp_path.exists()
        first_stamp = stamp_path.read_text().strip()
        assert first_stamp.isdigit()
        first_calls = call_log.read_text().strip().splitlines()
        assert len(first_calls) == 1
        # No BLOOM_NODE_BIN in this stub dir: the tap prefers a sibling
        # bloom-node (bundled next to it) and otherwise the running node.
        assert Path(first_calls[0]).name in {"node", "bloom-node"}

        # Second run inside the 60s debounce window must not spawn again.
        result2 = run_tap(payload, clean_env(home, state))
        assert result2.returncode == 0, result2.stderr or result2.stdout
        time.sleep(0.3)
        assert len(call_log.read_text().strip().splitlines()) == 1
        assert stamp_path.read_text().strip() == first_stamp


def test_tap_resolves_node_bin_override_and_shim_before_execpath() -> None:
    with tempfile.TemporaryDirectory(prefix="tap-node-bin-resolve-") as raw:
        root = Path(raw)
        home, state = make_home_state(root)
        call_log = root / "budget-calls.log"
        call_log.write_text("")
        env_recording_stub(home / ".local/bin/bloom-budget-update", call_log, "BLOOM_USAGE_NODE_BIN")
        # A bloom-node shim exists but BLOOM_NODE_BIN env still wins.
        (home / ".local/bin/bloom-node").write_text("#!/bin/sh\nexit 0\n")
        (home / ".local/bin/bloom-node").chmod(0o755)

        future = int(time.time()) + 7200
        payload = json.dumps({"rate_limits": {"five_hour": {"used_percentage": 1, "resets_at": future}}})
        env = clean_env(home, state, {"BLOOM_NODE_BIN": "/custom/node/path"})
        result = run_tap(payload, env)
        assert result.returncode == 0, result.stderr or result.stdout
        assert wait_for(lambda: call_log.read_text().strip() != "")
        assert call_log.read_text().strip() == "/custom/node/path"


def test_official_stamp_throttle_keys_on_mtime_not_content() -> None:
    # The stamp file is shared by the tap, the keepalive writer, and
    # bloom-usage-capture.sh. All three must throttle on its mtime, never by
    # parsing its content -- otherwise a value one writer considers garbage
    # (or a units mismatch) could make the writers disagree about whether a
    # refetch is due. Prove it by pointing an ISO string (never what any
    # writer emits; the real content is unix epoch seconds) at a fresh mtime
    # and confirming the throttle still holds.
    with tempfile.TemporaryDirectory(prefix="tap-stamp-mtime-") as raw:
        root = Path(raw)
        home, state = make_home_state(root)
        argv_log = root / "official-argv.log"
        argv_log.write_text("")
        argv_recording_stub(home / ".local/bin/bloom-usage-fetch-claude-official", argv_log)

        # Existing snapshot carries a week window whose own resetAt is
        # already behind us, so it is no longer usable; the incoming
        # payload drops seven_day outright too, which would normally
        # trigger a refetch absent the cooldown below.
        write_json(
            state / "claude-usage.json",
            {
                "schemaVersion": 1,
                "provider": "claude",
                "week": {
                    "label": "Current week (all models)",
                    "usedPct": 9,
                    "resetAt": "2020-01-01T00:00:00.000Z",
                },
            },
        )

        stamp_path = state / ".claude-official-last-attempt"
        stamp_path.parent.mkdir(parents=True, exist_ok=True)
        stamp_content = "2026-09-02T12:00:00.000Z"
        stamp_path.write_text(stamp_content)  # fresh mtime, non-numeric content

        future = int(time.time()) + 7200
        payload = json.dumps({"rate_limits": {"five_hour": {"used_percentage": 5, "resets_at": future}}})
        result = run_tap(payload, clean_env(home, state))
        assert result.returncode == 0, result.stderr or result.stdout

        time.sleep(0.3)
        assert argv_log.read_text().strip() == "", "fresh stamp mtime must suppress the refetch regardless of content"
        # A throttled call must not touch the stamp at all.
        assert stamp_path.read_text().strip() == stamp_content


def test_weekfable_captured_before_reset_pushes_bare_key_literal() -> None:
    with tempfile.TemporaryDirectory(prefix="tap-weekfable-expiry-") as raw:
        root = Path(raw)
        home, state = make_home_state(root)
        argv_recording_stub(
            home / ".local/bin/bloom-usage-fetch-claude-official", root / "official-argv.log"
        )

        write_json(
            state / "claude-usage.json",
            {
                "schemaVersion": 1,
                "provider": "claude",
                "week": {
                    "label": "Current week (all models)",
                    "usedPct": 20,
                    "resetAt": "2099-01-01T00:00:00.000Z",
                },
                "weekFable": {
                    "label": "Current week (Fable)",
                    "usedPct": 98,
                    "resetAt": "2020-01-01T00:00:00.000Z",
                    "resetLabel": "Jan 1 12:00 AM",
                    "capturedAt": "2019-12-01T00:00:00.000Z",
                },
            },
        )

        future = int(time.time()) + 7200
        payload = json.dumps(
            {
                "rate_limits": {
                    "five_hour": {"used_percentage": 5, "resets_at": future},
                    "seven_day": {"used_percentage": 20, "resets_at": future},
                }
            }
        )
        result = run_tap(payload, clean_env(home, state))
        assert result.returncode == 0, result.stderr or result.stdout

        usage = json.loads((state / "claude-usage.json").read_text())
        assert "weekFable" not in usage
        expired = usage.get("rateLimitExpired") or []
        # FableDisplay.shouldShow (UsageView.swift) checks rateLimitExpired
        # for the exact string "weekFable"; the human sentence alone would
        # never match it.
        assert "weekFable" in expired
        assert any(entry != "weekFable" and "Fable" in entry for entry in expired)
        assert len(expired) == len(set(expired)), "rateLimitExpired must stay de-duplicated"


def test_capture_hook_calls_scraper_in_api_mode_and_throttles() -> None:
    with tempfile.TemporaryDirectory(prefix="capture-hook-") as raw:
        root = Path(raw)
        home, state = make_home_state(root)
        argv_log = root / "scraper-argv.log"
        argv_log.write_text("")
        argv_recording_stub(home / ".local/bin/bloom-usage-fetch-claude-official", argv_log)
        env = clean_env(home, state)

        started = time.time()
        result = run_capture_hook(env)
        assert result.returncode == 0, result.stderr or result.stdout
        assert wait_for(lambda: argv_log.read_text().strip() != "", timeout=2.0)
        assert time.time() - started < 2.0
        assert argv_log.read_text().strip() == "--mode api"
        assert (state / ".claude-official-last-attempt").exists()

        # Second run inside MIN_INTERVAL (300s) must not call the scraper again.
        result2 = run_capture_hook(env)
        assert result2.returncode == 0, result2.stderr or result2.stdout
        time.sleep(0.3)
        assert len(argv_log.read_text().strip().splitlines()) == 1


def test_capture_hook_survives_corrupt_throttle_file() -> None:
    for corrupt_stamp in ("abc", "12abc"):
        with tempfile.TemporaryDirectory(prefix="capture-hook-corrupt-") as raw:
            root = Path(raw)
            home, state = make_home_state(root)
            argv_log = root / "scraper-argv.log"
            argv_log.write_text("")
            argv_recording_stub(home / ".local/bin/bloom-usage-fetch-claude-official", argv_log)
            (state / ".usage-capture-last").write_text(corrupt_stamp + "\n")

            result = run_capture_hook(clean_env(home, state))
            assert result.returncode == 0, f"{corrupt_stamp!r}: {result.stderr or result.stdout}"
            assert wait_for(lambda: argv_log.read_text().strip() != "", timeout=2.0)
            time.sleep(0.3)
            assert argv_log.read_text().splitlines() == ["--mode api"]


TESTS = [
    test_tap_writes_windows_with_event_at_and_key_only_health,
    test_tap_keeps_higher_usedpct_within_same_window,
    test_tap_accepts_new_window_on_different_reset,
    test_tap_fresh_official_holds_against_stale_high_repaint_and_refetches,
    test_tap_small_growth_over_fresh_official_is_accepted,
    test_tap_stale_official_yields_to_big_jump_but_refetches,
    test_tap_big_drop_is_held_but_refetches,
    test_tap_drops_dead_official_checked_at,
    test_tap_prints_builtin_statusline_when_real_hook_missing,
    test_tap_survives_unparseable_stdin,
    test_tap_stdin_timeout_forwards_whatever_arrived,
    test_tap_expired_window_triggers_official_refetch_once,
    test_tap_dropped_window_with_live_reset_does_not_refetch,
    test_tap_dropped_window_with_past_reset_triggers_refetch,
    test_tap_budget_update_debounced_with_node_bin_env,
    test_tap_resolves_node_bin_override_and_shim_before_execpath,
    test_official_stamp_throttle_keys_on_mtime_not_content,
    test_weekfable_captured_before_reset_pushes_bare_key_literal,
    test_capture_hook_calls_scraper_in_api_mode_and_throttles,
    test_capture_hook_survives_corrupt_throttle_file,
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
