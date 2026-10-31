// Experiment: does explicitly initialising the WinRT apartment inside
// flutter_tts's Windows plugin constructor stop the release-only
// 0xC0000409 crash? Run --restore when done.
const fs = require("fs");
const path = require("path");

const file = path.join(
  "C:", "Users", "noaha", "prj", "lingueez-web", ".flutter-home",
  "AppData", "Local", "Pub", "Cache", "hosted", "pub.dev",
  "flutter_tts-4.2.5", "windows", "flutter_tts_plugin.cpp",
);
const backup = file + ".lexumo-backup";

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

const PATCHED = [
  "\tFlutterTtsPlugin::FlutterTtsPlugin() {",
  "\t\t// lexumo: WinRT needs an initialised apartment. The Flutter runner calls",
  "\t\t// CoInitializeEx but ignores its HRESULT, so on a machine where that",
  "\t\t// failed the calls below throw and MSVC fail-fasts the process.",
  "\t\ttry { winrt::init_apartment(winrt::apartment_type::single_threaded); } catch (...) {}",
  "\t\tsynth = SpeechSynthesizer();",
  "\t\taddMplayer();",
  "\t\tisPaused = false;",
  "\t\tisSpeaking = false;",
  "\t\tawaitSpeakCompletion = false;",
  "\t\tspeakResult = FlutterResult();",
  "\t}",
].join("\n");

const src = fs.readFileSync(file, "utf8");
if (!src.includes(ORIGINAL)) {
  console.error("anchor not found — file is patched or changed");
  process.exit(1);
}
if (!fs.existsSync(backup)) fs.writeFileSync(backup, src, "utf8");
fs.writeFileSync(file, src.replace(ORIGINAL, PATCHED), "utf8");
console.log("patched with init_apartment");
