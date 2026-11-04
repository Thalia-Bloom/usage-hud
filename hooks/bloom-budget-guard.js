#!/usr/bin/env node
// PreToolUse circuit-breaker: when the Bloom token budget is in a risky mode,
// block new subagent (Task/Agent) spawns. Each subagent runs its own requests,
// which is the dominant token-burn driver under pressure.
//
// Modes:
//   green/yellow        → allow (silent)
//   orange/red/freeze   → block with explanation (exit 2)
//   unknown             → allow (silent) when the pipeline looks alive
//                         (the state's source event under 30 min old and the
//                         statusline tap heartbeat under 15 min old); block
//                         otherwise. Freshness is judged on
//                         state.sourceEventAt ONLY — the timestamp of the
//                         official usage reading itself. state.sourceUpdatedAt
//                         is deliberately not consulted as a fallback: the
//                         keepalive writer re-stamps it (it mirrors
//                         capturedAt) roughly every 60 seconds regardless of
//                         whether any new reading landed, so it is always
//                         fresh and proves nothing about the pipeline. A
//                         missing, empty, or unparsable sourceEventAt is NOT
//                         fresh — fail closed. A weekly or 5h reset
//                         legitimately drops the window for a while, and
//                         that gap should not read as a dead pipeline as
//                         long as sourceEventAt and the tap heartbeat stay
//                         current.

const fs = require('fs');
const os = require('os');
const path = require('path');

const HOME = os.homedir();
const STATE_DIR = process.env.CODEX_USAGE_HUD_STATE_DIR || process.env.BLOOM_USAGE_DIR || path.join(HOME, '.codex-usage-hud');

const STATE_MAX_AGE_MS = 30 * 60 * 1000;
const TAP_MAX_AGE_MS = 15 * 60 * 1000;

const STATE = path.join(STATE_DIR, 'token-budget-state.json');
const TAP = path.join(STATE_DIR, 'claude-statusline-tap.json');
const OVERRIDE_FILE = path.join(STATE_DIR, 'override-until.txt');

function overrideActive() {
  try {
    const ts = fs.readFileSync(OVERRIDE_FILE, 'utf8').trim();
    return new Date(ts).getTime() > Date.now();
  } catch { return false; }
}

// Milliseconds since an ISO 8601 timestamp, or null when it is missing or
// unparsable.
function ageMs(iso) {
  if (typeof iso !== 'string' || !iso) return null;
  const then = Date.parse(iso);
  if (!Number.isFinite(then)) return null;
  const delta = Date.now() - then;
  return delta >= 0 ? delta : null;
}

// Renders an age in minutes/hours for the block message, e.g. "42m old" or
// "1h 5m old".
function formatAge(ms) {
  const totalMinutes = Math.floor(ms / 60000);
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  return hours > 0 ? `${hours}h ${minutes}m old` : `${totalMinutes}m old`;
}

// Reads the statusline tap heartbeat's updatedAt age in ms, or null when the
// file is missing, unreadable, or carries no usable timestamp.
function tapAgeMs() {
  try {
    const tap = JSON.parse(fs.readFileSync(TAP, 'utf8'));
    return ageMs(tap.updatedAt);
  } catch {
    return null;
  }
}
const TIMEOUT = setTimeout(() => block('Budget guard could not read the agent request in time. Run the work in this session.'), 2000);

let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', c => (input += c));
process.stdin.on('end', () => {
  clearTimeout(TIMEOUT);
  try { evaluate(); } catch { block('Budget guard could not verify the current budget. Run the work in this session.'); }
});

function evaluate() {
  const data = JSON.parse(input);
  const tool = String(data.tool_name || '').toLowerCase();
  if (tool !== 'task' && tool !== 'agent') return process.exit(0);

  // Honor an explicit override when the operator needs to bypass the brake
  if (process.env.BLOOM_BUDGET_OVERRIDE === '1') return process.exit(0);
  if (overrideActive()) return process.exit(0);

  let state;
  try {
    state = JSON.parse(fs.readFileSync(STATE, 'utf8'));
  } catch {
    return block('Budget guard has no trustworthy budget reading. Run the work in this session.');
  }

  const mode = String(state.mode || '').toLowerCase();
  const weekly = Math.round(Number(state.weeklyUsedPct) || 0);
  const reset = state.weeklyResetLabel || 'reset unknown';

  if (!['green', 'yellow', 'orange', 'red', 'freeze', 'unknown'].includes(mode)) {
    return block('Budget guard has no trustworthy budget reading. Run the work in this session.');
  }

  if (mode === 'unknown') {
    // sourceEventAt only — see the header comment. sourceUpdatedAt is not a
    // fallback because the keepalive writer re-stamps it every ~60s
    // regardless of whether a fresh reading landed, so it is always fresh
    // and proves nothing.
    const eventAge = ageMs(state.sourceEventAt);
    const tapAge = tapAgeMs();
    const stateFresh = eventAge !== null && eventAge < STATE_MAX_AGE_MS;
    const tapFresh = tapAge !== null && tapAge < TAP_MAX_AGE_MS;
    if (stateFresh && tapFresh) return process.exit(0);

    const eventDesc = eventAge === null ? 'missing' : formatAge(eventAge);
    const tapDesc = tapAge === null ? 'missing' : formatAge(tapAge);
    return block(
      `Budget guard has no trustworthy budget reading (mode unknown, ` +
      `state event ${eventDesc}, tap ${tapDesc}). Run the work in this session.`
    );
  }

  if (mode === 'orange' || mode === 'red' || mode === 'freeze') {
    return block(
      `Budget guard blocked a new agent, mode is ${mode.toUpperCase()} ` +
      `(weekly ${weekly}%, ${reset}). Run the work in this session, or set ` +
      `BLOOM_BUDGET_OVERRIDE=1 to bypass.`
    );
  }

  return process.exit(0);
}

function block(reason) {
  process.stderr.write(`${reason}\n`);
  process.exit(2);
}
