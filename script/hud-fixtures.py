#!/usr/bin/env python3
"""Generate synthetic HUD state fixtures and render the real app against them.

Usage: python3 script/hud-fixtures.py [render]
Writes fixtures to /tmp/hud-fixtures/<scenario>/ and (with "render") renders
each through the release binary via CODEX_USAGE_HUD_STATE_DIR + SNAPSHOT env
to /tmp/hud-render-<scenario>.png. Scenarios cover states live data rarely
shows: calm, crisis, unknowns (degraded data), hot (over-pace), lanes
(new-provider truth pass), fable-expired (weekly reading cleared by reset —
must render "--", never "0%"), spend / spend-noplan (synthetic Claude Code
and Codex session logs read by the in-app token readers, with and without a
plan set; spend also renders the Activity window to
/tmp/hud-render-spend-activity.png).
HUD_FIXTURES_DIR and HUD_RENDER_DIR move the two /tmp locations.
"""
import json, os, shutil, subprocess, sys
from datetime import datetime, timedelta, timezone

now = datetime.now(timezone.utc)
iso = lambda d: d.strftime('%Y-%m-%dT%H:%M:%S.000Z')
def label(d):
    return d.astimezone().strftime('%b %-d %-I:%M %p')

BASE = os.environ.get('HUD_FIXTURES_DIR', '/tmp/hud-fixtures')
RENDER_DIR = os.environ.get('HUD_RENDER_DIR', '/tmp')

def snap(provider, display, sess, week, event_age_min=1, extra=None, contributors=None, week_fable=None,
         rate_limit_expired=None):
    d = {
        "schemaVersion": 1, "provider": provider, "displayName": display,
        "source": "fixture", "sourceKind": "official_api", "confidence": "high",
        "updatedAt": iso(now - timedelta(minutes=event_age_min)),
        "capturedAt": iso(now), "eventAt": iso(now - timedelta(minutes=event_age_min)),
        "contributors": contributors or [],
    }
    if sess:
        d["currentSession"] = {"label": "5-hour limit", "usedPct": sess[0],
            "resetAt": iso(now + timedelta(hours=sess[1])), "resetLabel": label(now + timedelta(hours=sess[1]))}
    if week:
        d["week"] = {"label": "weekly", "usedPct": week[0],
            "resetAt": iso(now + timedelta(hours=week[1])), "resetLabel": label(now + timedelta(hours=week[1]))}
    if week_fable:
        d["weekFable"] = {"label": "Fable weekly", "usedPct": week_fable[0],
            "resetAt": iso(now + timedelta(hours=week_fable[1])), "resetLabel": label(now + timedelta(hours=week_fable[1]))}
    if rate_limit_expired:
        # Statusline tap cleared these windows at the last reset — the row
        # must render "--", never a stale/zero percentage.
        d["rateLimitExpired"] = rate_limit_expired
        d["rateLimitExpiredAt"] = iso(now - timedelta(hours=1))
    if extra: d["extraUsage"] = extra
    return d

