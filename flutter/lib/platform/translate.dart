/// Term lookup for the word editor.
///
/// Ports `src/lib/translate.ts`. The app is offline-first, so this module is
/// strictly a convenience layer: every call is best-effort, results are cached
/// aggressively, and a failure never blocks the user from typing a definition
/// by hand.
///
/// **One structural difference from the web build.** The web version needs two
/// transports — a Rust `lookup_word` command and plain `fetch` — because
/// `dict.youdao.com/jsonapi` sends no `Access-Control-Allow-Origin` header, so a
/// browser fetch is rejected. Dart has no CORS: `dart:io` speaks TCP, so the
/// desktop proxy layer disappears entirely and every provider is reached
/// directly. What remains is the dictionary chain itself, which is the part that
/// was worth keeping: `createLookup` receives the adapter list plus an injected
/// cache, clock and HTTP seam, so tests build a lookup from fakes and never
/// touch the network.
///
/// The provider chain is data, not a branch. `flutter_defaultAdapters()` is the
/// only place the shipping chain is assembled.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../data/app_dir.dart';

/// A dictionary or machine-translation backend.
enum ProviderId {
  youdao('youdao'),
  youdaoSelfHosted('youdao-web'),
  myMemory('mymemory'),
  google('google');

  const ProviderId(this.wire);

  /// The string the web build used; kept so cached results stay comparable.
  final String wire;
}

/// One sense of a term, with the part of speech the provider tagged it with.
class DictSense {
  const DictSense({required this.pos, required this.meaning});

  /// Part of speech such as `adj.` — empty when the provider has no tags.
  final String pos;
  final String meaning;

  Map<String, Object?> toJson() => <String, Object?>{'pos': pos, 'meaning': meaning};

  static DictSense fromJson(Map<String, Object?> json) => DictSense(
        pos: json['pos'] as String? ?? '',
        meaning: json['meaning'] as String? ?? '',
      );

  @override
  bool operator ==(Object other) =>
      other is DictSense && other.pos == pos && other.meaning == meaning;

  @override
  int get hashCode => Object.hash(pos, meaning);

  @override
  String toString() => pos.isEmpty ? meaning : '$pos $meaning';
}

/// One bilingual example sentence.
class DictExample {
  const DictExample({required this.en, this.zh});

  final String en;

  /// Empty when the provider sent no translation for the sentence.
  final String? zh;

  Map<String, Object?> toJson() => <String, Object?>{'en': en, if (zh != null) 'zh': zh};

  static DictExample fromJson(Map<String, Object?> json) => DictExample(
        en: json['en'] as String? ?? '',
        zh: json['zh'] as String?,
      );
}

/// A successful lookup.
class LookupResult {
  const LookupResult({
    required this.term,
    required this.phonetic,
    required this.senses,
    required this.examples,
    required this.provider,
    this.fromCache = false,
  });

  final String term;

  /// IPA without slashes, e.g. `ˈkændɪd`. Empty when unknown.
  final String phonetic;
  final List<DictSense> senses;
  final List<DictExample> examples;
  final ProviderId provider;

  /// True when served from the local cache (no network happened).
  final bool fromCache;

  LookupResult fromCacheMarked() => LookupResult(
        term: term,
        phonetic: phonetic,
        senses: senses,
        examples: examples,
        provider: provider,
        fromCache: true,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'term': term,
        'phonetic': phonetic,
        'senses': senses.map((DictSense s) => s.toJson()).toList(),
        'examples': examples.map((DictExample e) => e.toJson()).toList(),
        'provider': provider.wire,
      };

  static LookupResult? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? provider = raw['provider'];
    final ProviderId id = ProviderId.values.firstWhere(
      (ProviderId p) => p.wire == provider,
      orElse: () => ProviderId.youdao,
    );
    final Object? senses = raw['senses'];
    return LookupResult(
      term: raw['term'] as String? ?? '',
      phonetic: raw['phonetic'] as String? ?? '',
      senses: senses is List
          ? senses
              .whereType<Map>()
              .map((Map m) => DictSense.fromJson(m.cast<String, Object?>()))
              .toList()
          : const <DictSense>[],
      examples: raw['examples'] is List
          ? (raw['examples']! as List)
              .whereType<Map>()
              .map((Map m) => DictExample.fromJson(m.cast<String, Object?>()))
              .toList()
          : const <DictExample>[],
      provider: id,
    );
  }
}

/// Why a lookup produced nothing. Lets the UI say something better than "出错了".
enum LookupFailure {
  rateLimited('rate-limited'),
  offline('offline'),
  notFound('not-found');

  const LookupFailure(this.reason);

  final String reason;
}

class LookupError implements Exception {
  const LookupError(this.reason, [this.message]);

