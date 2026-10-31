#!/usr/bin/env node
/**
 * Mutation check for `lib/platform/translate.dart`.
 *
 * Fifty-four green tests prove nothing on their own — the same lesson as the
 * dead-code scanner that reported "all clean" while itself being broken. This
 * script breaks one behaviour at a time and asserts the suite notices. A
 * mutation that survives is a hole in the tests, not a refactor.
 *
 * Each case: [name, exact source text, replacement]. The source text must
 * appear exactly once, or the case is reported as SKIP (a stale pattern is a
 * silent "pass" and would be worse than no check at all).
 */
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const root = path.join(__dirname, "..");
const file = path.join(root, "lib", "platform", "translate.dart");
const backup = path.join(root, ".mut", "pristine.dart");

const cases = [
  [
    "drops the proper-noun block",
    "      .where((String part) => !_isProperNoun(part))\n",
  ],
  [
    "per-provider leash",
    "      final int budget = remaining < _deps.perProviderTimeout.inMilliseconds\n          ? remaining\n          : _deps.perProviderTimeout.inMilliseconds;",
    "      const int budget = 999999;",
  ],
  [
    "force skips the cache",
    "    if (!options.force) {",
    "    if (true) {",
  ],
  [
    "cooldown is honoured",
    "      if (_cooling(adapter.id)) {",
    "      if (false) {",
  ],
  [
    "examples capped at two",
    "        if (examples.length >= 2) break;",
    "        if (examples.length >= 9) break;",
  ],
  [
    "secondary field capped at three",
    "  for (int i = 0; i < rest.length && picked.length < maxSecondarySenses; i++) {\n    picked.add(i);\n  }",
    "  for (int i = 0; i < rest.length; i++) {\n    picked.add(i);\n  }",
  ],
  [
    "a different part of speech is promoted",
    "    if (rest[i].pos.isNotEmpty && rest[i].pos != primary.pos) picked.add(i);",
    "    if (false) picked.add(i);",
  ],
  [
    "the cache key includes the language pair",
    "    '$from>$to:${term.trim().toLowerCase()}';",
    "    '${term.trim().toLowerCase()}';",
  ],
  [
    "google asks for zh-CN, not zh-CHS",
    "    return c.contains('tw') || c.contains('hk') ? 'zh-TW' : 'zh-CN';",
    "    return 'zh-CHS';",
  ],
  [
    "the dictionary only claims Chinese targets",
    "  bool canServe(String from, String to) => isChineseTarget(to);",
    "  bool canServe(String from, String to) => true;",
  ],
  [
    "a 411 in the body is a rate limit",
    "    if (parsed == null && _errorCodeOf(raw) == 411) {",
    "    if (false) {",
  ],
  [
    "myMemory drops low-confidence alternatives",
    "      if (value < 0.7) continue;",
    "      if (value < 0) continue;",
  ],
  [
    "the cache expires after its TTL",
    "    if (_options.clock.now() - record.at > _options.ttlMs) {",
    "    if (false) {",
  ],
  [
    "the cache drops the oldest key first",
    "    while (map.length > _options.max) {\n      map.remove(map.keys.first);\n    }",
    "    while (map.length > _options.max) {\n      map.remove(map.keys.last);\n    }",
  ],
  [
    "a cached result is marked as such",
    "    return record.result.fromCacheMarked();",
    "    return record.result;",
  ],
  [
    "an empty term never touches the network",
    "    if (cleaned.isEmpty) {\n      throw const LookupError(LookupFailure.notFound, 'empty term');\n    }",
    "",
  ],
];

const pristine = fs.readFileSync(backup, "utf8");

/**
 * A missing pubspec, a syntax error or a bad refactor all print `Error: …` and
 * exit non-zero, which would otherwise be indistinguishable from a test that
 * genuinely failed. Both signatures are checked because a compile error in the
 * test file and one in the library word themselves differently.
 */
function isCompileFailure(output) {
  if (/No pubspec\.yaml/.test(output)) return true;
  if (/Compilation failed/.test(output)) return true;
  return /Error: (?:[A-Z]|The \w+ .*isn't|Method not found|Undefined)/.test(output);
}

function runSuite() {
  try {
    // `flutterc` is a bash wrapper that pins HOME/APPDATA into the workspace, so
    // it has to be invoked through bash rather than exec'd directly on Windows.
    // The working directory must be the Flutter project root: Dart tools refuse
    // to run anywhere without a pubspec.yaml, and that refusal is an "Error:"
    // line that a naive matcher would read as a legitimate mutation catch.
    execFileSync("bash", ["../.flutter-sdk/flutterc", "test", "test/translate_test.dart"], {
      cwd: root,
      stdio: "pipe",
      timeout: 300000,
      // The reporter prints a line per test plus the stack of every failure, so
      // the default 1 MB cap silently truncates the `Failing tests:` summary at
      // the very end — which is exactly the block this script reads.
      maxBuffer: 64 * 1024 * 1024,
    });
    return { passed: true, output: "" };
  } catch (error) {
    const output = `${error.stdout ?? ""}${error.stderr ?? ""}`;
    return { passed: false, output };
  }
}

const results = [];
for (const [name, find, replace] of cases) {
  const count = pristine.split(find).length - 1;
  if (count !== 1) {
    results.push({ name, verdict: `SKIP (pattern matched ${count} times)` });
    continue;
  }
  fs.writeFileSync(file, pristine.replace(find, () => replace ?? ""));
  const { passed, output } = runSuite();
  if (passed) {
    results.push({ name, verdict: "SURVIVED - tests did not notice" });
    continue;
  }
  // A red suite is not proof the mutation was caught: a broken pattern can
  // simply fail to compile, which also exits non-zero. Require a real named
  // test failure with an assertion, otherwise call it what it is.
  //
  // The per-test progress lines read `00:00 +17 -1: <name> [E]` with no path,
  // so match the trailing summary block instead, whose lines do carry the path.
  const summary = output.slice(output.lastIndexOf("Failing tests:"));
  const named = (summary.match(/[\\/]test[/\\]translate_test\.dart: [^\n]+/g) ?? []).map(
    (line) => line.replace(/^.*translate_test\.dart: /, "").trim(),
  );
  if (named.length === 0) {
    const compile = isCompileFailure(output);
    results.push({
      name,
      verdict: compile ? "BROKE COMPILATION (not caught)" : "FAILED UNCLEARLY (not caught)",
    });
    continue;
  }
  // A compile error in a *different* file would also produce named failures, so
  // screen for that too. An uncaught exception in a test is a legitimate catch:
  // `lookupTerm` throwing where it should have returned fails the case just as
  // surely as a mismatched expectation.
  if (isCompileFailure(output)) {
    results.push({ name, verdict: "BROKE COMPILATION (not caught)" });
    continue;
  }
  results.push({ name, verdict: "caught", by: named.slice(0, 2) });
}

fs.writeFileSync(file, pristine);

let bad = 0;
for (const row of results) {
  const ok = row.verdict === "caught";
  if (!ok) bad++;
  const detail = ok ? `  (${(row.by ?? []).join(" | ")})` : `  <- ${row.verdict}`;
  console.log(`${ok ? "OK  " : "FAIL"} ${row.name}${detail}`);
}
console.log(`\n${results.length - bad}/${results.length} mutations caught`);
process.exit(bad === 0 ? 0 : 1);
