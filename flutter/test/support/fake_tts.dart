/// A silent [TtsEngine] for widget tests that render a page calling
/// `appSpeech` but do not care about speech.
///
/// `SettingsPage.initState` calls `appSpeech.warmUp()`, and `appSpeech` is the
/// process-wide singleton — which means any test that pumps the settings page
/// reaches the real `flutter_tts` plugin and its platform channel. Those calls
/// are wrapped in try/catch, so the test usually still passes, which is exactly
/// what makes it bad: a real failure inside the speech path would be swallowed
/// as "not available" and the page would silently render without its 发音
/// section, with nothing in the test output to say why.
///
/// `debugSetSpeech` exists for this. Installing this fake keeps the plugin out
/// entirely, so a page test asserts on the page and not on a plugin channel.
library;

import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:lexumo/platform/tts.dart';

/// Records nothing, fails nothing, needs no platform channel.
class SilentTtsEngine implements TtsEngine {
  SilentTtsEngine({this.initOk = true, List<VoiceInfo>? voices})
      : _voices = voices ?? const <VoiceInfo>[];

  /// What [init] answers. `false` models a phone with no speech engine.
  final bool initOk;
  final List<VoiceInfo> _voices;

  int initCalls = 0;
  final List<String> spoken = <String>[];
  int stopCalls = 0;

  @override
  set onDone(VoidCallback? callback) {}

  @override
  Future<bool> init() async {
    initCalls++;
    return initOk;
  }

  @override
  Future<List<VoiceInfo>> voices() async => _voices;

  @override
  Future<void> setLanguage(String lang) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setVoice(VoiceInfo? voice) async {}

  @override
  Future<void> speak(String text) async => spoken.add(text);

  @override
  Future<void> stop() async => stopCalls++;
}

/// A [Speech] over [SilentTtsEngine] whose voice polling never actually waits.
Speech silentSpeech({
  bool initOk = true,
  List<VoiceInfo>? voices,
  SilentTtsEngine? engine,
}) =>
    Speech(
      engine: engine ?? SilentTtsEngine(initOk: initOk, voices: voices),
      delay: (Duration _) async {},
    );