  final LookupFailure reason;
  final String? message;

  @override
  String toString() => message ?? reason.reason;
}

/* ------------------------------------------------------------------ cache */

const String _cacheKey = 'lexumo.dict.v1';
const int _cacheTtlMs = 1000 * 60 * 60 * 24 * 30;
const int _cacheMax = 400;

/// The slice of key/value storage the cache needs.
///
/// The web build passed `localStorage`; the Flutter port defaults to memory, and
/// `FileLookupStorage` can be wired in where a lookup should survive a restart.
abstract class LookupStorage {
  String? getItem(String key);
  void setItem(String key, String value);
  void removeItem(String key);
}

/// A storage that lives only as long as the process.
class MemoryLookupStorage implements LookupStorage {
  final Map<String, String> _entries = <String, String>{};

  @override
  String? getItem(String key) => _entries[key];

  @override
  void setItem(String key, String value) => _entries[key] = value;

  @override
  void removeItem(String key) => _entries.remove(key);
}

/// A storage backed by one file, so a lookup survives a restart.
///
/// The web build used `localStorage` and got persistence for free. Without this
/// the cache would only ever help within a single run of the app, which is the
/// wrong shape for a dictionary: the point is that the second time you look up
/// `serendipity` — tomorrow — it costs nothing.
///
/// Everything here is best-effort and synchronous, matching the interface the
/// cache is written against. A disk that refuses the write (a sandbox, a full
/// volume) leaves the in-memory copy authoritative for the session and costs a
/// repeated network call next time, which is the same outcome as no cache at
/// all — never an exception the editor has to handle.
class FileLookupStorage implements LookupStorage {
  FileLookupStorage(this.path);

  final String path;

  Map<String, String>? _entries;

  /// Read once, then keep in memory: the cache calls [getItem] on every lookup
  /// and re-reading a JSON file each time would put disk I/O on a keystroke path.
  Map<String, String> get _map {
    final Map<String, String>? cached = _entries;
    if (cached != null) return cached;
    final Map<String, String> loaded = <String, String>{};
    try {
      final File file = File(path);
      if (file.existsSync()) {
        final Object? raw = jsonDecode(file.readAsStringSync());
        if (raw is Map) {
          for (final MapEntry<Object?, Object?> entry in raw.entries) {
            final Object? key = entry.key;
            final Object? value = entry.value;
            if (key is String && value is String) loaded[key] = value;
          }
        }
      }
    } on Object {
      // A truncated or hand-edited file is not worth reporting: an empty cache
      // is a valid starting state, and the next write repairs it.
      loaded.clear();
    }
    return _entries = loaded;
  }

  void _flush() {
    try {
      final File file = File(path);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(_map));
    } on Object {
      // Keep the in-memory copy; see the class comment.
    }
  }

  @override
  String? getItem(String key) => _map[key];

  @override
  void setItem(String key, String value) {
    _map[key] = value;
    _flush();
  }

  @override
  void removeItem(String key) {
    if (_map.remove(key) != null) _flush();
  }
}

/// Injected time source. The cache TTL and the 429 cooldown both read it, so a
/// test can move time forward without waiting or resetting module state.
abstract class LookupClock {
  int now();
}

class SystemClock implements LookupClock {
  const SystemClock();

  @override
  int now() => DateTime.now().millisecondsSinceEpoch;
}

const LookupClock systemClock = SystemClock();

/// Cache as seen by the orchestrator: the TTL is already applied by [get].
abstract class LookupCache {
  LookupResult? get(String key);
  void set(String key, LookupResult result);
  int size();
  void clear();
}

class LookupCacheOptions {
  const LookupCacheOptions({
    this.storage,
    this.key = _cacheKey,
    this.ttlMs = _cacheTtlMs,
    this.max = _cacheMax,
    this.clock = systemClock,
  });

  /// `null` (the default) keeps everything in memory.
  final LookupStorage? storage;
  final String key;
  final int ttlMs;
  final int max;
  final LookupClock clock;
}

String _keyOf(String term, String from, String to) =>
    '$from>$to:${term.trim().toLowerCase()}';

class _CacheRecord {
  const _CacheRecord(this.at, this.result);

  final int at;
  final LookupResult result;

  Map<String, Object?> toJson() =>
      <String, Object?>{'at': at, 'result': result.toJson()};

  static _CacheRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? at = raw['at'];
    final LookupResult? result = LookupResult.fromJson(raw['result']);
    if (at is! num || result == null) return null;
    return _CacheRecord(at.toInt(), result);
  }
}

/// Build a lookup cache. Persistence, the 30-day TTL and the size cap are the
/// same as the web build; the only change is that they belong to an instance, so
/// two lookups (or two tests) never share state.
LookupCache createLookupCache([LookupCacheOptions options = const LookupCacheOptions()]) =>
    _LookupCache(options);

