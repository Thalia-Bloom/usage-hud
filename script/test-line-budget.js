#!/usr/bin/env node

const assert = require('assert');
const { byDir, total } = require('./count-shipped-lines.js');

/** Raised 2026-11-18 from 39400 to 40300: restored multi-bar StatusBarController and per-lane StatusPanel/LaneBars, and added ResetRadar + ResetRadarTests. */
const CEILING = 40300;
/** 50%+ cut target for follow-up PRs; this test does not enforce it yet. */
const TARGET = 19450;

assert.ok(Object.values(byDir).every((lines) => lines > 0), 'a shipped source directory is empty');
assert.ok(
  total <= CEILING,
  `Shipped code over budget: ${total} lines (ceiling ${CEILING}). ` +
    `Areas: ${JSON.stringify(byDir)}. site/ and store/ are packaging-only and not counted. ` +
    `Cut target for the license tree is ~${TARGET} lines (~50% off this baseline).`
);

console.log(`line budget: ${total}/${CEILING} shipped lines (target ${TARGET})`);
