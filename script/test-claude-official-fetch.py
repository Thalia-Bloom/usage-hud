#!/usr/bin/env python3
"""Hermetic tests for bin/bloom-usage-fetch-claude-official.

Covers the --mode api path (credential resolution, the usage-endpoint
fixtures, the re-read-before-write merge) and the PTY-mode hardening (the
SIGTERM-abort path, the all-zero-without-Fable settle-guard rejection).

No network, no Keychain, no launchd. The one scenario that would otherwise
touch the Keychain (no credential found) monkeypatches subprocess.run on the
imported module instead of invoking the real `security` binary.
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parent.parent
SCRIPT_PATH = ROOT / "bin/bloom-usage-fetch-claude-official"
FIXTURE_PATH = ROOT / "fixtures/claude-oauth-usage-sample.json"

ISO_MS_Z = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z")

METERED_KEYS = {
    "XAI_API_KEY",
    "GROK_API_KEY",
    "OPENAI_API_KEY",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "GOOGLE_API_KEY",
    "GEMINI_API_KEY",
    "GOOGLE_APPLICATION_CREDENTIALS",
    "CLAUDE_CODE_OAUTH_TOKEN",
}


def clean_env(home: Path, state: Path, extra: dict[str, str] | None = None) -> dict[str, str]:
    env = {key: value for key, value in os.environ.items() if key not in METERED_KEYS}
    env.update(
        {
            "HOME": str(home),
            "CODEX_USAGE_HUD_STATE_DIR": str(state),
            "BLOOM_USAGE_DIR": str(state),
            "PATH": "/usr/bin:/bin",
        }
    )
    if extra:
        env.update(extra)
    return env


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n")


def run_fetch(args: list[str], env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT_PATH), *args],
        text=True,
        capture_output=True,
        timeout=30,
        env=env,
        check=False,
    )


def load_module():
    """Import the script as a module, the way the shared harness does, so
    tests can call internal functions and swap module-level globals without
    a subprocess round trip.
    """
    sys.dont_write_bytecode = True
    loader = importlib.machinery.SourceFileLoader("usage_claude_fetch_api_contract", str(SCRIPT_PATH))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def configure_module(module, state: Path) -> None:
    module.STATE_DIR = state
    module.USAGE_PATH = state / "claude-usage.json"
    module.CAPTURE_PATH = state / "claude-official-usage.txt"
    module.OFFICIAL_STATUS_PATH = state / "claude-official-status.json"
    module.RATE_LIMIT_COOLDOWN_PATH = state / ".claude-official-rate-limited-until"


def local_label(raw_resets_at: str, is_5h: bool) -> str:
    """Compute the expected reset label the same way the script does, so the
    assertion tracks the formatting rule (h:mm a / MMM d h a in local time)
    instead of a wall-clock string baked to one TZ database snapshot.
    """
    text = raw_resets_at.replace("Z", "+00:00")
    # The script rounds the endpoint's 22:59:59.8-style resets to the minute.
    exact = datetime.fromisoformat(text).astimezone(timezone.utc)
    rounded = (exact + timedelta(seconds=30)).replace(second=0, microsecond=0)
    local_dt = rounded.astimezone()
    hour = local_dt.hour % 12 or 12
    meridiem = "AM" if local_dt.hour < 12 else "PM"
    if is_5h:
        return f"{hour}:{local_dt.minute:02d} {meridiem}"
    return f"{local_dt.strftime('%b')} {local_dt.day} {hour} {meridiem}"


# ---------------------------------------------------------------------------
# API mode
# ---------------------------------------------------------------------------


def test_api_mode_parses_fixture_into_expected_shape() -> None:
    fixture = json.loads(FIXTURE_PATH.read_text())
    session_reset = next(item["resets_at"] for item in fixture["limits"] if item["kind"] == "session")
    week_reset = next(item["resets_at"] for item in fixture["limits"] if item["kind"] == "weekly_all")
    expected_5h_label = local_label(session_reset, is_5h=True)
    expected_week_label = local_label(week_reset, is_5h=False)
    # Fixed against the fixture's actual clock values (data contract examples,
    # not this fixture) so a formatting regression trips even if TZ handling
    # elsewhere silently degrades to the wrong rule.
    assert expected_5h_label == "2:20 AM"
    assert expected_week_label == "Sep 9 4 PM"

    with tempfile.TemporaryDirectory(prefix="usage-claude-api-ok-") as raw_dir:
        root = Path(raw_dir)
        state = root / "state"
        env = clean_env(
            root,
            state,
            {
                "BLOOM_CLAUDE_USAGE_MODE": "api",
                "CLAUDE_CODE_OAUTH_TOKEN": "test-token-not-a-secret",
                "BLOOM_CLAUDE_USAGE_API_FIXTURE": str(FIXTURE_PATH),
                "TZ": "America/Los_Angeles",
            },
        )
        result = run_fetch([], env)
        assert result.returncode == 0, result.stderr or result.stdout

        snapshot = json.loads((state / "claude-usage.json").read_text())
        assert snapshot["currentSession"]["usedPct"] == 40
        assert snapshot["week"]["usedPct"] == 9
        assert snapshot["weekFable"]["usedPct"] == 8
        assert snapshot["source"] == "claude-code-official-usage-api"
        assert snapshot["sourceKind"] == "official_api"
        assert snapshot["confidence"] == "official"
        assert snapshot["confidenceNote"]
        assert snapshot["health"]["verdict"] == "fresh"

        # eventAt tracks capturedAt on every window (so the panel can age each
        # window independently even though this fetch stamped them together).
        assert snapshot["currentSession"]["eventAt"] == snapshot["capturedAt"]
        assert snapshot["week"]["eventAt"] == snapshot["capturedAt"]
        assert snapshot["weekFable"]["eventAt"] == snapshot["capturedAt"]
        assert snapshot["weekFable"]["capturedAt"] == snapshot["capturedAt"]

        # Exactly three fractional digits and a trailing Z, even though the
        # fixture's resets_at carries six digits and a numeric offset.
        assert ISO_MS_Z.fullmatch(snapshot["capturedAt"])
        assert ISO_MS_Z.fullmatch(snapshot["currentSession"]["resetAt"])
        assert ISO_MS_Z.fullmatch(snapshot["week"]["resetAt"])
        assert ISO_MS_Z.fullmatch(snapshot["weekFable"]["resetAt"])

        assert snapshot["currentSession"]["resetLabel"] == expected_5h_label
        assert snapshot["week"]["resetLabel"] == expected_week_label
        assert snapshot["weekFable"]["resetLabel"] == expected_week_label

        assert {item["name"] for item in snapshot["skills"]} == {"Limit · Fable weekly"}
        assert snapshot["officialUsage"]["source"] == "api"
        assert snapshot["officialUsage"]["extraUsage"] == {
            "enabled": False,
            "usedCredits": 0.0,
            "monthlyLimit": None,
        }

        status = json.loads((state / "claude-official-status.json").read_text())
        assert status["status"] == "ok"
        assert status["exitCode"] == 0
        assert ISO_MS_Z.fullmatch(status["updatedAt"])


def test_api_mode_other_weekly_scoped_names_become_skills() -> None:
    with tempfile.TemporaryDirectory(prefix="usage-claude-api-scoped-") as raw_dir:
        root = Path(raw_dir)
        state = root / "state"
        fixture_path = root / "fixture.json"
        write_json(
            fixture_path,
            {
                "limits": [
                    {"kind": "session", "percent": 5, "resets_at": "2026-09-03T09:19:59.000000+00:00", "scope": None},
                    {"kind": "weekly_all", "percent": 6, "resets_at": "2026-09-09T22:59:59.000000+00:00", "scope": None},
                    {
                        "kind": "weekly_scoped",
                        "percent": 12,
                        "resets_at": "2026-09-09T22:59:59.000000+00:00",
                        "scope": {"model": {"display_name": "Sonnet"}},
                    },
                    {
                        "kind": "weekly_scoped",
                        "percent": 3,
                        "resets_at": "2026-09-09T22:59:59.000000+00:00",
                        "scope": {"model": {"display_name": "Fable"}},
                    },
                ]
            },
        )
        env = clean_env(
            root,
            state,
            {
                "CLAUDE_CODE_OAUTH_TOKEN": "test-token",
                "BLOOM_CLAUDE_USAGE_API_FIXTURE": str(fixture_path),
            },
        )
        result = run_fetch(["--mode", "api"], env)
        assert result.returncode == 0, result.stderr or result.stdout
        snapshot = json.loads((state / "claude-usage.json").read_text())
        assert snapshot["weekFable"]["usedPct"] == 3
        names = {item["name"]: item["percent"] for item in snapshot["skills"]}
        assert names == {"Limit · Fable weekly": 3, "Limit · Sonnet weekly": 12}


def test_api_mode_authoritative_response_drops_missing_fable() -> None:
    """A successful API response is authoritative for the whole Claude window
    set: a fixture with no Fable scoped limit must delete a previously
    captured weekFable and its skill chip, and mark it expired, rather than
    letting {**existing, **official} keep the stale reading alive under this
    fetch's fresh stamp.
    """
    with tempfile.TemporaryDirectory(prefix="usage-claude-api-authoritative-drop-") as raw_dir:
        root = Path(raw_dir)
        state = root / "state"
        state.mkdir(parents=True)
        write_json(
            state / "claude-usage.json",
            {
                "schemaVersion": 1,
                "provider": "claude",
                "updatedAt": "2026-08-01T00:00:00.000Z",
                "weekFable": {"label": "Fable weekly", "usedPct": 98, "resetAt": None, "resetLabel": None},
                "skills": [{"name": "Limit · Fable weekly", "percent": 98}],
            },
        )
        fixture_path = root / "fixture.json"
        write_json(
            fixture_path,
            {
                "limits": [
                    {"kind": "session", "percent": 5, "resets_at": "2026-09-03T09:19:59.000000+00:00", "scope": None},
                    {"kind": "weekly_all", "percent": 6, "resets_at": "2026-09-09T22:59:59.000000+00:00", "scope": None},
                ]
            },
        )
        env = clean_env(
            root,
            state,
            {"CLAUDE_CODE_OAUTH_TOKEN": "test-token", "BLOOM_CLAUDE_USAGE_API_FIXTURE": str(fixture_path)},
        )
        result = run_fetch(["--mode", "api"], env)
        assert result.returncode == 0, result.stderr or result.stdout

        snapshot = json.loads((state / "claude-usage.json").read_text())
        assert "weekFable" not in snapshot
        assert all(item.get("name") != "Limit · Fable weekly" for item in snapshot.get("skills") or [])
        assert snapshot.get("rateLimitExpired") == ["weekFable"]


def test_api_mode_authoritative_response_clears_stale_fable_expiry() -> None:
    """The inverse of the drop case: once a response carries all three
    windows again, a leftover "weekFable" expiry marker from a prior gap must
    be cleared, not linger forever after the reading comes back.
    """
    with tempfile.TemporaryDirectory(prefix="usage-claude-api-authoritative-restore-") as raw_dir:
        root = Path(raw_dir)
        state = root / "state"
        state.mkdir(parents=True)
        write_json(
            state / "claude-usage.json",
            {
                "schemaVersion": 1,
                "provider": "claude",
                "updatedAt": "2026-08-01T00:00:00.000Z",
                "rateLimitExpired": ["weekFable", "Fable weekly captured before weekly reset"],
                "rateLimitExpiredAt": "2026-08-01T00:00:00.000Z",
            },
        )
        env = clean_env(
            root,
            state,
            {"CLAUDE_CODE_OAUTH_TOKEN": "test-token", "BLOOM_CLAUDE_USAGE_API_FIXTURE": str(FIXTURE_PATH)},
        )
        result = run_fetch(["--mode", "api"], env)
        assert result.returncode == 0, result.stderr or result.stdout

        snapshot = json.loads((state / "claude-usage.json").read_text())
        assert snapshot["weekFable"]["usedPct"] == 8
        assert "weekFable" not in (snapshot.get("rateLimitExpired") or [])


def test_api_mode_falls_back_to_top_level_utilization() -> None:
    with tempfile.TemporaryDirectory(prefix="usage-claude-api-fallback-") as raw_dir:
        root = Path(raw_dir)
        state = root / "state"
        fixture_path = root / "fixture.json"
        write_json(
            fixture_path,
            {
                "five_hour": {"utilization": 15, "resets_at": "2026-09-03T09:19:59.000000+00:00"},
                "seven_day": {"utilization": 22, "resets_at": "2026-09-09T22:59:59.000000+00:00"},
            },
        )
        env = clean_env(
            root,
            state,
            {"CLAUDE_CODE_OAUTH_TOKEN": "test-token", "BLOOM_CLAUDE_USAGE_API_FIXTURE": str(fixture_path)},
        )
        result = run_fetch(["--mode", "api"], env)
        assert result.returncode == 0, result.stderr or result.stdout
        snapshot = json.loads((state / "claude-usage.json").read_text())
        assert snapshot["currentSession"]["usedPct"] == 15
        assert snapshot["week"]["usedPct"] == 22
        assert "weekFable" not in snapshot
        assert "skills" not in snapshot or snapshot["skills"] == []


def test_api_mode_clears_stale_pty_contributors() -> None:
    """A month-old PTY-mode "what's contributing" list must not survive an
    API-mode merge under this fetch's fresh capturedAt stamp: the endpoint
    carries no driver breakdown, so build_api_payload sets contributors to
    an explicit empty list (not merely omitting the key) so merge_snapshot's
    dict spread actually clears the stale list instead of leaving it in
    place because official never mentioned it.
    """
    with tempfile.TemporaryDirectory(prefix="usage-claude-api-stale-contrib-") as raw_dir:
        root = Path(raw_dir)
        state = root / "state"
        state.mkdir(parents=True)
        write_json(
            state / "claude-usage.json",
            {
                "schemaVersion": 1,
                "provider": "claude",
                "updatedAt": "2026-08-01T00:00:00.000Z",
                "contributors": [
                    {"percent": 61, "label": "at >150k context", "note": "old PTY-mode reading"}
                ],
            },
        )
        env = clean_env(
            root,
            state,
            {"CLAUDE_CODE_OAUTH_TOKEN": "test-token", "BLOOM_CLAUDE_USAGE_API_FIXTURE": str(FIXTURE_PATH)},
        )
        result = run_fetch(["--mode", "api"], env)
        assert result.returncode == 0, result.stderr or result.stdout

        snapshot = json.loads((state / "claude-usage.json").read_text())
        assert snapshot["contributors"] == []
        assert snapshot["officialUsage"]["contributorsNote"] == (
            "Driver breakdown is not part of the usage endpoint; Claude Code "
            "computes it from a local transcript scan."
        )


def test_api_mode_unparsed_when_nothing_usable() -> None:
    with tempfile.TemporaryDirectory(prefix="usage-claude-api-unparsed-") as raw_dir:
        root = Path(raw_dir)
        state = root / "state"
        state.mkdir(parents=True)
        usage_path = state / "claude-usage.json"
        write_json(usage_path, {"marker": "untouched"})
        fixture_path = root / "fixture.json"
        write_json(fixture_path, {"limits": [], "spend": {}})
        env = clean_env(
            root,
            state,
            {"CLAUDE_CODE_OAUTH_TOKEN": "test-token", "BLOOM_CLAUDE_USAGE_API_FIXTURE": str(fixture_path)},
        )
        result = run_fetch(["--mode", "api"], env)
        assert result.returncode == 1
        assert json.loads(usage_path.read_text())["marker"] == "untouched"
        status = json.loads((state / "claude-official-status.json").read_text())
        assert status["status"] == "unparsed"
        assert "retryAt" in status
        # Routed through the same failure cooldown as unauthorized/
        # no_credential/offline: a response shape change is a durable
        # failure, not a transient one worth retrying on an unthrottled loop.
        assert_failure_cooldown(state)


def test_api_mode_rate_limited_writes_cooldown() -> None:
    with tempfile.TemporaryDirectory(prefix="usage-claude-api-429-") as raw_dir:
        root = Path(raw_dir)
        state = root / "state"
        env = clean_env(
            root,
            state,
            {
                "CLAUDE_CODE_OAUTH_TOKEN": "test-token",
                "BLOOM_CLAUDE_USAGE_API_FIXTURE_STATUS": "429",
                "BLOOM_CLAUDE_USAGE_API_FIXTURE_RETRY_AFTER": "42",
            },
        )
        result = run_fetch(["--mode", "api"], env)
        assert result.returncode == 1
        status = json.loads((state / "claude-official-status.json").read_text())
        assert status["status"] == "rate_limited"
        assert "retryAt" in status
        cooldown_file = state / ".claude-official-rate-limited-until"
        assert cooldown_file.exists()
        retry_epoch = int(cooldown_file.read_text().strip())
        # ~42s out, generous slack for test overhead; well under the 300s default.
        assert 0 < retry_epoch - int(time.time()) <= 90
        assert not (state / "claude-usage.json").exists()


def assert_failure_cooldown(state: Path, expected_seconds: int = 600, slack: int = 60) -> None:
    """A durable failure (unauthorized / no_credential / offline) must set the
    same cooldown file the rate-limited path uses, at the longer
    API_FAILURE_COOLDOWN_SECONDS interval, so a stale token or a dead
    Keychain entry does not retry every ~120s forever.
    """
    cooldown_file = state / ".claude-official-rate-limited-until"
    assert cooldown_file.exists()
    retry_epoch = int(cooldown_file.read_text().strip())
    assert abs((retry_epoch - int(time.time())) - expected_seconds) <= slack


def test_api_mode_unauthorized_no_cooldown() -> None:
    """Name predates the fix: a revoked/expired token is a durable failure,
    not a transient rate limit, so it now sets the 600s failure cooldown
    (BLOOM_CLAUDE_USAGE_FAILURE_COOLDOWN_SECONDS) instead of retrying on the
    next unthrottled invocation.
    """
    with tempfile.TemporaryDirectory(prefix="usage-claude-api-401-") as raw_dir:
        root = Path(raw_dir)
        state = root / "state"
        env = clean_env(
            root,
            state,
            {"CLAUDE_CODE_OAUTH_TOKEN": "test-token", "BLOOM_CLAUDE_USAGE_API_FIXTURE_STATUS": "401"},
        )
        result = run_fetch(["--mode", "api"], env)
        assert result.returncode == 1
        status = json.loads((state / "claude-official-status.json").read_text())
        assert status["status"] == "unauthorized"
        assert "retryAt" in status
        assert_failure_cooldown(state)
        assert not (state / "claude-usage.json").exists()


def test_api_mode_offline_on_network_error() -> None:
    with tempfile.TemporaryDirectory(prefix="usage-claude-api-offline-") as raw_dir:
        root = Path(raw_dir)
        state = root / "state"
        env = clean_env(
            root,
            state,
            {"CLAUDE_CODE_OAUTH_TOKEN": "test-token", "BLOOM_CLAUDE_USAGE_API_FIXTURE_STATUS": "offline"},
        )
        result = run_fetch(["--mode", "api"], env)
        assert result.returncode == 1
        status = json.loads((state / "claude-official-status.json").read_text())
        assert status["status"] == "offline"
        assert "retryAt" in status
        assert_failure_cooldown(state)
        assert not (state / "claude-usage.json").exists()


def test_api_mode_no_credential_writes_only_status_no_keychain() -> None:
    """No CLAUDE_CODE_OAUTH_TOKEN and no Keychain entry: writes status only.

    Runs in-process with subprocess.run monkeypatched so this never invokes
    the real `security` binary, per the no-Keychain-in-tests rule.
    """
    module = load_module()
    with tempfile.TemporaryDirectory(prefix="usage-claude-api-nocred-") as raw_dir:
        state = Path(raw_dir)
        configure_module(module, state)
        # A signed-in Claude Code home exists but holds no usable credential; never look at the real ~/.claude.
        (state / ".claude").mkdir()
        module.HOME = state
        write_json(module.USAGE_PATH, {"schemaVersion": 1, "provider": "claude", "marker": "untouched"})

        def fake_run(*_args, **_kwargs):
            return subprocess.CompletedProcess(["security"], returncode=44, stdout="", stderr="not found")

        original_run = module.subprocess.run
        had_token = "CLAUDE_CODE_OAUTH_TOKEN" in os.environ
        original_token = os.environ.pop("CLAUDE_CODE_OAUTH_TOKEN", None)
        module.subprocess.run = fake_run
        try:
            result = module.run_api_mode()
        finally:
            module.subprocess.run = original_run
            if had_token:
                os.environ["CLAUDE_CODE_OAUTH_TOKEN"] = original_token  # type: ignore[assignment]

        assert result == 1
        assert json.loads(module.USAGE_PATH.read_text())["marker"] == "untouched"
        status = json.loads(module.OFFICIAL_STATUS_PATH.read_text())
        assert status["status"] == "no_credential"
        assert "sign in" in status["message"]
        assert status["exitCode"] == 0
        assert "retryAt" in status
        assert_failure_cooldown(state)


def _run_with_keychain(module, state: Path, expires_ms: int, outcome: dict | None, calls: list) -> int:
    """Run api mode with a fake Keychain item (never the real `security`)
    whose access token expires at `expires_ms`; record endpoint calls."""
    (state / ".claude").mkdir(exist_ok=True)
    module.HOME = state
    value = json.dumps({"claudeAiOauth": {"accessToken": "fake-test-token", "expiresAt": expires_ms}})

    def fake_run(*_args, **_kwargs):
        return subprocess.CompletedProcess(["security"], returncode=0, stdout=value, stderr="")

    def fake_fetch(token):
        calls.append(token)
        return outcome or {"kind": "offline", "detail": "test"}

    original_run, original_fetch = module.subprocess.run, module.fetch_api_usage
    original_token = os.environ.pop("CLAUDE_CODE_OAUTH_TOKEN", None)
    module.subprocess.run, module.fetch_api_usage = fake_run, fake_fetch
    try:
        return module.run_api_mode()
    finally:
        module.subprocess.run, module.fetch_api_usage = original_run, original_fetch
        if original_token is not None:
            os.environ["CLAUDE_CODE_OAUTH_TOKEN"] = original_token


def test_api_mode_expired_token_is_never_sent_and_recovers_on_renewal() -> None:
    """Claude Code's access token lives ~8h and only Claude Code renews it.
    An expired token must not reach the endpoint (401s there earned hour-long
    429s), must say so in plain words, must not start a timed cooldown, and
    the first run after Claude Code renews it must fetch at once."""
    module = load_module()
    with tempfile.TemporaryDirectory(prefix="usage-claude-api-expired-") as raw_dir:
        state = Path(raw_dir)
        configure_module(module, state)
        calls: list = []
        past = int((time.time() - 3600) * 1000)
        assert _run_with_keychain(module, state, past, None, calls) == 1
        assert calls == []
        status = json.loads(module.OFFICIAL_STATUS_PATH.read_text())
        assert status["status"] == "token_expired"
        assert "Open Claude Code once" in status["message"]
        assert "retryAt" not in status
        assert not (state / ".claude-official-rate-limited-until").exists()
        # Still expired a minute later: still no call.
        _run_with_keychain(module, state, past, None, calls)
        assert calls == []
        # Claude Code ran and renewed the token: fetched on the next run.
        future = int((time.time() + 8 * 3600) * 1000)
        _run_with_keychain(module, state, future, None, calls)
        assert len(calls) == 1


def test_api_mode_refused_token_is_tried_once_per_credential() -> None:
    """A 401 with an unexpired token is a real sign-out: tried once, then not
    again until the Keychain holds a different credential."""
    module = load_module()
    with tempfile.TemporaryDirectory(prefix="usage-claude-api-refused-") as raw_dir:
        state = Path(raw_dir)
        configure_module(module, state)
        calls: list = []
        first = int((time.time() + 3600) * 1000)
        assert _run_with_keychain(module, state, first, {"kind": "unauthorized"}, calls) == 1
        status = json.loads(module.OFFICIAL_STATUS_PATH.read_text())
        assert status["status"] == "unauthorized"
        assert status["credentialStamp"] == str(first)
        assert not (state / ".claude-official-rate-limited-until").exists()
        _run_with_keychain(module, state, first, {"kind": "unauthorized"}, calls)
        assert len(calls) == 1, "same refused credential must not be sent again"
        _run_with_keychain(module, state, first + 1000, {"kind": "unauthorized"}, calls)
        assert len(calls) == 2, "a new credential is tried at once"


def test_merge_and_write_keeps_concurrent_tap_write() -> None:
    """The statusline tap can re-stamp claude-usage.json while the fetch is
    in flight. merge_and_write must notice the file moved since its first
    read and fold the official reading onto the fresh copy instead of
    clobbering the tap's write.
    """
    module = load_module()
    with tempfile.TemporaryDirectory(prefix="usage-claude-api-merge-race-") as raw_dir:
        state = Path(raw_dir)
        configure_module(module, state)

        stale = {
            "schemaVersion": 1,
            "provider": "claude",
            "updatedAt": "2020-01-01T00:00:00.000Z",
            "tracker": {"marker": "stale-tap"},
        }
        fresh_tap = {
            "schemaVersion": 1,
            "provider": "claude",
            "updatedAt": "2020-01-01T00:05:00.000Z",
            "tracker": {"marker": "fresh-tap-mid-run"},
        }
        write_json(module.USAGE_PATH, stale)

        reads = {"count": 0}
        real_read_json = module.read_json

        def scripted_read_json(path):
            if path != module.USAGE_PATH:
                return real_read_json(path)
            reads["count"] += 1
            # First read (merge_and_write's initial snapshot) sees the stale
            # copy; every read after that sees the tap's write landing mid-run.
            return dict(stale) if reads["count"] == 1 else dict(fresh_tap)

        module.read_json = scripted_read_json
        try:
            official = {
                "schemaVersion": 1,
                "provider": "claude",
                "source": "claude-code-official-usage-api",
                "currentSession": {"label": "5-hour limit", "usedPct": 40, "resetAt": None, "resetLabel": None, "eventAt": "now"},
                "skills": [],
            }
            merged = module.merge_and_write(official)
        finally:
            module.read_json = real_read_json

        assert reads["count"] >= 2
        assert merged["tracker"]["marker"] == "fresh-tap-mid-run"
        assert merged["currentSession"]["usedPct"] == 40
        on_disk = json.loads(module.USAGE_PATH.read_text())
        assert on_disk["tracker"]["marker"] == "fresh-tap-mid-run"
        assert on_disk["currentSession"]["usedPct"] == 40


def test_merge_snapshot_official_replaces_older_higher_reading() -> None:
    """A mid-window account reset drops usage without moving resets_at. The
    official reading is the truth as of its capture: an existing reading that
    is higher but OLDER than the official capture is replaced (the sticky 99%
    weekly bar on 2026-10-04 after the endpoint said 2%).
    """
    module = load_module()
    existing = {
        "schemaVersion": 1,
        "provider": "claude",
        "week": {
            "label": "Current week (all models)",
            "usedPct": 99,
            "resetAt": "2026-10-07T23:00:00.000Z",
            "eventAt": "2026-10-04T20:44:23.811Z",
            "source": "statusline",
        },
        "currentSession": {
            "label": "Current session",
            "usedPct": 42,
            "resetAt": "2026-10-05T01:40:00.000Z",
            "eventAt": "2026-10-04T20:44:23.811Z",
            "source": "statusline",
        },
    }
    official = {
        "schemaVersion": 1,
        "provider": "claude",
        "source": "claude-code-official-usage-api",
        "week": {
            "label": "Current week (all models)",
            "usedPct": 2,
            "resetAt": "2026-10-07T23:00:00.068Z",  # same minute, reset mid-window
            "eventAt": "2026-10-04T20:55:43.700Z",
        },
        "currentSession": {
            "label": "Current session",
            "usedPct": 42,
            "resetAt": "2026-10-05T01:40:00.068Z",
            "eventAt": "2026-10-04T20:55:43.700Z",
        },
        "skills": [],
    }
    merged = module.merge_snapshot(existing, official)
    assert merged["week"]["usedPct"] == 2
    assert merged["week"]["eventAt"] == "2026-10-04T20:55:43.700Z"
    assert merged["week"]["source"] == "official"
    assert merged["currentSession"]["usedPct"] == 42
    assert merged["currentSession"]["source"] == "official"


def test_merge_snapshot_keeps_higher_reading_observed_after_official_capture() -> None:
    """Usage is monotonic within one window: a statusline reading that is
    higher AND newer than the official capture means usage grew between the
    fetch and the merge, so it is kept with its own eventAt/source.
    """
    module = load_module()
    existing = {
        "schemaVersion": 1,
        "provider": "claude",
        "week": {
            "label": "Current week (all models)",
            "usedPct": 15,
            "resetAt": "2026-09-30T23:00:00.000Z",
            "eventAt": "2026-09-26T21:55:00.000Z",
            "source": "statusline",
        },
    }
    official = {
        "schemaVersion": 1,
        "provider": "claude",
        "source": "claude-code-official-usage-api",
        "week": {
            "label": "Current week (all models)",
            "usedPct": 14,
            "resetAt": "2026-09-30T23:00:30.000Z",  # same minute
            "eventAt": "2026-09-26T21:54:00.000Z",  # captured before the tap
        },
        "skills": [],
    }
    merged = module.merge_snapshot(existing, official)
    assert merged["week"]["usedPct"] == 15
    assert merged["week"]["eventAt"] == "2026-09-26T21:55:00.000Z"
    assert merged["week"]["source"] == "statusline"


def test_merge_snapshot_accepts_new_window_on_different_reset() -> None:
    """A different (later) resetAt is a new window, so the official reading
    wins outright even though its usedPct is numerically lower."""
    module = load_module()
    existing = {
        "week": {
            "label": "Current week (all models)",
            "usedPct": 98,
            "resetAt": "2026-09-23T23:00:00.000Z",
            "eventAt": "2026-09-23T20:00:00.000Z",
        },
    }
    official = {
        "schemaVersion": 1,
        "provider": "claude",
        "week": {
            "label": "Current week (all models)",
            "usedPct": 2,
            "resetAt": "2026-09-30T23:00:00.000Z",  # rolled over to a new window
            "eventAt": "2026-09-26T21:54:00.000Z",
        },
    }
    merged = module.merge_snapshot(existing, official)
    assert merged["week"]["usedPct"] == 2
    assert merged["week"]["source"] == "official"


def test_merge_snapshot_drops_dead_official_checked_at() -> None:
    """officialCheckedAt is a dead field nothing reads; every merge must
    drop it instead of letting it survive forever from a stale write."""
    module = load_module()
    existing = {"provider": "claude", "officialCheckedAt": "2026-08-07T06:17:17.441041Z"}
    official = {"schemaVersion": 1, "provider": "claude", "source": "claude-code-official-usage-api"}
    merged = module.merge_snapshot(existing, official)
    assert "officialCheckedAt" not in merged


def test_sigterm_before_credential_check_aborts_api_mode() -> None:
    """A SIGTERM landing while resolve_credential() is still running (a slow
    Keychain lookup) must abort api mode before the network call, the same
    way the PTY read loop aborts before /usage settles: honest "aborted"
    status, no snapshot write, no fetch attempted.
    """
    module = load_module()
    with tempfile.TemporaryDirectory(prefix="usage-claude-api-sigterm-early-") as raw_dir:
        state = Path(raw_dir)
        configure_module(module, state)
        write_json(module.USAGE_PATH, {"schemaVersion": 1, "provider": "claude", "marker": "keep"})

        fetch_calls = {"count": 0}
        original_fetch = module.fetch_api_usage

        def counting_fetch(token):
            fetch_calls["count"] += 1
            return original_fetch(token)

        module.fetch_api_usage = counting_fetch
        module._terminate_requested = True
        had_token = "CLAUDE_CODE_OAUTH_TOKEN" in os.environ
        original_token = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN")
        os.environ["CLAUDE_CODE_OAUTH_TOKEN"] = "test-token"
        try:
            result = module.run_api_mode()
        finally:
            module.fetch_api_usage = original_fetch
            module._terminate_requested = False
            if had_token:
                os.environ["CLAUDE_CODE_OAUTH_TOKEN"] = original_token  # type: ignore[assignment]
            else:
                os.environ.pop("CLAUDE_CODE_OAUTH_TOKEN", None)

        assert result == 1
        assert fetch_calls["count"] == 0
        assert json.loads(module.USAGE_PATH.read_text())["marker"] == "keep"
        status = json.loads(module.OFFICIAL_STATUS_PATH.read_text())
        assert status["status"] == "aborted"
        assert "before it completed" in status["message"]
        # Routed through the same failure cooldown as unauthorized/
        # no_credential/offline/unparsed: a caller whose own timeout is set
        # too tight must not retry this on an unthrottled loop.
        assert "retryAt" in status
        assert_failure_cooldown(state)


def test_sigterm_after_fetch_aborts_before_merge() -> None:
    """A SIGTERM landing after fetch_api_usage() returns (a slow-to-cancel
    urllib call) must abort before build_api_payload/merge_and_write run,
    even though the fetch itself succeeded.
    """
    module = load_module()
    fixture = json.loads(FIXTURE_PATH.read_text())
    with tempfile.TemporaryDirectory(prefix="usage-claude-api-sigterm-late-") as raw_dir:
        state = Path(raw_dir)
        configure_module(module, state)
        write_json(module.USAGE_PATH, {"schemaVersion": 1, "provider": "claude", "marker": "keep"})

        def fetch_then_terminate(_token):
            module._terminate_requested = True
            return {"kind": "ok", "body": fixture}

        original_fetch = module.fetch_api_usage
        module.fetch_api_usage = fetch_then_terminate
        had_token = "CLAUDE_CODE_OAUTH_TOKEN" in os.environ
        original_token = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN")
        os.environ["CLAUDE_CODE_OAUTH_TOKEN"] = "test-token"
        try:
            result = module.run_api_mode()
        finally:
            module.fetch_api_usage = original_fetch
            module._terminate_requested = False
            if had_token:
                os.environ["CLAUDE_CODE_OAUTH_TOKEN"] = original_token  # type: ignore[assignment]
            else:
                os.environ.pop("CLAUDE_CODE_OAUTH_TOKEN", None)

        assert result == 1
        assert json.loads(module.USAGE_PATH.read_text())["marker"] == "keep"
        status = json.loads(module.OFFICIAL_STATUS_PATH.read_text())
        assert status["status"] == "aborted"
        assert "retryAt" in status
        assert_failure_cooldown(state)


# ---------------------------------------------------------------------------
# PTY mode hardening
# ---------------------------------------------------------------------------


def test_sigterm_flag_writes_aborted_without_snapshot() -> None:
    module = load_module()
    with tempfile.TemporaryDirectory(prefix="usage-claude-pty-aborted-") as raw_dir:
        state = Path(raw_dir)
        configure_module(module, state)
        write_json(module.USAGE_PATH, {"schemaVersion": 1, "provider": "claude", "marker": "keep"})

        captured = datetime.now(timezone.utc)
        result = module.process_usage("Current session\n17% used\n", 0, captured, terminated=True)

        assert result == 1
        assert json.loads(module.USAGE_PATH.read_text())["marker"] == "keep"
        status = json.loads(module.OFFICIAL_STATUS_PATH.read_text())
        assert status["status"] == "aborted"
        assert "settled" in status["message"]

        # request_termination sets the module-level flag the read loop checks,
        # without raising, so process_usage still gets to run afterward.
        assert module._terminate_requested is False
        module.request_termination(15, None)
        assert module._terminate_requested is True


def test_pty_settle_guard_rejects_all_zero_panel_without_fable() -> None:
    module = load_module()
    with tempfile.TemporaryDirectory(prefix="usage-claude-pty-unsettled-") as raw_dir:
        state = Path(raw_dir)
        configure_module(module, state)
        write_json(module.USAGE_PATH, {"schemaVersion": 1, "provider": "claude", "marker": "keep"})

        raw = """
