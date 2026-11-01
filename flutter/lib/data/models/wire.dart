/// The sync wire edge: the only module that knows what the server sends.
///
/// Ported from `src/lib/wire.ts` (311 lines). The TS header explains the bug
/// that created the module: the server stamps `_rev` onto every record it
/// returns, the merge used to store that object verbatim, and `_rev` was then
/// persisted as domain data, re-uploaded by the next push and written into the
/// user's JSON backup.
///
/// The port has the same two duties, but only one of them is still enforced at
/// runtime:
///
///   · **decode** still validates shape and rebuilds every record field by
///     field. A response is untrusted input: a malformed row must cost that
///     row, not the round and certainly not the snapshot.
///
///   · **encode** can no longer leak `_rev` by accident, because [Word],
///     [WordList] and [ReviewLog] have nowhere to keep it and their `toJson`
///     enumerates fields instead of spreading an object. The rebuild survives
///     anyway — it is the seam that keeps that property true if an untyped
///     source is ever added, and it normalises optional text (`''` → `null`).
///
/// The TS module worked on `Record<string, unknown>` and could hand unknown
/// keys to `AppData`. That is impossible here, so the wire records are sealed
/// types ([WordRecord], [ListRecord], [LogRecord]) and [ChangeSet] carries
/// them. `sync_merge.dart` merges the typed result; nothing in this file ever
/// reaches the snapshot as a map.
///
/// Pure: no I/O, no module state, no clock.
library;

import '../../domain/models/types.dart';

/* ------------------------------------------------------------------ */
/* Wire record shapes                                                  */
/*                                                                     */
/* `WordRecord = Word | Tombstone` in the TS; a sealed hierarchy in     */
/* Dart, because a tombstone and a record are merged by different       */
/* rules and pattern matching is what keeps the two from being          */
/* confused. A tombstone is `{id, updatedAt, deleted: true}` (logs:     */
/* `{id, at, deleted: true}`) — minimal on purpose: the server only     */
/* needs to know which id went away and when.                           */
/* ------------------------------------------------------------------ */

/// One entry of the `words` bucket: either a full record or its tombstone.
sealed class WordRecord {
  const WordRecord();

  /// The record identity. Always non-empty — [decodeChangeSet] drops a record
  /// that arrives without one, because an id is what LWW merges on.
  String get id;

  /// The stamp this record competes with in last-write-wins.
  int get updatedAt;

  /// The wire form. Rebuilt from domain fields, so no server bookkeeping and
  /// no unknown key can appear here.
  Map<String, dynamic> toJson();
}

/// A live word.
final class WordEdit extends WordRecord {
  const WordEdit(this.word);

  final Word word;

  @override
  String get id => word.id;

  @override
  int get updatedAt => word.updatedAt;

  @override
  Map<String, dynamic> toJson() => word.toJson();
}

/// A word that was deleted at [updatedAt].
final class WordTombstone extends WordRecord {
  const WordTombstone({required this.id, required this.updatedAt});

  @override
  final String id;

  @override
  final int updatedAt;

  @override
  Map<String, dynamic> toJson() =>
      {'id': id, 'updatedAt': updatedAt, 'deleted': true};
}

/// One entry of the `lists` bucket.
sealed class ListRecord {
  const ListRecord();

  String get id;

  int get updatedAt;

  Map<String, dynamic> toJson();
}

/// A live word list.
final class ListEdit extends ListRecord {
  const ListEdit(this.list);

  final WordList list;

  @override
  String get id => list.id;

  @override
  int get updatedAt => list.updatedAt;

  @override
  Map<String, dynamic> toJson() => list.toJson();
}

/// A list that was deleted at [updatedAt].
final class ListTombstone extends ListRecord {
  const ListTombstone({required this.id, required this.updatedAt});

  @override
  final String id;

  @override
  final int updatedAt;

  @override
  Map<String, dynamic> toJson() =>
      {'id': id, 'updatedAt': updatedAt, 'deleted': true};
}

/// One entry of the `logs` bucket.
///
/// Review logs are append-only and deduplicated by id, so their stamp is `at`
/// (when the review happened) rather than `updatedAt` — a log is never edited.
sealed class LogRecord {
  const LogRecord();

  String get id;

  /// When the review happened. The stamp deletions are compared against.
  int get at;

  Map<String, dynamic> toJson();
}

/// A live review log.
final class LogEntry extends LogRecord {
  const LogEntry(this.log);

  final ReviewLog log;

  @override
  String get id => log.id;

  @override
  int get at => log.at;

  @override
  Map<String, dynamic> toJson() => log.toJson();
}

/// A review log that was deleted at [at].
final class LogTombstone extends LogRecord {
  const LogTombstone({required this.id, required this.at});

  @override
  final String id;

  @override
  final int at;

