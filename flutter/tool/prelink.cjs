// Creates the plugin symlinks that Flutter's Dart-side code cannot create here
// (errno 1314: the token lacks SeCreateSymbolicLinkPrivilege even with Developer
// Mode on). mklink /D works, and flutter_plugins.dart skips a link that already
// points at the right target, so pre-creating them is enough.
//
// Usage: node prelink.cjs [projectDir]   (default: the flutter/ project)
const fs = require("fs");
const path = require("path");

const proj = path.resolve(process.argv[2] || path.join(__dirname, ".."));
const depsFile = path.join(proj, ".flutter-plugins-dependencies");
if (!fs.existsSync(depsFile)) {
  console.error(`no ${depsFile} — run "flutter pub get" first`);
  process.exit(1);
}

const deps = JSON.parse(fs.readFileSync(depsFile, "utf8"));
const linkDir = path.join(proj, "windows", "flutter", "ephemeral", ".plugin_symlinks");
fs.mkdirSync(linkDir, { recursive: true });

const plugins = (deps.plugins && deps.plugins.windows) || [];
const lines = ["@echo off"];
let queued = 0;

for (const p of plugins) {
  // That generated file escapes separators twice, so a parsed path can hold runs
  // of backslashes. Collapse them, then trim the trailing separator (mklink
  // treats it as part of the name).
  const target = p.path.replace(/\\{2,}/g, "\\").replace(/[\\/]+$/, "");
  const link = path.join(linkDir, p.name);
  if (fs.existsSync(link)) {
    console.log(`exists  ${p.name}`);
    continue;
  }
  lines.push(`mklink /D "${link}" "${target}"`);
  console.log(`queue   ${p.name} -> ${target}`);
  queued++;
}
lines.push("exit /b 0");

const bat = path.join(proj, "windows", "flutter", "ephemeral", "_mklinks.bat");
fs.writeFileSync(bat, lines.join("\r\n"), "utf8");
console.log(`\nwrote ${bat} (${queued} links, ${plugins.length - queued} already present)`);