class _LookupCache implements LookupCache {
  _LookupCache(this._options);

  final LookupCacheOptions _options;

  /// Loaded on first use, so constructing this never touches storage.
  Map<String, _CacheRecord>? _map;

  Map<String, _CacheRecord> get _records {
    final Map<String, _CacheRecord>? loaded = _map;
    if (loaded != null) return loaded;
    final Map<String, _CacheRecord> map = <String, _CacheRecord>{};
    final String? raw = _options.storage?.getItem(_options.key);
    if (raw != null && raw.isNotEmpty) {
      try {
        final Object? decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final MapEntry<Object?, Object?> entry in decoded.entries) {
            final _CacheRecord? record = _CacheRecord.fromJson(entry.value);
            if (record != null) map['${entry.key}'] = record;
          }
        }
      } on FormatException {
        // A corrupted cache is not worth reporting: it is a cache.
        map.clear();
      }
    }
    _map = map;
    return map;
  }

  void _persist() {
    final LookupStorage? storage = _options.storage;
    if (storage == null) return;
    final Map<String, Object?> out = <String, Object?>{};
    for (final MapEntry<String, _CacheRecord> entry in _records.entries) {
      out[entry.key] = entry.value.toJson();
    }
    try {
      storage.setItem(_options.key, jsonEncode(out));
    } on Object {
      // Storage full or read-only: the cache still works for this session.
    }
  }

  @override
  LookupResult? get(String key) {
    final Map<String, _CacheRecord> map = _records;
    final _CacheRecord? record = map[key];
    if (record == null) return null;
    if (_options.clock.now() - record.at > _options.ttlMs) {
      map.remove(key);
      _persist();
      return null;
    }
    return record.result.fromCacheMarked();
  }

  @override
  void set(String key, LookupResult result) {
    final Map<String, _CacheRecord> map = _records;
    map.remove(key);
    map[key] = _CacheRecord(_options.clock.now(), result);
    // Oldest out first: insertion order is preserved by a Dart map, and the
    // record was just re-inserted, so the head is the least recently written.
    while (map.length > _options.max) {
      map.remove(map.keys.first);
    }
    _persist();
  }

  @override
  int size() => _records.length;

  @override
  void clear() {
    _records.clear();
    _options.storage?.removeItem(_options.key);
  }
}

/* --------------------------------------------------------------- helpers */

/// Collapse runs of whitespace and trim. A term typed from a sentence often
/// arrives with a trailing space, which would make it a different cache key.
String normalizeTermText(String term) => term.trim().replaceAll(RegExp(r'\s+'), ' ');

String _stripTags(String input) => input.replaceAll(RegExp(r'<[^>]+>'), '');

/// Map app language codes onto the dialects Youdao's endpoints expect.
String youdaoLang(String code) {
  final String c = code.toLowerCase();
  if (c.startsWith('zh')) return 'zh-CHS';
  if (c.startsWith('en')) return 'en';
  // The remaining dialects are passed through unchanged; Youdao accepts a bare
  // ISO code for the languages it translates.
  for (final String known in <String>['ja', 'ko', 'fr', 'de', 'es', 'ru']) {
    if (c.startsWith(known)) return known;
  }
  return code;
}

/// Google Translate does not accept Youdao's `zh-CHS` dialect tag. Worse than
/// rejecting it, it silently echoes the input back untranslated — which reads as
/// a real gloss and hides the failure. Google wants `zh-CN` / `zh-TW`.
String googleLang(String code) {
  final String c = code.toLowerCase();
  if (c.startsWith('zh')) {
    return c.contains('tw') || c.contains('hk') ? 'zh-TW' : 'zh-CN';
  }
  return youdaoLang(code);
}

String myMemoryPair(String from, String to) {
  String norm(String c) {
    final String lower = c.toLowerCase();
    if (lower.startsWith('zh')) return 'zh-CN';
    if (lower.startsWith('en')) return 'en';
    return lower.length > 2 ? lower.substring(0, 2) : lower;
  }

  return '${norm(from)}|${norm(to)}';
}

/// Youdao appends a proper-noun block to nearly every common word:
///
///   `【名】 （Record）（美）勒科尔（人名）`
///
/// It is not a sense of the word — it is the surname that happens to share its
/// spelling. Left in place it crowds out the real secondary senses (and with a
/// three-sense budget it can be the only thing that survives).
bool _isProperNoun(String meaning) =>
    RegExp(r'^【名】').hasMatch(meaning) || meaning.contains('（人名）');

