// Lexumo patch for the vendored flutter_tts Windows plugin.
//
// THE CRASH: SpeechSynthesizer's MEMBER default constructor performs WinRT
// activation. On this machine that activation throws, and because it happens
// during member initialisation -- before the constructor body runs -- there is
// no try/catch that can reach it. The C++ runtime fail-fasts the process with
// 0xC0000409 (STATUS_STACK_BUFFER_OVERRUN) and the app dies before it draws.
//
// THE FIX: default-construct both members to null (no activation, cannot throw)
// and activate inside the constructor body under try/catch, recording whether
// it worked in `ready`. Every entry point checks that flag first, so a machine
// where activation fails gets a plugin that answers "no speech" instead of a
// process that dies on startup.
//
// Only the desktop (WINAPI_FAMILY_DESKTOP_APP) half of the file is touched; the
// UWP half after `#else` is left exactly as upstream shipped it.
//
//   node .winrun/patch_tts_deferred.cjs
//   node .winrun/patch_tts_deferred.cjs --restore
const fs = require('fs');
const path = require('path');

const SRC = path.join(
  __dirname, '..', 'third_party',
  'flutter_tts', 'windows', 'flutter_tts_plugin.cpp',
);
const BACKUP = SRC + '.lexpristine';

if (process.argv.includes('--restore')) {
  if (fs.existsSync(BACKUP)) {
    fs.copyFileSync(BACKUP, SRC);
    fs.unlinkSync(BACKUP);
    console.log('restored');
  } else {
    console.log('nothing to restore');
  }
  process.exit(0);
}

if (!fs.existsSync(BACKUP)) fs.copyFileSync(SRC, BACKUP);
const whole = fs.readFileSync(BACKUP, 'utf8');

// Split at the UWP branch so anchors stay unique and the UWP half is untouched.
const SPLIT = '\n#else\n';
const cut = whole.indexOf(SPLIT);
if (cut < 0) throw new Error('#else split point not found');
const head = whole.slice(0, cut);
const tail = whole.slice(cut);

let src = head;

function sub(from, to, label) {
  const n = src.split(from).length - 1;
  if (n !== 1) throw new Error(`${label}: anchor matched ${n} times, want 1`);
  const i = src.indexOf(from);
  src = src.slice(0, i) + to + src.slice(i + from.length);
}

// 1. members: null-construct, no activation, cannot throw
sub(
  '\t\tSpeechSynthesizer synth;\n' +
  '\t\twinrt::Windows::Media::Playback::MediaPlayer mPlayer;\n',
  '\t\t// Lexumo patch: null-constructed so member initialisation performs no\n' +
  '\t\t// WinRT activation. A throw there cannot be caught and fail-fasts the\n' +
  '\t\t// process; activate() does it inside a try/catch instead.\n' +
  '\t\tSpeechSynthesizer synth{ nullptr };\n' +
  '\t\twinrt::Windows::Media::Playback::MediaPlayer mPlayer{ nullptr };\n' +
  '\t\tbool ready = false;\n',
  'members',
);

// 2. declare activate()
sub(
  '\t\tvoid addMplayer();\n',
  '\t\tvoid addMplayer();\n\t\tbool activate();\n',
  'addMplayer decl',
);

// 3. constructor body: activate under try/catch
sub(
  '\tFlutterTtsPlugin::FlutterTtsPlugin() {\n' +
  '\t\tsynth = SpeechSynthesizer();\n' +
  '\t\taddMplayer();\n',
  '\t// Lexumo patch: activation happens here, where a C++ exception can be\n' +
  '\t// caught, rather than in a member initialiser where it cannot.\n' +
  '\tbool FlutterTtsPlugin::activate() {\n' +
  '\t\tif (ready) return true;\n' +
  '\t\ttry {\n' +
  '\t\t\tsynth = SpeechSynthesizer();\n' +
  '\t\t\taddMplayer();\n' +
  '\t\t\tready = true;\n' +
  '\t\t} catch (...) {\n' +
  '\t\t\tready = false;\n' +
  '\t\t}\n' +
  '\t\treturn ready;\n' +
  '\t}\n' +
  '\n' +
  '\tFlutterTtsPlugin::FlutterTtsPlugin() {\n' +
  '\t\tactivate();\n',
  'ctor',
);

