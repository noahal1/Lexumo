// Tests for the speech seam.
//
// The point of `lib/data/services/tts.dart` is that everything above it is testable
// without a platform channel, so these tests drive [Speech] through a fake
// [TtsEngine] and assert on what the engine was asked to do. The things worth
// pinning down are the ones where the port had to make a decision the web
// build did not face:
//
//   * the rate conversion (web scale 1.0 → plugin scale 0.5),
//   * the voice URI round trip (a persisted handle must survive a restart in
//     which no in-memory voice map exists),
//   * `supported` before and after a failed warm-up,
//   * `onEnd` firing exactly once.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/data/services/tts.dart';

/// Records everything the service asks for, and can be made to fail.
class FakeEngine implements TtsEngine {
  FakeEngine({this.initOk = true, List<VoiceInfo>? voices})
      : _voices = voices ?? const <VoiceInfo>[];

  bool initOk;
  List<VoiceInfo> _voices;

  int initCalls = 0;
  final List<String> spoken = <String>[];
  final List<String> languages = <String>[];
  final List<double> rates = <double>[];
  final List<VoiceInfo?> voicesSet = <VoiceInfo?>[];
  int stopCalls = 0;
  VoidCallback? _onDone;

  @override
  set onDone(VoidCallback? callback) => _onDone = callback;

  /// Pretends the engine finished an utterance.
  void finish() => _onDone?.call();

  @override
  Future<bool> init() async {
    initCalls++;
    return initOk;
  }

  @override
  Future<List<VoiceInfo>> voices() async => _voices;

  void setVoices(List<VoiceInfo> list) => _voices = list;

  @override
  Future<void> setLanguage(String lang) async => languages.add(lang);

  @override
  Future<void> setRate(double rate) async => rates.add(rate);

  @override
  Future<void> setVoice(VoiceInfo? voice) async => voicesSet.add(voice);

  @override
  Future<void> speak(String text) async => spoken.add(text);

  @override
  Future<void> stop() async => stopCalls++;
}

/// A [Speech] whose voice polling never actually waits.
Speech buildSpeech(TtsEngine engine) =>
    Speech(engine: engine, delay: (Duration _) async {});

VoiceInfo voice(String lang, String name, {bool local = true}) => VoiceInfo(
      uri: 'tts:${Uri.encodeComponent(lang)}:${Uri.encodeComponent(name)}',
      name: name,
      lang: lang,
      local: local,
    );