Claude Code
Current session
0% used
Resets 1h
Current week (all models)
0% used
Resets 2d
"""
        captured = datetime.now(timezone.utc)
        result = module.process_usage(raw, 0, captured)

        assert result == 1
        assert json.loads(module.USAGE_PATH.read_text())["marker"] == "keep"
        status = json.loads(module.OFFICIAL_STATUS_PATH.read_text())
        assert status["status"] == "unsettled"


def test_pty_settle_guard_accepts_all_zero_panel_with_fable_line() -> None:
    """A fresh-reset panel can legitimately show 0% everywhere. The rejection
    is specifically for 0% *and* no Fable line at all (the historical
    truncated-panel shape), so a genuine all-zero reading with a Fable line
    present must still be accepted.
    """
    module = load_module()
    with tempfile.TemporaryDirectory(prefix="usage-claude-pty-zero-fable-") as raw_dir:
        state = Path(raw_dir)
        configure_module(module, state)

        raw = """
Claude Code
Current session
0% used
Resets 1h
Current week (all models)
0% used
Resets 2d
Current week (Fable)
0% used
Resets 2d
"""
        captured = datetime.now(timezone.utc)
        result = module.process_usage(raw, 0, captured)

        assert result == 0
        snapshot = json.loads(module.USAGE_PATH.read_text())
        assert snapshot["weekFable"]["usedPct"] == 0
        status = json.loads(module.OFFICIAL_STATUS_PATH.read_text())
        assert status["status"] == "ok"
        assert snapshot["officialUsage"]["source"] == "pty"


def test_pty_official_usage_names_pty_source() -> None:
    """The doctor's window-contract check needs to know which path produced
    a reading. PTY parses must say so explicitly in officialUsage.source, the
    same way build_api_payload already stamps it "api".
    """
    module = load_module()
    raw = "Current session\n25% used\nResets 1h\nCurrent week (all models)\n5% used\nResets 2d\n"
    captured = datetime.now(timezone.utc)
    official = module.parse_usage(raw, captured)
    assert official["officialUsage"]["source"] == "pty"


def test_percent_snapshot_settle_helper_matches_on_stable_text() -> None:
    """Sanity check for the settle guard's building block: the same rendered
    text parses to the same (label, percent) tuple twice, and a still-empty
    buffer never matches another empty buffer (an all-empty comparison would
    let the guard "settle" on nothing).
    """
    module = load_module()
    raw = "Current session\n25% used\nResets 1h\nCurrent week (all models)\n5% used\nResets 2d\n"
    first = module.percent_snapshot(raw)
    second = module.percent_snapshot(raw)
    assert first == second
    assert first != tuple()
    assert module.percent_snapshot("") == tuple()


def test_api_mode_offline_status_carries_detail_and_interpreter() -> None:
    """The status file must say WHY the endpoint was unreachable. A bare
    "unreachable" hid a CERTIFICATE_VERIFY_FAILED from an interpreter with an
    empty CA store for two days (2026-09-10 to 09-12)."""
    with tempfile.TemporaryDirectory(prefix="usage-claude-api-detail-") as raw_dir:
        root = Path(raw_dir)
        state = root / "state"
        env = clean_env(
            root,
            state,
            {"CLAUDE_CODE_OAUTH_TOKEN": "test-token", "BLOOM_CLAUDE_USAGE_API_FIXTURE_STATUS": "offline"},
        )
        result = run_fetch(["--mode", "api"], env)
        assert result.returncode == 1
        status = json.loads((state / "claude-official-status.json").read_text())
        assert status["status"] == "offline"
        assert status["detail"] == "simulated offline"
        assert "simulated offline" in status["message"]
        assert status["interpreter"].endswith("python3") or "python" in status["interpreter"]


def test_tls_context_falls_back_to_system_bundle_when_store_is_empty() -> None:
    """An interpreter with zero CAs (python.org build, certificates never
    installed) must still verify against the macOS system bundle."""
    import ssl

    module = load_module()
    empty = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    assert empty.cert_store_stats()["x509_ca"] == 0
    if not any(Path(bundle).is_file() for bundle in module.SYSTEM_CA_BUNDLES):
        return  # not a Mac with /etc/ssl/cert.pem; nothing to prove here
    ctx = module.build_tls_context(empty)
    assert ctx.cert_store_stats()["x509_ca"] > 0
    assert module._tls_trust_source in module.SYSTEM_CA_BUNDLES


def test_api_mode_skips_when_official_reading_is_fresh_unless_forced() -> None:
    """The claude-writer LaunchAgent runs api mode every 60s; without this
    gate that is 1,440 endpoint calls a day."""
    with tempfile.TemporaryDirectory(prefix="usage-claude-api-fresh-") as raw_dir:
        root = Path(raw_dir)
        state = root / "state"
        state.mkdir(parents=True)
        fresh_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
        (state / "claude-usage.json").write_text(json.dumps({
            "schemaVersion": 1,
            "provider": "claude",
            "officialUsage": {"capturedAt": fresh_at, "source": "api"},
            "weekFable": {"usedPct": 12, "capturedAt": fresh_at},
        }))
        # A fixture that would fail loudly if the gate let the fetch through.
        env = clean_env(
            root,
            state,
            {"CLAUDE_CODE_OAUTH_TOKEN": "test-token", "BLOOM_CLAUDE_USAGE_API_FIXTURE_STATUS": "offline"},
        )
        result = run_fetch(["--mode", "api"], env)
        assert result.returncode == 0, result.stdout + result.stderr
        assert "skipped" in result.stdout
        assert not (state / "claude-official-status.json").exists()

        forced = run_fetch(["--mode", "api", "--force"], env)
        assert forced.returncode == 1
        status = json.loads((state / "claude-official-status.json").read_text())
        assert status["status"] == "offline"


def test_api_mode_skips_while_shared_cooldown_is_active() -> None:
    with tempfile.TemporaryDirectory(prefix="usage-claude-api-cooldown-skip-") as raw_dir:
        root = Path(raw_dir)
        state = root / "state"
        state.mkdir(parents=True)
        (state / ".claude-official-rate-limited-until").write_text(str(int(time.time()) + 300))
        env = clean_env(
            root,
            state,
            {"CLAUDE_CODE_OAUTH_TOKEN": "test-token", "BLOOM_CLAUDE_USAGE_API_FIXTURE_STATUS": "offline"},
        )
        result = run_fetch(["--mode", "api"], env)
        assert result.returncode == 0, result.stdout + result.stderr
        assert "cooldown" in result.stdout
        assert not (state / "claude-official-status.json").exists()


def test_credential_falls_back_to_service_only_and_credentials_file_and_detects_lock() -> None:
    module = load_module()
    with tempfile.TemporaryDirectory(prefix="usage-claude-cred-fallback-") as raw_dir:
        state = Path(raw_dir)
        configure_module(module, state)
        (state / ".claude").mkdir()
        module.HOME = state
        seen_cmds: list[list[str]] = []

        def service_only_ok(cmd, **_kw):
            seen_cmds.append(list(cmd))
            if "-a" in cmd:
                return subprocess.CompletedProcess(cmd, returncode=44, stdout="", stderr="not found")
            return subprocess.CompletedProcess(cmd, returncode=0, stdout=json.dumps({"claudeAiOauth": {"accessToken": "svc-token"}}), stderr="")

        orig_run, orig_tok = module.subprocess.run, os.environ.pop("CLAUDE_CODE_OAUTH_TOKEN", None)
        try:
            module.subprocess.run = service_only_ok
            module.LAST_CREDENTIAL.clear()
            assert module.resolve_credential() == "svc-token" and module.LAST_CREDENTIAL.get("lookup") == "keychain"
            assert any("-a" not in c for c in seen_cmds)
            stamp = module.credential_stamp("svc-token")
            assert stamp is not None and "svc-token" not in stamp and len(stamp) == 16
            module.subprocess.run = lambda cmd, **_kw: subprocess.CompletedProcess(cmd, returncode=36, stdout="", stderr="User interaction is not allowed.")
            module.LAST_CREDENTIAL.clear()
            assert module.run_api_mode() == 1 and json.loads(module.OFFICIAL_STATUS_PATH.read_text())["status"] == "keychain_locked"
            (state / ".claude" / ".credentials.json").write_text(json.dumps({"claudeAiOauth": {"accessToken": "file-token"}}))
            module.LAST_CREDENTIAL.clear()
            assert module.resolve_credential() == "file-token" and module.LAST_CREDENTIAL.get("lookup") == "credentials_file"
        finally:
            module.subprocess.run = orig_run
            if orig_tok is not None:
                os.environ["CLAUDE_CODE_OAUTH_TOKEN"] = orig_tok


def test_manual_refresh_bypasses_failure_cooldown_but_keeps_429_cooldown() -> None:
    with tempfile.TemporaryDirectory(prefix="usage-claude-manual-refresh-") as raw_dir:
        root = Path(raw_dir)
        state = root / "state"
        state.mkdir(parents=True)
        (state / ".claude-official-rate-limited-until").write_text(str(int(time.time()) + 500))
        write_json(state / "claude-official-status.json", {"status": "no_credential", "updatedAt": "2026-01-01T00:00:00Z"})
        env = clean_env(root, state, {"CLAUDE_CODE_OAUTH_TOKEN": "test-token", "BLOOM_CLAUDE_USAGE_API_FIXTURE": str(FIXTURE_PATH), "CODEX_USAGE_HUD_MANUAL_REFRESH": "1"})
        ok = run_fetch(["--mode", "api"], env)
        assert ok.returncode == 0, ok.stdout + ok.stderr
        assert json.loads((state / "claude-official-status.json").read_text())["status"] == "ok"
        (state / ".claude-official-rate-limited-until").write_text(str(int(time.time()) + 300))
        write_json(state / "claude-official-status.json", {"status": "rate_limited", "updatedAt": "2026-01-01T00:00:00Z"})
        held = run_fetch(["--mode", "api"], env)
        assert held.returncode == 0 and "cooldown" in held.stdout


TESTS = [
    test_api_mode_parses_fixture_into_expected_shape,
    test_api_mode_other_weekly_scoped_names_become_skills,
    test_api_mode_authoritative_response_drops_missing_fable,
    test_api_mode_authoritative_response_clears_stale_fable_expiry,
    test_api_mode_falls_back_to_top_level_utilization,
    test_api_mode_clears_stale_pty_contributors,
    test_api_mode_unparsed_when_nothing_usable,
    test_api_mode_rate_limited_writes_cooldown,
    test_api_mode_unauthorized_no_cooldown,
    test_api_mode_offline_on_network_error,
    test_api_mode_no_credential_writes_only_status_no_keychain,
    test_api_mode_expired_token_is_never_sent_and_recovers_on_renewal,
    test_api_mode_refused_token_is_tried_once_per_credential,
    test_merge_and_write_keeps_concurrent_tap_write,
    test_merge_snapshot_official_replaces_older_higher_reading,
    test_merge_snapshot_keeps_higher_reading_observed_after_official_capture,
    test_merge_snapshot_accepts_new_window_on_different_reset,
    test_merge_snapshot_drops_dead_official_checked_at,
    test_sigterm_before_credential_check_aborts_api_mode,
    test_sigterm_after_fetch_aborts_before_merge,
    test_sigterm_flag_writes_aborted_without_snapshot,
    test_pty_settle_guard_rejects_all_zero_panel_without_fable,
    test_pty_settle_guard_accepts_all_zero_panel_with_fable_line,
    test_pty_official_usage_names_pty_source,
    test_percent_snapshot_settle_helper_matches_on_stable_text,
    test_api_mode_offline_status_carries_detail_and_interpreter,
    test_tls_context_falls_back_to_system_bundle_when_store_is_empty,
    test_api_mode_skips_when_official_reading_is_fresh_unless_forced,
    test_api_mode_skips_while_shared_cooldown_is_active,
    test_credential_falls_back_to_service_only_and_credentials_file_and_detects_lock,
    test_manual_refresh_bypasses_failure_cooldown_but_keeps_429_cooldown,
]


def main() -> int:
    failures = 0
    for test in TESTS:
        try:
            test()
        except AssertionError as error:
            failures += 1
            print(f"FAIL - {test.__name__}: {error}")
        except Exception as error:  # noqa: BLE001 - surface unexpected errors as failures
            failures += 1
            print(f"ERROR - {test.__name__}: {error!r}")
        else:
            print(f"ok  - {test.__name__}")
    total = len(TESTS)
    print(f"{total - failures} passed, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