/// True when a list asks for a Chinese gloss (the only thing Youdao's dictionary
/// endpoint can produce).
bool isChineseTarget(String? to) => to == null || to.toLowerCase().startsWith('zh');

/// Turn one Youdao sense string into `{pos, meaning}` parts.
List<DictSense> splitSense(String raw) {
  final String text = _stripTags(raw).trim();
  if (text.isEmpty) return const <DictSense>[];
  final RegExpMatch? match = RegExp(r'^([a-z]{1,6}\.)\s*(.+)$', caseSensitive: false)
      .firstMatch(text);
  final String pos = match == null ? '' : match[1]!;
  final String body = match == null ? text : match[2]!;
  return body
      .split(RegExp(r'[；;]\s*'))
      .map((String part) => part.trim())
      .where((String part) => part.isNotEmpty)
      .where((String part) => !_isProperNoun(part))
      .map((String meaning) => DictSense(pos: pos, meaning: meaning))
      .toList();
}

/* --------------------------------------------------------------- parsers */

/// Parse the `dict.youdao.com/jsonapi` payload. Returns null when empty.
LookupResult? parseYoudao(Object? raw, String term) {
  if (raw is! Map) return null;

  final List<DictSense> senses = <DictSense>[];
  final Object? ec = raw['ec'];
  if (ec is Map) {
    final Object? words = ec['word'];
    if (words is List && words.isNotEmpty && words.first is Map) {
      final Map word = words.first as Map;
      final Object? trs = word['trs'];
      if (trs is List) {
        for (final Object? entry in trs) {
          if (entry is! Map) continue;
          final Object? tr = entry['tr'];
          if (tr is! List) continue;
          for (final Object? t in tr) {
            if (t is! Map) continue;
            final Object? l = t['l'];
            if (l is! Map) continue;
            final Object? items = l['i'];
            final List<Object?> list = items is List
                ? items
                : items == null
                    ? const <Object?>[]
                    : <Object?>[items];
            for (final Object? item in list) {
              if (item is String) senses.addAll(splitSense(item));
            }
          }
        }
      }
    }
  }

  // A sentence or an uncommon phrase only gets machine translation.
  if (senses.isEmpty) {
    final Object? fanyi = raw['fanyi'];
    if (fanyi is Map && fanyi['tran'] is String) {
      final String tran = _stripTags(fanyi['tran'] as String).trim();
      if (tran.isNotEmpty) senses.add(DictSense(pos: '', meaning: tran));
    }
  }
  if (senses.isEmpty) return null;

  final List<DictExample> examples = <DictExample>[];
  final Object? blng = raw['blng_sents_part'];
  if (blng is Map) {
    final Object? pairs = blng['sentence-pair'];
    if (pairs is List) {
      for (final Object? pair in pairs) {
        if (pair is! Map) continue;
        final String en = _stripTags('${pair['sentence'] ?? ''}').trim();
        if (en.isEmpty) continue;
        final String zh = _stripTags('${pair['sentence-translation'] ?? ''}').trim();
        examples.add(zh.isEmpty ? DictExample(en: en) : DictExample(en: en, zh: zh));
        if (examples.length >= 2) break;
      }
    }
  }

  String phonetic = '';
  final Object? ecWord = ec is Map ? ec['word'] : null;
  if (ecWord is List && ecWord.isNotEmpty && ecWord.first is Map) {
    final Map word = ecWord.first as Map;
    final String us = '${word['usphone'] ?? ''}'.trim();
    final String uk = '${word['ukphone'] ?? ''}'.trim();
    phonetic = us.isNotEmpty ? us : uk;
  }

  return LookupResult(
    term: term,
    phonetic: phonetic,
    senses: senses,
    examples: examples,
    provider: ProviderId.youdao,
  );
}

/// Youdao sends `errorCode` as a string (`"0"`), but be lenient about both shapes.
int? _errorCodeOf(Object? raw) {
  if (raw is! Map) return null;
  final Object? code = raw['errorCode'];
  if (code is int) return code;
  if (code is num) return code.toInt();
  if (code is String && code.trim().isNotEmpty) return int.tryParse(code.trim());
  return null;
}

/// Parse the `aidemo.youdao.com/trans` payload (machine translation).
LookupResult? parseYoudaoTranslation(Object? raw, String term) {
  if (_errorCodeOf(raw) != 0) return null;
  final Map data = raw! as Map;
  final Object? lines = data['translation'];
  if (lines is! List) return null;
  final List<String> cleaned = lines
      .map((Object? line) => _stripTags('${line ?? ''}').trim())
      .where((String line) => line.isNotEmpty)
      .toList();
  if (cleaned.isEmpty) return null;
  return LookupResult(
    term: term,
    phonetic: '',
    senses: cleaned.map((String meaning) => DictSense(pos: '', meaning: meaning)).toList(),
    examples: const <DictExample>[],
    provider: ProviderId.youdaoSelfHosted,
  );
}