void main() {
  group('supported', () {
    test('answers true before the first probe, so the button does not flash',
        () {
      final engine = FakeEngine(initOk: false);
      final speech = buildSpeech(engine);
      expect(speech.supported, isTrue);
      expect(speech.isReady, isFalse);
    });

    test('answers false after a failed warm-up', () async {
      final speech = buildSpeech(FakeEngine(initOk: false));
      expect(await speech.warmUp(), isFalse);
      expect(speech.supported, isFalse);
      expect(speech.isReady, isTrue);
    });

    test('stays true after a successful warm-up', () async {
      final speech = buildSpeech(FakeEngine(voices: [voice('en-US', 'A')]));
      expect(await speech.warmUp(), isTrue);
      expect(speech.supported, isTrue);
    });

    test('warm-up runs the engine exactly once', () async {
      final engine = FakeEngine(voices: [voice('en-US', 'A')]);
      final speech = buildSpeech(engine);
      await speech.warmUp();
      await speech.warmUp();
      await speech.warmUp();
      expect(engine.initCalls, 1);
    });
  });

  group('rate', () {
    test('converts the web scale to the plugin scale', () async {
      final engine = FakeEngine(voices: [voice('en-US', 'A')]);
      final speech = buildSpeech(engine);
      // The stored default is 0.95 (web scale); the plugin's normal is 0.5.
      await speech.speak('hello', lang: 'en-US', rate: 0.95);
      expect(engine.rates.single, closeTo(0.475, 1e-9));
    });

    test('1.0 stays 0.5, and the slider bounds map inside the valid range',
        () async {
      final engine = FakeEngine(voices: [voice('en-US', 'A')]);
      final speech = buildSpeech(engine);
      await speech.speak('a', lang: 'en-US', rate: 1.0);
      await speech.speak('b', lang: 'en-US', rate: 0.5);
      await speech.speak('c', lang: 'en-US', rate: 1.5);
      expect(engine.rates, [0.5, 0.25, 0.75]);
    });

    test('a missing rate is normal speed', () async {
      final engine = FakeEngine(voices: [voice('en-US', 'A')]);
      final speech = buildSpeech(engine);
      await speech.speak('a', lang: 'en-US');
      expect(engine.rates.single, 0.5);
    });

    test('clamps a rate the settings page could never produce', () async {
      final engine = FakeEngine(voices: [voice('en-US', 'A')]);
      final speech = buildSpeech(engine);
      await speech.speak('a', lang: 'en-US', rate: 99);
      await speech.speak('b', lang: 'en-US', rate: -3);
      expect(engine.rates, [0.75, 0.25]);
    });
  });

  group('voice selection', () {
    test('picks the exact language tag over a same-base one', () async {
      final engine = FakeEngine(voices: [
        voice('en-GB', 'British'),
        voice('en-US', 'American'),
      ]);
      final speech = buildSpeech(engine);
      await speech.speak('hello', lang: 'en-US');
      expect(engine.voicesSet.single?.name, 'American');
    });

    test('prefers a local voice when both match equally', () async {
      final engine = FakeEngine(voices: [
        voice('en-US', 'Remote', local: false),
        voice('en-US', 'Local', local: true),
      ]);
      final speech = buildSpeech(engine);
      await speech.speak('hello', lang: 'en-US');
      expect(engine.voicesSet.single?.name, 'Local');
    });

    test('honours a stored voice URI', () async {
      final chosen = voice('en-GB', 'British');
      final engine = FakeEngine(voices: [voice('en-US', 'American'), chosen]);
      final speech = buildSpeech(engine);
      await speech.speak('hello', lang: 'en-US', voiceURI: chosen.uri);
      expect(engine.voicesSet.single, chosen);
    });

    test('falls back to the language when the stored voice is gone', () async {
      final engine = FakeEngine(voices: [voice('en-US', 'American')]);
      final speech = buildSpeech(engine);
      // A voice the user picked on another device, no longer installed.
      await speech.speak(
        'hello',
        lang: 'en-US',
        voiceURI: voice('en-GB', 'Uninstalled').uri,
      );
      // The URI still carries name+locale, so it is honoured by identity
      // rather than dropped: the platform decides whether it exists.
      expect(engine.voicesSet.single?.name, 'Uninstalled');
      expect(engine.voicesSet.single?.lang, 'en-GB');
    });

    test('ignores a voice URI the web build wrote', () async {
      final engine = FakeEngine(voices: [voice('en-US', 'American')]);
      final speech = buildSpeech(engine);
      // Web Speech's own `voiceURI` — not our `tts:` scheme.
      await speech.speak(
        'hello',
        lang: 'en-US',
        voiceURI: 'Microsoft David - English (United States)',
      );
      expect(engine.voicesSet.single?.name, 'American');
    });

    test('sets the language even when no voice matches', () async {
      final engine = FakeEngine(voices: const []);
      final speech = buildSpeech(engine);
      await speech.speak('bonjour', lang: 'fr-FR');
      expect(engine.languages, contains('fr-FR'));
    });
  });

  group('speak', () {
    test('trims and refuses empty text, still calling onEnd', () async {
      final engine = FakeEngine(voices: [voice('en-US', 'A')]);
      final speech = buildSpeech(engine);
      var ended = 0;
      await speech.speak('   ', onEnd: () => ended++);
      expect(engine.spoken, isEmpty);
      expect(ended, 1);
    });

    test('does not speak when the engine is unusable', () async {
      final engine = FakeEngine(initOk: false);
      final speech = buildSpeech(engine);
      var ended = 0;
      await speech.speak('hello', lang: 'en-US', onEnd: () => ended++);
      expect(engine.spoken, isEmpty);
      expect(ended, 1);
    });

    test('fires onEnd once even if the engine reports twice', () async {
      final engine = FakeEngine(voices: [voice('en-US', 'A')]);
      final speech = buildSpeech(engine);
      var ended = 0;
      await speech.speak('hello', lang: 'en-US', onEnd: () => ended++);
      // The plugin can emit both a completion and a cancel for one utterance.
      engine.finish();
      engine.finish();
      expect(ended, 1);
    });

    test('speaks the trimmed text', () async {
      final engine = FakeEngine(voices: [voice('en-US', 'A')]);
      final speech = buildSpeech(engine);
      await speech.speak('  soliloquy  ', lang: 'en-US');
      expect(engine.spoken.single, 'soliloquy');
    });
  });

  group('stop', () {
    test('is a no-op before the engine was ever warmed', () async {
      final engine = FakeEngine();
      final speech = buildSpeech(engine);
      await speech.stop();
      expect(engine.stopCalls, 0);
    });

    test('forwards once warm', () async {
      final engine = FakeEngine(voices: [voice('en-US', 'A')]);
      final speech = buildSpeech(engine);
      await speech.warmUp();
      await speech.stop();
      expect(engine.stopCalls, 1);
    });
  });

  group('voicesFor', () {
    test('matches on the base language across separators', () {
      final all = [
        voice('en_US', 'Underscore'),
        voice('en-GB', 'British'),
        voice('fr-FR', 'French'),
      ];
      final english = voicesFor(all, 'en-US');
      expect(english.length, 2);
      expect(english.first.name, 'Underscore');
    });

    test('returns nothing for an empty language', () {
      expect(voicesFor([voice('en-US', 'A')], ''), isEmpty);
    });
  });

  group('onVoicesChanged', () {
    test('notifies subscribers when the list arrives', () async {
      final engine = FakeEngine(voices: [voice('en-US', 'A')]);
      final speech = buildSpeech(engine);
      var notifications = 0;
      final off = speech.onVoicesChanged(() => notifications++);
      await speech.warmUp();
      // Let the microtask flush.
      await Future<void>.delayed(Duration.zero);
      expect(notifications, greaterThan(0));
      off();
      final before = notifications;
      await speech.refreshVoices();
      await Future<void>.delayed(Duration.zero);
      expect(notifications, before);
    });
  });

  group('appSpeech', () {
    // Pages call `appSpeech` (the singleton), not a [Speech] they were handed.
    // A widget test that renders a page therefore reaches the real plugin and
    // its platform channel; `debugSetSpeech` is the seam that prevents it.
    // Without these tests the seam itself is never exercised, so a break in it
    // would only surface as a confusing MissingPluginException inside some
    // unrelated page test.
    //
    // `speech` is a lazy top-level `final`, so merely *reading* it constructs a
    // real `FlutterTts`, and that wants a binary messenger. Hence the binding
    // below: without it, touching the singleton in a plain `test()` throws
    // "Cannot set the method call handler before the binary messenger has been
    // initialized". This is also the reason `debugSetSpeech` must be called
    // before the first page build — it is the only way to keep the real engine
    // out of a widget test.
    setUpAll(TestWidgetsFlutterBinding.ensureInitialized);
    tearDown(() => debugSetSpeech(null));

    test('is the singleton out of the box', () {
      expect(appSpeech, same(speech));
    });

    test('honours a replacement, and goes back to the singleton', () {
      final fake = buildSpeech(FakeEngine());
      debugSetSpeech(fake);
      expect(appSpeech, same(fake));
      expect(appSpeech, isNot(same(speech)));

      debugSetSpeech(null);
      expect(appSpeech, same(speech));
    });

    test('the replacement is what pages actually drive', () async {
      final engine = FakeEngine(voices: [voice('en-US', 'A')]);
      debugSetSpeech(buildSpeech(engine));
      await appSpeech.speak('hello', lang: 'en-US');
      expect(engine.spoken, ['hello']);
    });
  });

  group('FlutterTtsEngine.init', () {
    // This group is about one real-world trap. This build vendors
    // `flutter_tts` to patch a Windows crash; the patched plugin keeps its
    // channel registered even after its synthesiser failed to activate, and
    // then answers every call with a neutral value instead of throwing. A
    // probe that only asks "did the channel reply" therefore reports a
    // working engine on a machine that cannot speak a word — the 发音 button
    // would render and do nothing.
    //
    // These drive the real [FlutterTtsEngine] over a fake `FlutterTts` backed
    // by a mocked method channel, which is the only way to exercise the
    // decision without a device.

    setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

    /// Answers channel calls from [answers], or throws for a missing method.
    void mockChannel(Map<String, Object?> answers) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('flutter_tts'),
        (MethodCall call) async {
          if (!answers.containsKey(call.method)) {
            throw MissingPluginException('no ${call.method}');
          }
          return answers[call.method];
        },
      );
    }

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
    });

    test('Windows: no voices means unsupported, even though the channel answers',
        () async {
      // Exactly what the patched plugin returns when activation failed: every
      // call is answered, the list is simply empty.
      mockChannel({'awaitSpeakCompletion': 1, 'getVoices': <Object?>[]});
      final engine = FlutterTtsEngine(null, TargetPlatform.windows);
      expect(await engine.init(), isFalse);
    });

    test('Windows: a voice list means supported', () async {
      mockChannel({
        'awaitSpeakCompletion': 1,
        'getVoices': <Object?>[
          {'name': 'Zira', 'locale': 'en-US'},
        ],
      });
      final engine = FlutterTtsEngine(null, TargetPlatform.windows);
      expect(await engine.init(), isTrue);
    });

    test('Android: a cold engine that has not listed voices yet still counts',
        () async {
      // Android's plugin queues calls until the background engine is up, so an
      // empty list here means "not yet". Failing on it would hide the 发音
      // button on every cold start.
      mockChannel({'awaitSpeakCompletion': 1, 'getVoices': <Object?>[]});
      final engine = FlutterTtsEngine(null, TargetPlatform.android);
      expect(await engine.init(), isTrue);
    });

    test('a missing channel means unsupported on every platform', () async {
      mockChannel(const {}); // every call throws MissingPluginException
      expect(await FlutterTtsEngine(null, TargetPlatform.android).init(),
          isFalse);
      expect(await FlutterTtsEngine(null, TargetPlatform.windows).init(),
          isFalse);
    });
  });
}