  @override
  Map<String, dynamic> toJson() => {'id': id, 'at': at, 'deleted': true};
}

/// Settings travel as one document with one stamp — there is no per-field
/// merge, which is why this is not a tombstone-able record.
class SettingsRecord {
  const SettingsRecord({required this.settings, required this.updatedAt});

  final Settings settings;
  final int updatedAt;

  Map<String, dynamic> toJson() => {...settings.toJson(), 'updatedAt': updatedAt};
}

/// One direction of a sync round: what to push, or what the server answered.
///
/// Declared here rather than in `domain/types.dart` because it is wire
/// vocabulary, not domain vocabulary — the snapshot never holds a [ChangeSet].
class ChangeSet {
  const ChangeSet({
    this.words = const [],
    this.lists = const [],
    this.logs = const [],
    this.settings,
  });

  final List<WordRecord> words;
  final List<ListRecord> lists;
  final List<LogRecord> logs;

  /// `null` means "no settings change in this direction", which is not the
  /// same as "settings are empty".
  final SettingsRecord? settings;

  /// Nothing to send and nothing to merge — also what an idle round transmits.
  static const ChangeSet empty = ChangeSet();

  bool get isEmpty =>
      words.isEmpty && lists.isEmpty && logs.isEmpty && settings == null;

  Map<String, dynamic> toJson() => {
        'words': words.map((r) => r.toJson()).toList(),
        'lists': lists.map((r) => r.toJson()).toList(),
        'logs': logs.map((r) => r.toJson()).toList(),
        'settings': settings?.toJson(),
      };
}

/* ------------------------------------------------------------------ */
/* Coercion                                                            */
/*                                                                     */
/* Each of these answers "what does this field mean when it is missing  */
/* or hostile", which is the whole job of a decoder. They do NOT trim:   */
/* the server's text is the user's text, and trimming here would make a  */
/* synced word differ from the same word typed locally.                  */
/* ------------------------------------------------------------------ */

/// Non-string and absent both mean the empty string, the domain default.
String _str(Object? value) => value is String ? value : '';

/// Optional text. Absent, non-string and **empty** all collapse to `null`, so
/// a decoded record compares equal to one that never had the field, and so
/// `toJson` omits the key instead of writing `""`.
String? _optString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

/// A stamp or counter. Non-numbers, `NaN` and infinities all mean 0.
///
/// The TS kept a fractional number as-is; the domain fields are `int`, so the
/// port truncates. Nothing writes a fractional stamp, so this is a guard
/// against a hostile payload rather than a real conversion.
int _int(Object? value) {
  if (value is int) return value;
  if (value is double && value.isFinite) return value.toInt();
  return 0;
}

/// A real number (SRS ease, TTS rate).
double _double(Object? value) {
  if (value is num && (value is! double || value.isFinite)) return value.toDouble();
  return 0;
}

/// Only the literal `true` is true. The TS did the same (`value === true`),
/// which is why a `"false"` string cannot turn a flag on.
bool _bool(Object? value) => value == true;

/// A stamp is a finite number. A record without one cannot take part in LWW,
/// so it is rejected rather than defaulted to 0 — that would let a malformed
/// record win against a real one written in 1970.
bool _isStamp(Object? value) => value is int || (value is double && value.isFinite);

/// An id must be a non-empty string: `{id: ""}` is a record nothing can merge.
bool _hasId(Object? value) => value is String && value.isNotEmpty;

/// The three grades the server may send. Anything else is not a log.
bool _isGrade(Object? value) => value == 'hard' || value == 'good' || value == 'easy';

/// A JSON object, copied into a `Map<String, dynamic>`.
///
/// The copy is deliberate rather than `cast`: a hostile payload can carry
/// non-string keys, and a cast view would only blow up later, on access, far
/// from the record that caused it. Unknown keys are dropped here — this
/// function is where "only domain fields survive" starts.
Map<String, dynamic>? _asRecord(Object? value) {
  if (value is! Map) return null;
  final out = <String, dynamic>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is String) out[key] = entry.value;
  }
  return out;
}

SrsState? _asSrs(Object? value) {
  final raw = _asRecord(value);
  if (raw == null) return null;
  return SrsState(
    ease: _double(raw['ease']),
    intervalDays: _int(raw['intervalDays']),
    dueAt: _int(raw['dueAt']),
    reviewCount: _int(raw['reviewCount']),
    correctCount: _int(raw['correctCount']),
    lastReviewedAt: _isStamp(raw['lastReviewedAt']) ? _int(raw['lastReviewedAt']) : null,
  );
}

