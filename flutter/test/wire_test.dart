/// Port of `src/lib/wire.test.ts` (17 `it` cases, one Dart test each).
///
/// Same fixtures and the same expected values as the vitest file, so the two
/// builds can be diffed case by case. Two assertions could not be transcribed
/// literally and say so at their site:
///
///   · `expect(x).not.toHaveProperty("mystery")` — the Dart types have no room
///     for an unknown key at all, so the equivalent is "the decoded record
///     re-serialises to exactly the domain fields".
///   · `JSON.stringify(decoded)` — a `ChangeSet` is typed here, not a plain
///     object; the round trip through [ChangeSet.toJson] is what plays that
///     role.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/data/models/sync_merge.dart';
import 'package:lexumo/data/services/transfer.dart';
import 'package:lexumo/data/models/wire.dart';
import 'package:lexumo/domain/models/types.dart';

/* ------------------------------------------------------------------ */
/* Fixtures                                                            */
/* ------------------------------------------------------------------ */

Word word(String id, int updatedAt, {String? term, String? phonetic, String? pos, String? exampleZh, String? definition}) {
  return Word(
    id: id,
    term: term ?? id,
    phonetic: phonetic,
    pos: pos,
    definition: definition ?? '',
    definition2: '',
    example: '',
    exampleZh: exampleZh,
    note: '',
    status: WordStatus.new_,
    favorite: false,
    listId: DEFAULT_LIST_ID,
    sourceLang: 'en',
    targetLang: 'zh-CN',
    listenCount: 0,
    srs: null,
    createdAt: 1000,
    updatedAt: updatedAt,
  );
}

WordList list(String id, int updatedAt, {String? name}) {
  return WordList(
    id: id,
    name: name ?? id,
    sourceLang: 'en',
    targetLang: 'zh-CN',
    createdAt: 1000,
    updatedAt: updatedAt,
  );
}

ReviewLog log(String id, String wordId, String grade, int at) {
  return ReviewLog(
    id: id,
    wordId: wordId,
    grade: Grade.fromWire(grade),
    at: at,
    intervalBefore: 1,
    intervalAfter: 2,
  );
}

AppData data({
  List<WordList> lists = const [],
  List<Word> words = const [],
  List<ReviewLog> logs = const [],
  Settings settings = const Settings(),
  int settingsUpdatedAt = 0,
  Tombstones tombstones = const Tombstones(),
  PendingChanges pending = const PendingChanges(),
}) {
  return AppData(
    version: DATA_VERSION,
    lists: lists,
    words: words,
    logs: logs,
    settings: settings,
    settingsUpdatedAt: settingsUpdatedAt,
    tombstones: tombstones,
    pending: pending,
  );
}

/// What the server actually answers: every record stamped with its revision.
///
/// In the TS these were domain objects with an extra `_rev` key. The Dart types
/// cannot carry one, so the map below is the only place a `_rev` can exist —
/// which is the point: it has to be dropped at the boundary, not carried in.
Map<String, dynamic> wireWord(String id, int updatedAt, [int rev = 11]) =>
    {...word(id, updatedAt).toJson(), '_rev': rev};

bool hasRev(Object? value) => jsonEncode(value).contains('_rev');

