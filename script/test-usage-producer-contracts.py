#!/usr/bin/env python3
"""Hermetic producer-contract regressions. No network or real provider CLIs."""

from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

sys.dont_write_bytecode = True


ROOT = Path(__file__).resolve().parent.parent
NODE = shutil.which("node")
if not NODE:
    raise SystemExit("node is required")

METERED_KEYS = {
    "XAI_API_KEY",
    "GROK_API_KEY",
    "OPENAI_API_KEY",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "GOOGLE_API_KEY",
    "GEMINI_API_KEY",
    "GOOGLE_APPLICATION_CREDENTIALS",
}


def clean_env(home: Path, state: Path, extra: dict[str, str] | None = None) -> dict[str, str]:
    env = {key: value for key, value in os.environ.items() if key not in METERED_KEYS}
    env.update(
        {
            "HOME": str(home),
            "BLOOM_CODEX_ACCOUNT_REFRESH": "0", "BLOOM_CLAUDE_OFFICIAL_FETCH_BIN": "/usr/bin/true",
            "CODEX_USAGE_HUD_STATE_DIR": str(state),
            "BLOOM_USAGE_DIR": str(state),
            "PATH": f"{Path(NODE).parent}:/usr/bin:/bin",
        }
    )
    if extra:
        env.update(extra)
    return env


def run_node(script: Path, args: list[str], env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [NODE, str(script), *args],
        text=True,
        capture_output=True,
        timeout=30,
        env=env,
        check=False,
    )


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n")


def codex_snapshot(rate: dict[str, object], official: dict[str, object] | None = None) -> dict[str, object]:
    with tempfile.TemporaryDirectory(prefix="usage-codex-contract-") as raw:
        root = Path(raw)
        state = root / "state"
        codex_home = root / "codex"
        session = codex_home / "sessions" / "fixture.jsonl"
        event = {
            "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {"total_token_usage": {}, "last_token_usage": {}},
                "rate_limits": {"limit_id": "codex", "plan_type": "pro", **rate},
            },
        }
        session.parent.mkdir(parents=True)
        session.write_text(json.dumps(event) + "\n")
        if official is not None:
            write_json(state / "codex-account-usage.json", official)
        result = run_node(
            ROOT / "bin/bloom-usage-write-codex",
            [],
            clean_env(root, state, {"CODEX_HOME": str(codex_home)}),
        )
        assert result.returncode == 0, result.stderr or result.stdout
        return json.loads((state / "codex-usage.json").read_text())


def test_codex_account_poll_refresh_and_failure_age() -> None:
    with tempfile.TemporaryDirectory(prefix="usage-codex-account-") as raw:
        root = Path(raw); state = root / "state"; fake = root / "bin"
        fake.mkdir()
        cli = fake / "codex"
        cli.write_text("#!/usr/bin/env python3\n" + """
import json, os, sys, time
from pathlib import Path
counter = Path(os.environ['QUOTA_CALLS'])
counter.write_text(counter.read_text() + 'x' if counter.exists() else 'x')
for line in sys.stdin:
    request = json.loads(line)
    if request.get('id') == 1:
        print(json.dumps({'id': 1, 'result': {}}), flush=True)
    elif request.get('id') == 2:
        if os.environ.get('FAIL_QUOTA'):
            print(json.dumps({'id': 2, 'error': {'message': 'unavailable'}}), flush=True)
        else:
            print(json.dumps({'id': 2, 'result': {'rateLimitsByLimitId': {'codex': {
                'limitId': 'codex', 'primary': {'usedPercent': 12, 'windowDurationMins': 300, 'resetsAt': int(time.time()) + 3600},
                'secondary': {'usedPercent': 61, 'windowDurationMins': 10080, 'resetsAt': int(time.time()) + 86400}
            }}}}), flush=True)
""")
        cli.chmod(0o755)
        calls = root / "calls"
        env = clean_env(root, state, {"BLOOM_CODEX_ACCOUNT_REFRESH": "1", "QUOTA_CALLS": str(calls),
            "CODEX_HOME": str(root / "codex"), "PATH": f"{fake}:{Path(sys.executable).parent}:{Path(NODE).parent}:/usr/bin:/bin"})
        def run():
            result = run_node(ROOT / "bin/bloom-usage-write-codex", [], env)
            assert result.returncode == 0, result.stderr
            return json.loads((state / "codex-usage.json").read_text())
        first = run()
        assert first['sourceKind'] == 'official_app_server'
        assert first['week']['usedPct'] == 61 and first['currentSession']['usedPct'] == 12
        assert run()['eventAt'] == first['eventAt'] and calls.read_text() == 'x'
        env['CODEX_USAGE_HUD_MANUAL_REFRESH'] = '1'
        second = run()
        assert calls.read_text() == 'xx' and second['eventAt'] > first['eventAt']
        env['FAIL_QUOTA'] = '1'
        assert run()['eventAt'] == second['eventAt'] and calls.read_text() == 'xxx'