/// Parse the `api.mymemory.translated.net/get` payload.
LookupResult? parseMyMemory(Object? raw, String term) {
  if (raw is! Map) return null;
  final Object? result = raw['responseData'];
  final String primary =
      result is Map ? _stripTags('${result['translatedText'] ?? ''}').trim() : '';
  if (primary.isEmpty) return null;

  final List<String> meanings = <String>[primary];
  final Object? matches = raw['matches'];
  if (matches is List) {
    for (final Object? match in matches) {
      if (match is! Map) continue;
      final String text = _stripTags('${match['translation'] ?? ''}').trim();
      // Only alternatives that translate the term itself, not longer segments.
      final String segment = '${match['segment'] ?? ''}'.trim().toLowerCase();
      if (text.isEmpty || meanings.contains(text)) continue;
      if (segment.isNotEmpty && segment != term.trim().toLowerCase()) continue;
      final Object? score = match['match'];
      final double value = score is num ? score.toDouble() : 0;
      if (value < 0.7) continue;
      meanings.add(text);
      if (meanings.length >= 3) break;
    }
  }
  return LookupResult(
    term: term,
    phonetic: '',
    senses: meanings.map((String meaning) => DictSense(pos: '', meaning: meaning)).toList(),
    examples: const <DictExample>[],
    provider: ProviderId.myMemory,
  );
}

/// Parse the `translate.googleapis.com/translate_a/single` nested array.
LookupResult? parseGoogle(Object? raw, String term) {
  if (raw is! List || raw.isEmpty || raw.first is! List) return null;
  final String text = (raw.first as List)
      .map((Object? chunk) => chunk is List && chunk.isNotEmpty ? '${chunk.first ?? ''}' : '')
      .join()
      .trim();
  if (text.isEmpty) return null;
  return LookupResult(
    term: term,
    phonetic: '',
    senses: <DictSense>[DictSense(pos: '', meaning: text)],
    examples: const <DictExample>[],
    provider: ProviderId.google,
  );
}

/* ------------------------------------------------------------- transport */

/// The HTTP seam. Injected so tests never open a socket.
///
/// `getJson` decodes a 2xx body as JSON, throws [LookupError] with
/// [LookupFailure.rateLimited] on 429, and any other failure — including a
/// timeout — as a plain exception the orchestrator treats as "this provider
/// did not answer".
abstract class LookupHttp {
  Future<Object?> getJson(Uri url, {required Duration timeout});
}

/// `dart:io` transport. There is no CORS in Dart, which is why the web build's
/// Rust proxy has no counterpart here.
class IoLookupHttp implements LookupHttp {
  IoLookupHttp({HttpClient? client, this.userAgent = _defaultAgent})
      : _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 6);
  }

  static const String _defaultAgent =
      'Lexumo/0.1 (+https://github.com/noahal1/lingueez-web)';

  final HttpClient _client;
  final String userAgent;

  @override
  Future<Object?> getJson(Uri url, {required Duration timeout}) async {
    final HttpClientRequest request = await _client
        .getUrl(url)
        .timeout(timeout);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(HttpHeaders.userAgentHeader, userAgent);
    final HttpClientResponse response = await request.close().timeout(timeout);
    final String body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(timeout);
    if (response.statusCode == 429) {
      throw const LookupError(LookupFailure.rateLimited);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LookupError(LookupFailure.offline, 'http ${response.statusCode}');
    }
    try {
      return jsonDecode(body);
    } on FormatException {
      throw LookupError(LookupFailure.offline, 'not json');
    }
  }
}

/* ------------------------------------------------------------- providers */

const int _cooldownMs = 90 * 1000;

/// Per-call context an adapter needs beyond the term itself.
class LookupContext {
  const LookupContext({
    required this.from,
    required this.to,
    required this.http,
    required this.timeout,
  });

  final String from;
  final String to;
  final LookupHttp http;

  /// This provider's own budget, already clamped to what is left of the total.
  final Duration timeout;
}

/// One dictionary provider.
///
/// [canServe] is consulted before the fetch, so a chain may hold providers that
/// only cover some language pairs. [fetch] returns null when the provider
/// answered but had nothing (fall through to the next one) and throws
/// [LookupError] with [LookupFailure.rateLimited] to trigger that provider's
/// cooldown.
abstract class LookupAdapter {
  ProviderId get id;
  bool canServe(String from, String to);
  Future<LookupResult?> fetch(String term, LookupContext context);
}

/// The dictionary endpoint. Youdao's `jsonapi` always glosses into Chinese,
/// whatever `to` the list asked for, so this adapter only claims Chinese targets;
/// every other pair is left to the machine-translation adapters.
class YoudaoAdapter implements LookupAdapter {
  const YoudaoAdapter();

