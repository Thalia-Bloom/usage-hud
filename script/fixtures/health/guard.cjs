// Reviewer-authored isolation preload. Blocks network and host processes.
// launchctl print is substituted (running) so doctor never touches real launchd.
// Only the synthetic fake `codex` binary under FAKE_CODEX_DIR may be spawned.
const cp = require('child_process');
const path = require('path');
const realSpawn = cp.spawn;
const allowed = process.env.FAKE_CODEX_DIR ? path.join(process.env.FAKE_CODEX_DIR, 'codex') : null;
cp.execFileSync = (file, args) => {
  if (file === 'launchctl' && args && args[0] === 'print') {
    if (process.env.FAIL_GROK_JOB && String(args[1]).endsWith('.grok-writer')) throw Error('not loaded');
    return 'state = running\nruns = 1\n';
  }
  throw Error('host process forbidden: ' + file);
};
cp.spawn = (file, args, opts) => {
  if (file === 'codex' && allowed) return realSpawn(allowed, args, opts);
  throw Error('process forbidden: ' + file);
};
cp.exec = cp.execSync = cp.spawnSync = cp.execFile = () => { throw Error('process forbidden'); };
require('https').get = () => { throw Error('HTTP ' + (process.env.FAKE_HTTP || '503')); };
require('https').request = () => { throw Error('network forbidden'); };
global.fetch = () => { throw Error('network forbidden'); };
for (const mod of ['http', 'net', 'tls']) {
  for (const key of ['request', 'get', 'connect', 'createConnection']) {
    if (require(mod)[key]) require(mod)[key] = () => { throw Error('network forbidden'); };
  }
}
