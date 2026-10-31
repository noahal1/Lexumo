const fs = require('fs');
const file = process.argv[2] || '.shots/kb-words.xml';
const s = fs.readFileSync(file, 'utf8');
const texts = [...s.matchAll(/(?:text|content-desc)="([^"]+)"/g)]
  .map((m) => m[1])
  .filter(Boolean);

console.log('unique labels:');
[...new Set(texts)].slice(0, 40).forEach((t) => console.log('  *', t.slice(0, 70)));

console.log('\nshortcut traces:');
const probes = ['Ctrl', 'Enter', 'Esc', 'Tab', 'Shift'];
let found = 0;
for (const p of probes) {
  const hit = texts.some((t) => t.includes(p));
  if (hit) found++;
  console.log(`  ${p}: ${hit ? 'PRESENT' : 'absent'}`);
}
const hasKeycapLine = texts.some((t) => t.includes('Ctrl+') || /^[?\/n]$/.test(t));
console.log(`  bare keycap token: ${hasKeycapLine ? 'PRESENT' : 'absent'}`);
console.log(`\nverdict: ${found === 0 && !hasKeycapLine ? 'CLEAN (no keyboard hints)' : 'HINTS STILL VISIBLE'}`);