  @override
  ProviderId get id => ProviderId.youdao;

  @override
  bool canServe(String from, String to) => isChineseTarget(to);

  @override
  Future<LookupResult?> fetch(String term, LookupContext context) async {
    final Object? raw = await context.http.getJson(
      Uri.https('dict.youdao.com', '/jsonapi', <String, String>{'q': term}),
      timeout: context.timeout,
    );
    return parseYoudao(raw, term);
  }
}

class YoudaoWebAdapter implements LookupAdapter {
  const YoudaoWebAdapter();

  @override
  ProviderId get id => ProviderId.youdaoSelfHosted;

  @override
  bool canServe(String from, String to) => true;

  @override
  Future<LookupResult?> fetch(String term, LookupContext context) async {
    final Object? raw = await context.http.getJson(
      Uri.https('aidemo.youdao.com', '/trans', <String, String>{
        'q': term,
        'from': youdaoLang(context.from),
        'to': youdaoLang(context.to),
      }),
      timeout: context.timeout,
    );
    final LookupResult? parsed = parseYoudaoTranslation(raw, term);
    // Youdao signals quota exhaustion with errorCode 411 in a 200 body.
    if (parsed == null && _errorCodeOf(raw) == 411) {
      throw const LookupError(LookupFailure.rateLimited);
    }
    return parsed;
  }
}

class MyMemoryAdapter implements LookupAdapter {
  const MyMemoryAdapter();

  @override
  ProviderId get id => ProviderId.myMemory;

  @override
  bool canServe(String from, String to) => true;

  @override
  Future<LookupResult?> fetch(String term, LookupContext context) async {
    final Object? raw = await context.http.getJson(
      Uri.https('api.mymemory.translated.net', '/get', <String, String>{
        'q': term,
        'langpair': myMemoryPair(context.from, context.to),
      }),
      timeout: context.timeout,
    );
    return parseMyMemory(raw, term);
  }
}

class GoogleAdapter implements LookupAdapter {
  const GoogleAdapter();

  @override
  ProviderId get id => ProviderId.google;

  @override
  bool canServe(String from, String to) => true;

  @override
  Future<LookupResult?> fetch(String term, LookupContext context) async {
    final Object? raw = await context.http.getJson(
      Uri.https('translate.googleapis.com', '/translate_a/single', <String, String>{
        'client': 'gtx',
        'sl': googleLang(context.from),
        'tl': googleLang(context.to),
        'dt': 't',
        'q': term,
      }),
      timeout: context.timeout,
    );
    return parseGoogle(raw, term);
  }
}

/// The chain the app ships with.
///
/// The desktop dictionary leads because it returns senses, phonetics and
/// examples that machine translation cannot; the two CORS-friendly public
/// endpoints follow to cover non-Chinese targets and to fill gaps.
List<LookupAdapter> defaultAdapters() => const <LookupAdapter>[
      YoudaoAdapter(),
      GoogleAdapter(),
      MyMemoryAdapter(),
    ];

/* ------------------------------------------------------------- lookup core */

class LookupOptions {
  const LookupOptions({
    this.from,
    this.to,
    this.force = false,
    this.prefer,
  });

  final String? from;
  final String? to;

  /// Skip the cache and re-fetch (the "重新翻译" button).
  final bool force;

  /// Adapter ids to try first, in this order. Everything else keeps its chain
  /// position afterwards.
  ///
  /// The engines are not interchangeable for every query. Youdao translates
  /// *into* Chinese from a dictionary and *out of* Chinese as machine
  /// translation, which renders a bare noun as a polite sentence — `苹果` comes
  /// back as `りんごです`, not `りんご`. That is fine for prose and wrong for a
  /// vocabulary entry, which needs the lemma. Callers that want a word rather
  /// than a sentence ask for the engine that returns one.
  final List<ProviderId>? prefer;
}

/// What a lookup instance exposes.
abstract class Lookup {
  Future<LookupResult> lookupTerm(String term, [LookupOptions options]);
  void clearCache();
  int cacheSize();

  /// Forget the 429 cooldowns.
  void resetCooldown();
}

class LookupDeps {
  const LookupDeps({
    required this.adapters,
    this.cache,
    this.clock = systemClock,
    this.http,
    this.perProviderTimeout = const Duration(seconds: 4),
    this.totalTimeout = const Duration(seconds: 9),
  });

  /// Fallback order, first to last.
  final List<LookupAdapter> adapters;

  /// Defaults to a fresh cache bound to [clock].
  final LookupCache? cache;
  final LookupClock clock;
  final LookupHttp? http;

