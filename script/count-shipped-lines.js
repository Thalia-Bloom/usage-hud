#!/usr/bin/env node
/**
 * Count lines in the Mac product tree (what we ship and run).
 * site/ and store/ are Bloom ops — packaging only, not in this total.
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const SHIPPED_DIRS = ['Sources', 'Tests', 'bin', 'script', 'launchd', 'Resources'];

const TEXT_EXT = new Set([
  '.swift', '.py', '.js', '.mjs', '.sh', '.plist', '.txt', '.json', '.svg', '.html', '.css', '.md'
]);
const SKIP_PARTS = new Set(['__pycache__', 'node_modules', '.git']);
const BINARY_EXT = new Set(['.png', '.webp', '.icns', '.car', '.mp4', '.gif', '.zip', '.woff2']);

function shouldCount(filePath) {
  const rel = path.relative(ROOT, filePath);
  const parts = rel.split(path.sep);
  if (parts.some((p) => SKIP_PARTS.has(p))) return false;
  const ext = path.extname(filePath).toLowerCase();
  if (BINARY_EXT.has(ext)) return false;
  if (parts[0] === 'bin' && ext === '') return true;
  if (TEXT_EXT.has(ext)) return true;
  return false;
}

function lineCount(filePath) {
  const buf = fs.readFileSync(filePath);
  if (buf.includes(0)) return 0;
  const text = buf.toString('utf8');
  return text ? text.split('\n').length - Number(text.endsWith('\n')) : 0;
}

function walk(dir, out) {
  if (!fs.existsSync(dir)) return;
  for (const name of fs.readdirSync(dir)) {
    const full = path.join(dir, name);
    const st = fs.statSync(full);
    if (st.isDirectory()) walk(full, out);
    else if (shouldCount(full)) out.push({ rel: path.relative(ROOT, full), lines: lineCount(full) });
  }
}

const byDir = Object.fromEntries(SHIPPED_DIRS.map((d) => [d, 0]));
let total = 0;
for (const dir of SHIPPED_DIRS) {
  const files = [];
  walk(path.join(ROOT, dir), files);
  for (const f of files) {
    const top = f.rel.split(path.sep)[0];
    byDir[top] += f.lines;
    total += f.lines;
  }
}

module.exports = { byDir, total, SHIPPED_DIRS };

if (require.main === module) {
  for (const d of SHIPPED_DIRS) console.log(`${d}: ${byDir[d]}`);
  console.log(`TOTAL: ${total}`);
}
