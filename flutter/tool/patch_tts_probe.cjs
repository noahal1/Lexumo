// Diagnostic patch for flutter_tts's Windows plugin.
//
// Symptom it investigates: a release (AOT) build of ANY app that depends on
// flutter_tts dies with 0xC0000409 (STATUS_STACK_BUFFER_OVERRUN, i.e. the CRT
// fail-fast that MSVC raises for an uncaught C++ exception) within ~2s of
// launch, while the same app in debug mode runs fine. Wrapping the plugin's
// constructor in try/catch stops the crash, which places the throwing call
// inside FlutterTtsPlugin::FlutterTtsPlugin().
//
// Writes into the pub cache, so always revert with --restore.
const fs = require("fs");
const path = require("path");

const file = path.join(
  "C:", "Users", "noaha", "prj", "lingueez-web", ".flutter-home",
  "AppData", "Local", "Pub", "Cache", "hosted", "pub.dev",
  "flutter_tts-4.2.5", "windows", "flutter_tts_plugin.cpp",
);
const backup = file + ".lexumo-backup";
const logFile = "C:\\\\Users\\\\noaha\\\\prj\\\\lingueez-web\\\\.winrun\\\\tts-probe.log";

if (process.argv.includes("--restore")) {
  if (!fs.existsSync(backup)) {
    console.error("nothing to restore");
    process.exit(1);
  }
  fs.copyFileSync(backup, file);
  fs.unlinkSync(backup);
  console.log("restored");
  process.exit(0);
}

const ORIGINAL = [
  "\tFlutterTtsPlugin::FlutterTtsPlugin() {",
  "\t\tsynth = SpeechSynthesizer();",
  "\t\taddMplayer();",
  "\t\tisPaused = false;",
  "\t\tisSpeaking = false;",
  "\t\tawaitSpeakCompletion = false;",
  "\t\tspeakResult = FlutterResult();",
  "\t}",
].join("\n");

// Each step logs before it runs, so the last line in the log names the call
// that threw.
const PATCHED = [
  "\tFlutterTtsPlugin::FlutterTtsPlugin() {",
  "\t\tisPaused = false;",
  "\t\tisSpeaking = false;",
  "\t\tawaitSpeakCompletion = false;",
  "\t\tspeakResult = FlutterResult();",
  `\t\tFILE* _lg = fopen("${logFile}", "w");`,
  '\t\tif (_lg) { fprintf(_lg, "ctor entered\\n"); fflush(_lg); }',
  "\t\ttry {",
  '\t\t\tif (_lg) { fprintf(_lg, "calling SpeechSynthesizer...\\n"); fflush(_lg); }',
  "\t\t\tsynth = SpeechSynthesizer();",
  '\t\t\tif (_lg) { fprintf(_lg, "SpeechSynthesizer OK\\n"); fflush(_lg); }',
  '\t\t\tif (_lg) { fprintf(_lg, "calling addMplayer...\\n"); fflush(_lg); }',
  "\t\t\taddMplayer();",
  '\t\t\tif (_lg) { fprintf(_lg, "addMplayer OK\\n"); fflush(_lg); }',
  '\t\t\tif (_lg) { fprintf(_lg, "ctor done\\n"); fflush(_lg); }',
  "\t\t} catch (const winrt::hresult_error& e) {",
  '\t\t\tif (_lg) { fprintf(_lg, "THREW hresult 0x%08X\\n", (unsigned)e.code()); fflush(_lg); }',
  "\t\t} catch (const std::exception& e) {",
  '\t\t\tif (_lg) { fprintf(_lg, "THREW std::exception: %s\\n", e.what()); fflush(_lg); }',
  "\t\t} catch (...) {",
  '\t\t\tif (_lg) { fprintf(_lg, "THREW unknown\\n"); fflush(_lg); }',
  "\t\t}",
  "\t}",
].join("\n");

const src = fs.readFileSync(file, "utf8");
if (!src.includes(ORIGINAL)) {
  console.error("anchor not found — already patched, or the file changed");
  process.exit(1);
}
if (!fs.existsSync(backup)) fs.writeFileSync(backup, src, "utf8");
fs.writeFileSync(file, src.replace(ORIGINAL, PATCHED), "utf8");
console.log("patched", file);