  /// How long one provider may take before the chain moves on, and how long the
  /// whole lookup may take across all of them.
  ///
  /// These are two budgets, not one. A single shared 9 s signal used to be
  /// handed to every adapter, so a provider that never answers at all — Google's
  /// endpoint from the Android WebView, for instance — ate the entire budget and
  /// left the providers behind it holding an already-aborted signal. The visible
  /// symptom was a translate button stuck on "翻译中…" and then reporting the
  /// term as missing while a perfectly good provider behind it never got a try.
  final Duration perProviderTimeout;
  final Duration totalTimeout;
}

/// Build a lookup from its parts. The adapter list is data, and the cache and
/// cooldown live in this instance, so a test can make a fresh lookup per case
/// instead of resetting module state.
Lookup createLookup(LookupDeps deps) => _Lookup(deps);

class _Lookup implements Lookup {
  _Lookup(this._deps)
      : _store = _deps.cache ?? createLookupCache(LookupCacheOptions(clock: _deps.clock)),
        _http = _deps.http ?? IoLookupHttp();

  final LookupDeps _deps;
  final LookupCache _store;
  final LookupHttp _http;
  final Map<ProviderId, int> _cooldown = <ProviderId, int>{};

  bool _cooling(ProviderId provider) {
    final int? until = _cooldown[provider];
    if (until == null) return false;
    if (_deps.clock.now() > until) {
      _cooldown.remove(provider);
      return false;
    }
    return true;
  }

  void _markCooling(ProviderId provider) {
    _cooldown[provider] = _deps.clock.now() + _cooldownMs;
  }

  @override
  Future<LookupResult> lookupTerm(String term, [LookupOptions options = const LookupOptions()]) async {
    final String cleaned = normalizeTermText(term);
    if (cleaned.isEmpty) {
      throw const LookupError(LookupFailure.notFound, 'empty term');
    }

    final String from = options.from ?? 'en';
    final String to = options.to ?? 'zh-CN';
    final String key = _keyOf(cleaned, from, to);

    if (!options.force) {
      final LookupResult? cached = _store.get(key);
      if (cached != null) return cached;
    }

    final int deadline = _deps.clock.now() + _deps.totalTimeout.inMilliseconds;
    bool rateLimited = false;
    bool reachable = false;

    // `prefer` only reorders; it never removes a fallback. A caller asking for
    // Google first still gets MyMemory when Google is unreachable.
    final List<ProviderId>? prefer = options.prefer;
    final List<LookupAdapter> chain = prefer == null || prefer.isEmpty
        ? _deps.adapters
        : <LookupAdapter>[
            ...(_deps.adapters.where((LookupAdapter a) => prefer.contains(a.id))),
            ...(_deps.adapters.where((LookupAdapter a) => !prefer.contains(a.id))),
          ];

    for (final LookupAdapter adapter in chain) {
      if (!adapter.canServe(from, to)) continue;
      if (_cooling(adapter.id)) {
        rateLimited = true;
        continue;
      }
      final int remaining = deadline - _deps.clock.now();
      if (remaining <= 0) break;
      final int budget = remaining < _deps.perProviderTimeout.inMilliseconds
          ? remaining
          : _deps.perProviderTimeout.inMilliseconds;
      final LookupContext context = LookupContext(
        from: from,
        to: to,
        http: _http,
        timeout: Duration(milliseconds: budget),
      );
      try {
        final LookupResult? result = await adapter.fetch(cleaned, context);
        reachable = true;
        if (result != null) {
          _store.set(key, result);
          return result;
        }
      } on LookupError catch (error) {
        if (error.reason == LookupFailure.rateLimited) {
          _markCooling(adapter.id);
          rateLimited = true;
        }
      } on Object {
        // A timeout or transport failure costs this provider one slot of the
        // budget; the chain keeps going.
      }
    }

    if (rateLimited) throw const LookupError(LookupFailure.rateLimited);
    if (!reachable) throw const LookupError(LookupFailure.offline);
    throw const LookupError(LookupFailure.notFound);
  }

  @override
  void clearCache() => _store.clear();

  @override
  int cacheSize() => _store.size();

  @override
  void resetCooldown() => _cooldown.clear();
}

/* -------------------------------------------------------- default instance */

Lookup? _defaultLookup;

/// The app-wide lookup, built lazily so importing this library opens no socket.
///
/// The cache is file-backed on a real install: a dictionary lookup costs a
/// network round trip, and the second time the same word comes up — tomorrow,
/// after a restart — it should cost nothing. Tests override this wholesale with
/// [debugSetLookup], so the file is only ever touched by the shipping app.
Lookup get defaultLookup => _defaultLookup ??= createLookup(
      LookupDeps(
        adapters: defaultAdapters(),
        cache: createLookupCache(
          LookupCacheOptions(storage: FileLookupStorage(lookupCacheFile())),
        ),
      ),
    );

