#!/usr/bin/env node
// Synthetic stand-in for `codex app-server --listen stdio://`. Speaks just the
// two JSON-RPC calls bloom-usage-write-codex makes. Shape mirrors the fields the
// producer reads (rateLimits.primary/secondary usedPercent/windowDurationMins/resetsAt).
// FAKE_CODEX_MODE: ok | weekonly | corrupt | error | weekprimary[_absent|_corrupt|_unknown|_empty] | twoweeks | swapped
const mode = process.env.FAKE_CODEX_MODE || 'ok';
const now = Math.floor(Date.now() / 1000);
let buf = '';
process.stdin.on('data', (c) => {
  buf += c;
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i); buf = buf.slice(i + 1);
    let msg; try { msg = JSON.parse(line); } catch (_) { continue; }
    if (msg.id === 1) process.stdout.write(JSON.stringify({ id: 1, result: {} }) + '\n');
    if (msg.id === 2) {
      if (mode === 'error') { process.stdout.write(JSON.stringify({ id: 2, error: { code: -1, message: 'x' } }) + '\n'); continue; }
      const primary = { usedPercent: 12, windowDurationMins: 300, resetsAt: now + 3600 };
      const secondary = { usedPercent: 43, windowDurationMins: 10080, resetsAt: now + 86400 };
      const rateLimits = { limitId: 'codex', primary: mode === 'weekonly' ? null : mode === 'corrupt' ? {...primary, usedPercent: 150} : primary, secondary };
      // Weekly quota reported in the primary slot, with null/absent secondary,
      // and invalid/unclassified/duplicate extra slots that must not qualify.
      const slots = {
        weekprimary: [secondary, null], weekprimary_absent: [secondary],
        weekprimary_corrupt: [secondary, {...primary, usedPercent: 150}],
        weekprimary_unknown: [secondary, {usedPercent: 5, windowDurationMins: 60, resetsAt: now + 600}],
        weekprimary_empty: [secondary, {}], twoweeks: [secondary, {...secondary, usedPercent: 50}],
        swapped: [secondary, primary]
      }[mode];
      if (slots) {
        delete rateLimits.secondary;
        rateLimits.primary = slots[0];
        if (slots.length > 1) rateLimits.secondary = slots[1];
      }
      process.stdout.write(JSON.stringify({ id: 2, result: { rateLimits } }) + '\n');
    }
  }
});
process.stdin.on('end', () => process.exit(0));
