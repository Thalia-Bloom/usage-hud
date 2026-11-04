#!/usr/bin/env node

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const HOOK = path.resolve(__dirname, '..', 'hooks', 'bloom-budget-guard.js');

function run(mode, extraEnv = {}) {
  const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), 'budget-guard-'));
  if (mode !== 'missing') {
    fs.writeFileSync(
      path.join(stateDir, 'token-budget-state.json'),
      mode === 'malformed' ? '{' : JSON.stringify({ mode, weeklyUsedPct: 50, weeklyResetLabel: 'Friday' })
    );
  }
  return spawnSync(process.execPath, [HOOK], {
    input: JSON.stringify({ tool_name: 'Agent', tool_input: {} }),
    encoding: 'utf8',
    env: {
      ...process.env,
      CODEX_USAGE_HUD_STATE_DIR: stateDir,
      BLOOM_USAGE_DIR: stateDir,
      ...extraEnv
    }
  });
}

for (const mode of ['green', 'yellow']) {
  const result = run(mode);
  assert.strictEqual(result.status, 0, `${mode}: ${result.stderr}`);
}

for (const mode of ['orange', 'red', 'freeze', 'unknown', 'malformed', 'missing']) {
  const result = run(mode);
  assert.strictEqual(result.status, 2, `${mode}: expected block, got ${result.status}`);
  assert.match(result.stderr, /run the work in this session/i);
}

const override = run('unknown', { BLOOM_BUDGET_OVERRIDE: '1' });
assert.strictEqual(override.status, 0, override.stderr);

// --- Rollover-aware unknown mode ---
// A weekly or 5h reset legitimately drops the window for a while. The guard
// should allow through the gap only while the pipeline still looks alive:
// a recent official reading (state.sourceEventAt) and a recent statusline
// tap heartbeat. state.updatedAt is deliberately NOT the freshness signal:
// the always-on HUD app rewrites it every few seconds regardless of whether
// any usage reading landed, so it proves nothing on its own. Likewise
// state.sourceUpdatedAt is NOT a fallback for sourceEventAt: the keepalive
// writer re-stamps it every ~60s (it mirrors capturedAt), so it is always
// fresh and proves nothing either. Missing, empty, or unparsable
// sourceEventAt is not fresh — fail closed.

const MINUTE_MS = 60 * 1000;
const HOUR_MS = 60 * MINUTE_MS;

function isoAgeAgo(ms) {
  return new Date(Date.now() - ms).toISOString();
}

function runRollover({ sourceEventAgeMs, tapAgeMs, includeTap = true, extraState = {} }) {
  const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), 'budget-guard-rollover-'));
  fs.writeFileSync(
    path.join(stateDir, 'token-budget-state.json'),
    JSON.stringify({
      mode: 'unknown',
      weeklyUsedPct: 50,
      weeklyResetLabel: 'Friday',
      // The HUD app rewrites this every ~5s; tests pin it "fresh" throughout
      // so a guard that mistakenly keys off updatedAt would (wrongly) pass.
      updatedAt: isoAgeAgo(0),
      ...(sourceEventAgeMs !== undefined ? { sourceEventAt: isoAgeAgo(sourceEventAgeMs) } : {}),
      ...extraState
    })
  );
  if (includeTap) {
    fs.writeFileSync(
      path.join(stateDir, 'claude-statusline-tap.json'),
      JSON.stringify({ updatedAt: isoAgeAgo(tapAgeMs) })
    );
  }
  return spawnSync(process.execPath, [HOOK], {
    input: JSON.stringify({ tool_name: 'Agent', tool_input: {} }),
    encoding: 'utf8',
    env: {
      ...process.env,
      CODEX_USAGE_HUD_STATE_DIR: stateDir,
      BLOOM_USAGE_DIR: stateDir
    }
  });
}

{
  // Fresh source event (5m), fresh tap (2m) -> allow.
  const result = runRollover({ sourceEventAgeMs: 5 * MINUTE_MS, tapAgeMs: 2 * MINUTE_MS });
  assert.strictEqual(result.status, 0, `unknown+fresh event+fresh tap: expected allow, got ${result.status} ${result.stderr}`);
}

{
  // Fresh source event (5m), stale tap (20m, over the 15m ceiling) -> block.
  const result = runRollover({ sourceEventAgeMs: 5 * MINUTE_MS, tapAgeMs: 20 * MINUTE_MS });
  assert.strictEqual(result.status, 2, `unknown+fresh event+stale tap: expected block, got ${result.status}`);
  assert.match(result.stderr, /run the work in this session/i);
  assert.match(result.stderr, /mode unknown/i);
}

{
  // Stale source event (1h, over the 30m ceiling), fresh tap (2m) -> block.
  const result = runRollover({ sourceEventAgeMs: 60 * MINUTE_MS, tapAgeMs: 2 * MINUTE_MS });
  assert.strictEqual(result.status, 2, `unknown+stale event+fresh tap: expected block, got ${result.status}`);
  assert.match(result.stderr, /run the work in this session/i);
}

{
  // Fresh source event (5m), no tap file at all -> block.
  const result = runRollover({ sourceEventAgeMs: 5 * MINUTE_MS, includeTap: false });
  assert.strictEqual(result.status, 2, `unknown+no tap file: expected block, got ${result.status}`);
  assert.match(result.stderr, /run the work in this session/i);
  assert.match(result.stderr, /tap missing/i);
}

{
  // state.updatedAt is fresh (the HUD app just rewrote it) but the official
  // reading (sourceEventAt) is 2h old -> block. This is the regression case:
  // a guard keyed off updatedAt would wrongly allow this through.
  const result = runRollover({ sourceEventAgeMs: 2 * HOUR_MS, tapAgeMs: 2 * MINUTE_MS });
  assert.strictEqual(result.status, 2, `unknown+fresh updatedAt+stale sourceEventAt: expected block, got ${result.status}`);
  assert.match(result.stderr, /run the work in this session/i);
  assert.match(result.stderr, /mode unknown/i);
}

{
  // sourceEventAt absent, sourceUpdatedAt fresh (5m) -> still block. The
  // keepalive writer re-stamps sourceUpdatedAt every ~60s regardless of
  // whether a fresh reading landed, so it is never a valid fallback.
  const result = runRollover({ tapAgeMs: 2 * MINUTE_MS, extraState: { sourceUpdatedAt: isoAgeAgo(5 * MINUTE_MS) } });
  assert.strictEqual(result.status, 2, `unknown+sourceUpdatedAt-only fresh: expected block, got ${result.status}`);
  assert.match(result.stderr, /run the work in this session/i);
  assert.match(result.stderr, /state event missing/i);
}

{
  // Neither sourceEventAt nor sourceUpdatedAt present -> not fresh -> block,
  // even with a fresh tap. Proves the "both missing = not fresh" contract.
  const result = runRollover({ tapAgeMs: 2 * MINUTE_MS });
  assert.strictEqual(result.status, 2, `unknown+no source timestamps: expected block, got ${result.status}`);
  assert.match(result.stderr, /run the work in this session/i);
  assert.match(result.stderr, /state event missing/i);
}

console.log('budget guard: fail-closed modes verified (rollover-aware)');
