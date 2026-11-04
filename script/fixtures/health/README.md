Health regression fixtures

legacy-grok-writer.cjs is byte-identical to bin/bloom-usage-write-grok
from the pinned 6db786240fbe046ccf60b2523b088bc2e5692549 baseline.
It runs only under a fresh synthetic home and guard.cjs, to generate the
actual legacy missing-auth and genuine billing snapshots for upgrade tests.
Do not update this historical producer when changing current behavior.

fake-codex.js and guard.cjs derive from the independent .4 reviewer probes.
The fake server answers initialize and account/rateLimits/read with the real
producer's camelCase response shape. Modes are full, weekonly and error.
Only the temporary copied fake executable can spawn; launchctl print is
substituted, HTTPS get throws a fixture HTTP error, other network is blocked.
No live provider or authentication is used. All fixture source files are 0644;
the test creates an executable copy of fake-codex.js in its temporary home.