// 4. destructor: Close() on a null player throws out of a destructor
sub(
  '\tFlutterTtsPlugin::~FlutterTtsPlugin() { mPlayer.Close(); }\n',
  '\tFlutterTtsPlugin::~FlutterTtsPlugin() {\n' +
  '\t\t// Lexumo patch: Close() on a null player would throw out of a dtor.\n' +
  '\t\tif (ready) {\n' +
  '\t\t\ttry { mPlayer.Close(); } catch (...) {}\n' +
  '\t\t}\n' +
  '\t}\n',
  'dtor',
);

// 5. addMplayer is called from activate() (inside try/catch) and from stop()
// (inside the Dart message loop, where a throw is just as fatal). Make it safe
// at both call sites instead of depending on the caller.
sub(
  '\tvoid FlutterTtsPlugin::addMplayer() {\n' +
  '\t\tmPlayer = winrt::Windows::Media::Playback::MediaPlayer::MediaPlayer();\n',
  '\tvoid FlutterTtsPlugin::addMplayer() {\n' +
  '\t\ttry {\n' +
  '\t\tmPlayer = winrt::Windows::Media::Playback::MediaPlayer::MediaPlayer();\n',
  'addMplayer open',
);
sub(
  '\t\t\t\t\tisSpeaking = false;\n' +
  '\t\t\t\t});\n' +
  '\t}\n',
  '\t\t\t\t\tisSpeaking = false;\n' +
  '\t\t\t\t});\n' +
  '\t\t} catch (...) {\n' +
  '\t\t\tready = false;\n' +
  '\t\t}\n' +
  '\t}\n',
  'addMplayer close',
);

// 6. guard each entry point. Methods owning a FlutterResult answer 0 ("did not
// work") so the Dart side gets a reply instead of hanging forever.
const GUARDS = [
  ['\tvoid FlutterTtsPlugin::pause() {\n', '\t\tif (!ready) return;\n'],
  ['\tvoid FlutterTtsPlugin::continuePlay() {\n', '\t\tif (!ready) return;\n'],
  ['\tvoid FlutterTtsPlugin::stop() {\n', '\t\tif (!ready) return;\n'],
  [
    '\tvoid FlutterTtsPlugin::getVoices(flutter::EncodableList& voices) {\n',
    '\t\tif (!ready) return;\n',
  ],
  [
    '\tvoid FlutterTtsPlugin::getLanguages(flutter::EncodableList& languages) {\n',
    '\t\tif (!ready) return;\n',
  ],
  [
    '\tvoid FlutterTtsPlugin::setVoice(const std::string voiceLanguage, const std::string voiceName, FlutterResult& result) {\n',
    '\t\tif (!ready) { result->Success(0); return; }\n',
  ],
  [
    '\tvoid FlutterTtsPlugin::setLanguage(const std::string voiceLanguage, FlutterResult& result) {\n',
    '\t\tif (!ready) { result->Success(0); return; }\n',
  ],
  [
    '\tvoid FlutterTtsPlugin::speak(const std::string text, FlutterResult result) {\n',
    '\t\tif (!ready) { result->Success(0); return; }\n',
  ],
  [
    '\twinrt::Windows::Foundation::IAsyncAction FlutterTtsPlugin::asyncSpeak(const std::string text) {\n',
    '\t\tif (!ready) co_return;\n',
  ],
];
for (const [anchor, guard] of GUARDS) sub(anchor, anchor + guard, anchor.trim());

// 7. the three one-liners that touch synth.Options()
for (const [name, arg] of [
  ['setVolume', 'newVolume'],
  ['setPitch', 'newPitch'],
  ['setRate', 'newRate'],
]) {
  const re = new RegExp(`\\tvoid FlutterTtsPlugin::${name}\\(const double ${arg}\\) \\{ (.*?) \\}\\n`);
  const m = src.match(re);
  if (!m) throw new Error(`${name}: one-liner not found`);
  sub(m[0], `\tvoid FlutterTtsPlugin::${name}(const double ${arg}) { if (!ready) return; ${m[1]} }\n`, name);
}

fs.writeFileSync(SRC, src + tail);
console.log('patched   ' + SRC);
console.log('ready guard sites: ' + (head === src ? 0 : (src.match(/!ready/g) || []).length));
console.log('activate() defs  : ' + (src.match(/bool FlutterTtsPlugin::activate/g) || []).length);
