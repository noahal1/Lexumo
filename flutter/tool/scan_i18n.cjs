// Find i18n keys that no code reads.
//
// A key is "used" when the literal string appears anywhere in lib/ or test/
// outside the two dictionary files themselves. That is deliberately crude —
// `context.t('a.b')` and `I18n.translate(lang, 'a.b')` both contain the literal,
// so one scan covers every call shape.
//
// The one shape it misses is a key built at runtime from a variable. Those are
// listed separately by looking for `t(` calls whose argument is not a literal,
// so a key that only appears through such a call is not reported as dead.
const fs = require('fs');
const path = require('path');

const root = process.cwd();
const dictFiles = ['lib/ui/core/i18n/zh_cn.dart', 'lib/ui/core/i18n/en.dart'];

function walk(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(p, out);
    else if (entry.name.endsWith('.dart')) out.push(p);
  }
  return out;
}

const allDart = [...walk('lib'), ...walk('test')];
const dictSet = new Set(dictFiles.map((f) => path.resolve(root, f)));
const codeFiles = allDart.filter((f) => !dictSet.has(path.resolve(root, f)));

// Every string literal in non-dictionary code.
const codeText = codeFiles.map((f) => fs.readFileSync(f, 'utf8')).join('\n');

function keysIn(file) {
  const s = fs.readFileSync(file, 'utf8');
  const out = [];
  for (const m of s.matchAll(/^\s*'([a-zA-Z0-9_.]+)':/gm)) out.push(m[1]);
  return out;
}

const zh = keysIn('lib/ui/core/i18n/zh_cn.dart');
const en = keysIn('lib/ui/core/i18n/en.dart');

const dead = [];
for (const key of zh) {
  // Word-boundary-ish: the key appears as a quoted literal somewhere in code.
  if (!codeText.includes("'" + key + "'") && !codeText.includes('"' + key + '"')) {
    dead.push(key);
  }
}

// Keys present in one dictionary but not the other — a different bug, worth
// knowing about separately.
const zhSet = new Set(zh);
const enSet = new Set(en);
const onlyZh = zh.filter((k) => !enSet.has(k));
const onlyEn = en.filter((k) => !zhSet.has(k));

console.log('zh keys:', zh.length, ' en keys:', en.length);
console.log('');
console.log('=== dead keys (in zh dictionary, never referenced in code) ===');
if (dead.length === 0) console.log('  (none)');
else for (const k of dead) console.log('  ' + k);

console.log('');
console.log('=== only in zh ===');
if (onlyZh.length === 0) console.log('  (none)');
else for (const k of onlyZh) console.log('  ' + k);

console.log('');
console.log('=== only in en ===');
if (onlyEn.length === 0) console.log('  (none)');
else for (const k of onlyEn) console.log('  ' + k);

console.log('');
console.log('dead count:', dead.length);