def test_codex_classifies_and_dual_writes() -> None:
    future = int(time.time()) + 7200
    snapshot = codex_snapshot(
        {
            # The real regression shape: weekly may arrive in primary.
            "primary": {"used_percent": 11, "window_minutes": 10080, "resets_at": future},
            "secondary": {"used_percent": 42, "window_minutes": 300, "resets_at": future},
        }
    )
    assert snapshot["week"]["usedPct"] == 11
    assert snapshot["currentSession"]["usedPct"] == 42
    windows = {item["id"]: item for item in snapshot["windows"]}
    assert windows["week"]["usedPct"] == 11
    assert windows["5h"]["usedPct"] == 42
    assert windows["week"]["state"] == "live"
    assert snapshot["health"]["verdict"] == "fresh"

    labeled = codex_snapshot(
        {
            "primary": {"used_percent": 17, "name": "Current week", "resets_at": future},
            "secondary": {"used_percent": 33, "label": "Current session", "resets_at": future},
        }
    )
    assert labeled["week"]["usedPct"] == 17
    assert labeled["currentSession"]["usedPct"] == 33

    past = int(time.time()) - 60
    expired = codex_snapshot(
        {
            "primary": {"used_percent": 54, "window_minutes": 300, "resets_at": past},
            "secondary": {"used_percent": 7, "window_minutes": 10080, "resets_at": past},
        }
    )
    assert "currentSession" not in expired and "week" not in expired
    expired_windows = {item["id"]: item for item in expired["windows"]}
    assert expired_windows["5h"]["state"] == "expired"
    assert expired_windows["5h"]["usedPct"] == 54
    assert expired_windows["week"]["state"] == "expired"


def test_codex_preserves_newer_official_account_quota() -> None:
    official = {"provider": "codex", "sourceKind": "official_app_server",
                "eventAt": datetime.fromtimestamp(time.time() + 1, timezone.utc).isoformat(),
                "week": {"usedPct": 5, "resetAt": datetime.fromtimestamp(time.time()+7200, timezone.utc).isoformat()}}
    rate = {"primary": {"used_percent": 90, "window_minutes": 10080, "resets_at": int(time.time()) + 7200},
            "secondary": {"used_percent": 100, "window_minutes": 300, "resets_at": int(time.time()) + 3600}}
    merged = codex_snapshot(rate, official)
    assert merged["week"]["usedPct"] == 5
    assert merged["currentSession"]["usedPct"] == 100
    assert {w["id"] for w in merged["windows"]} == {"week", "5h"}
    for pct in (None, True, -1, 101):
        invalid = {**official, "week": {**official["week"], "usedPct": pct}}
        assert codex_snapshot(rate, invalid)["week"]["usedPct"] == 90
    official["eventAt"] = "2020-01-01T00:00:00Z"
    assert codex_snapshot(rate, official)["week"]["usedPct"] == 90
    official["eventAt"] = "2099-01-01T00:00:00Z"
    assert codex_snapshot(rate, official)["week"]["usedPct"] == 90


def test_codex_nonlive_official_short_preserves_live_local_limit() -> None:
    future = datetime.fromtimestamp(time.time() + 3600, timezone.utc).isoformat()
    past = datetime.fromtimestamp(time.time() - 60, timezone.utc).isoformat()
    rate = {"primary": {"used_percent": 90, "window_minutes": 10080, "resets_at": int(time.time()) + 7200},
            "secondary": {"used_percent": 100, "window_minutes": 300, "resets_at": int(time.time()) + 3600}}
    for short in ({"usedPct": 40, "resetAt": past}, {"usedPct": 40, "resetAt": "invalid"},
                  {"usedPct": "40", "resetAt": future}, None):
        official = {"provider": "codex", "sourceKind": "official_app_server",
                    "eventAt": datetime.fromtimestamp(time.time() + 1, timezone.utc).isoformat(),
                    "week": {"usedPct": 5, "resetAt": future}, "currentSession": short}
        merged = codex_snapshot(rate, official)
        assert merged["week"]["usedPct"] == 5
        assert merged["currentSession"]["usedPct"] == 100, short
        assert merged["currentSession"]["eventAt"] < merged["eventAt"]
        assert next(w for w in merged["windows"] if w["id"] == "5h")["state"] == "live"


def test_codex_live_official_short_remains_preferred() -> None:
    future = datetime.fromtimestamp(time.time() + 3600, timezone.utc).isoformat()
    official = {"provider": "codex", "sourceKind": "official_app_server",
                "eventAt": datetime.fromtimestamp(time.time() + 1, timezone.utc).isoformat(),
                "week": {"usedPct": 5, "resetAt": future},
                "currentSession": {"usedPct": 40, "resetAt": future}}
    rate = {"primary": {"used_percent": 90, "window_minutes": 10080, "resets_at": int(time.time()) + 7200},
            "secondary": {"used_percent": 100, "window_minutes": 300, "resets_at": int(time.time()) + 3600}}
    assert codex_snapshot(rate, official)["currentSession"]["usedPct"] == 40


