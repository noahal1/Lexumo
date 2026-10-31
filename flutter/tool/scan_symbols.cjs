// Find declared-but-never-referenced identifiers in the design token layer and
// the icon set. Those two files are almost entirely declarative, so a name that
// never appears outside its own declaration is dead weight.
//
// Method: collect every declared name from the target file, then count
// occurrences of that name across lib/ and test/. A name declared once and
// never mentioned again is dead. This is a heuristic — a name could collide
// with a Dart builtin — so the output is for review, not blind deletion.
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

const allDart = [...walk('lib'), ...walk('test')];
const corpus = allDart.map((f) => fs.readFileSync(f, 'utf8')).join('\n');

function countName(name) {
  // Count occurrences not immediately preceded by an identifier character, so
  // `x1` does not match inside `x10`.
  const re = new RegExp('(?<![A-Za-z0-9_$])' + name.replace(/[$]/g, '\\$') + '(?![A-Za-z0-9_$])', 'g');
  return (corpus.match(re) || []).length;
}

function scan(file, declPattern, label) {
  const src = fs.readFileSync(file, 'utf8');
  const names = [];
  for (const m of src.matchAll(declPattern)) names.push(m[1]);
  const dead = [];
  for (const name of names) {
    if (countName(name) <= 1) dead.push(name);
  }
  console.log(`=== ${label} (${file}) ===`);
  console.log(`declared ${names.length}, never used elsewhere: ${dead.length}`);
  for (const d of dead) console.log('  ' + d);
  console.log('');
  return { names, dead };
}

// tokens.dart: `static const double x1 = 4;` style + `static const String ui`
scan('lib/design/tokens.dart', /static const (?:double|String|int|Duration)? ?([A-Za-z_][A-Za-z0-9_]*)/g, 'tokens constants');

// lex_icon.dart: `static const String words = '...';` inside abstract final class Ic
scan('lib/ui/lex_icon.dart', /static const ([A-Za-z_][A-Za-z0-9_]*) =/g, 'Ic icon names');
