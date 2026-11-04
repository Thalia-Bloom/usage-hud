#!/usr/bin/env node
/**
 * Fail if the Mac product tree (or root install docs) contain Bloom-private paths,
 * hostnames, keys or other secrets. Public product URLs and support@thaliabloom.com are OK.
 */
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { SHIPPED_DIRS } = require('./count-shipped-lines.js');

const ROOT = path.resolve(__dirname, '..');
const ROOT_DOCS = ['README.md', 'INSTALL.md', 'LICENSE'];

const FORBIDDEN = [
  { re: /\/Users\/thalia\b/i, label: 'owner home path' },
  { re: /playground-cursor|PLAYGROUND_(URL|AGENT|REQUEST)/i, label: 'Playground internals' },
  { re: /origin\.cursor\.com/i, label: 'private Cursor host' },
  { re: /\bHeathrow\b/, label: 'private personal name' },
  { re: /\bMac mini\b/i, label: 'Bloom infra host' },
  { re: /door\.thaliabloom\.com/i, label: 'private collector host' },
  { re: /\bDOOR_KEY\s*=\s*['"][^'"]{6,}['"]/, label: 'literal door key' },
  { re: /sk-[a-zA-Z0-9]{20,}/, label: 'API secret shape' },
  { re: /whsec_[a-zA-Z0-9]+/, label: 'webhook secret shape' },
  { re: /-----BEGIN (RSA |EC )?PRIVATE KEY-----/, label: 'private key block' },
];

const SKIP_PARTS = new Set(['__pycache__', 'node_modules', '.git']);
const BINARY_EXT = new Set(['.png', '.webp', '.icns', '.car', '.mp4', '.gif', '.zip', '.woff2']);

function shouldScan(filePath) {
  const rel = path.relative(ROOT, filePath);
  if (rel === path.join('script', 'test-shipped-open-source.js')) return false;
  const parts = rel.split(path.sep);
  if (parts.some((p) => SKIP_PARTS.has(p))) return false;
  const ext = path.extname(filePath).toLowerCase();
  if (BINARY_EXT.has(ext)) return false;
  if (parts[0] === 'bin' && ext === '') return true;
  return ext !== '' || rel.endsWith('LICENSE');
}

function walk(dir, out) {
  if (!fs.existsSync(dir)) return;
  for (const name of fs.readdirSync(dir)) {
    const full = path.join(dir, name);
    const st = fs.statSync(full);
    if (st.isDirectory()) walk(full, out);
    else if (shouldScan(full)) out.push(full);
  }
}

function scanFile(filePath) {
  const buf = fs.readFileSync(filePath);
  if (buf.includes(0)) return [];
  return scanText(path.relative(ROOT, filePath), buf.toString('utf8'));
}

function scanText(rel, text) {
  if (rel === 'script/test-shipped-open-source.js') return [];
  const hits = [];
  for (const { re, label } of FORBIDDEN) {
    if (re.test(text)) hits.push({ rel, label, re: re.source });
  }
  return hits;
}

const files = [];
for (const doc of ROOT_DOCS) {
  const full = path.join(ROOT, doc);
  if (fs.existsSync(full)) files.push(full);
}
for (const dir of [...SHIPPED_DIRS, 'hooks', 'fixtures']) walk(path.join(ROOT, dir), files);
for (const name of ['Makefile', 'Package.swift', 'Package.resolved']) files.push(path.join(ROOT, name));

const fromStdin = process.argv.includes('--stdin');
const violations = fromStdin
  ? JSON.parse(fs.readFileSync(0, 'utf8')).flatMap(([name, text]) => scanText(name, text))
  : files.flatMap(scanFile);

assert.strictEqual(
  violations.length,
  0,
  `Open-source hygiene failed:\n${violations.map((v) => `  ${v.rel}: ${v.label} (${v.re})`).join('\n')}`
);

console.log(`open-source hygiene: ${fromStdin ? 'export' : files.length + ' files'}, 0 forbidden patterns`);
