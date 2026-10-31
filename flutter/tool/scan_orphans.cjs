// Find lib/ files that no other file imports — orphans.
//
// Skips main.dart (the entry point, imported by nothing) and files reached only
// through `part`/`export` (none here, but cheap to be safe).
const fs = require('fs');
const path = require('path');

function walk(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(p, out);
    else if (entry.name.endsWith('.dart')) out.push(p);
  }
  return out;
}

const libFiles = walk('lib');
const testFiles = walk('test');
const all = [...libFiles, ...testFiles];

// For each file, which other files mention its basename in an import?
function importersOf(file) {
  const base = path.basename(file, '.dart');
  const out = [];
  for (const other of all) {
    if (path.resolve(other) === path.resolve(file)) continue;
    const src = fs.readFileSync(other, 'utf8');
    // `import '.../base.dart';` — match the basename in any relative import.
    const re = new RegExp("import\\s+'[^']*/" + base + "\\.dart'|import\\s+'" + base + "\\.dart'");
    if (re.test(src)) out.push(other);
  }
  return out;
}

console.log('=== orphan lib files (nothing imports them) ===');
let n = 0;
for (const f of libFiles) {
  const rel = f.replace(/\\/g, '/');
  if (rel === 'lib/main.dart') continue;
  const importers = importersOf(f);
  if (importers.length === 0) {
    console.log('  ' + rel);
    n++;
  }
}
if (n === 0) console.log('  (none)');
console.log('count:', n);

console.log('');
console.log('=== lib files imported only by tests (never by lib) ===');
let m = 0;
for (const f of libFiles) {
  const rel = f.replace(/\\/g, '/');
  if (rel === 'lib/main.dart') continue;
  const importers = importersOf(f);
  const byLib = importers.filter((p) => p.replace(/\\/g, '/').startsWith('lib/'));
  if (importers.length > 0 && byLib.length === 0) {
    console.log('  ' + rel + '  <- ' + importers.map((p) => p.replace(/\\/g, '/')).join(', '));
    m++;
  }
}
if (m === 0) console.log('  (none)');
console.log('count:', m);