scenarios = {
  "calm": {
    "claude-usage.json": snap("claude", "Claude Code", (12, 4.0), (10, 24*6.2), week_fable=(23, 24*6.2)),
    "codex-usage.json": snap("codex", "Codex", (8, 3.5), (22, 24*5.5)),
    "gemini-usage.json": snap("gemini", "Gemini", None, (35, 14)),
  },
  "crisis": {
    "claude-usage.json": snap("claude", "Claude Code", (97, 1.2), (88, 24*1.5), week_fable=(94, 24*1.5),
        contributors=[{"percent": 92, "label": "while 6+ sessions ran in parallel", "note": "Queue non-urgent sessions."}]),
    "codex-usage.json": snap("codex", "Codex", (100, 0.8), (96, 24*1.5)),
    "gemini-usage.json": snap("gemini", "Gemini", None, (99.9, 9)),
  },
  "unknowns": {
    # Stale Fable reading (3d-old capture) must say so, not pass as live.
    "claude-usage.json": {**snap("claude", "Claude Code", (45, 2.5), None, event_age_min=200),
        "weekFable": {"label": "Fable weekly", "usedPct": 37,
            "resetAt": iso(now + timedelta(hours=50)), "resetLabel": label(now + timedelta(hours=50)),
            "capturedAt": iso(now - timedelta(hours=72))}},
    "codex-usage.json": {**snap("codex", "Codex", None, None), "week": {"label": "weekly", "usedPct": 61}},
  },
  # A fresh writer check cannot hide yesterday's rate-limited Claude reading.
  "rate-limited": {
    "provider-preferences.json": {
        "detectedAt": iso(now), "found": ["Claude Code", "Codex"], "missing": [],
        "connected": ["claude", "codex"], "shown": ["claude", "codex"],
        "nodeAvailable": True, "pythonAvailable": True},
    "claude-usage.json": {**snap("claude", "Claude Code", None, (17, 48), event_age_min=1440),
        "weekFable": {"label": "Fable weekly", "usedPct": 31,
            "resetAt": iso(now + timedelta(hours=48)), "resetLabel": label(now + timedelta(hours=48)),
            "capturedAt": iso(now - timedelta(days=1))},
        "health": {"verdict": "stale", "reason": "Claude usage endpoint is rate-limited.", "checkedAt": iso(now)},
        "officialUsageStatus": {"status": "rate_limited", "updatedAt": iso(now),
            "retryAt": iso(now + timedelta(minutes=5))}},
    "codex-usage.json": snap("codex", "Codex", None, (1, 168)),
  },
  "hot": {
    "claude-usage.json": snap("claude", "Claude Code", (55, 3.0), (62, 24*5.8)),
    "codex-usage.json": snap("codex", "Codex", (10, 4.2), (12, 24*6.5)),
    "gemini-usage.json": snap("gemini", "Gemini", None, (15, 18)),
  },
  # Fable's official weekly reading was cleared by the statusline tap at the
  # last reset and hasn't been refetched — the row must show "--", never "0%".
  "fable-expired": {
    "claude-usage.json": snap("claude", "Claude Code", (18, 4.0), (14, 24*6.2),
        rate_limit_expired=["weekFable"]),
    "codex-usage.json": snap("codex", "Codex", (8, 3.5), (22, 24*5.5)),
  },
  # New-lane truth pass (2026-07-09): Grok lane, Antigravity-weekly Gemini,
  # an idle Codex (expired window + old event = "IDLE · window clear", not
  # silence), and a writer-flagged degraded lane.
  "lanes": {
    "claude-usage.json": snap("claude", "Claude Code", (8, 4.5), (21, 24*6.3)),
    "codex-usage.json": snap("codex", "Codex", None, None, event_age_min=12*60),
    "gemini-usage.json": {**snap("gemini", "Gemini", (0.7, 1.8), (11.9, 24*4.3)),
        "week": {**snap("gemini", "Gemini", None, (11.9, 24*4.3))["week"], "label": "Claude/GPT (agy) weekly"},
        "health": {"verdict": "fresh", "checkedAt": iso(now), "reason": None}},
    "grok-usage.json": {**snap("grok", "Grok", None, (4, 24*6.4), extra="Weekly credits 4% used"),
        "health": {"verdict": "stale", "checkedAt": iso(now),
                   "reason": "Grok CLI token expired; open grok once to refresh it."}},
  },
  # First-run setup card (Slice B1): only the tools that were found, no CLI names.
  "first-run": {
    "setup-card.json": {
        "phase": "prompt",
        "found": ["Claude Code", "Codex"],
        "missing": ["Gemini", "Grok", "Ollama"],
    },
    "provider-preferences.json": {
        "detectedAt": iso(now),
        "found": ["Claude Code", "Codex"],
        "missing": ["Gemini", "Grok", "Ollama"],
        "connected": ["claude", "codex"],
        "shown": ["claude", "codex"],
        "nodeAvailable": True,
        "pythonAvailable": True,
    },
  },
  "first-run-done": {
    "setup-card.json": {"phase": "complete"},
    "provider-preferences.json": {
        "detectedAt": iso(now),
        "found": ["Claude Code", "Codex"],
        "missing": ["Gemini", "Grok", "Ollama"],
        "connected": ["claude", "codex"],
        "shown": ["claude", "codex"],
        "nodeAvailable": True,
        "pythonAvailable": True,
    },
    "claude-usage.json": snap("claude", "Claude Code", (18, 4.0), (42, 24*6.2)),
    "codex-usage.json": snap("codex", "Codex", (8, 3.5), (22, 24*5.5)),
  },
}