/// Where the on-disk lookup cache lives.
///
/// A separate file from `lexumo.json` on purpose: the snapshot is the user's
/// data and is backed up, synced and exported, while a dictionary cache is
/// disposable and would only bloat every backup with payloads the user never
/// typed. Losing it costs one network call per term.
String lookupCacheFile() =>
    '${AppDir.dataDir}${Platform.pathSeparator}lookup-cache.json';

/// Replace the app-wide lookup, for tests.
///
/// The same seam as `debugSetSpeech` in `tts.dart`, and for the same reason:
/// every widget that builds the editor would otherwise reach a live socket, and
/// a page test that quietly skips its lookup path is worse than no test.
void debugSetLookup(Lookup? replacement) {
  _defaultLookup = replacement;
}

/// Module-level entry point for callers that do not want to thread an instance.
Future<LookupResult> lookupTerm(String term, [LookupOptions options = const LookupOptions()]) =>
    defaultLookup.lookupTerm(term, options);

/// Reset provider cooldowns on the default instance (manual retry).
void resetProviderCooldown() => defaultLookup.resetCooldown();

/* ----------------------------------------------------------- formatting */

/// How many extra senses the secondary field may hold. A long word can come back
/// with dozens (`run` returns forty-five, 437 characters' worth); past three of
/// them the field stops being a gloss and becomes a dictionary page.
const int maxSecondarySenses = 3;

/// The primary sense on its own, with no part-of-speech prefix.
///
/// The tag belongs in its own field (`Word.pos`) rather than glued to the front
/// of the meaning: `"n. 类比，比拟"` is a dictionary line, not a gloss, and it
/// reads badly in the word list, on a flashcard, and as a quiz option.
String primaryMeaning(LookupResult result) =>
    result.senses.isEmpty ? '' : result.senses.first.meaning;

/// The remaining senses, joined the way Chinese dictionaries write them.
///
/// Two rules, both learned from what the dictionary actually returns:
///
/// 1. **A different part of speech outranks another sense of the same one.**
///    `record` arrives as noun, noun, noun, verb, adjective; taking the first
///    three senses would spend the whole field on three noun shades and hide the
///    fact that the word is also a verb. So senses that disagree with the primary
///    tag are picked first, and only leftover slots go to same-tag senses.
/// 2. **A sense keeps its tag only once per run**, and never when it matches the
///    primary one — `candid` (three adjective senses) reads
///    `"抓拍的，偷拍的；公正的"`, not `"adj. 抓拍的，偷拍的；adj. 公正的"`.
///
/// The chosen senses are still emitted in dictionary order.
String alternativeMeaning(LookupResult result) {
  if (result.senses.isEmpty) return '';
  final DictSense primary = result.senses.first;
  final List<DictSense> rest = result.senses.sublist(1);

  final Set<int> picked = <int>{};
  // Pass one: a part of speech the primary sense does not have.
  for (int i = 0; i < rest.length && picked.length < maxSecondarySenses; i++) {
    if (rest[i].pos.isNotEmpty && rest[i].pos != primary.pos) picked.add(i);
  }
  // Pass two: fill what is left with further shades of the primary sense.
  for (int i = 0; i < rest.length && picked.length < maxSecondarySenses; i++) {
    picked.add(i);
  }

  final List<String> parts = <String>[];
  String? lastPos;
  final List<int> ordered = picked.toList()..sort();
  for (final int i in ordered) {
    final DictSense sense = rest[i];
    final bool needsTag =
        sense.pos.isNotEmpty && sense.pos != primary.pos && sense.pos != lastPos;
    parts.add(needsTag ? '${sense.pos} ${sense.meaning}' : sense.meaning);
    lastPos = sense.pos;
  }
  return parts.join('；');
}

/// All senses as one line — used for the "填入释义" preview and toasts.
String formatSenses(LookupResult result) => result.senses
    .map((DictSense s) => s.pos.isEmpty ? s.meaning : '${s.pos} ${s.meaning}')
    .join('；');

/// Distinct part-of-speech tags in order of first appearance, e.g.
/// `["n.", "v.", "adj."]`. Feeds the `pos` field in the editor: a word can be a
/// noun and a verb at once, and the secondary field only has room for three
/// senses, so this is the reliable place to record that it is both.
List<String> posTags(LookupResult result) {
  final Set<String> seen = <String>{};
  final List<String> tags = <String>[];
  for (final DictSense sense in result.senses) {
    if (sense.pos.isNotEmpty && seen.add(sense.pos)) tags.add(sense.pos);
  }
  return tags;
}
