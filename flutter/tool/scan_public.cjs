// Find public top-level declarations that nothing outside their own file
// references. The analyzer already reports unused *private* members; this
// covers the public surface, which it deliberately leaves alone.
//
// A declaration is dead when no other file mentions its name AND its own file
// mentions it only on lines that define it (the declaration itself and any
// constructor). Counting raw occurrences is wrong: `class Foo` followed by
// `const Foo({...})` is already two mentions in one file, so a naive
// "appears only once" test never fires and every dead class looks alive.
//
// NOTE: on Windows path.join yields backslashes, so every path is normalised to
// forward slashes before prefix comparison. Skipping that scans nothing and
// reports a false all-clear.
const fs = require('fs');
const path = require('path');

const norm = (p) => p.split(String.fromCharCode(92)).join('/');

function walk(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(p, out);
    else if (entry.name.endsWith('.dart')) out.push(p);
  }
  return out;
}

const files = [...walk('lib'), ...walk('test')];
const perFile = new Map(files.map((f) => [norm(f), fs.readFileSync(f, 'utf8')]));

function nameRe(name) {
  return new RegExp('(?<![A-Za-z0-9_$])' + name.replace(/[$]/g, '\\$') + '(?![A-Za-z0-9_$])');
}

// Lines in `src` that mention `name`, excluding declaration and constructor
// definition lines. A constructor looks like `const Name(`, `Name({`, `Name._(`
// possibly after `factory`/`const`/`new`.
function realUses(src, name) {
  const re = nameRe(name);
  const esc = name.replace(/[$]/g, '\\$');
  const declRe = new RegExp('^(?:abstract |sealed |final |base )*(?:class|mixin|enum|extension|typedef)\\s+' + esc + '\\b');
  const ctorRe = new RegExp('^\\s*(?:(?:const|factory|new)\\s+)?' + esc + '\\s*[.({]');
  let n = 0;
  for (const line of src.split(/\r?\n/)) {
    if (!re.test(line)) continue;
    if (declRe.test(line)) continue;
    // A definition terminates with ';' or opens a body/initialiser with
    // '{'; an instantiation continues with ',' or ')'.
    const trimmed = line.trimEnd();
    if (ctorRe.test(line) && (trimmed.endsWith(';') || trimmed.endsWith('{'))) continue;
    // A top-level function signature. Column 0 keeps indented calls out.
    const topLevelFn = new RegExp('^[A-Za-z_][A-Za-z0-9_<>,?\\[\\] ]*\\s+' + esc + '\\s*[(<]');
    if (topLevelFn.test(line)) continue;
    n++;
  }
  return n;
}

const skip = new Set(['lib/i18n/zh_cn.dart', 'lib/i18n/en.dart', 'lib/ui/icon_paths.dart']);

const declRe = /^(?:abstract |sealed |final |base )*(?:class|mixin|enum|extension|typedef) ([A-Za-z_][A-Za-z0-9_]*)|^(?:Future<[^>]*>|void|bool|int|double|String|Widget|List<[^>]*>|Map<[^>]*>|[A-Z][A-Za-z0-9_]*\??) ([a-z_][A-Za-z0-9_]*)\(/gm;

const dead = [];
let scanned = 0;
for (const [file, src] of perFile) {
  if (!file.startsWith('lib/') || skip.has(file)) continue;
  scanned++;
  for (const m of src.matchAll(declRe)) {
    const name = m[1] || m[2];
    if (!name || name === 'main') continue;
    // Private members are already covered by the analyzer's unused_element.
    if (name.startsWith('_')) continue;
    // Extensions are used through their members, never by name.
    if (m[0].startsWith('extension')) continue;
    const re = nameRe(name);
    let inOthers = 0;
    for (const [other, otherSrc] of perFile) {
      if (other === file) continue;
      if (re.test(otherSrc)) inOthers++;
    }
    if (inOthers > 0) continue;
    if (realUses(src, name) > 0) continue;
    dead.push({ file, name });
  }
}

console.log('lib files scanned:', scanned);
console.log('');
console.log('=== public declarations with no external reference and no real local use ===');
if (dead.length === 0) console.log('  (none)');
else for (const d of dead) console.log(`  ${d.file}: ${d.name}`);
console.log('');
console.log('count:', dead.length);
