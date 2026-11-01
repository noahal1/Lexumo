/// Text-to-speech, behind one seam.
///
/// Ports `src/lib/tts.ts`. The web module had two engines (Web Speech and the
/// Tauri `tts` plugin) and picked between them at runtime; here there is one
/// engine — `flutter_tts`, which is itself a thin wrapper over each platform's
/// native synthesiser (SAPI on Windows, `TextToSpeech` on Android). So the
/// engine-selection half of the original does not need porting. What *does*
/// need porting is everything the two implementations disagreed about:
///
///   * **The rate scale.** Web Speech treats `1.0` as normal speed. The
///     `flutter_tts` API deliberately re-bases that so `0.5` is normal, on
///     every platform (`FlutterTtsPlugin.kt` does `rate * 2` before handing it
///     to Android; `flutter_tts_plugin.cpp` does `SpeakingRate(rate + 0.5)` on
///     Windows). `Settings.ttsRate` is stored in the *web* scale because the
///     snapshot format predates this port, so [Speech.speak] converts on the
///     way out and nothing above this file has to know.
///   * **The voice list.** Web Speech exposes a `SpeechSynthesisVoice` object
///     and a `voiceURI` string. The plugin exposes `{name, locale}` maps and
///     no stable id, so [VoiceInfo.uri] is synthesised here — self-describing,
///     because `Settings.ttsVoiceURI` is persisted and has to survive a
///     restart in which no in-memory map exists.
///   * **Readiness.** The Android engine answers `getVoices` with nothing
///     until it has initialised, and the plugin queues calls rather than
///     failing them, so [Speech.warmUp] polls briefly instead of trusting the
///     first answer.
///
/// Everything a caller touches is small on purpose: [speechSupported] gates
/// whether a 发音 button renders at all, [speak] makes a sound, [stop] cuts it
/// off. The same four names the web build used.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// One selectable voice, shaped like the web build's `VoiceInfo` so the
/// settings page and the persisted `ttsVoiceURI` did not have to change shape.
@immutable
class VoiceInfo {
  const VoiceInfo({
    required this.uri,
    required this.name,
    required this.lang,
    required this.local,
  });

  /// Stable handle persisted in `Settings.ttsVoiceURI`. See [_encodeVoiceUri].
  final String uri;

  /// The platform's display name, e.g. `en-us-x-sfg#female_2-local`.
  final String name;

  /// BCP-47-ish tag, e.g. `en-US`.
  final String lang;

  /// Whether the voice works without a network round trip.
  final bool local;

  @override
  bool operator ==(Object other) => other is VoiceInfo && other.uri == uri;

  @override
  int get hashCode => uri.hashCode;

  @override
  String toString() => 'VoiceInfo($uri)';
}

/// The seam. Tests inject a fake; the app injects [FlutterTtsEngine].
///
/// Keeping this an interface is the same call `src/lib/tts.ts` made when it
/// hid two engines behind one module: the pages must not know which
/// synthesiser is underneath, and the test suite must not need a real one.
abstract class TtsEngine {
  /// Resolves once the engine is usable. `false` means "this device cannot
  /// speak", which the UI turns into a disabled button rather than a silent
  /// no-op.
  Future<bool> init();

  /// `{name, locale}` pairs. Empty until [init] succeeds.
  Future<List<VoiceInfo>> voices();

  Future<void> setLanguage(String lang);

  /// Rate in the **plugin's** scale (0.5 = normal). [Speech] converts.
  Future<void> setRate(double rate);

  /// `null` restores the platform default.
  Future<void> setVoice(VoiceInfo? voice);

  Future<void> speak(String text);

  Future<void> stop();

  /// Fires when an utterance finishes or is cancelled. [Speech] uses it to
  /// forward the caller's `onEnd`.
  set onDone(VoidCallback? callback);
}

/// The real engine: `flutter_tts`.
class FlutterTtsEngine implements TtsEngine {
  FlutterTtsEngine([FlutterTts? impl, TargetPlatform? platform])
      : _tts = impl ?? FlutterTts(),
        _platform = platform ?? defaultTargetPlatform;

  final FlutterTts _tts;
  final TargetPlatform _platform;
  VoidCallback? _onDone;