/* ------------------------------------------------------------------ */
/* Record rebuilders                                                   */
/*                                                                     */
/* These never throw and never copy unknown keys: they are the whole    */
/* reason `_rev` cannot reach the snapshot. Decode validates first,     */
/* encode trusts the domain type and rebuilds anyway — a snapshot       */
/* written before this module existed could still carry `_rev` in the   */
/* TS build, and `encodeAppData` is what scrubbed it.                   */
/* ------------------------------------------------------------------ */

Word _cleanWord(Object? value) {
  final raw = _asRecord(value) ?? const <String, dynamic>{};
  return Word(
    id: _str(raw['id']),
    term: _str(raw['term']),
    phonetic: _optString(raw['phonetic']),
    pos: _optString(raw['pos']),
    definition: _str(raw['definition']),
    definition2: _str(raw['definition2']),
    example: _str(raw['example']),
    exampleZh: _optString(raw['exampleZh']),
    note: _str(raw['note']),
    status: WordStatus.fromWire(_str(raw['status'])),
    favorite: _bool(raw['favorite']),
    listId: _str(raw['listId']),
    sourceLang: _str(raw['sourceLang']),
    targetLang: _str(raw['targetLang']),
    listenCount: _int(raw['listenCount']),
    srs: _asSrs(raw['srs']),
    createdAt: _int(raw['createdAt']),
    updatedAt: _int(raw['updatedAt']),
  );
}

WordRecord _cleanWordRecord(Object? value) {
  final raw = _asRecord(value) ?? const <String, dynamic>{};
  if (raw['deleted'] == true) {
    return WordTombstone(id: _str(raw['id']), updatedAt: _int(raw['updatedAt']));
  }
  return WordEdit(_cleanWord(raw));
}

WordList _cleanList(Object? value) {
  final raw = _asRecord(value) ?? const <String, dynamic>{};
  return WordList(
    id: _str(raw['id']),
    name: _str(raw['name']),
    sourceLang: _str(raw['sourceLang']),
    targetLang: _str(raw['targetLang']),
    createdAt: _int(raw['createdAt']),
    updatedAt: _int(raw['updatedAt']),
  );
}

ListRecord _cleanListRecord(Object? value) {
  final raw = _asRecord(value) ?? const <String, dynamic>{};
  if (raw['deleted'] == true) {
    return ListTombstone(id: _str(raw['id']), updatedAt: _int(raw['updatedAt']));
  }
  return ListEdit(_cleanList(raw));
}

ReviewLog _cleanLog(Object? value) {
  final raw = _asRecord(value) ?? const <String, dynamic>{};
  return ReviewLog(
    id: _str(raw['id']),
    wordId: _str(raw['wordId']),
    grade: Grade.fromWire(_str(raw['grade'])),
    at: _int(raw['at']),
    intervalBefore: _int(raw['intervalBefore']),
    intervalAfter: _int(raw['intervalAfter']),
  );
}

LogRecord _cleanLogRecord(Object? value) {
  final raw = _asRecord(value) ?? const <String, dynamic>{};
  if (raw['deleted'] == true) {
    return LogTombstone(id: _str(raw['id']), at: _int(raw['at']));
  }
  return LogEntry(_cleanLog(raw));
}

/// Rebuilt from scratch, so every numeric field takes 0 when the server omits
/// it — *not* [Settings]'s constructor defaults. A decoded settings record is
/// the server's document, and inventing `dailyGoal: 20` for a field it never
/// sent would silently overwrite the local value.
Settings _cleanSettings(Object? value) {
  final raw = _asRecord(value) ?? const <String, dynamic>{};
  return Settings(
    theme: ThemeMode_.fromWire(_str(raw['theme'])),
    uiLang: UiLang.fromWire(_str(raw['uiLang'])),
    dailyGoal: _int(raw['dailyGoal']),
    ttsRate: _double(raw['ttsRate']),
    ttsVoiceURI: _str(raw['ttsVoiceURI']),
    autoPlayAudio: _bool(raw['autoPlayAudio']),
    audioFirst: _bool(raw['audioFirst']),
    newCardsPerDay: _int(raw['newCardsPerDay']),
    reviewOrder: raw['reviewOrder'] == 'random' ? 'random' : 'due',
    autoSync: _bool(raw['autoSync']),
  );
}

SettingsRecord _cleanSettingsRecord(Object? value) {
  final raw = _asRecord(value) ?? const <String, dynamic>{};
  return SettingsRecord(
    settings: _cleanSettings(raw),
    updatedAt: _int(raw['updatedAt']),
  );
}

/* ------------------------------------------------------------------ */
/* Decode                                                              */
/* ------------------------------------------------------------------ */

/*
 * Minimal shape checks. A record is admitted only when it carries the fields
 * its kind is merged by — a log-shaped object in `words` has no `term`, a
 * record with no `updatedAt` cannot participate in LWW, and neither belongs in
 * the snapshot. The server already rejects most of this (server/src/store.js),
 * so these guards are about the client not trusting a response it did not
 * validate.
 *
 * A tombstone is exempt from the "carries its payload" half: it has no payload
 * by design, so only its id and its stamp are checked.
 */

