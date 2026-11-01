/// A [Lookup] for widget tests that render the editor but do not want a socket.
///
/// `word_editor.dart` reaches `defaultLookup` when a lookup button is pressed,
/// and `defaultLookup` is the process-wide singleton — built lazily over a real
/// `HttpClient` and a file-backed cache. A page test that presses 翻译 without
/// installing this fake would attempt a network call from a unit test: slow,
/// flaky, and dependent on the developer's connectivity.
///
/// `debugSetLookup` exists for this, the same seam as `debugSetSpeech`.
library;

import 'dart:async';

import 'package:lexumo/platform/translate.dart';

/// Records every query and answers from a script.
class FakeLookup implements Lookup {
  FakeLookup({
    this.result,
    this.failure,
    this.delay = Duration.zero,
  });

  /// What a successful call returns. Null means "nothing found".
  LookupResult? result;

  /// When set, every call throws this instead of answering.
  LookupFailure? failure;

  /// How long a call pretends to take — lets a test observe the loading state.
  Duration delay;

  /// Every term asked for, in order, with its options.
  final List<({String term, LookupOptions options})> calls =
      <({String term, LookupOptions options})>[];

  int clearCalls = 0;
  int resetCalls = 0;

  @override
  Future<LookupResult> lookupTerm(
    String term, [
    LookupOptions options = const LookupOptions(),
  ]) async {
    calls.add((term: term, options: options));
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final LookupFailure? bad = failure;
    if (bad != null) throw LookupError(bad);
    return result ??
        LookupResult(
          term: term,
          phonetic: '',
          senses: const <DictSense>[],
          examples: const <DictExample>[],
          provider: ProviderId.youdao,
        );
  }

  @override
  void clearCache() => clearCalls++;

  @override
  int cacheSize() => 0;

  @override
  void resetCooldown() => resetCalls++;
}

/// A result with the given senses, for tests that assert on what got filled in.
LookupResult lookupResult({
  String term = 'candid',
  String phonetic = 'ˈkændɪd',
  List<DictSense> senses = const <DictSense>[],
  List<DictExample> examples = const <DictExample>[],
  bool fromCache = false,
}) =>
    LookupResult(
      term: term,
      phonetic: phonetic,
      senses: senses,
      examples: examples,
      provider: ProviderId.youdao,
      fromCache: fromCache,
    );
