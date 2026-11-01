/// Port of `src/lib/syncMerge.test.ts` (23 `it`) and `src/lib/syncRound.test.ts`
/// (13 `it`) — 36 cases, one Dart test each.
///
/// The first half exercises the pure merge functions directly, exactly as the
/// vitest file does. The second half drives a real [Store] with a mutable clock,
/// because the properties under test are about what one whole round does to a
/// snapshot, not about a function in isolation. The clock matters there: the
/// version guard compares `updatedAt` values, and a frozen clock would make
/// "the edit bumped the version" vacuous.
///
/// One TS case had no Dart equivalent and is re-expressed rather than dropped:
/// `applyRound is not a local edit` asserted that a round does not emit on the
/// `localChanges` bus. There is no such bus in this tree — `Store.applyMerged`
/// is the write half and marks nothing — so the case asserts the property the
/// bus was there to observe: a round leaves no record pending and bumps no
/// stamp, while a real edit does both.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/data/models/sync_merge.dart' as sm;
import 'package:lexumo/data/models/wire.dart';
import 'package:lexumo/domain/models/types.dart';

const int T0 = 1700000000000;

/* ------------------------------------------------------------------ */
/* Fixtures                                                            */
/* ------------------------------------------------------------------ */

Word word(String id, int updatedAt, {String? definition, String? term}) {
  return Word(
    id: id,
    term: term ?? id,
    definition: definition ?? '',
    definition2: '',
    example: '',
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

ReviewLog log(String id, int at, {String wordId = 'w1', Grade grade = Grade.good}) {
  return ReviewLog(
    id: id,
    wordId: wordId,
    grade: grade,
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

ChangeSet emptyChanges() => sm.EMPTY_CHANGES;

/* ------------------------------------------------------------------ */
/* Store harness (the syncRound half)                                  */
/* ------------------------------------------------------------------ */

/// A real store plus a hand-cranked clock, mirroring the TS `freshStore`.
class Harness {
  Harness({int start = T0}) : _now = start {
    store = Store(
      persistence: MemoryStore(emptyData()),
      clock: () => _now,
      saveDelayMs: 0,
    );
  }

  late final Store store;
  int _now;

  /// Move the injected clock forward; returns the new "now".
  int advance([int ms = 1000]) => _now += ms;

  AppData get data => store.data;

  /// The TS `store.getChangesToPush()`, which the Dart store does not expose.
  ChangeSet get changesToPush => sm.collectChanges(store.data);

  /// The TS `store.applyRound(round)`, expressed as merge-then-install.
  void applyRound(sm.SyncRound round) =>
      store.applyMerged(sm.applyRound(store.data, round));
}

Future<Harness> freshStore({int start = T0}) async {
  final harness = Harness(start: start);
  await harness.store.init();
  return harness;
}

Word wordRecord({String id = 'w_remote', String term = 'remote', int? updatedAt}) {
  return Word(
    id: id,
    term: term,
    definition: '',
    definition2: '',
    example: '',
    note: '',
    status: WordStatus.new_,
    favorite: false,
    listId: DEFAULT_LIST_ID,
    sourceLang: 'en',
    targetLang: 'zh-CN',
    listenCount: 0,
    srs: null,
    createdAt: T0,
    updatedAt: updatedAt ?? T0,
  );
}

void main() {
  /* ================================================================ */
  /* collectChanges                                                    */
  /* ================================================================ */

  group('collectChanges', () {
    test('returns nothing when nothing is pending', () {
      final changes = sm.collectChanges(data(words: [word('w1', 5)]));
      expect(sm.hasChanges(changes), isFalse);
      expect(sm.pendingCount(data()), 0);
    });

    test('includes pending words, lists, logs and settings', () {
      final d = data(
        words: [word('w1', 5)],
        lists: [list('l1', 6)],
        logs: [log('g1', 7)],
        settingsUpdatedAt: 8,
        pending: const PendingChanges(
          words: ['w1'],
          lists: ['l1'],
          logs: ['g1'],
          settings: true,
        ),
      );

      final changes = sm.collectChanges(d);

      expect(changes.words, hasLength(1));
      expect(changes.lists, hasLength(1));
      expect(changes.logs, hasLength(1));
      expect(changes.settings!.updatedAt, 8);
      expect(sm.pendingCount(d), 4);
    });

    test('turns a deleted word into a tombstone record', () {
      final d = data(
        tombstones: const Tombstones(words: {'w9': 42}),
        pending: const PendingChanges(words: ['w9']),
      );

      final changes = sm.collectChanges(d);

      expect(changes.words[0].toJson(), {'id': 'w9', 'updatedAt': 42, 'deleted': true});
      expect(changes.words[0], isA<WordTombstone>());
    });

    test('turns a deleted review log into a log tombstone', () {
      final d = data(
        tombstones: const Tombstones(logs: {'g9': 33}),
        pending: const PendingChanges(logs: ['g9']),
      );

      expect(sm.collectChanges(d).logs[0].toJson(), {'id': 'g9', 'at': 33, 'deleted': true});
    });

    test('skips ids that are pending but no longer exist', () {
      final d = data(pending: const PendingChanges(words: ['ghost']));
      expect(sm.collectChanges(d).words, isEmpty);
    });
  });

  /* ================================================================ */
  /* applyRemote — words                                               */
  /* ================================================================ */

  group('applyRemote words', () {
    test('adds a word the device has never seen', () {
      final next = sm.applyRemote(
        data(),
        const ChangeSet(words: [WordEdit(Word(
          id: 'w1',
          term: 'w1',
          definition: '',
          definition2: '',
          example: '',
          note: '',
          status: WordStatus.new_,
          favorite: false,
          listId: DEFAULT_LIST_ID,
          sourceLang: 'en',
          targetLang: 'zh-CN',
          listenCount: 0,
          srs: null,
          createdAt: 1000,
          updatedAt: 10,
        ))]),
      );

      expect(next.words.map((w) => w.id).toList(), ['w1']);
    });

    test('takes the newer remote copy (LWW)', () {
      final next = sm.applyRemote(
        data(words: [word('w1', 5, definition: 'old')]),
        ChangeSet(words: [WordEdit(word('w1', 9, definition: 'new'))]),
      );

      expect(next.words[0].definition, 'new');
    });

    test('ignores an older remote copy', () {
      final next = sm.applyRemote(
        data(words: [word('w1', 9, definition: 'mine')]),
        ChangeSet(words: [WordEdit(word('w1', 5, definition: 'theirs'))]),
      );

      expect(next.words[0].definition, 'mine');
    });

    test('keeps a pending local edit that is newer than the pushed echo', () {
      final local = data(
        words: [word('w1', 20, definition: 'edited during sync')],
        pending: const PendingChanges(words: ['w1']),
      );

      final next = sm.applyRemote(local, ChangeSet(words: [WordEdit(word('w1', 10))]));

      expect(next.words[0].definition, 'edited during sync');
      expect(next.pending.words, contains('w1'));
    });

    test('applies a remote tombstone', () {
      final next = sm.applyRemote(
        data(words: [word('w1', 5)]),
        const ChangeSet(words: [WordTombstone(id: 'w1', updatedAt: 9)]),
      );

      expect(next.words, isEmpty);
      expect(next.tombstones.words['w1'], 9);
    });

    test('keeps a local word that was deleted more recently than the remote edit', () {
      final local = data(tombstones: const Tombstones(words: {'w1': 30}));

      final next = sm.applyRemote(local, ChangeSet(words: [WordEdit(word('w1', 20))]));

      expect(next.words, isEmpty);
    });

    test('resurrects a word when the remote edit is newer than the local tombstone', () {
      final local = data(tombstones: const Tombstones(words: {'w1': 5}));

      final next = sm.applyRemote(local, ChangeSet(words: [WordEdit(word('w1', 40))]));

      expect(next.words.map((w) => w.id).toList(), ['w1']);
      expect(next.tombstones.words['w1'], isNull);
    });

    test('clears the pending flag once a record is settled', () {
      final local = data(
        words: [word('w1', 5)],
        pending: const PendingChanges(words: ['w1']),
      );

      final next = sm.applyRemote(local, ChangeSet(words: [WordEdit(word('w1', 5))]));

      expect(next.pending.words, isNot(contains('w1')));
    });
  });

  /* ================================================================ */
  /* applyRemote — lists                                               */
  /* ================================================================ */

  group('applyRemote lists', () {
    test('adds, updates and deletes lists', () {
      var next = sm.applyRemote(
        data(),
        ChangeSet(lists: [ListEdit(list('l1', 1, name: 'A'))]),
      );
      expect(next.lists[0].name, 'A');

      next = sm.applyRemote(
        next,
        ChangeSet(lists: [ListEdit(list('l1', 2, name: 'B'))]),
      );
      expect(next.lists[0].name, 'B');

      next = sm.applyRemote(
        next,
        const ChangeSet(lists: [ListTombstone(id: 'l1', updatedAt: 3)]),
      );
      expect(next.lists, isEmpty);
      expect(next.tombstones.lists['l1'], 3);
    });

    test('ignores a stale list edit', () {
      final next = sm.applyRemote(
        data(lists: [list('l1', 10, name: 'mine')]),
        ChangeSet(lists: [ListEdit(list('l1', 2, name: 'theirs'))]),
      );

      expect(next.lists[0].name, 'mine');
    });
  });

  /* ================================================================ */
  /* applyRemote — logs                                                */
  /* ================================================================ */

  group('applyRemote logs', () {
    test('unions review logs by id', () {
      final next = sm.applyRemote(
        data(logs: [log('g1', 1)]),
        ChangeSet(logs: [LogEntry(log('g1', 1)), LogEntry(log('g2', 2))]),
      );

      expect(next.logs.map((l) => l.id).toList()..sort(), ['g1', 'g2']);
    });

    test('applies a log tombstone', () {
      final next = sm.applyRemote(
        data(logs: [log('g1', 1), log('g2', 2)]),
        const ChangeSet(logs: [LogTombstone(id: 'g1', at: 5)]),
      );

      expect(next.logs.map((l) => l.id).toList(), ['g2']);
      expect(next.tombstones.logs['g1'], 5);
    });

    test('does not re-add a log that a tombstone removed', () {
      final local = data(tombstones: const Tombstones(logs: {'g1': 5}));

      final next = sm.applyRemote(local, ChangeSet(logs: [LogEntry(log('g1', 1))]));

      expect(next.logs, isEmpty);
    });

    test('keeps a pending log tombstone that is newer than the remote one', () {
      final local = data(
        tombstones: const Tombstones(logs: {'g1': 20}),
        pending: const PendingChanges(logs: ['g1']),
      );

      final next = sm.applyRemote(
        local,
        const ChangeSet(logs: [LogTombstone(id: 'g1', at: 5)]),
      );

      expect(next.pending.logs, contains('g1'));
    });
  });

  /* ================================================================ */
  /* applyRemote — settings                                            */
  /* ================================================================ */

  group('applyRemote settings', () {
    test('takes newer remote settings', () {
      final local = data(
        settings: const Settings(dailyGoal: 5),
        settingsUpdatedAt: 1,
      );

      final next = sm.applyRemote(
        local,
        const ChangeSet(
          settings: SettingsRecord(
            settings: Settings(dailyGoal: 99),
            updatedAt: 2,
          ),
        ),
      );

      expect(next.settings.dailyGoal, 99);
      expect(next.settingsUpdatedAt, 2);
    });

    test('keeps newer local settings', () {
      final local = data(
        settings: const Settings(dailyGoal: 42),
        settingsUpdatedAt: 10,
      );

      final next = sm.applyRemote(
        local,
        const ChangeSet(
          settings: SettingsRecord(
            settings: Settings(dailyGoal: 1),
            updatedAt: 2,
          ),
        ),
      );

      expect(next.settings.dailyGoal, 42);
      expect(next.settingsUpdatedAt, 10);
    });

    test('replaces the whole settings record (settings sync as one unit)', () {
      final local = data(
        settings: const Settings(uiLang: UiLang.en),
        settingsUpdatedAt: 1,
      );

      final next = sm.applyRemote(
        local,
        const ChangeSet(
          settings: SettingsRecord(
            settings: Settings(dailyGoal: 33),
            updatedAt: 2,
          ),
        ),
      );

      expect(next.settings.dailyGoal, 33);
      // The remote record is the newer full snapshot, so its values win
      // wholesale — including the fields it never meant to change.
      expect(next.settings.uiLang, UiLang.zhCN);
    });
  });

  /* ================================================================ */
  /* Immutability                                                      */
  /* ================================================================ */

  group('applyRemote immutability', () {
    test('does not mutate the input snapshot', () {
      final local = data(words: [word('w1', 5)]);
      // `toJson` allocates fresh maps, so encoding here is the deep copy the TS
      // took with `JSON.parse(JSON.stringify(local))`.
      final snapshot = jsonEncode(local.toJson());

      sm.applyRemote(
        local,
        ChangeSet(words: [WordEdit(word('w1', 99)), WordEdit(word('w2', 99))]),
      );

      expect(jsonEncode(local.toJson()), snapshot);
    });
  });

  /* ================================================================ */
  /* applyRound — the half we sent                                     */
  /* ================================================================ */

  group('applyRound settles the half we sent', () {
    test('clears every pending flag for the versions the round sent', () async {
      final h = await freshStore();
      final deck = h.store.createList(name: 'Deck', sourceLang: 'en', targetLang: 'zh-CN');
      final w = h.store.addWord(NewWordInput(term: 'a', listId: deck.id));
      h.advance();
      h.store.gradeWord(w.id, Grade.good);
      h.advance();
      h.store.updateSettings((s) => s.copyWith(dailyGoal: 7));

      expect(sm.pendingCount(h.data), greaterThan(0));

      h.applyRound(sm.SyncRound(sent: h.changesToPush, received: sm.EMPTY_CHANGES));

      expect(sm.pendingCount(h.data), 0);
      expect(h.changesToPush.isEmpty, isTrue);
    });

    test('settles nothing when the round sent nothing', () async {
      final h = await freshStore();
      final w = h.store.addWord(const NewWordInput(term: 'a', listId: DEFAULT_LIST_ID));

      // A round that pushed nothing has no versions to settle; a naive "clear
      // everything" would silently drop this edit.
      h.applyRound(const sm.SyncRound(sent: sm.EMPTY_CHANGES, received: sm.EMPTY_CHANGES));

      expect(h.data.pending.words, contains(w.id));
    });

    test('keeps a record pending when it was edited after the push was built', () async {
      final h = await freshStore();
      final w = h.store.addWord(const NewWordInput(term: 'before', listId: DEFAULT_LIST_ID));
      h.advance();
      final sent = h.changesToPush;

      h.advance();
      h.store.updateWord(w.id, (cur) => cur.copyWith(term: 'after'));
      h.applyRound(sm.SyncRound(sent: sent, received: sm.EMPTY_CHANGES));

      // The guard must compare against the version that was actually pushed.
      // Clearing merely because the id is in `sent` would drop the newer edit.
      expect(h.data.pending.words, contains(w.id));
      final local = h.data.words.firstWhere((x) => x.id == w.id);
      expect(local.term, 'after');
      expect(local.updatedAt, greaterThan(sent.words[0].updatedAt));
    });

    test('does not settle an edit the round never sent', () async {
      final h = await freshStore();
      h.store.addWord(const NewWordInput(term: 'already pending', listId: DEFAULT_LIST_ID));
      final sent = h.changesToPush;

      h.advance();
      final fresh =
          h.store.addWord(const NewWordInput(term: 'added mid-flight', listId: DEFAULT_LIST_ID));
      h.applyRound(sm.SyncRound(sent: sent, received: sm.EMPTY_CHANGES));

      expect(h.data.pending.words, [fresh.id]);
    });

    test('keeps a settings edit that landed after the push was built', () async {
      final h = await freshStore();
      h.store.updateSettings((s) => s.copyWith(dailyGoal: 5));
      h.advance();
      final sent = h.changesToPush;

      h.advance();
      h.store.updateSettings((s) => s.copyWith(dailyGoal: 9));
      h.applyRound(sm.SyncRound(sent: sent, received: sm.EMPTY_CHANGES));

      expect(h.data.settings.dailyGoal, 9);
      expect(h.data.pending.settings, isTrue);
    });
  });

  /* ================================================================ */
  /* applyRound — the half the server sent                             */
  /* ================================================================ */

  group('applyRound merges the half the server sent', () {
    test('merges a remote record into the same snapshot', () async {
      final h = await freshStore();

      h.applyRound(sm.SyncRound(
        sent: sm.EMPTY_CHANGES,
        received: ChangeSet(words: [WordEdit(wordRecord())]),
      ));

      expect(h.data.words.map((w) => w.id).toList(), ['w_remote']);
      expect(h.data.pending.words, isEmpty);
    });

    test('applies a remote tombstone and drops the local record', () async {
      final h = await freshStore();
      final w = h.store.addWord(const NewWordInput(term: 'a', listId: DEFAULT_LIST_ID));
      h.applyRound(sm.SyncRound(sent: h.changesToPush, received: sm.EMPTY_CHANGES));

      h.advance();
      h.applyRound(sm.SyncRound(
        sent: sm.EMPTY_CHANGES,
        received: ChangeSet(words: [WordTombstone(id: w.id, updatedAt: T0 + 5000)]),
      ));

      expect(h.data.words, isEmpty);
      expect(h.data.tombstones.words[w.id], T0 + 5000);
    });

    test("keeps a local edit that is newer than the server's copy", () async {
      final h = await freshStore();
      final w = h.store.addWord(const NewWordInput(term: 'local', listId: DEFAULT_LIST_ID));
      h.advance();
      h.store.updateWord(w.id, (cur) => cur.copyWith(term: 'newer'));

      h.applyRound(sm.SyncRound(
        sent: sm.EMPTY_CHANGES,
        received: ChangeSet(words: [
          WordEdit(wordRecord(id: w.id, term: 'older', updatedAt: T0 + 500)),
        ]),
      ));

      expect(h.data.words[0].term, 'newer');
      expect(h.data.pending.words, contains(w.id));
    });

    test('keeps a mid-flight edit when the server echoes the version we pushed', () async {
      final h = await freshStore();
      final w = h.store.addWord(const NewWordInput(term: 'before', listId: DEFAULT_LIST_ID));
      h.advance();
      final sent = h.changesToPush;

      h.advance();
      h.store.updateWord(w.id, (cur) => cur.copyWith(term: 'after'));
      // The server answers with exactly what we pushed — the stale echo must not
      // win over the edit that landed while the request was in flight.
      h.applyRound(sm.SyncRound(sent: sent, received: sent));

      expect(h.data.words[0].term, 'after');
      expect(h.data.pending.words, contains(w.id));
    });

    test('stops protecting a record once this round settled its push', () async {
      // Protocol rule: only a record that has NOT been pushed may outrank an
      // incoming record by updatedAt. The tombstone below is older than the
      // local copy, yet it wins — and it only wins because settle ran first.
      // This is the one place the round's order is observable, so it is what
      // would fail if the halves were swapped.
      final h = await freshStore();
      final w = h.store.addWord(const NewWordInput(term: 'a', listId: DEFAULT_LIST_ID));
      h.advance();
      h.store.updateWord(w.id, (cur) => cur.copyWith(term: 'newer'));
      final sent = h.changesToPush;

      h.applyRound(sm.SyncRound(
        sent: sent,
        received: ChangeSet(words: [WordTombstone(id: w.id, updatedAt: T0 + 500)]),
      ));

      expect(h.data.words, isEmpty);
      expect(h.data.tombstones.words[w.id], T0 + 500);
    });

    test('does not duplicate a record the server echoes back', () async {
      final h = await freshStore();
      h.store.addWord(const NewWordInput(term: 'a', listId: DEFAULT_LIST_ID));
      final sent = h.changesToPush;

      h.applyRound(sm.SyncRound(sent: sent, received: sent));

      expect(h.data.words, hasLength(1));
      expect(h.data.words[0].updatedAt, sent.words[0].updatedAt);
      expect(sm.pendingCount(h.data), 0);
    });
  });

  /* ================================================================ */
  /* A round is not a local edit                                       */
  /* ================================================================ */

  group('applyRound is not a local edit', () {
    test('does not emit a local change for the round it applies', () async {
      final h = await freshStore();
      final w = h.store.addWord(const NewWordInput(term: 'a', listId: DEFAULT_LIST_ID));
      final sent = h.changesToPush;
      final stampBefore = h.data.words[0].updatedAt;

      h.applyRound(sm.SyncRound(sent: sent, received: sent));

      // A pushing round must not echo: re-marking the records pending here is
      // what scheduled a wasted extra sync round after every push. There is no
      // local-change bus in this tree, so the observable form of "did not emit"
      // is "left nothing pending and bumped no version".
      expect(h.data.pending.words, isEmpty);
      expect(h.data.words[0].updatedAt, stampBefore);

      // Control: a real local edit does mark the record, so the assertion above
      // is not passing merely because nothing is ever marked.
      h.store.updateWord(w.id, (cur) => cur.copyWith(term: 'edited'));
      expect(h.data.pending.words, contains(w.id));
    });
  });

  /* ================================================================ */
  /* Snapshot immutability across a round                              */
  /* ================================================================ */

  group('applyRound keeps snapshots immutable', () {
    test('does not mutate the snapshot that was current before the round', () async {
      final h = await freshStore();
      final w = h.store.addWord(const NewWordInput(term: 'a', listId: DEFAULT_LIST_ID));
      final before = h.data;

      h.applyRound(sm.SyncRound(sent: h.changesToPush, received: sm.EMPTY_CHANGES));

      // `settle` returns a new snapshot, so the one a listener (or React) may
      // still be rendering keeps its pending flag.
      expect(before.pending.words, contains(w.id));
      expect(h.data.pending.words, isEmpty);
      expect(identical(h.data, before), isFalse);
    });
  });
}