  @override
  set onDone(VoidCallback? callback) {
    _onDone = callback;
    _tts.setCompletionHandler(() => _onDone?.call());
    // A cancel is an end from the caller's point of view: it is how "stop and
    // move on" resolves the awaiting future.
    _tts.setCancelHandler(() => _onDone?.call());
  }

  /// Whether the engine can actually produce sound.
  ///
  /// The shape of this probe is platform-specific on purpose. The reason is a
  /// real one: this build vendors `flutter_tts` (see
  /// `third_party/flutter_tts/`) to patch a Windows crash, and the patched
  /// Windows plugin keeps its channel alive after its synthesiser fails to
  /// activate — it answers every call with a neutral `0` instead of throwing.
  /// So on Windows "the channel replied" proves nothing, and only a voice list
  /// does.
  ///
  /// Android is the opposite: the engine comes up in the background and the
  /// plugin queues calls until it is ready, so an empty list on the first probe
  /// is normal and means "not yet", not "never". Treating it as a failure would
  /// hide the 发音 button on every cold start.
  @override
  Future<bool> init() async {
    try {
      // Android's engine comes up asynchronously and the plugin *queues*
      // calls made before that, so this returns promptly and the first
      // `speak` is not lost.
      await _tts.awaitSpeakCompletion(false);
    } catch (_) {
      // The channel itself is missing: no engine at all.
      return false;
    }
    if (_platform != TargetPlatform.windows) return true;

    // Windows: a wired channel is not a working engine. Ask for the one thing
    // only a live synthesiser can answer. The polling loop in [refreshVoices]
    // is not reused here because a poll that ends in "still nothing" would
    // cost three seconds of a page waiting to render.
    try {
      return (await voices()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<VoiceInfo>> voices() async {
    try {
      final dynamic raw = await _tts.getVoices;
      if (raw is! List) return const <VoiceInfo>[];
      final out = <VoiceInfo>[];
      for (final entry in raw) {
        if (entry is! Map) continue;
        final name = '${entry['name'] ?? ''}';
        final locale = '${entry['locale'] ?? ''}';
        if (name.isEmpty || locale.isEmpty) continue;
        // Android reports whether a voice needs the network; Windows does not
        // report the field at all and its voices are local, so absent = local.
        final networkRequired = '${entry['network_required'] ?? '0'}' == '1';
        out.add(VoiceInfo(
          uri: _encodeVoiceUri(locale, name),
          name: name,
          lang: locale,
          local: !networkRequired,
        ));
      }
      return out;
    } catch (_) {
      return const <VoiceInfo>[];
    }
  }

  @override
  Future<void> setLanguage(String lang) async {
    try {
      await _tts.setLanguage(lang);
    } catch (_) {
      // A language the device has no voice for: the platform falls back to its
      // default, which is better than refusing to speak.
    }
  }

  @override
  Future<void> setRate(double rate) async {
    try {
      await _tts.setSpeechRate(rate);
    } catch (_) {}
  }

  @override
  Future<void> setVoice(VoiceInfo? voice) async {
    try {
      if (voice == null) {
        await _tts.clearVoice();
        return;
      }
      // The plugin takes `{name, locale}` — both halves, because it matches on
      // the pair and a name alone is not unique across locales.
      await _tts.setVoice(<String, String>{
        'name': voice.name,
        'locale': voice.lang,
      });
    } catch (_) {}
  }

  @override
  Future<void> speak(String text) async {
    try {
      await _tts.speak(text);
    } catch (_) {
      // No engine, or the request was refused. There is nothing actionable to
      // surface mid-card, so speech simply does not happen — same decision the
      // web module made in `speakNative`'s catch.
      _onDone?.call();
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}

/* ------------------------------------------------------------------------ */
/* Voice URI encoding                                                        */
/* ------------------------------------------------------------------------ */

/// `tts:<locale>:<name>`, both percent-encoded.
///
/// `Uri.encodeComponent` escapes `:` and `%`, so splitting the result on `:`
/// yields exactly three fields no matter what the platform put in the name —
/// Android voice names contain `#`, `_` and `-`, and Windows ones contain
/// backslashes and spaces.
String _encodeVoiceUri(String locale, String name) =>
    'tts:${Uri.encodeComponent(locale)}:${Uri.encodeComponent(name)}';

/// The inverse of [_encodeVoiceUri]. Returns `null` for anything that is not
/// ours, so a `ttsVoiceURI` written by the web build (a raw
/// `SpeechSynthesisVoice.voiceURI`) degrades to "automatic" instead of
/// throwing.
({String locale, String name})? _decodeVoiceUri(String uri) {
  if (!uri.startsWith('tts:')) return null;
  final parts = uri.split(':');
  if (parts.length != 3) return null;
  try {
    return (
      locale: Uri.decodeComponent(parts[1]),
      name: Uri.decodeComponent(parts[2]),
    );
  } catch (_) {
    return null;
  }
}

/// The BCP-47 base subtag, lowercased: `en-US` → `en`.
String _baseLang(String lang) {
  final lower = lang.toLowerCase();
  final dash = lower.indexOf('-');
  final underscore = lower.indexOf('_');
  final cut = <int>[
    if (dash >= 0) dash,
    if (underscore >= 0) underscore,
  ].fold<int>(lower.length, (a, b) => a < b ? a : b);
  return lower.substring(0, cut);
}

/// Voices matching [lang], best first — exact tag, then same base language,
/// then local before network. Mirrors `voicesFor` in `src/lib/tts.ts`.
List<VoiceInfo> voicesFor(List<VoiceInfo> all, String lang) {
  if (lang.isEmpty) return const <VoiceInfo>[];
  final base = _baseLang(lang);
  final target = lang.toLowerCase();
  final matching = all
      .where((v) => v.lang.toLowerCase().startsWith(base))
      .toList(growable: false);
  final indexed = <(int, VoiceInfo)>[
    for (final v in matching)
      (
        (v.lang.toLowerCase() == target ? 0 : 1) * 2 + (v.local ? 0 : 1),
        v,
      ),
  ];
  // Stable: equal ranks keep the platform's own order.
  indexed.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final e in indexed) e.$2];
}

/* ------------------------------------------------------------------------ */
/* The service                                                               */
/* ------------------------------------------------------------------------ */

/// The one thing the pages talk to.
///
/// A single instance lives in [speech]; tests build their own with a fake
/// engine so no platform channel is ever touched.
class Speech {
  Speech({TtsEngine? engine, Future<void> Function(Duration)? delay})
      : _engine = engine ?? FlutterTtsEngine(),
        _delay = delay ?? Future<void>.delayed;

  final TtsEngine _engine;
  final Future<void> Function(Duration) _delay;

  bool _initialised = false;
  bool _usable = false;
  List<VoiceInfo> _voices = const <VoiceInfo>[];
  final List<VoidCallback> _listeners = <VoidCallback>[];

  /// True when a 发音 control should be rendered.
  ///
  /// Before [warmUp] this answers `true` on purpose: a cold mobile engine is
  /// up in a few hundred milliseconds, and hiding the button until then would
  /// make it flash in. After a *failed* warm-up it answers `false` — at that
  /// point promising speech that will never arrive is the worse lie. This is
  /// exactly the rule `speechSupported()` used in the web build.
  bool get supported => _initialised ? _usable : true;

  /// True once [warmUp] has decided. Lets the settings page distinguish
  /// "not yet" from "no".
  bool get isReady => _initialised;

  List<VoiceInfo> get voices => _voices;

  /// Idempotent, and safe to call from several pages' `initState`.
  Future<bool> warmUp() async {
    if (_initialised) return _usable;
    _initialised = true;
    try {
      _usable = await _engine.init();
    } catch (_) {
      _usable = false;
    }
    if (_usable) await refreshVoices();
    _notify();
    return _usable;
  }

  /// Re-reads the voice list. Android needs a few attempts before the engine
  /// reports anything, so this polls — bounded, and it gives up quietly.
  Future<void> refreshVoices() async {
    for (var attempt = 0; attempt < 10; attempt++) {
      final list = await _engine.voices();
      if (list.isNotEmpty) {
        _voices = list;
        _notify();
        return;
      }
      // 300 ms between probes: the engine's own init takes a few hundred ms,
      // and polling faster only burns frames.
      await _delay(const Duration(milliseconds: 300));
    }
    // Leave the list empty. The settings page renders the "no voices" note and
    // `speak` still tries, because a device can speak without enumerating.
    _voices = const <VoiceInfo>[];
    _notify();
  }

  /// Voices for one language, best match first.
  List<VoiceInfo> voicesForLang(String lang) => voicesFor(_voices, lang);

  /// Subscribes to voice-list changes; returns the unsubscribe.
  VoidCallback onVoicesChanged(VoidCallback cb) {
    _listeners.add(cb);
    // A caller that subscribes before the first probe finished still hears
    // about it.
    if (_voices.isNotEmpty) {
      scheduleMicrotask(cb);
    }
    return () => _listeners.remove(cb);
  }

  void _notify() {
    for (final cb in List<VoidCallback>.of(_listeners)) {
      cb();
    }
  }

  /// Speaks [text] in [lang] at [rate] (web scale, 1.0 = normal).
  ///
  /// [voiceURI] is the persisted handle; an unknown one falls back to the best
  /// match for [lang] rather than failing, because a voice can be uninstalled
  /// between runs.
  Future<void> speak(
    String text, {
    String? lang,
    double? rate,
    String? voiceURI,
    VoidCallback? onEnd,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      onEnd?.call();
      return;
    }
    if (!await warmUp()) {
      onEnd?.call();
      return;
    }

    // Resolve the voice before configuring, so one `setVoice` call does the
    // work instead of set-then-correct.
    VoiceInfo? voice;
    if (voiceURI != null && voiceURI.isNotEmpty) {
      voice = _voices.where((v) => v.uri == voiceURI).firstOrNull;
      // A device that never enumerates its voices still accepts `setVoice` by
      // name+locale, and the persisted URI carries both — so recover the
      // choice from the URI itself rather than silently reverting to default.
      if (voice == null) {
        final decoded = _decodeVoiceUri(voiceURI);
        if (decoded != null) {
          voice = VoiceInfo(
            uri: voiceURI,
            name: decoded.name,
            lang: decoded.locale,
            local: true,
          );
        }
      }
    }
    voice ??= lang == null || lang.isEmpty
        ? null
        : voicesForLang(lang).firstOrNull;

    if (voice != null) {
      await _engine.setVoice(voice);
      await _engine.setLanguage(voice.lang);
    } else if (lang != null && lang.isNotEmpty) {
      await _engine.setLanguage(lang);
    }

    await _engine.setRate(_toEngineRate(rate));

    // Wire the completion forward *before* speaking, or a fast utterance
    // finishes before the handler is attached.
    final completer = onEnd == null ? null : _DoneOnce(onEnd);
    _engine.onDone = completer?.call;

    await _engine.speak(trimmed);
  }

  /// Cuts off whatever is playing. Safe to call when nothing is.
  Future<void> stop() async {
    if (!_initialised) return;
    await _engine.stop();
  }

  /// Web scale (1.0 = normal) → plugin scale (0.5 = normal).
  ///
  /// The app's slider is bounded to 0.5–1.5, which lands on 0.25–0.75 — inside
  /// the range every platform documents as valid.
  static double _toEngineRate(double? rate) {
    final web = (rate ?? 1.0).clamp(0.5, 1.5);
    return (web * 0.5).clamp(0.1, 1.5);
  }
}

/// Guards [Speech.speak]'s `onEnd` against the plugin firing both a completion
/// and a cancel for one utterance — the caller asked for one callback.
class _DoneOnce {
  _DoneOnce(this._cb);

  final VoidCallback _cb;
  bool _fired = false;

  void call() {
    if (_fired) return;
    _fired = true;
    _cb();
  }
}

/// The process-wide instance. Pages use this; tests build their own [Speech].
final Speech speech = Speech();

/// Swap the singleton for a fake. Test-only: the real engine needs a platform
/// channel, which a widget test does not have.
@visibleForTesting
void debugSetSpeech(Speech? replacement) {
  _override = replacement;
}

Speech? _override;

/// What pages should call. Reads [_override] first so a test's fake wins
/// without every page taking a constructor argument.
Speech get appSpeech => _override ?? speech;