# --- Synthetic session logs for the in-app token readers (spend scenarios) ---

def claude_line(msg_id, minutes_ago, model, cwd, session, inp, out, write_1h, read):
    return json.dumps({
        "cwd": cwd, "sessionId": session, "version": "2.1.0", "type": "assistant",
        "message": {"model": model, "id": msg_id, "type": "message", "role": "assistant",
                    "content": [{"type": "text", "text": "fixture"}],
                    "usage": {"input_tokens": inp, "output_tokens": out,
                              "cache_creation_input_tokens": write_1h, "cache_read_input_tokens": read,
                              "cache_creation": {"ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": write_1h}}},
        "requestId": "req_" + msg_id, "uuid": "u_" + msg_id,
        "timestamp": iso(now - timedelta(minutes=minutes_ago)),
    }, separators=(',', ':'))


def codex_lines(session, cwd, model, steps):
    """steps: (minutes_ago, input, cached, output) per request; written as
    the running totals Codex logs, with one repeated event."""
    start = now - timedelta(minutes=steps[0][0] + 5)
    lines = [json.dumps({"timestamp": iso(start), "type": "session_meta",
                         "payload": {"id": session, "timestamp": iso(start), "cwd": cwd, "originator": "codex_cli_rs"}}),
             json.dumps({"timestamp": iso(start), "type": "turn_context", "payload": {"cwd": cwd, "model": model}})]
    total = [0, 0, 0]
    for minutes_ago, inp, cached, out in steps:
        total = [total[0] + inp, total[1] + cached, total[2] + out]
        def usage(u):
            return {"input_tokens": u[0], "cached_input_tokens": u[1], "cache_write_input_tokens": 0,
                    "output_tokens": u[2], "reasoning_output_tokens": 0, "total_tokens": u[0] + u[2]}
        event = {"timestamp": iso(now - timedelta(minutes=minutes_ago)), "type": "event_msg",
                 "payload": {"type": "token_count",
                             "info": {"total_token_usage": usage(total), "last_token_usage": usage([inp, cached, out])},
                             "rate_limits": {"limit_id": "codex", "plan_type": "plus"}}}
        lines.append(json.dumps(event, separators=(',', ':')))
    lines.append(lines[-1])  # Codex repeats a total; the reader must not count it twice
    return lines