bool _isWord(Map<String, dynamic> raw) =>
    _hasId(raw['id']) &&
    (raw['deleted'] == true
        ? _isStamp(raw['updatedAt'])
        : raw['term'] is String && _isStamp(raw['updatedAt']));

bool _isList(Map<String, dynamic> raw) =>
    _hasId(raw['id']) &&
    (raw['deleted'] == true
        ? _isStamp(raw['updatedAt'])
        : raw['name'] is String && _isStamp(raw['updatedAt']));

bool _isLog(Map<String, dynamic> raw) =>
    _hasId(raw['id']) &&
    (raw['deleted'] == true
        ? _isStamp(raw['at'])
        : raw['wordId'] is String && _isStamp(raw['at']) && _isGrade(raw['grade']));

/// Turn the raw `changes` of a sync response into a domain [ChangeSet].
///
/// Malformed records are dropped one by one rather than throwing: a bad row
/// should cost that row, not the whole round — and not the snapshot. Garbage
/// of any shape (null, a list, a string) decodes to [ChangeSet.empty].
ChangeSet decodeChangeSet(Object? raw) {
  final body = _asRecord(raw) ?? const <String, dynamic>{};

  final words = <WordRecord>[];
  final rawWords = body['words'];
  if (rawWords is List) {
    for (final item in rawWords) {
      final record = _asRecord(item);
      if (record != null && _isWord(record)) words.add(_cleanWordRecord(record));
    }
  }

  final lists = <ListRecord>[];
  final rawLists = body['lists'];
  if (rawLists is List) {
    for (final item in rawLists) {
      final record = _asRecord(item);
      if (record != null && _isList(record)) lists.add(_cleanListRecord(record));
    }
  }

  final logs = <LogRecord>[];
  final rawLogs = body['logs'];
  if (rawLogs is List) {
    for (final item in rawLogs) {
      final record = _asRecord(item);
      if (record != null && _isLog(record)) logs.add(_cleanLogRecord(record));
    }
  }

  final settings = _asRecord(body['settings']);
  return ChangeSet(
    words: words,
    lists: lists,
    logs: logs,
    settings: settings != null && _isStamp(settings['updatedAt'])
        ? _cleanSettingsRecord(settings)
        : null,
  );
}

/* ------------------------------------------------------------------ */
/* Encode                                                              */
/* ------------------------------------------------------------------ */

/// The payload sent to the server, as JSON-ready maps.
///
/// The TS rebuilt every record here to keep `_rev` off the wire, because
/// `collectChanges` handed over the snapshot's own objects. In the port a
/// [ChangeSet] already holds typed records whose `toJson` enumerates fields
/// rather than spreading an object, so `_rev` cannot appear either way — but
/// the rebuild is kept because it is the *normalisation* step, not just a
/// scrub: a word added locally with `phonetic: ''` would otherwise go out as
/// `"phonetic": ""`, where the TS sent the key omitted. Both decode back to
/// `null`, so this only keeps the bytes identical to the web build's.
///
/// Encoding is idempotent: encoding a decoded change set, decoding that and
/// encoding it again produces the same JSON.
Map<String, dynamic> encodeChangeSet(ChangeSet delta) {
  return ChangeSet(
    words: delta.words.map((r) => _cleanWordRecord(r.toJson())).toList(),
    lists: delta.lists.map((r) => _cleanListRecord(r.toJson())).toList(),
    logs: delta.logs.map((r) => _cleanLogRecord(r.toJson())).toList(),
    settings: delta.settings == null
        ? null
        : _cleanSettingsRecord(delta.settings!.toJson()),
  ).toJson();
}

/// Project a snapshot for persistence or backup: domain records only.
///
/// In the TS this was the guard that stopped `_rev` from being written into a
/// backup file. Here the types already guarantee it, so what the rebuild still
/// buys is normalisation: an optional text field that is `''` becomes `null`,
/// exactly as decoding would have produced it. That keeps "a snapshot loaded
/// from disk" and "a snapshot decoded from the wire" the same shape, which is
/// what lets the two be compared in tests.
///
/// `pending` and `tombstones` are sync bookkeeping and are carried through
/// untouched — deciding that a backup should not contain them is
/// `data/transfer.dart`'s job, not this projection's.
AppData encodeAppData(AppData data) {
  return data.copyWith(
    words: data.words.map((w) => _cleanWord(w.toJson())).toList(),
    lists: data.lists.map((l) => _cleanList(l.toJson())).toList(),
    logs: data.logs.map((l) => _cleanLog(l.toJson())).toList(),
    settings: _cleanSettings(data.settings.toJson()),
  );
}