void main() {
  /* ---------------------------------------------------------------- */
  /* decode: server bookkeeping never reaches the snapshot             */
  /* ---------------------------------------------------------------- */

  group('decodeChangeSet strips server bookkeeping', () {
    test('removes _rev from every record kind', () {
      final decoded = decodeChangeSet({
        'words': [
          wireWord('w1', 10),
          {'id': 'w2', 'updatedAt': 20, 'deleted': true, '_rev': 12},
        ],
        'lists': [
          {...list('l1', 30).toJson(), '_rev': 13},
        ],
        'logs': [
          {
            'id': 'g1',
            'wordId': 'w1',
            'grade': 'good',
            'at': 40,
            'intervalBefore': 1,
            'intervalAfter': 2,
            '_rev': 14,
          },
          {'id': 'g2', 'at': 50, 'deleted': true, '_rev': 15},
        ],
        'settings': {...const Settings().toJson(), 'updatedAt': 60, '_rev': 16},
      });

      expect(hasRev(decoded.toJson()), isFalse);
      expect(decoded.words, hasLength(2));
      expect((decoded.words[0] as WordEdit).word.toJson(), word('w1', 10).toJson());
      expect(
        (decoded.words[1] as WordTombstone).toJson(),
        {'id': 'w2', 'updatedAt': 20, 'deleted': true},
      );
      expect((decoded.lists[0] as ListEdit).list.toJson(), list('l1', 30).toJson());
      expect((decoded.logs[0] as LogEntry).log.toJson(), log('g1', 'w1', 'good', 40).toJson());
      expect(
        (decoded.logs[1] as LogTombstone).toJson(),
        {'id': 'g2', 'at': 50, 'deleted': true},
      );
      expect(decoded.settings!.settings.toJson(), const Settings().toJson());
      expect(decoded.settings!.updatedAt, 60);
    });

    test('drops unknown keys instead of copying them', () {
      final decoded = decodeChangeSet({
        'words': [
          {...wireWord('w1', 10), 'mystery': 'nope'},
        ],
        'lists': [
          {...list('l1', 20).toJson(), 'mystery': 'nope'},
        ],
        'logs': [
          {
            'id': 'g1',
            'wordId': 'w1',
            'grade': 'good',
            'at': 30,
            'intervalBefore': 1,
            'intervalAfter': 2,
            'mystery': 'nope',
          },
        ],
        'settings': {...const Settings().toJson(), 'updatedAt': 40, 'mystery': 'nope'},
      });

      // The TS asserted on `JSON.stringify(decoded)` and on `toHaveProperty`.
      // A typed record cannot hold an unknown key, so what is worth asserting
      // is that the record re-serialises to exactly the domain field set.
      expect(jsonEncode(decoded.toJson()), isNot(contains('mystery')));
      expect((decoded.words[0] as WordEdit).word.toJson(), word('w1', 10).toJson());
      expect(decoded.settings!.settings.toJson(), const Settings().toJson());
    });

    test('fills optional fields a sparse record omits with domain defaults', () {
      final decoded = decodeChangeSet({
        'words': [
          {'id': 'w1', 'term': 'hola', 'updatedAt': 10},
        ],
        'settings': {'updatedAt': 20},
      });

      // A sparse record must not reach the snapshot with missing fields: the
      // UI and the JSON backup read these unconditionally.
      final w = (decoded.words[0] as WordEdit).word;
      expect(w.id, 'w1');
      expect(w.term, 'hola');
      expect(w.updatedAt, 10);
      expect(w.definition, '');
      expect(w.phonetic, isNull);
      expect(w.srs, isNull);
      expect(w.status, WordStatus.new_);
      expect(w.favorite, isFalse);

      // Settings are rebuilt from the payload, so an omitted field is the
      // domain default for that field only — `theme` falls back to `system`
      // through `ThemeMode_.fromWire`.
      final s = decoded.settings!.settings;
      expect(decoded.settings!.updatedAt, 20);
      expect(s.theme, ThemeMode_.system);
      expect(s.dailyGoal, 0);
      expect(s.toJson().values, isNot(contains(isNull)));
    });
  });

  /* ---------------------------------------------------------------- */
  /* decode: optional text fields survive the boundary                 */
  /* ---------------------------------------------------------------- */

  group('optional text fields', () {
    test('keeps phonetic, pos and exampleZh through decode', () {
      final decoded = decodeChangeSet({
        'words': [
          {
            'id': 'w1',
            'term': 'candid',
            'phonetic': 'ˈkændɪd',
            'pos': 'adj.',
            'example': 'She is very candid.',
            'exampleZh': '她为人很坦诚。',
            'updatedAt': 10,
          },
        ],
      });

      final w = (decoded.words[0] as WordEdit).word;
      expect(w.phonetic, 'ˈkændɪd');
      expect(w.pos, 'adj.');
      expect(w.exampleZh, '她为人很坦诚。');
    });

    test('keeps them through encode, so a backup is not lossy', () {
      final d = data(words: [
        word('w1', 5, phonetic: 'ˈkændɪd', pos: 'adj.', exampleZh: '她为人很坦诚。'),
      ]);

      final clean = encodeAppData(d);

      expect(clean.words[0].phonetic, 'ˈkændɪd');
      expect(clean.words[0].pos, 'adj.');
      expect(clean.words[0].exampleZh, '她为人很坦诚。');
    });

    test('collapses an empty optional field to null rather than an empty string', () {
      final decoded = decodeChangeSet({
        'words': [
          {
            'id': 'w1',
            'term': 'hola',
            'phonetic': '',
            'pos': '',
            'exampleZh': '',
            'updatedAt': 10,
          },
        ],
      });

      final w = (decoded.words[0] as WordEdit).word;
      expect(w.phonetic, isNull);
      expect(w.pos, isNull);
      expect(w.exampleZh, isNull);
      // `toJson` omits a null optional field, which is the Dart spelling of the
      // TS's "`JSON.stringify` drops the key".
      expect(jsonEncode(w.toJson()), isNot(contains('"phonetic"')));
      expect(jsonEncode(w.toJson()), isNot(contains('"pos"')));
    });
  });

  /* ---------------------------------------------------------------- */
  /* decode: malformed records are dropped, not merged                 */
  /* ---------------------------------------------------------------- */

  group('decodeChangeSet rejects malformed records', () {
    test('drops records without an id or without their merge stamp', () {
      final decoded = decodeChangeSet({
        'words': [
          {'term': 'no id', 'updatedAt': 1},
          {'id': '', 'term': 'empty id', 'updatedAt': 1},
          {'id': 'w1', 'term': 'no stamp'},
          {'id': 'w2', 'term': 'bad stamp', 'updatedAt': 'soon'},
        ],
      });

      expect(decoded.words, isEmpty);
    });

    test('drops records of the wrong kind', () {
      final decoded = decodeChangeSet({
        // A review log in the words bucket has no `term`; a word in the logs
        // bucket has no `wordId`/`at`. Neither can be merged by its bucket's
        // rule.
        'words': [
          {'id': 'g1', 'wordId': 'w1', 'grade': 'good', 'at': 5},
        ],
        'lists': [
          {'id': 'l1', 'updatedAt': 5},
        ],
        'logs': [word('w1', 5).toJson()],
      });

      expect(decoded.words, isEmpty);
      expect(decoded.lists, isEmpty);
      expect(decoded.logs, isEmpty);
    });

    test('drops a malformed settings record', () {
      expect(decodeChangeSet({'settings': {'dailyGoal': 5}}).settings, isNull);
      expect(decodeChangeSet({'settings': 'nope'}).settings, isNull);
    });

    test('never throws on garbage', () {
      expect(decodeChangeSet(null).toJson(), ChangeSet.empty.toJson());
      expect(decodeChangeSet([1, 2, 3]).toJson(), ChangeSet.empty.toJson());
      expect(
        decodeChangeSet({
          'words': 'nope',
          'lists': 5,
          'logs': <String, dynamic>{},
          'settings': 7,
        }).toJson(),
        ChangeSet.empty.toJson(),
      );
      expect(
        decodeChangeSet({
          'words': [null, 3, <String, dynamic>{}],
        }).words,
        isEmpty,
      );
    });
  });

  /* ---------------------------------------------------------------- */
  /* encode: nothing leaves the client that is not domain data         */
  /* ---------------------------------------------------------------- */

  group('encodeChangeSet', () {
    test('never emits _rev, even from a snapshot persisted before the fix', () {
      // The Dart `Word` cannot hold `_rev`, so the "polluted" snapshot is
      // expressed at the only layer that could ever carry one: the raw map the
      // wire hands over. Round-tripping it is what the TS test checked.
      final polluted = wireWord('w1', 5, 7);
      final d = data(
        words: [(decodeChangeSet({'words': [polluted]}).words[0] as WordEdit).word],
        lists: [list('l1', 6)],
        pending: const PendingChanges(words: ['w1'], lists: ['l1']),
      );

      final encoded = encodeChangeSet(collectChanges(d));

      expect(hasRev(encoded), isFalse);
      expect((encoded['words'] as List).first, word('w1', 5).toJson());
      expect((encoded['lists'] as List).first, list('l1', 6).toJson());
      // Settle compares these stamps against the local copy, so rebuilding
      // must preserve them exactly.
      expect(((encoded['words'] as List).first as Map)['updatedAt'], 5);
    });

    test('is idempotent after decode', () {
      final raw = {
        'words': [wireWord('w1', 10)],
        'lists': [
          {...list('l1', 20).toJson(), '_rev': 3},
        ],
        'logs': [
          {
            'id': 'g1',
            'wordId': 'w1',
            'grade': 'easy',
            'at': 30,
            'intervalBefore': 1,
            'intervalAfter': 2,
            '_rev': 4,
          },
        ],
        'settings': {...const Settings().toJson(), 'updatedAt': 40, '_rev': 5},
      };

      final decoded = decodeChangeSet(raw);
      final once = encodeChangeSet(decoded);
      final twice = encodeChangeSet(decodeChangeSet(once));

      expect(once, decoded.toJson());
      expect(twice, once);
      expect(hasRev(twice), isFalse);
    });
  });

  /* ---------------------------------------------------------------- */
  /* The leak that motivated this module                               */
  /* ---------------------------------------------------------------- */

  group('applyRemote consumes decoded records', () {
    test('does not persist _rev into the snapshot', () {
      final raw = {
        'words': [wireWord('w1', 10)],
        'lists': [
          {...list('l1', 20).toJson(), '_rev': 3},
        ],
        'logs': [
          {
            'id': 'g1',
            'wordId': 'w1',
            'grade': 'good',
            'at': 30,
            'intervalBefore': 1,
            'intervalAfter': 2,
            '_rev': 4,
          },
        ],
        'settings': {
          ...const Settings(dailyGoal: 42).toJson(),
          'updatedAt': 40,
          '_rev': 5,
        },
      };

      final next = applyRemote(data(), decodeChangeSet(raw));

      expect(hasRev(next.toJson()), isFalse);
      expect(next.words[0].term, 'w1');
      expect(next.lists[0].name, 'l1');
      expect(next.logs[0].id, 'g1');
      expect(next.settings.dailyGoal, 42);
    });
  });

  /* ---------------------------------------------------------------- */
  /* JSON backup                                                       */
  /* ---------------------------------------------------------------- */

  group('JSON backup', () {
    test('exports only the user\'s data, never sync bookkeeping', () {
      final d = data(
        words: [word('w1', 5, term: 'hola')],
        tombstones: const Tombstones(words: {'gone': 1}),
        pending: const PendingChanges(words: ['w1']),
      );

      final text = exportJson(d);
      final parsed = jsonDecode(text) as Map<String, dynamic>;

      expect(parsed.keys.toList()..sort(), [
        'lists',
        'logs',
        'settings',
        'settingsUpdatedAt',
        'version',
        'words',
      ]);
      expect(parsed.containsKey('pending'), isFalse);
      expect(parsed.containsKey('tombstones'), isFalse);
      expect(hasRev(parsed), isFalse);
      expect(((parsed['words'] as List).first as Map)['term'], 'hola');
    });

    test('still imports a backup written before pending/tombstones were dropped', () {
      final legacy = jsonEncode({
        'version': DATA_VERSION,
        'lists': [list('l1', 1).toJson()],
        'words': [word('w1', 2, term: 'hola').toJson()],
        'logs': <Object?>[],
        'settings': const Settings().toJson(),
        'settingsUpdatedAt': 3,
        'tombstones': const Tombstones(words: {'gone': 1}).toJson(),
        'pending': const PendingChanges(words: ['w1']).toJson(),
      });

      final result = parseImport(legacy, DEFAULT_LIST_ID);

      expect(result.format, ImportFormat.json);
      expect(result.skipped, 0);
      expect(result.words, hasLength(1));
      expect(result.words[0].term, 'hola');
    });

    test('round-trips its own export', () {
      final d = data(words: [
        word('w1', 5, term: 'hola'),
        word('w2', 6, term: 'adios'),
      ]);

      final result = parseImport(exportJson(d), DEFAULT_LIST_ID);

      expect(result.words.map((w) => w.term).toList(), ['hola', 'adios']);
    });
  });

  /* ---------------------------------------------------------------- */
  /* Snapshot projection                                               */
  /* ---------------------------------------------------------------- */

  group('encodeAppData', () {
    test('scrubs server keys from every record but keeps the snapshot shape', () {
      final d = data(
        words: [word('w1', 5)],
        tombstones: const Tombstones(words: {'gone': 1}),
        pending: const PendingChanges(words: ['w1']),
      );

      final clean = encodeAppData(d);

      expect(hasRev(clean.words), isFalse);
      expect(clean.words[0].toJson(), word('w1', 5).toJson());
      // Sync bookkeeping is not the backup's business, but this projection is
      // not the place that decides it — transfer omits it.
      expect(clean.pending.words, ['w1']);
      expect(clean.tombstones.words['gone'], 1);
    });
  });
}