def write_token_logs(root):
    store = '/Users/demo/Projects/storefront'
    api = '/Users/demo/Projects/api-server'
    claude = []
    for i in range(300):  # a busy week on the storefront, heaviest today
        minutes = 8 + (i * 4 if i < 60 else 240 + (i - 60) * 35)
        claude.append(claude_line(f"msg_s{i}", minutes, "claude-opus-5-5", store, "sess-store", 40, 3000, 15000, 500000))
    claude.append(claude_line("msg_s0", 8, "claude-opus-5-5", store, "sess-store", 40, 3000, 15000, 500000))  # streamed twice
    api_lines = [claude_line(f"msg_a{i}", 70 + i * 12, "claude-sonnet-5", api, "sess-api", 30, 900, 3000, 90000) for i in range(12)]
    proj = os.path.join(root, 'claude', 'projects')
    os.makedirs(os.path.join(proj, '-Users-demo-Projects-storefront'))
    os.makedirs(os.path.join(proj, '-Users-demo-Projects-api-server'))
    open(os.path.join(proj, '-Users-demo-Projects-storefront', 'sess-store.jsonl'), 'w').write('\n'.join(claude) + '\n')
    open(os.path.join(proj, '-Users-demo-Projects-api-server', 'sess-api.jsonl'), 'w').write('\n'.join(api_lines) + '\n')
    day = now.astimezone()
    codex_dir = os.path.join(root, 'codex', 'sessions', day.strftime('%Y'), day.strftime('%m'), day.strftime('%d'))
    os.makedirs(codex_dir)
    steps = [(12 + k * 25, 90000, 78000, 2400) for k in reversed(range(48))]
    open(os.path.join(codex_dir, 'rollout-fixture-mobile.jsonl'), 'w').write(
        '\n'.join(codex_lines('thread-mobile', '/Users/demo/Projects/mobile-app', 'gpt-6-sol', steps)) + '\n')


spend_snaps = {
    "claude-usage.json": snap("claude", "Claude Code", (31, 3.1), (38, 24*4.2)),
    "codex-usage.json": snap("codex", "Codex", (12, 2.5), (27, 24*5.1)),
}
token_log_scenarios = {
    "spend": {**spend_snaps, "plan-settings.json": {"claude": "claude-max-5x", "codex": "chatgpt-plus"}},
    "spend-noplan": dict(spend_snaps),
}
scenarios.update(token_log_scenarios)

shutil.rmtree(BASE, ignore_errors=True)
for name, files in scenarios.items():
    d = os.path.join(BASE, name)
    os.makedirs(d)
    for fn, content in files.items():
        json.dump(content, open(os.path.join(d, fn), 'w'), indent=1)
    if name in token_log_scenarios:
        write_token_logs(os.path.join(d, 'token-logs'))
print("fixtures:", sorted(os.listdir(BASE)))

if len(sys.argv) > 1 and sys.argv[1] == 'render':
    root = os.path.join(os.path.dirname(__file__), '..', '.build')
    # `make app` bundles the universal build with Sparkle in Contents/Frameworks (the bare
    # .build/apple binary can't find Sparkle); plain `swift build -c release` lands in .build/release.
    candidates = [os.path.join(os.path.dirname(__file__), '..', 'dist', 'CodexUsageHUD.app', 'Contents', 'MacOS', 'CodexUsageHUD'),
                  os.path.join(root, 'release', 'CodexUsageHUD')]
    binp = max((c for c in candidates if os.path.exists(c)), key=os.path.getmtime, default=candidates[-1])
    for name in scenarios:
        out = os.path.join(RENDER_DIR, f'hud-render-{name}.png')
        env = dict(os.environ, CODEX_USAGE_HUD_STATE_DIR=os.path.join(BASE, name),
                   CODEX_USAGE_HUD_SNAPSHOT=out)
        env.pop('CODEX_USAGE_HUD_TOKEN_LOGS', None)
        if name in token_log_scenarios:
            env['CODEX_USAGE_HUD_TOKEN_LOGS'] = os.path.join(BASE, name, 'token-logs')
        subprocess.run([binp], env=env, check=True)
        print(f'rendered {out}')
    activity = os.path.join(RENDER_DIR, 'hud-render-spend-activity.png')
    env = dict(os.environ, CODEX_USAGE_HUD_STATE_DIR=os.path.join(BASE, 'spend'),
               CODEX_USAGE_HUD_TOKEN_LOGS=os.path.join(BASE, 'spend', 'token-logs'),
               CODEX_USAGE_HUD_ACTIVITY_SNAPSHOT=activity)
    subprocess.run([binp], env=env, check=True)
    print(f'rendered {activity}')