def test_codex_expired_official_week_keeps_recorded_percentage() -> None:
    official = {"provider": "codex", "sourceKind": "official_app_server",
                "eventAt": datetime.fromtimestamp(time.time() + 1, timezone.utc).isoformat(),
                "week": {"usedPct": 75, "resetAt": datetime.fromtimestamp(time.time() - 60, timezone.utc).isoformat()}}
    rate = {"primary": {"used_percent": 90, "window_minutes": 10080, "resets_at": int(time.time()) + 7200}}
    merged = codex_snapshot(rate, official)
    assert merged["week"]["usedPct"] == 75
    assert merged["windows"][0]["state"] == "expired"


def test_claude_writer_reconciles_health() -> None:
    with tempfile.TemporaryDirectory(prefix="usage-claude-writer-") as raw:
        root = Path(raw)
        state = root / "state"
        usage = state / "claude-usage.json"
        status = state / "claude-official-status.json"
        future = datetime.fromtimestamp(time.time() + 7200, timezone.utc).isoformat().replace("+00:00", "Z")
        write_json(
            usage,
            {
                "schemaVersion": 1,
                "provider": "claude",
                "source": "claude usage keepalive writer",
                "updatedAt": "2020-01-01T00:00:00Z",
                "capturedAt": "2020-01-01T00:00:00Z",
                "currentSession": {"label": "5h", "usedPct": 20, "resetAt": future},
                "providerHealth": {"status": "unparsed", "message": "stale warning"},
                "subagents": [
                    {"name": "gsd-review", "percent": 80},
                    {"name": "active-agent", "percent": 20},
                ],
                "contributors": [],
                "skills": [],
            },
        )
        write_json(
            status,
            {
                "schemaVersion": 1,
                "status": "ok",
                "message": "official usage parsed",
                "updatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            },
        )
        writer_env = clean_env(
            root,
            state,
            {"BLOOM_USAGE_OUT": str(usage), "BLOOM_CLAUDE_USAGE_STATUS": str(status)},
        )
        result = run_node(
            ROOT / "bin/bloom-usage-write-claude",
            [],
            writer_env,
        )
        assert result.returncode == 0, result.stderr or result.stdout
        written = json.loads(usage.read_text())
        assert "providerHealth" not in written
        assert written["health"]["verdict"] == "fresh"
        assert [item["name"] for item in written["subagents"]] == ["active-agent"]

        write_json(
            status,
            {
                "schemaVersion": 1,
                "status": "ok",
                "message": "parsed before forced PTY cleanup",
                "exitCode": -9,
                "updatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            },
        )
        killed_result = run_node(ROOT / "bin/bloom-usage-write-claude", [], writer_env)
        assert killed_result.returncode == 0, killed_result.stderr or killed_result.stdout
        killed = json.loads(usage.read_text())
        assert killed["officialUsageStatus"]["exitCode"] == -9
        assert killed["providerHealth"]["exitCode"] == -9
        assert killed["health"]["verdict"] == "degraded"
        assert killed["health"]["reason"] == "official /usage exited -9"


def load_claude_fetch_module():
    sys.dont_write_bytecode = True
    path = ROOT / "bin/bloom-usage-fetch-claude-official"
    loader = importlib.machinery.SourceFileLoader("usage_claude_fetch_contract", str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def configure_claude_fetch(module, state: Path) -> None:
    module.STATE_DIR = state
    module.USAGE_PATH = state / "claude-usage.json"
    module.CAPTURE_PATH = state / "claude-official-usage.txt"
    module.OFFICIAL_STATUS_PATH = state / "claude-official-status.json"
    module.RATE_LIMIT_COOLDOWN_PATH = state / ".claude-official-rate-limited-until"


def test_claude_fetch_rejects_nonzero_and_cleans_fresh() -> None:
    module = load_claude_fetch_module()
    raw = """
Claude Code
Current session
42% used
Resets 1h
Current week (all models)
11% used
Resets 2d
Extra usage
Last 24h
"""
    captured = datetime.now(timezone.utc)

    with tempfile.TemporaryDirectory(prefix="usage-claude-fetch-fail-") as raw_dir:
        state = Path(raw_dir)
        configure_claude_fetch(module, state)
        original = {"schemaVersion": 1, "provider": "claude", "marker": "keep"}
        write_json(module.USAGE_PATH, original)
        result = module.process_usage(raw, -9, captured)
        assert result == 1
        assert json.loads(module.USAGE_PATH.read_text()) == original
        status = json.loads(module.OFFICIAL_STATUS_PATH.read_text())
        assert status["status"] == "failed" and status["exitCode"] == -9

    with tempfile.TemporaryDirectory(prefix="usage-claude-fetch-ok-") as raw_dir:
        state = Path(raw_dir)
        configure_claude_fetch(module, state)
        write_json(
            module.USAGE_PATH,
            {
                "schemaVersion": 1,
                "provider": "claude",
                "providerHealth": {"status": "unparsed"},
                "subagents": [
                    {"name": "gsd-stale", "percent": 99},
                    {"name": "current", "percent": 1},
                ],
                "skills": [],
            },
        )
        result = module.process_usage(raw, 0, captured)
        assert result == 0
        written = json.loads(module.USAGE_PATH.read_text())
        assert "providerHealth" not in written
        assert written["health"]["verdict"] == "fresh"
        assert [item["name"] for item in written["subagents"]] == ["current"]
        assert json.loads(module.OFFICIAL_STATUS_PATH.read_text())["status"] == "ok"

    with tempfile.TemporaryDirectory(prefix="usage-claude-fetch-cleanup-") as raw_dir:
        state = Path(raw_dir)
        configure_claude_fetch(module, state)
        write_json(module.USAGE_PATH, {"schemaVersion": 1, "provider": "claude"})
        result = module.process_usage(raw, 0, captured, cleanup_exit_code=-9)
        assert result == 0
        status = json.loads(module.OFFICIAL_STATUS_PATH.read_text())
        assert status["status"] == "ok"
        assert status["exitCode"] == 0
        assert status["cleanupForced"] is True
        assert status["cleanupExitCode"] == -9


def test_claude_fetch_reaps_clean_exit_before_signaling() -> None:
    module = load_claude_fetch_module()
    pid = os.fork()
    if pid == 0:
        time.sleep(0.2)
        os._exit(0)
    assert module.reap_child(pid) == (0, False)


def test_gemini_has_no_legacy_oauth_fetcher() -> None:
    """The fetcher that reused the Gemini CLI's OAuth client against Google
    directly is gone (Google suspends accounts for that); agy is the only path."""
    assert not (ROOT / "bin/bloom-usage-fetch-gemini").exists()
    writer = (ROOT / "bin/bloom-usage-write-gemini-agy").read_text()
    assert "bloom-usage-fetch-gemini" not in writer
    assert "LEGACY_OAUTH" not in writer


def write_executable(path: Path, body: str) -> None:
    path.write_text(body)
    path.chmod(0o755)


def test_gemini_agy_total_failure_writes_status_and_nonzero_exit() -> None:
    """agy is installed but no live LS, no cache, and spawn disabled: every
    strategy is exhausted. The writer must surface that instead
    of silently exiting 0 with nothing written anywhere (bloom-budget-update
    otherwise has no way to count this lane as failed)."""
    with tempfile.TemporaryDirectory(prefix="usage-gemini-total-failure-") as raw:
        root = Path(raw)
        state = root / "state"
        state.mkdir()

        agy = root / "bin/agy"
        agy.parent.mkdir(parents=True)
        write_executable(agy, "#!/bin/sh\nexit 1\n")

        result = run_node(
            ROOT / "bin/bloom-usage-write-gemini-agy",
            [],
            clean_env(
                root,
                state,
                {
                    "BLOOM_AGY_SPAWN": "0",
                    "BLOOM_AGY_BIN": str(agy),
                },
            ),
        )
        assert result.returncode == 1, result.stderr or result.stdout
        status = json.loads((state / "gemini-official-status.json").read_text())
        assert status["status"] == "offline"
        assert not (state / "gemini-usage.json").exists()


def gemini_agy_snapshot(quota: dict[str, object], cache_age_seconds: int = 1800) -> dict[str, object]:
    with tempfile.TemporaryDirectory(prefix="usage-gemini-agy-contract-") as raw:
        root = Path(raw)
        state = root / "state"
        out = state / "gemini-usage.json"
        # Default cached quota is 30 minutes old: past the 10-minute refresh
        # gate but inside the 2-hour spawn gate, so the writer rebuilds the
        # snapshot from cache without touching the network or spawning agy.
        cached_at = datetime.fromtimestamp(time.time() - cache_age_seconds, timezone.utc).isoformat().replace("+00:00", "Z")
        write_json(out, {"antigravity": {"capturedAt": cached_at, "quota": quota}})
        result = run_node(
            ROOT / "bin/bloom-usage-write-gemini-agy",
            [],
            clean_env(root, state, {"BLOOM_AGY_SPAWN": "0"}),
        )
        assert result.returncode == 0, result.stderr or result.stdout
        return json.loads(out.read_text())


def antigravity_bucket(bucket_id: str, window: str, used_pct: float, reset_at: str) -> dict[str, object]:
    return {
        "bucketId": bucket_id,
        "window": window,
        "remainingFraction": 1 - used_pct / 100,
        "resetTime": reset_at,
    }


def test_gemini_agy_windows_match_v1_week_and_session() -> None:
    future = datetime.fromtimestamp(time.time() + 7200, timezone.utc).isoformat().replace("+00:00", "Z")
    snapshot = gemini_agy_snapshot(
        {
            "groups": [
                {
                    "displayName": "Gemini models",
                    "buckets": [
                        antigravity_bucket("gemini-week", "week", 10, future),
                        antigravity_bucket("gemini-5h", "5h", 5, future),
                    ],
                },
                {
                    "displayName": "Claude and GPT models",
                    "buckets": [
                        antigravity_bucket("agy-week", "week", 90, future),
                        antigravity_bucket("agy-5h", "5h", 40, future),
                    ],
                },
            ]
        }
    )
    # v1 fields name the row "Gemini" and must read the Gemini-models pool,
    # not whichever pool (Claude/GPT via Antigravity) happens to be fullest.
    assert snapshot["week"]["usedPct"] == 10
    assert snapshot["currentSession"]["usedPct"] == 5
    # windows[] must carry the SAME pair under canonical role ids so the
    # panel's schema-v2 name scoring cannot land on a different bucket.
    windows = {item["id"]: item for item in snapshot["windows"]}
    assert set(windows) == {"week", "5h"}
    assert windows["week"]["usedPct"] == 10
    assert windows["5h"]["usedPct"] == 5
    assert windows["week"]["state"] == "live"
    # Full bucket inventory (every pool) stays visible outside windows[].
    assert len(snapshot["contributors"]) == 4
    assert snapshot["extraUsage"].count("%") == 4


def test_gemini_agy_single_bucket_quota() -> None:
    future = datetime.fromtimestamp(time.time() + 7200, timezone.utc).isoformat().replace("+00:00", "Z")
    snapshot = gemini_agy_snapshot(
        {
            "groups": [
                {
                    "displayName": "Gemini models",
                    "buckets": [antigravity_bucket("gemini-week", "week", 25, future)],
                }
            ]
        }
    )
    assert snapshot["week"]["usedPct"] == 25
    assert "currentSession" not in snapshot
    assert [item["id"] for item in snapshot["windows"]] == ["week"]
    assert snapshot["windows"][0]["usedPct"] == 25


def test_gemini_agy_falls_back_to_fullest_bucket_when_no_gemini_group() -> None:
    # No group displayName matches /gemini/i at all: the row still needs a
    # number, so it falls back to the fullest bucket rather than going blank.
    future = datetime.fromtimestamp(time.time() + 7200, timezone.utc).isoformat().replace("+00:00", "Z")
    snapshot = gemini_agy_snapshot(
        {
            "groups": [
                {
                    "displayName": "Claude and GPT models",
                    "buckets": [
                        antigravity_bucket("agy-week", "week", 90, future),
                        antigravity_bucket("agy-5h", "5h", 40, future),
                    ],
                },
            ]
        }
    )
    assert snapshot["week"]["usedPct"] == 90
    assert snapshot["currentSession"]["usedPct"] == 40


def test_gemini_agy_cache_reuse_carries_honest_age() -> None:
    future = datetime.fromtimestamp(time.time() + 7200, timezone.utc).isoformat().replace("+00:00", "Z")
    quota = {
        "groups": [
            {
                "displayName": "Gemini models",
                "buckets": [antigravity_bucket("gemini-week", "week", 25, future)],
            }
        ]
    }
    # 20-minute-old cache: reused, still fresh, and capturedAt must keep the
    # quota's own stamp instead of being restamped to now — restamping used to
    # launder the cache's age past codex-usage-doctor's freshness check.
    fresh = gemini_agy_snapshot(quota, cache_age_seconds=1200)
    assert fresh["capturedAt"] == fresh["antigravity"]["capturedAt"]
    assert fresh["health"]["verdict"] == "fresh"
    # 50-minute-old cache with probing unavailable: reused and still fresh
    # (the stale line sits at 60 minutes, above the 30-minute cadence).
    mid = gemini_agy_snapshot(quota, cache_age_seconds=3000)
    assert mid["capturedAt"] == mid["antigravity"]["capturedAt"]
    assert mid["health"]["verdict"] == "fresh"
    # 70-minute-old cache with probing unavailable: reused, self-reports stale.
    old = gemini_agy_snapshot(quota, cache_age_seconds=4200)
    assert old["capturedAt"] == old["antigravity"]["capturedAt"]
    assert old["health"]["verdict"] == "stale"
    # The health check itself ran now; only the data stamp carries the age.
    checked_at = datetime.fromisoformat(old["health"]["checkedAt"].replace("Z", "+00:00"))
    assert abs(time.time() - checked_at.timestamp()) < 120


AGY_QUOTA_JSON = {
    "conversation_id": "",
    "status": "SUCCESS",
    "usage": {"input_tokens": 0, "output_tokens": 0, "total_tokens": 0},
    "command": {
        "name": "usage",
        "data": {
            "groups": [
                {
                    "name": "Gemini Models",
                    "buckets": [{"id": "gemini-weekly", "window": "weekly", "remaining_fraction": 0.968451976776123, "reset_time": "2099-09-28T04:11:01Z"}],
                },
                {
                    "name": "Claude and GPT models",
                    "buckets": [{"id": "3p-weekly", "window": "weekly", "remaining_fraction": 1, "reset_time": "2099-10-03T17:35:07Z"}],
                },
            ]
        },
    },
}


def fake_agy(root: Path, mode: str) -> tuple[Path, Path]:
    """A stand-in agy that logs argv; mode ok prints quota JSON, fail exits 1,
    hang ignores SIGTERM and records its pid so the test can prove the kill."""
    calls = root / "agy-calls.log"
    quota = root / "agy-quota.json"
    quota.write_text(json.dumps(AGY_QUOTA_JSON))
    body = {
        "ok": f'cat "{quota}"\nexit 0\n',
        "fail": 'echo "error: not logged in" >&2\nexit 1\n',
        "hang": f'trap "" TERM\necho $$ > "{root}/agy-hang.pid"\nsleep 30 &\necho $! >> "{root}/agy-hang.pid"\nwait\n',
    }[mode]
    agy = root / f"agy-{mode}"
    write_executable(agy, f'#!/bin/sh\nprintf "%s\\n" "$*" >> "{calls}"\n{body}')
    return agy, calls


def test_gemini_agy_resolves_agy_from_path_without_local_bin() -> None:
    """AGY_BIN used to check only ~/.local/bin/agy. agy installed on PATH
    (or /opt/homebrew/bin, the Antigravity CLI's other common install spot)
    must be found too, with no BLOOM_AGY_BIN override and no ~/.local/bin."""
    with tempfile.TemporaryDirectory(prefix="usage-gemini-agy-path-") as raw:
        root = Path(raw)
        state = root / "state"
        agy, calls = fake_agy(root, "ok")
        path_bin = root / "path-only-bin"
        path_bin.mkdir()
        agy_on_path = path_bin / "agy"
        agy_on_path.write_text(agy.read_text())
        agy_on_path.chmod(0o755)

        env = clean_env(root, state)
        env["PATH"] = f"{path_bin}{os.pathsep}{env['PATH']}"
        env.pop("BLOOM_AGY_BIN", None)

        result = run_node(ROOT / "bin/bloom-usage-write-gemini-agy", [], env)
        assert result.returncode == 0, result.stderr or result.stdout
        assert calls.read_text().strip(), "agy on PATH was never invoked"
        snap = json.loads((state / "gemini-usage.json").read_text())
        assert snap["source"] == "antigravity cli /quota"


def test_gemini_agy_probe_reads_both_groups_and_paces_spawns() -> None:
    with tempfile.TemporaryDirectory(prefix="usage-gemini-probe-") as raw:
        root = Path(raw)
        state = root / "state"
        agy, calls = fake_agy(root, "ok")
        env = clean_env(root, state, {"BLOOM_AGY_BIN": str(agy)})
        result = run_node(ROOT / "bin/bloom-usage-write-gemini-agy", [], env)
        assert result.returncode == 0, result.stderr or result.stdout
        snap = json.loads((state / "gemini-usage.json").read_text())
        assert snap["source"] == "antigravity cli /quota"
        assert snap["health"]["verdict"] == "fresh"
        pools = {pool["id"]: pool for pool in snap["pools"]}
        assert pools["gemini"]["remainingFraction"] == 0.9685
        assert pools["claude-gpt"]["remainingFraction"] == 1
        assert snap["week"]["usedPct"] == 3.2
        argv = calls.read_text().splitlines()
        assert argv == [f"-p /quota --output-format json --print-timeout 40s --log-file {state}/agy-probe.log"]

        # Cache older than the 30-minute spawn spacing, but a probe just ran: no spawn.
        # 48 reads a day spaced 30 minutes apart cover the whole day without going stale.
        snap["antigravity"]["capturedAt"] = datetime.fromtimestamp(time.time() - 5 * 3600, timezone.utc).isoformat()
        write_json(state / "gemini-usage.json", snap)
        run_node(ROOT / "bin/bloom-usage-write-gemini-agy", [], env)
        assert len(calls.read_text().splitlines()) == 1, "second spawn inside the 30-minute spacing"
        assert "next probe after" in json.loads((state / "gemini-usage.json").read_text())["health"]["reason"]

        # --force is the attended re-read: it bypasses the spacing and is
        # counted apart, so it never spends the automatic schedule.
        run_node(ROOT / "bin/bloom-usage-write-gemini-agy", ["--force"], env)
        assert len(calls.read_text().splitlines()) == 2
        probe = json.loads((state / "gemini-agy-probe-state.json").read_text())
        assert probe["spawnsToday"] == 1 and probe["forcedToday"] == 1 and probe["lastAttemptForced"] is True

        # Both daily caps hold even when the spacing has elapsed.
        probe.update(spawnsToday=48, forcedToday=4, lastAttemptAt="2000-01-01T00:00:00Z")
        write_json(state / "gemini-agy-probe-state.json", probe)
        snap = json.loads((state / "gemini-usage.json").read_text())
        snap["antigravity"]["capturedAt"] = datetime.fromtimestamp(time.time() - 5 * 3600, timezone.utc).isoformat()
        write_json(state / "gemini-usage.json", snap)
        run_node(ROOT / "bin/bloom-usage-write-gemini-agy", [], env)
        run_node(ROOT / "bin/bloom-usage-write-gemini-agy", ["--force"], env)
        assert len(calls.read_text().splitlines()) == 2, "daily caps must stop the spawn"


def test_gemini_agy_probe_schedule_never_goes_stale() -> None:
    # Walk the default gate over two days in 5-minute steps, the way HUD
    # refreshes reach it: 48 reads a day, and no gap that ages past the
    # 60-minute stale line.
    script = r"""
const { spawnGate, localDate, SPAWN_AFTER_MS, STALE_AFTER_MS } = require(process.argv[1]);
const start = new Date(); start.setHours(0, 0, 0, 0);
let state = {}; const reads = [];
for (let t = start.getTime(); t < start.getTime() + 48 * 3600e3; t += 5 * 60e3) {
  if (reads.length && t - reads[reads.length - 1] < SPAWN_AFTER_MS) continue;
  if (!spawnGate(state, t, false).allowed) continue;
  const day = localDate(new Date(t));
  state = { day, spawnsToday: (state.day === day ? state.spawnsToday : 0) + 1, lastAttemptAt: new Date(t).toISOString(), consecutiveFailures: 0 };
  reads.push(t);
}
const gaps = reads.slice(1).map((t, i) => (t - reads[i]) / 60e3);
const perDay = {}; for (const t of reads) { const d = localDate(new Date(t)); perDay[d] = (perDay[d] || 0) + 1; }
console.log(JSON.stringify({ staleMin: STALE_AFTER_MS / 60e3, maxGap: Math.max(...gaps), perDay: Object.values(perDay), last: (start.getTime() + 48 * 3600e3 - reads[reads.length - 1]) / 60e3 }));
"""
    env = {key: value for key, value in os.environ.items() if not key.startswith("BLOOM_AGY_")}
    result = subprocess.run([NODE, "-e", script, str(ROOT / "bin/bloom-usage-write-gemini-agy")], text=True, capture_output=True, timeout=30, env=env)
    assert result.returncode == 0, result.stderr
    sim = json.loads(result.stdout)
    assert sim["perDay"] == [48, 48], sim
    assert sim["staleMin"] == 60 and sim["maxGap"] <= 60 and sim["last"] <= 60, sim


def test_gemini_agy_probe_backs_off_and_kills_its_group() -> None:
    with tempfile.TemporaryDirectory(prefix="usage-gemini-probe-fail-") as raw:
        root = Path(raw)
        state = root / "state"
        agy, calls = fake_agy(root, "fail")
        env = clean_env(root, state, {"BLOOM_AGY_BIN": str(agy)})
        run_node(ROOT / "bin/bloom-usage-write-gemini-agy", [], env)
        probe = json.loads((state / "gemini-agy-probe-state.json").read_text())
        assert probe["consecutiveFailures"] == 1 and "not logged in" in probe["lastError"]
        run_node(ROOT / "bin/bloom-usage-write-gemini-agy", [], env)
        assert len(calls.read_text().splitlines()) == 1, "failure must back off before retrying"

        # A hung agy that ignores SIGTERM is killed with its whole group.
        hang, _ = fake_agy(root, "hang")
        (state / "gemini-agy-probe-state.json").unlink()
        started = time.time()
        result = run_node(
            ROOT / "bin/bloom-usage-write-gemini-agy",
            [],
            clean_env(root, state, {"BLOOM_AGY_BIN": str(hang), "BLOOM_AGY_PROBE_TIMEOUT_MS": "1500"}),
        )
        # No cache and the probe timed out: a real failure now (see
        # test_gemini_agy_total_failure_writes_status_and_nonzero_exit).
        assert result.returncode == 1, result.stderr
        assert time.time() - started < 15
        pids = [int(line) for line in (root / "agy-hang.pid").read_text().split()]
        time.sleep(0.3)
        for pid in pids:
            try:
                os.kill(pid, 0)
                alive = True
            except ProcessLookupError:
                alive = False
            assert not alive, f"probe left pid {pid} running"
        probe = json.loads((state / "gemini-agy-probe-state.json").read_text())
        assert "timed out" in probe["lastError"]


def grok_billing_config(percent: float = 1.0) -> dict:
    return {
        "config": {
            "currentPeriod": {
                "type": "USAGE_PERIOD_TYPE_WEEKLY",
                "start": "2026-08-27T02:09:29.213841+00:00",
                "end": "2026-09-03T02:09:29.213841+00:00",
            },
            "creditUsagePercent": percent,
            "productUsage": [{"product": "GrokBuild", "usagePercent": percent}],
            "billingPeriodStart": "2026-08-27T02:09:29.213841+00:00",
            "billingPeriodEnd": "2026-09-03T02:09:29.213841+00:00",
        }
    }


def write_grok_session(home: Path, last_active_at: str, model: str = "grok-4.6") -> None:
    session_dir = (
        home
        / ".grok"
        / "sessions"
        / "%2FUsers%2Fdemo"
        / "01a04e49-02d0-7543-b7ed-dd67ec62992f"
    )
    session_dir.mkdir(parents=True)
    write_json(
        session_dir / "summary.json",
        {
            "session_summary": "Catch-Up Refactoring",
            "current_model_id": model,
            "last_active_at": last_active_at,
            "updated_at": last_active_at,
        },
    )


def grok_writer_snapshot(
    billing: dict,
    last_active_at: str,
    extra: dict[str, str] | None = None,
    prior: dict | None = None,
) -> dict:
    with tempfile.TemporaryDirectory(prefix="usage-grok-writer-") as raw:
        root = Path(raw)
        state = root / "state"
        state.mkdir()
        if prior is not None:
            write_json(state / "grok-usage.json", prior)
        write_grok_session(root, last_active_at)
        env = clean_env(
            root,
            state,
            {
                "GROK_HOME": str(root / ".grok"),
                "BLOOM_GROK_BILLING_JSON": json.dumps(billing),
                "BLOOM_GROK_MIN_REFRESH_MS": "600000",
                **(extra or {}),
            },
        )
        result = run_node(ROOT / "bin/bloom-usage-write-grok", [], env)
        assert result.returncode == 0, result.stderr or result.stdout
        return json.loads((state / "grok-usage.json").read_text())


def test_grok_writer_stamps_window_from_billing_not_idle_session() -> None:
    # Keep an explicitly idle session two days old across calendar dates.
    idle_at = datetime.fromtimestamp(time.time() - 2 * 86400, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    snap = grok_writer_snapshot(grok_billing_config(1.0), idle_at)
    assert snap["week"]["usedPct"] == 1.0
    assert snap["week"]["eventAt"] == snap["capturedAt"]
    assert snap["windows"][0]["eventAt"] == snap["capturedAt"]
    assert snap["eventAt"] == idle_at
    assert "GrokBuild" in [item["label"] for item in snap["contributors"]]
    assert snap["official"]["periodEnd"] == "2026-09-03T02:09:29.213Z"
    # The source event stays observable, but an idle run is not a session today.
    assert "session" not in (snap.get("extraUsage") or "")


def test_grok_writer_refetches_when_local_session_moves() -> None:
    first_active = "2026-08-27T04:56:54.375Z"
    later_active = "2026-08-29T16:20:00.000Z"
    prior = grok_writer_snapshot(grok_billing_config(0.0), first_active)
    assert prior["week"]["usedPct"] == 0.0
    # Same capturedAt-age would have early-returned before the localMoved gate.
    later = grok_writer_snapshot(
        grok_billing_config(1.0),
        later_active,
        prior=prior,
    )
    assert later["week"]["usedPct"] == 1.0
    assert later["eventAt"].startswith("2026-08-29T16:20:00")


def test_install_manifest_has_runtime_parity() -> None:
    makefile = (ROOT / "Makefile").read_text()
    uninstall = (ROOT / "script/uninstall.sh").read_text()
    assert "bloom-usage-write-gemini-agy" in makefile
    assert "bloom-usage-write-grok" in makefile
    assert "com.codexusagehud.grok-writer" in makefile
    assert 'bin/bloom-usage-capture.sh "$(HOME)/.claude/hooks/bloom-usage-capture.sh"' in makefile
    assert "bloom-usage-write-gemini-agy" in uninstall
    assert "bloom-usage-write-grok" in uninstall
    assert "com.codexusagehud.grok-writer" in uninstall
    assert 'CAPTURE_HOOK="$HOME/.claude/hooks/bloom-usage-capture.sh"' in uninstall
    assert 'cmp -s "$ROOT_DIR/bin/bloom-usage-capture.sh" "$CAPTURE_HOOK"' in uninstall
    assert 'GUARD_HOOK="$HOME/.claude/hooks/bloom-budget-guard.js"' in uninstall
    assert 'if [ -f "$GUARD_HOOK" ] && cmp -s "$ROOT_DIR/hooks/bloom-budget-guard.js" "$GUARD_HOOK"; then\n  rm -f "$GUARD_HOOK"\nfi' in uninstall
    assert 'echo "Usage HUD uninstalled. State preserved unless REMOVE_STATE=1 was set."' in uninstall


TESTS = [
    test_codex_account_poll_refresh_and_failure_age,
    test_codex_classifies_and_dual_writes,
    test_codex_preserves_newer_official_account_quota,
    test_codex_nonlive_official_short_preserves_live_local_limit,
    test_codex_live_official_short_remains_preferred,
    test_codex_expired_official_week_keeps_recorded_percentage,
    test_claude_writer_reconciles_health,
    test_claude_fetch_rejects_nonzero_and_cleans_fresh,
    test_claude_fetch_reaps_clean_exit_before_signaling,
    test_gemini_has_no_legacy_oauth_fetcher,
    test_gemini_agy_windows_match_v1_week_and_session,
    test_gemini_agy_single_bucket_quota,
    test_gemini_agy_falls_back_to_fullest_bucket_when_no_gemini_group,
    test_gemini_agy_total_failure_writes_status_and_nonzero_exit,
    test_gemini_agy_cache_reuse_carries_honest_age,
    test_gemini_agy_resolves_agy_from_path_without_local_bin,
    test_gemini_agy_probe_reads_both_groups_and_paces_spawns,
    test_gemini_agy_probe_schedule_never_goes_stale,
    test_gemini_agy_probe_backs_off_and_kills_its_group,
    test_grok_writer_stamps_window_from_billing_not_idle_session,
    test_grok_writer_refetches_when_local_session_moves,
    test_install_manifest_has_runtime_parity,
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
