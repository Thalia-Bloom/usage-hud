#!/usr/bin/env python3
"""Hermetic regressions for bin/codex-usage-doctor.

Runs the real doctor script against a temp HOME and a temp
CODEX_USAGE_HUD_STATE_DIR seeded with fixture JSON, then asserts on specific
stdout lines. No network, no Keychain, no launchd, no real credentials.

Follows the clean_env/run_node/write_json helper pattern from
script/test-usage-producer-contracts.py, duplicated here (not imported) so
this file stays a standalone, ownable test module.
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
DOCTOR = ROOT / "bin/codex-usage-doctor"
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
            "CODEX_USAGE_HUD_STATE_DIR": str(state),
            "BLOOM_USAGE_DIR": str(state),
            "PATH": f"{Path(NODE).parent}:/usr/bin:/bin",
        }
    )
    if extra:
        env.update(extra)
    return env


def run_doctor(home: Path, state: Path, extra: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [NODE, str(DOCTOR)],
        text=True,
        capture_output=True,
        timeout=30,
        env=clean_env(home, state, extra),
        check=False,
    )


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n")


def iso_z(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def minutes_ago(minutes: float) -> datetime:
    return datetime.now(timezone.utc) - timedelta(minutes=minutes)


def find_line(stdout: str, needle: str) -> str | None:
    for line in stdout.splitlines():
        if needle in line:
            return line
    return None


def base_home(root: Path) -> Path:
    # A minimal, always-present skeleton so unrelated doctor checks (codex
    # home / sessions) do not throw; their exact pass/warn/fail state in this
    # hermetic env is out of scope here (per the harden task's instruction to
    # ignore launchd-shaped lines in the temp env).
    home = root / "home"
    (home / ".codex" / "sessions").mkdir(parents=True)
    # Claude Code present, so the doctor runs its Claude lane checks.
    (home / ".claude").mkdir(parents=True, exist_ok=True)
    return home


def test_absent_tools_get_one_ok_line_each() -> None:
    with tempfile.TemporaryDirectory(prefix="doctor-blank-") as raw:
        root = Path(raw)
        home = root / "home"
        home.mkdir()
        state = root / "state"
        state.mkdir(mode=0o700)
        # An inherited Codex profile must not turn this absent-tools fixture
        # into a check of the real user's sessions.
        result = run_doctor(home, state, {"CODEX_HOME": str(home / ".codex")})
        # launchd belongs to the logged-in Mac, not the temporary HOME.
        # Whether the app is running is outside this lane-only check.
        for line in result.stdout.splitlines():
            if "com.codexusagehud." in line:
                continue
            assert "FAIL" not in line, result.stdout
        for needle in ("codex: not installed", "claude: Claude Code not installed", "grok: Grok CLI not installed"):
            line = find_line(result.stdout, needle)
            assert line and line.startswith("OK"), result.stdout


def test_codex_without_sessions_is_one_warning() -> None:
    for with_empty_sessions in (False, True):
        with tempfile.TemporaryDirectory(prefix="doctor-codex-first-day-") as raw:
            root = Path(raw)
            home = root / "home"
            codex = home / ".codex"
            codex.mkdir(parents=True)
            if with_empty_sessions:
                (codex / "sessions").mkdir()
            state = root / "state"
            result = run_doctor(home, state, {"CODEX_HOME": str(codex)})
            lane_lines = [line for line in result.stdout.splitlines()
                          if any(name in line for name in
                                 ("codex home:", "codex sessions:", "session logs:",
                                  "rate-limit event:", "codex snapshot:", "codex:"))]
            assert not any(line.startswith("FAIL") for line in lane_lines), result.stdout
            warnings = [line for line in lane_lines if line.startswith("WARN")]
            assert len(warnings) == 1, result.stdout
            assert "run one Codex session" in warnings[0], warnings[0]


def test_codex_session_without_limits_still_fails() -> None:
    with tempfile.TemporaryDirectory(prefix="doctor-codex-no-limits-") as raw:
        root = Path(raw)
        home = root / "home"
        sessions = home / ".codex" / "sessions"
        sessions.mkdir(parents=True)
        (sessions / "session.jsonl").write_text('{}\n')
        result = run_doctor(home, root / "state", {"CODEX_HOME": str(sessions.parent)})
        for name in ("codex home", "codex sessions", "session logs"):
            line = find_line(result.stdout, name)
            assert line and line.startswith("OK"), result.stdout
        line = find_line(result.stdout, "rate-limit event")
        assert line and line.startswith("FAIL"), result.stdout
        line = find_line(result.stdout, "codex snapshot")
        assert line and line.startswith("WARN"), result.stdout
        assert "run one Codex session" not in result.stdout, result.stdout


def seed_official(
    state: Path,
    *,
    status: str,
    message: str,
    source: str | None,
    captured_minutes_ago: float,
    used_pct: float = 8.0,
) -> None:
    captured_at = iso_z(minutes_ago(captured_minutes_ago))
    official_usage: dict[str, object] = {"capturedAt": captured_at, "limits": []}
    if source is not None:
        # Omitting the key entirely (rather than writing None) exercises the
        # real legacy shape: a PTY-mode snapshot from before officialUsage
        # carried a "source" field at all.
        official_usage["source"] = source
    write_json(
        state / "claude-usage.json",
        {
            "schemaVersion": 1,
            "provider": "claude",
            "officialUsage": official_usage,
            "weekFable": {
                "label": "Fable",
                "usedPct": used_pct,
                "capturedAt": captured_at,
                "resetAt": iso_z(minutes_ago(-7 * 24 * 60)),
            },
        },
    )
    write_json(
        state / "claude-official-status.json",
        {
            "schemaVersion": 1,
            "status": status,
            "message": message,
            "updatedAt": iso_z(minutes_ago(0)),
        },
    )


def claude_window(used_pct: float, reset_offset_minutes: float, event_minutes_ago: float = 0) -> dict:
    """Build a v1 Claude window object (currentSession/week/weekFable shape).

    reset_offset_minutes is positive for a reset in the future, negative for
    a reset already in the past.
    """
    return {
        "usedPct": used_pct,
        "resetAt": iso_z(minutes_ago(-reset_offset_minutes)),
        "eventAt": iso_z(minutes_ago(event_minutes_ago)),
    }


def seed_claude_windows(
    state: Path,
    *,
    current_session: dict | None = None,
    week: dict | None = None,
    week_fable: dict | None = None,
) -> None:
    payload: dict[str, object] = {"schemaVersion": 1, "provider": "claude"}
    if current_session is not None:
        payload["currentSession"] = current_session
    if week is not None:
        payload["week"] = week
    if week_fable is not None:
        payload["weekFable"] = week_fable
    write_json(state / "claude-usage.json", payload)


def write_settings(home: Path, status_command: str, guard_command: str) -> None:
    settings_dir = home / ".claude"
    settings_dir.mkdir(parents=True, exist_ok=True)
    write_json(
        settings_dir / "settings.json",
        {
            "statusLine": {"type": "command", "command": status_command},
            "hooks": {
                "PreToolUse": [
                    {
                        "matcher": "Task|Agent",
                        "hooks": [{"type": "command", "command": guard_command, "timeout": 3000}],
                    }
                ]
            },
        },
    )


def test_official_usage_fresh_is_ok() -> None:
    with tempfile.TemporaryDirectory(prefix="doctor-official-fresh-") as raw:
        root = Path(raw)
        home = base_home(root)
        state = root / "state"
        seed_official(state, status="ok", message="Claude Code official /usage parsed.", source="api", captured_minutes_ago=2)
        result = run_doctor(home, state)
        assert result.returncode in (0, 1, 2), result.stderr

        line = find_line(result.stdout, "claude official /usage")
        assert line, result.stdout
        assert line.startswith("OK"), line
        assert "source api" in line, line

        fable_line = find_line(result.stdout, "fable weekly reading")
        assert fable_line, result.stdout
        assert fable_line.startswith("OK"), fable_line
        assert "source api" in fable_line, fable_line


def test_official_usage_aging_warns() -> None:
    with tempfile.TemporaryDirectory(prefix="doctor-official-aging-") as raw:
        root = Path(raw)
        home = base_home(root)
        state = root / "state"
        seed_official(state, status="ok", message="Claude Code official /usage parsed.", source="api", captured_minutes_ago=45)
        result = run_doctor(home, state)

        line = find_line(result.stdout, "claude official /usage")
        assert line, result.stdout
        assert line.startswith("WARN"), line
        assert "aging" in line, line

        fable_line = find_line(result.stdout, "fable weekly reading")
        assert fable_line, result.stdout
        assert fable_line.startswith("WARN"), fable_line
        assert "keepalive refetches every 5 min" in fable_line, fable_line
        assert "claude-refresh-now" not in fable_line, fable_line


def test_official_usage_unauthorized_fails_with_remedy() -> None:
    with tempfile.TemporaryDirectory(prefix="doctor-official-unauth-") as raw:
        root = Path(raw)
        home = base_home(root)
        state = root / "state"
        seed_official(
            state,
            status="unauthorized",
            message="Open Claude Code once to refresh the token.",
            source="api",
            captured_minutes_ago=90,
        )
        result = run_doctor(home, state)

        line = find_line(result.stdout, "claude official /usage")
        assert line, result.stdout
        assert line.startswith("FAIL"), line
        assert "Open Claude Code once to refresh the token." in line, line

        # Only Claude Code can repair a credential; point at that first.
        fable_line = find_line(result.stdout, "fable weekly reading")
        assert fable_line, result.stdout
        assert fable_line.startswith("WARN"), fable_line
        assert "open Claude Code and sign in" in fable_line, fable_line
        assert "--force" not in fable_line, fable_line


def test_official_usage_no_credential_fails() -> None:
    with tempfile.TemporaryDirectory(prefix="doctor-official-nocred-") as raw:
        root = Path(raw)
        home = base_home(root)
        state = root / "state"
        seed_official(
            state,
            status="no_credential",
            message="No Claude Code credential in Keychain; open Claude Code once to sign in.",
            source="unknown",
            captured_minutes_ago=200,
        )
        result = run_doctor(home, state)
        line = find_line(result.stdout, "claude official /usage")
        assert line, result.stdout
        assert line.startswith("FAIL"), line
        assert "open Claude Code once to sign in" in line, line


def test_official_usage_warn_statuses() -> None:
    warn_statuses = ["rate_limited", "offline", "unparsed", "aborted", "unsettled"]
    for status in warn_statuses:
        with tempfile.TemporaryDirectory(prefix=f"doctor-official-{status}-") as raw:
            root = Path(raw)
            home = base_home(root)
            state = root / "state"
            seed_official(state, status=status, message=f"{status} detail", source="api", captured_minutes_ago=5)
            result = run_doctor(home, state)
            line = find_line(result.stdout, "claude official /usage")
            assert line, result.stdout
            assert line.startswith("WARN"), f"{status}: {line}"


def test_official_usage_source_pty_is_accepted() -> None:
    with tempfile.TemporaryDirectory(prefix="doctor-official-pty-") as raw:
        root = Path(raw)
        home = base_home(root)
        state = root / "state"
        seed_official(state, status="ok", message="parsed", source="pty", captured_minutes_ago=2)
        result = run_doctor(home, state)

        line = find_line(result.stdout, "claude official /usage")
        assert line, result.stdout
        assert line.startswith("OK"), line
        assert "source pty" in line, line

        fable_line = find_line(result.stdout, "fable weekly reading")
        assert fable_line, result.stdout
        assert "source pty" in fable_line, fable_line


def test_official_usage_missing_source_is_legacy_reading() -> None:
    with tempfile.TemporaryDirectory(prefix="doctor-official-nosource-") as raw:
        root = Path(raw)
        home = base_home(root)
        state = root / "state"
        seed_official(state, status="ok", message="parsed", source=None, captured_minutes_ago=2)
        result = run_doctor(home, state)

        line = find_line(result.stdout, "claude official /usage")
        assert line, result.stdout
        assert line.startswith("OK"), line
        assert "source unknown (legacy reading)" in line, line

        fable_line = find_line(result.stdout, "fable weekly reading")
        assert fable_line, result.stdout
        assert "source unknown (legacy reading)" in fable_line, fable_line


def test_statusline_and_guard_bare_node_warns() -> None:
    with tempfile.TemporaryDirectory(prefix="doctor-bare-node-") as raw:
        root = Path(raw)
        home = base_home(root)
        state = root / "state"
        tap = home / ".local" / "bin" / "bloom-usage-statusline-tap"
        tap.parent.mkdir(parents=True)
        tap.write_text("#!/usr/bin/env node\n")
        guard = home / ".claude" / "hooks" / "bloom-budget-guard.js"
        guard.parent.mkdir(parents=True)
        guard.write_text("// fixture\n")
        write_settings(home, f'node "{tap}"', f'node "{guard}"')

        result = run_doctor(home, state)

        status_line = find_line(result.stdout, "claude statusline command")
        assert status_line, result.stdout
        assert status_line.startswith("WARN"), status_line
        assert "minimal PATH" in status_line, status_line
        assert "absolute node path" in status_line, status_line

        guard_line = find_line(result.stdout, "claude budget guard hook")
        assert guard_line, result.stdout
        assert guard_line.startswith("WARN"), guard_line
        assert "minimal PATH" in guard_line, guard_line


def test_statusline_and_guard_bloom_node_is_ok() -> None:
    with tempfile.TemporaryDirectory(prefix="doctor-bloom-node-") as raw:
        root = Path(raw)
        home = base_home(root)
        state = root / "state"
        bloom_node = home / ".local" / "bin" / "bloom-node"
        bloom_node.parent.mkdir(parents=True)
        bloom_node.write_text("#!/usr/bin/env bash\n")
        tap = home / ".local" / "bin" / "bloom-usage-statusline-tap"
        tap.write_text("#!/usr/bin/env node\n")
        guard = home / ".claude" / "hooks" / "bloom-budget-guard.js"
        guard.parent.mkdir(parents=True)
        guard.write_text("// fixture\n")
        write_settings(home, f'"{bloom_node}" "{tap}"', f'"{bloom_node}" "{guard}"')

        result = run_doctor(home, state)

        status_line = find_line(result.stdout, "claude statusline command")
        assert status_line, result.stdout
        assert status_line.startswith("OK"), status_line

        guard_line = find_line(result.stdout, "claude budget guard hook")
        assert guard_line, result.stdout
        assert guard_line.startswith("OK"), guard_line


def test_statusline_absolute_node_path_is_ok() -> None:
    with tempfile.TemporaryDirectory(prefix="doctor-abs-node-") as raw:
        root = Path(raw)
        home = base_home(root)
        state = root / "state"
        node_bin = root / "toolchain" / "bin" / "node"
        node_bin.parent.mkdir(parents=True)
        node_bin.write_text("#!/bin/sh\n")
        tap = home / ".local" / "bin" / "bloom-usage-statusline-tap"
        tap.parent.mkdir(parents=True)
        tap.write_text("#!/usr/bin/env node\n")
        write_settings(home, f'"{node_bin}" "{tap}"', "node \"/does/not/matter/bloom-budget-guard.js\"")

        result = run_doctor(home, state)
        status_line = find_line(result.stdout, "claude statusline command")
        assert status_line, result.stdout
        assert status_line.startswith("OK"), status_line
        assert "absolute node path" in status_line, status_line


def test_statusline_missing_script_warns_even_with_bloom_node() -> None:
    with tempfile.TemporaryDirectory(prefix="doctor-missing-script-") as raw:
        root = Path(raw)
        home = base_home(root)
        state = root / "state"
        missing_tap = home / ".local" / "bin" / "bloom-usage-statusline-tap"
        write_settings(home, f'"{home}/.local/bin/bloom-node" "{missing_tap}"', "node \"/x/bloom-budget-guard.js\"")

        result = run_doctor(home, state)
        status_line = find_line(result.stdout, "claude statusline command")
        assert status_line, result.stdout
        assert status_line.startswith("WARN"), status_line
        assert "script missing" in status_line, status_line


def test_writer_error_log_recent_warns() -> None:
    with tempfile.TemporaryDirectory(prefix="doctor-writer-log-") as raw:
        root = Path(raw)
        home = base_home(root)
        state = root / "state"
        log_dir = home / "Library" / "Application Support" / "Codex Usage HUD" / "logs"
        log_dir.mkdir(parents=True)
        (log_dir / "claude-writer.err.log").write_text(
            "ReferenceError: synthesizeTrackerWindows is not defined\n"
        )
        (log_dir / "grok-writer.err.log").write_text("")

        result = run_doctor(home, state)

        line = find_line(result.stdout, "claude writer log")
        assert line, result.stdout
        assert line.startswith("WARN"), line
        # The doctor quotes only the log's last line. Verify that contract
        # directly rather than assuming which line survives.
        assert "ReferenceError" in line, line

        grok_line = find_line(result.stdout, "grok writer log")
        assert grok_line is None, result.stdout  # unused Grok has no relevant helper check


def test_writer_error_log_quotes_only_last_line_truncated() -> None:
    with tempfile.TemporaryDirectory(prefix="doctor-writer-log-lastline-") as raw:
        root = Path(raw)
        home = base_home(root)
        state = root / "state"
        log_dir = home / "Library" / "Application Support" / "Codex Usage HUD" / "logs"
        log_dir.mkdir(parents=True)
        long_tail = "x" * 200
        (log_dir / "claude-writer.err.log").write_text(
            f"ReferenceError: synthesizeTrackerWindows is not defined\n    at Object.<anonymous> ({long_tail})\n"
        )

        result = run_doctor(home, state)
        line = find_line(result.stdout, "claude writer log")
        assert line, result.stdout
        assert line.startswith("WARN"), line
        assert "ReferenceError" not in line, line  # that was the first line, not the last
        assert "at Object.<anonymous>" in line, line
        assert long_tail not in line, "expected the quoted last line truncated to 120 chars"


def test_writer_error_log_quote_masks_secrets() -> None:
    with tempfile.TemporaryDirectory(prefix="doctor-writer-log-redaction-") as raw:
        root = Path(raw)
        home = base_home(root)
        state = root / "state"
        log_dir = home / "Library" / "Application Support" / "Codex Usage HUD" / "logs"
        log_dir.mkdir(parents=True)
        token = "sk-ant-oat01-fixture-token-for-redaction"
        hex_token = "abcdef0123456789" * 2 + "abcdef01"  # gitleaks:allow -- generated redaction-test fixture
        message = f"request failed: Bearer {token} trace={hex_token}; retry later"
        (log_dir / "claude-writer.err.log").write_text(message + "\n")

        result = run_doctor(home, state)
        output = result.stdout + result.stderr
        assert token not in output, "writer token leaked"
        assert hex_token not in output, "hex token leaked"
        line = find_line(result.stdout, "claude writer log")
        assert line and line.startswith("WARN"), line
        assert '"request failed: Bearer [redacted] trace=[redacted]; retry later"' in line, line

        # Also redact standalone keys and a bearer value crossing the old
        # 120-character boundary, for both writers using this shared check.
        # This Grok log belongs to a configured (even invalid) installation.
        write_json(home / ".grok" / "auth.json", {})
        cases = [
            ("grok-writer.err.log", "grok writer log", f"key={token}; retry later", '"key=[redacted]; retry later"'),
            ("claude-writer.err.log", "claude writer log", "x" * 100 + " Bearer " + "fixture" * 30, '"' + "x" * 100 + " Bearer [redacted]" + '"'),
        ]
        for filename, label, message, expected in cases:
            (log_dir / filename).write_text(message + "\n")
            result = run_doctor(home, state)
            output = result.stdout + result.stderr
            assert token not in output, "standalone key leaked"
            assert "fixture" not in output, "truncated bearer prefix leaked"
            line = find_line(result.stdout, label)
            assert line and line.startswith("WARN"), line
            assert expected in line, line


def test_writer_error_log_old_is_ok() -> None:
    with tempfile.TemporaryDirectory(prefix="doctor-writer-log-old-") as raw:
        root = Path(raw)
        home = base_home(root)
        state = root / "state"
        log_dir = home / "Library" / "Application Support" / "Codex Usage HUD" / "logs"
        log_dir.mkdir(parents=True)
        log_file = log_dir / "claude-writer.err.log"
        log_file.write_text("old crash, long since fixed\n")
        old_time = time.time() - (10 * 24 * 60 * 60)
        os.utime(log_file, (old_time, old_time))

        result = run_doctor(home, state)
        line = find_line(result.stdout, "claude writer log")
        assert line, result.stdout
        assert line.startswith("OK"), line


def test_writer_error_log_missing_is_ok() -> None:
    with tempfile.TemporaryDirectory(prefix="doctor-writer-log-missing-") as raw:
        root = Path(raw)
        home = base_home(root)
        state = root / "state"
        result = run_doctor(home, state)
        line = find_line(result.stdout, "claude writer log")
        assert line, result.stdout
        assert line.startswith("OK"), line


def test_budget_mode_variants() -> None:
    cases = [("green", "OK"), ("yellow", "OK"), ("orange", "WARN"), ("red", "WARN"), ("freeze", "WARN")]
    for mode, expected in cases:
        with tempfile.TemporaryDirectory(prefix=f"doctor-budget-{mode}-") as raw:
            root = Path(raw)
            home = base_home(root)
            state = root / "state"
            # claude budget mode is only checked once the opt-in PreToolUse
            # budget-guard hook is actually wired in (see write_settings).
            write_settings(home, "node /nonexistent/statusline.js", "node /nonexistent/bloom-budget-guard.js")
            write_json(
                state / "token-budget-state.json",
                {"schemaVersion": 1, "mode": mode, "weeklyUsedPct": 42, "updatedAt": iso_z(minutes_ago(0))},
            )
            result = run_doctor(home, state)
            line = find_line(result.stdout, "claude budget mode")
            assert line, result.stdout
            assert line.startswith(expected), f"{mode}: {line}"


def test_budget_mode_missing_fails() -> None:
    with tempfile.TemporaryDirectory(prefix="doctor-budget-missing-") as raw:
        root = Path(raw)
        home = base_home(root)
        state = root / "state"
        write_settings(home, "node /nonexistent/statusline.js", "node /nonexistent/bloom-budget-guard.js")
        result = run_doctor(home, state)
        line = find_line(result.stdout, "claude budget mode")
        assert line, result.stdout
        assert line.startswith("FAIL"), line


def test_budget_mode_unknown_reports_rollover_gap() -> None:
    with tempfile.TemporaryDirectory(prefix="doctor-budget-unknown-") as raw:
        root = Path(raw)
        home = base_home(root)
        state = root / "state"
        write_settings(home, "node /nonexistent/statusline.js", "node /nonexistent/bloom-budget-guard.js")
        write_json(
            state / "token-budget-state.json",
            {"schemaVersion": 1, "mode": "unknown", "updatedAt": iso_z(minutes_ago(20))},
        )
        write_json(
            state / "claude-statusline-tap.json",
            {
                "schemaVersion": 1,
                "updatedAt": iso_z(minutes_ago(3)),
                "parsed": True,
                "hasFiveHour": True,
                "hasSevenDay": True,
            },
        )
        result = run_doctor(home, state)
        line = find_line(result.stdout, "claude budget mode")
        assert line, result.stdout
        assert line.startswith("WARN"), line
        assert "rollover gap" in line, line
        assert "tap heartbeat" in line, line


def test_budget_guard_checks_silent_on_buyer_default_install() -> None:
    """A fresh buyer install never wires the PreToolUse budget-guard hook
    (INSTALL.md never asks them to). Both budget-guard checks must skip
    silently instead of reporting a FAIL/WARN about an automation the buyer
    never turned on -- even with no ~/.claude/settings.json at all and a
    token-budget-state.json missing (the same missing-state that fails hard
    once the hook is configured, per test_budget_mode_missing_fails)."""
    with tempfile.TemporaryDirectory(prefix="doctor-budget-not-configured-") as raw:
        root = Path(raw)
        home = base_home(root)
        state = root / "state"
        result = run_doctor(home, state)
        assert find_line(result.stdout, "claude budget guard hook") is None, result.stdout
        assert find_line(result.stdout, "claude budget mode") is None, result.stdout


def test_statusline_tap_windows_missing_briefly_is_ok() -> None:
    with tempfile.TemporaryDirectory(prefix="doctor-tap-brief-gap-") as raw:
        root = Path(raw)
        home = base_home(root)
        state = root / "state"
        write_json(
            state / "claude-statusline-tap.json",
            {
                "schemaVersion": 1,
                "updatedAt": iso_z(minutes_ago(1)),
                "parsed": True,
                "hasFiveHour": False,
                "hasSevenDay": False,
                "wroteSnapshot": True,
            },
        )
        result = run_doctor(home, state)
        line = find_line(result.stdout, "claude statusline tap")
        assert line, result.stdout
        assert line.startswith("OK"), line


def test_statusline_tap_windows_missing_persisted_warns() -> None:
    with tempfile.TemporaryDirectory(prefix="doctor-tap-persisted-gap-") as raw:
        root = Path(raw)
        home = base_home(root)
        state = root / "state"
        write_json(
            state / "claude-statusline-tap.json",
            {
                "schemaVersion": 1,
                "updatedAt": iso_z(minutes_ago(7 * 60)),
                "parsed": True,
                "hasFiveHour": False,
                "hasSevenDay": False,
                "wroteSnapshot": True,
            },
        )
        result = run_doctor(home, state)
        line = find_line(result.stdout, "claude statusline tap")
        assert line, result.stdout
        assert line.startswith("WARN"), line
        assert "over 6h" in line, line


def test_claude_windows_live_set_is_ok() -> None:
    with tempfile.TemporaryDirectory(prefix="doctor-claude-windows-live-") as raw:
        root = Path(raw)
        home = base_home(root)
        state = root / "state"
        seed_claude_windows(
            state,
            current_session=claude_window(40, reset_offset_minutes=3 * 60, event_minutes_ago=1),
            week=claude_window(9, reset_offset_minutes=6 * 24 * 60, event_minutes_ago=1),
            week_fable=claude_window(8, reset_offset_minutes=6 * 24 * 60, event_minutes_ago=1),
        )
        result = run_doctor(home, state)

        line = find_line(result.stdout, "claude windows")
        assert line, result.stdout
        assert line.startswith("OK"), line
        assert "5h 40%" in line, line
        assert "week 9%" in line, line
        assert "Fable 8%" in line, line
        assert "resets in" in line, line


def test_claude_windows_week_reset_past_fails() -> None:
    with tempfile.TemporaryDirectory(prefix="doctor-claude-windows-past-") as raw:
        root = Path(raw)
        home = base_home(root)
        state = root / "state"
        seed_claude_windows(
            state,
            week=claude_window(9, reset_offset_minutes=-60, event_minutes_ago=1),
        )
        result = run_doctor(home, state)

        line = find_line(result.stdout, "claude windows")
        assert line, result.stdout
        assert line.startswith("FAIL"), line
        assert "week 9%" in line, line
        assert "past its reset" in line, line
        assert "cannot be aged" not in line, "past-reset failure must not borrow the missing-resetAt reason"


def test_claude_windows_missing_reset_fails_with_its_own_reason() -> None:
    with tempfile.TemporaryDirectory(prefix="doctor-claude-windows-noreset-") as raw:
        root = Path(raw)
        home = base_home(root)
        state = root / "state"
        window = claude_window(9, reset_offset_minutes=6 * 24 * 60, event_minutes_ago=1)
        window.pop("resetAt")
        seed_claude_windows(state, week=window)
        result = run_doctor(home, state)

        line = find_line(result.stdout, "claude windows")
        assert line, result.stdout
        assert line.startswith("FAIL"), line
        assert "week 9% resetAt missing or unparsable" in line, line
        assert "cannot be aged" in line, line
        assert "past its reset" not in line, "missing resetAt must not be reported as a past reset"


def test_claude_windows_empty_set_warns() -> None:
    with tempfile.TemporaryDirectory(prefix="doctor-claude-windows-empty-") as raw:
        root = Path(raw)
        home = base_home(root)
        state = root / "state"
        seed_claude_windows(state)
        result = run_doctor(home, state)

        line = find_line(result.stdout, "claude windows")
        assert line, result.stdout
        assert line.startswith("WARN"), line
        assert "no Claude windows in snapshot" in line, line


def test_doctor_never_prints_secrets() -> None:
    with tempfile.TemporaryDirectory(prefix="doctor-privacy-") as raw:
        root = Path(raw)
        home = base_home(root)
        state = root / "state"
        secret_token = "sk-ant-oat01-should-never-appear-in-doctor-output"
        write_json(
            state / "claude-usage.json",
            {
                "schemaVersion": 1,
                "provider": "claude",
                "officialUsage": {"source": "api", "capturedAt": iso_z(minutes_ago(2))},
            },
        )
        write_json(
            state / "claude-official-status.json",
            {
                "schemaVersion": 1,
                "status": "ok",
                "message": "parsed",
                "updatedAt": iso_z(minutes_ago(0)),
                "accessToken": secret_token,
            },
        )
        result = run_doctor(home, state)
        assert secret_token not in result.stdout, "doctor stdout leaked a credential-shaped value"
        assert secret_token not in result.stderr, "doctor stderr leaked a credential-shaped value"


def test_optional_statusline_is_not_a_setup_failure() -> None:
    for command in (None, "~/.claude/statusline.sh", 'bash "$HOME/.claude/statusline.sh"'):
        with tempfile.TemporaryDirectory(prefix="doctor-optional-statusline-") as raw:
            root = Path(raw)
            home = base_home(root)
            state = root / "state"
            if command:
                write_settings(home, command, "")
                script = home / ".claude/statusline.sh"
                script.write_text("#!/bin/sh\necho existing-custom-statusline\n")
            result = run_doctor(home, state)
            for label in ("claude statusline command", "claude statusline tap"):
                line = find_line(result.stdout, label)
                assert line and line.startswith("OK"), result.stdout
            assert "command does not resolve" not in result.stdout


def test_configured_tap_still_needs_a_heartbeat() -> None:
    with tempfile.TemporaryDirectory(prefix="doctor-configured-statusline-") as raw:
        root = Path(raw)
        home = base_home(root)
        state = root / "state"
        tap = home / "Library/Application Support/Codex Usage HUD/bin/bloom-usage-statusline-tap"
        tap.parent.mkdir(parents=True)
        tap.write_text("#!/usr/bin/env node\n")
        # The documented direct command and an existing user's shell wrapper.
        wrapper = home / ".claude/statusline.sh"
        wrapper.write_text(f'#!/bin/sh\n"{tap}"\n')
        for command in ('"$HOME/Library/Application Support/Codex Usage HUD/bin/bloom-usage-statusline-tap"',
                        "~/.claude/statusline.sh"):
            write_settings(home, command, "")
            result = run_doctor(home, state)
            line = find_line(result.stdout, "claude statusline command")
            assert line and line.startswith("OK"), result.stdout
            line = find_line(result.stdout, "claude statusline tap")
            assert line and line.startswith("WARN") and "configured but no heartbeat" in line, result.stdout


def test_rate_limit_reports_cooldown_instead_of_normal_cadence() -> None:
    with tempfile.TemporaryDirectory(prefix="doctor-rate-limit-retry-") as raw:
        root = Path(raw)
        home = base_home(root)
        state = root / "state"
        seed_official(state, status="rate_limited", message="Rate limited", source="api", captured_minutes_ago=1440)
        status_path = state / "claude-official-status.json"
        status = json.loads(status_path.read_text())
        for retry_at, expected in ((iso_z(minutes_ago(-5)), "automatic retry in about 5 min"),
                                   (iso_z(minutes_ago(5)), "last check was rate-limited"),
                                   ("invalid", "last check was rate-limited")):
            status["retryAt"] = retry_at
            write_json(status_path, status)
            result = run_doctor(home, state)
            for label in ("claude official /usage", "fable weekly reading"):
                line = find_line(result.stdout, label)
                assert line and line.startswith("WARN") and expected in line, result.stdout
                assert "keepalive refetches every 5 min" not in line, line
                assert "--force" not in line, line


TESTS = [
    test_codex_without_sessions_is_one_warning,
    test_codex_session_without_limits_still_fails,
    test_optional_statusline_is_not_a_setup_failure,
    test_configured_tap_still_needs_a_heartbeat,
    test_rate_limit_reports_cooldown_instead_of_normal_cadence,
    test_official_usage_fresh_is_ok,
    test_official_usage_aging_warns,
    test_official_usage_unauthorized_fails_with_remedy,
    test_official_usage_no_credential_fails,
    test_official_usage_warn_statuses,
    test_official_usage_source_pty_is_accepted,
    test_official_usage_missing_source_is_legacy_reading,
    test_statusline_and_guard_bare_node_warns,
    test_statusline_and_guard_bloom_node_is_ok,
    test_statusline_absolute_node_path_is_ok,
    test_statusline_missing_script_warns_even_with_bloom_node,
    test_writer_error_log_recent_warns,
    test_writer_error_log_quotes_only_last_line_truncated,
    test_writer_error_log_quote_masks_secrets,
    test_writer_error_log_old_is_ok,
    test_writer_error_log_missing_is_ok,
    test_budget_mode_variants,
    test_budget_mode_missing_fails,
    test_budget_mode_unknown_reports_rollover_gap,
    test_budget_guard_checks_silent_on_buyer_default_install,
    test_statusline_tap_windows_missing_briefly_is_ok,
    test_statusline_tap_windows_missing_persisted_warns,
    test_claude_windows_live_set_is_ok,
    test_claude_windows_week_reset_past_fails,
    test_claude_windows_missing_reset_fails_with_its_own_reason,
    test_claude_windows_empty_set_warns,
    test_doctor_never_prints_secrets,
    test_absent_tools_get_one_ok_line_each,
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
