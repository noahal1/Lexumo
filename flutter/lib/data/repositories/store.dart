// The private fields below cannot be initializing formals: a named parameter
// may not start with an underscore, which is the whole point of the field.
// ignore_for_file: prefer_initializing_formals
/// Application store: one observable snapshot plus the domain operations —
/// words, lists, reviews, settings.
///
/// Ported from `src/lib/store.ts`. The shape survives the port:
///
///   * [Store] is built from a [Persistence] adapter and a clock, so a test can
///     drive real mutations instead of hand-assembling snapshots.
///   * every write goes through [_commit]: let the operation produce the next
///     snapshot, then publish it and schedule persistence. The web build cloned
///     and mutated a draft; here the operations return a new [AppData] instead,
///     which is the same thing with the mutation made explicit — records are
///     immutable, so the old snapshot a listener still holds cannot be corrupted.
///   * sync bookkeeping (`pending` + `tombstones`) is written only by
///     `journal.dart`, so a new operation cannot forget to mark its change.
///
/// The React half of the original (`useSyncExternalStore`, `useAppData`) has no
/// Dart equivalent; [Store.addListener] plus a `ChangeNotifier` adapter in
/// `app/` replaces it.
library;

import 'dart:async';

import '../../domain/models/srs.dart' as srs;
import '../../domain/models/types.dart';
import '../../domain/models/utils.dart' show normalizeTerm, uid;
import '../models/journal.dart' as journal;
import '../models/journal.dart' show RecordKind;
import '../services/snapshot_store.dart';

/// A snapshot with nothing in it — the state before [Store.init] finishes.
AppData emptyData() => AppData(
      version: DATA_VERSION,
      lists: const [],
      words: const [],
      logs: const [],
      settings: const Settings(),
      settingsUpdatedAt: 0,
      tombstones: const Tombstones(),
      pending: const PendingChanges(),
    );

/// Give [d] a default list when it has none, so the app is never listless.
///
/// Reached on first run and after a wipe. The id is the fixed [DEFAULT_LIST_ID]
/// rather than a fresh `uid` because sync treats that id as the identity of "the
/// built-in list"; minting a new one each wipe would orphan every tombstone.
AppData withDefaultList(AppData d, int now) => d.copyWith(
      lists: [
        WordList(
          id: DEFAULT_LIST_ID,
          name: '我的词库',
          sourceLang: 'en',
          targetLang: 'zh-CN',
          createdAt: now,
          updatedAt: now,
        ),
      ],
    );

/// What [Store.addWord] takes. Mirrors `NewWordInput`; the optional fields follow
/// the same trim-and-default rules the web form applied.
class NewWordInput {
  const NewWordInput({
    required this.term,
    this.phonetic,
    this.pos,
    this.definition,
    this.definition2,
    this.example,
    this.exampleZh,
    this.note,
    required this.listId,
    this.status,
    this.favorite,
  });

  final String term;
  final String? phonetic;

  /// Part-of-speech tags, space separated (`adj.` / `n. v.`).
  final String? pos;
  final String? definition;
  final String? definition2;
  final String? example;

  /// Translation of [example]; same optionality as [phonetic].
  final String? exampleZh;
  final String? note;
  final String listId;
  final WordStatus? status;
  final bool? favorite;
}

/// The outcome of one grade, including the log id needed to undo it.
class GradeResult {
  const GradeResult({required this.srs, required this.status, required this.logId});
  final SrsState srs;
  final WordStatus status;

  /// Id of the review log entry this grade appended, so it can be undone.
  final String logId;
}

int _systemClock() => DateTime.now().millisecondsSinceEpoch;

/// Fold a patch into the word with [id], returning the new snapshot. A missing id
/// leaves the snapshot untouched, which is what every caller wants.
AppData _replaceWord(AppData d, String id, Word Function(Word current) patch) {
  final at = d.words.indexWhere((w) => w.id == id);
  if (at < 0) return d;
  final words = List<Word>.of(d.words);
  words[at] = patch(words[at]);
  return d.copyWith(words: words);
}

/// The store. One instance lives in the app (see the singleton at the bottom);
/// tests build their own with [MemoryStore] and a frozen clock.
class Store {
  Store({
    required Persistence persistence,
    int Function()? clock,
    AppData Function(int now)? seed,
    this.saveDelayMs = 220,
  })  : _persistence = persistence,
        _clock = clock ?? _systemClock,
        _seed = seed;

  final Persistence _persistence;
  final int Function() _clock;
  final AppData Function(int now)? _seed;

  /// Persistence debounce in ms. `0` saves immediately (tests).
  final int saveDelayMs;

  AppData _data = emptyData();
  bool _ready = false;
  Timer? _saveTimer;
  final Set<void Function()> _listeners = <void Function()>{};

  /* ---------------------------------------------------------------- */
  /* Lifecycle                                                         */
  /* ---------------------------------------------------------------- */

  /// Load the snapshot once at boot; first run seeds the demo deck.
  Future<void> init() async {
    final loaded = await _persistence.load();
    // A `recovered` load is still a good snapshot — the adapter already fell
    // back to the sidecar, and the UI surfaces the notice separately.
    final snapshot = loaded.data;
    _data = snapshot ?? _seed?.call(_clock()) ?? emptyData();
    if (_data.lists.isEmpty) _data = withDefaultList(_data, _clock());
    _ready = true;
    _notify();
    _scheduleSave();
  }

  bool get isReady => _ready;

  /// The current snapshot. Identical object until the next write, so a widget can
  /// compare by identity to decide whether to rebuild.
  AppData get data => _data;

  /// Subscribe to snapshot changes. Call the returned closure to unsubscribe.
  void Function() addListener(void Function() listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void _notify() {
    // Copied first: a listener that mutates the store during notification would
    // otherwise throw a concurrent-modification error.
    for (final fn in List<void Function()>.of(_listeners)) {
      fn();
    }
  }

  void _scheduleSave() {
    if (saveDelayMs <= 0) {
      unawaited(_persistence.save(_data));
      return;
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(Duration(milliseconds: saveDelayMs), () {
      _saveTimer = null;
      unawaited(_persistence.save(_data));
    });
  }

  /// Flush a pending debounced save. Called on window close and by tests.
  Future<void> flush() async {
    if (_saveTimer != null) {
      _saveTimer!.cancel();
      _saveTimer = null;
    }
    await _persistence.save(_data);
  }

  /// Publish the result of [mutator] and schedule persistence.
  void _commit(AppData Function(AppData d) mutator) {
    final next = mutator(_data);
    if (identical(next, _data)) return;
    _data = next;
    _notify();
    _scheduleSave();
  }

  /* ---------------------------------------------------------------- */
  /* Lists                                                             */
  /* ---------------------------------------------------------------- */

  WordList createList({
    required String name,
    required String sourceLang,
    required String targetLang,
  }) {
    final now = _clock();
    final trimmed = name.trim();
    final list = WordList(
      id: uid('list'),
      name: trimmed.isEmpty ? '未命名词库' : trimmed,
      sourceLang: sourceLang,
      targetLang: targetLang,
      createdAt: now,
      updatedAt: now,
    );
    _commit((d) => journal.touch(
          d.copyWith(lists: [...d.lists, list]),
          RecordKind.list,
          list.id,
        ));
    return list;
  }

  void renameList(String id, String name) {
    _commit((d) {
      final list = d.lists.where((l) => l.id == id).firstOrNull;
      if (list == null) return d;
      final trimmed = name.trim();
      final lists = List<WordList>.of(d.lists);
      lists[lists.indexWhere((l) => l.id == id)] = list.copyWith(
        name: trimmed.isEmpty ? list.name : trimmed,
        updatedAt: _clock(),
      );
      return journal.touch(d.copyWith(lists: lists), RecordKind.list, id);
    });
  }

  void deleteList(String id) {
    final now = _clock();
    _commit((d) {
      final doomed = d.words.where((w) => w.listId == id).map((w) => w.id).toList();
      final stripped = d.copyWith(lists: d.lists.where((l) => l.id != id).toList());
      // One cascade for words *and* their review logs — the same declaration
      // every other delete uses.
      return journal.bury(journal.purgeWords(stripped, doomed, now), RecordKind.list, id, now);
    });
  }

  /* ---------------------------------------------------------------- */
  /* Words                                                             */
  /* ---------------------------------------------------------------- */

  Word addWord(NewWordInput input) {
    final list = _data.lists.where((l) => l.id == input.listId).firstOrNull ??
        (_data.lists.isEmpty ? null : _data.lists[0]);
    final now = _clock();
    String trimOrEmpty(String? s) => (s ?? '').trim();
    String? trimOrNull(String? s) {
      final t = trimOrEmpty(s);
      return t.isEmpty ? null : t;
    }

    final word = Word(
      id: uid('w'),
      term: input.term.trim(),
      phonetic: trimOrEmpty(input.phonetic),
      pos: trimOrNull(input.pos),
      definition: trimOrEmpty(input.definition),
      definition2: trimOrEmpty(input.definition2),
      example: trimOrEmpty(input.example),
      exampleZh: trimOrNull(input.exampleZh),
      note: trimOrEmpty(input.note),
      status: input.status ?? WordStatus.new_,
      favorite: input.favorite ?? false,
      listId: list?.id ?? DEFAULT_LIST_ID,
      sourceLang: list?.sourceLang ?? 'en',
      targetLang: list?.targetLang ?? 'zh-CN',
      listenCount: 0,
      srs: null,
      createdAt: now,
      updatedAt: now,
    );
    _commit((d) => journal.touch(
          d.copyWith(words: [word, ...d.words]),
          RecordKind.word,
          word.id,
        ));
    return word;
  }

  /// Apply [patch] to a word. The caller supplies a pure `Word -> Word` step so
  /// no operation can mutate a record a listener is still holding.
  void updateWord(String id, Word Function(Word current) patch) {
    _commit((d) {
      final changed = _replaceWord(d, id, (w) => patch(w).copyWith(updatedAt: _clock()));
      if (identical(changed, d)) return d;
      return journal.touch(changed, RecordKind.word, id);
    });
  }

  void deleteWord(String id) {
    final now = _clock();
    _commit((d) => journal.purgeWords(d, [id], now));
  }

  void deleteWords(Iterable<String> ids) {
    final now = _clock();
    _commit((d) => journal.purgeWords(d, ids, now));
  }

  /// Undo a delete: put the word back together with the review logs it lost.
  void restoreWord(Word word, [List<ReviewLog> logs = const []]) {
    final now = _clock();
    _commit((d) {
      // Already back (double-tapped undo, or the word was re-added by hand).
      if (d.words.any((w) => w.id == word.id)) return d;
      // Undo has to un-bury what the delete buried, or the next sync round would
      // push a tombstone for a word the user can see in the list.
      var next = d.copyWith(
        words: [word.copyWith(updatedAt: now), ...d.words],
        tombstones: Tombstones(
          words: Map<String, int>.of(d.tombstones.words)..remove(word.id),
          lists: d.tombstones.lists,
          logs: d.tombstones.logs,
        ),
      );
      next = journal.touch(next, RecordKind.word, word.id);
      for (final log in logs) {
        if (next.logs.any((l) => l.id == log.id)) continue;
        next = journal.touch(
          next.copyWith(
            logs: [...next.logs, log],
            tombstones: Tombstones(
              words: next.tombstones.words,
              lists: next.tombstones.lists,
              logs: Map<String, int>.of(next.tombstones.logs)..remove(log.id),
            ),
          ),
          RecordKind.log,
          log.id,
        );
      }
      return next;
    });
  }

  void toggleFavorite(String id) {
    _commit((d) {
      final w = d.words.where((x) => x.id == id).firstOrNull;
      if (w == null) return d;
      return journal.touch(
        _replaceWord(d, id, (cur) => cur.copyWith(favorite: !w.favorite, updatedAt: _clock())),
        RecordKind.word,
        id,
      );
    });
  }

  void bumpListen(String id) {
    _commit((d) {
      if (!d.words.any((x) => x.id == id)) return d;
      return journal.touch(
        _replaceWord(
          d,
          id,
          (cur) => cur.copyWith(listenCount: cur.listenCount + 1, updatedAt: _clock()),
        ),
        RecordKind.word,
        id,
      );
    });
  }

  /* ---------------------------------------------------------------- */
  /* Reviewing                                                         */
  /* ---------------------------------------------------------------- */

  GradeResult? gradeWord(String id, Grade grade, [int? now]) {
    final at = now ?? _clock();
    final word = _data.words.where((w) => w.id == id).firstOrNull;
    if (word == null) return null;
    // The whole decision (schedule, never-demote, log contents) is srs.dart's;
    // this wrapper only persists it.
    final result = srs.reviewCard(
      srs.CardState(srs: word.srs, status: word.status),
      grade,
      at,
      wordId: id,
      logId: uid('r'),
    );
    final changed = _replaceWord(
      _data,
      id,
      (cur) => cur.copyWith(srs: result.srs, status: result.status, updatedAt: at),
    );
    if (identical(changed, _data)) return null;
    _commit((d) => journal.touch(
          journal.touch(
            changed.copyWith(logs: [...changed.logs, result.log]),
            RecordKind.word,
            id,
          ),
          RecordKind.log,
          result.log.id,
        ));
    // `status` is the promoted status that was stored, not the raw interval
    // status — callers see the same value the snapshot now holds.
    return GradeResult(srs: result.srs, status: result.status, logId: result.log.id);
  }

  /// Roll back a single grade: restore the schedule the word had before, put the
  /// status back exactly as it was (including the never-demote behaviour, which a
  /// plain recompute would get wrong) and drop the log.
  void undoReview(
    String id,
    SrsState? prevSrs,
    WordStatus prevStatus,
    String logId, [
    int? now,
  ]) {
    final at = now ?? _clock();
    final restored = srs.undoGrade(srs.CardState(srs: prevSrs, status: prevStatus), logId);
    _commit((d) {
      final changed = _replaceWord(
        d,
        id,
        // `clearSrs` must follow the snapshot being restored, not be forced on:
        // `copyWith` gives it precedence over `srs`, so a hard `true` would
        // throw away the schedule this call just restored and leave a card that
        // already had one with `srs == null`. Only a word that was genuinely
        // unscheduled before the grade (`restored.srs == null`) needs the clear,
        // because `copyWith(srs: null)` alone would keep the current value.
        (cur) => cur.copyWith(
          srs: restored.srs,
          clearSrs: restored.srs == null,
          status: restored.status,
          updatedAt: at,
        ),
      );
      if (identical(changed, d)) return d;
      final withoutLog = changed.copyWith(
        logs: changed.logs.where((log) => log.id != restored.removedLogId).toList(),
      );
      return journal.bury(
        journal.touch(withoutLog, RecordKind.word, id),
        RecordKind.log,
        restored.removedLogId,
        at,
      );
    });
  }

  void setWordStatus(String id, WordStatus status) {
    _commit((d) {
      final changed = _replaceWord(d, id, (cur) => cur.copyWith(status: status, updatedAt: _clock()));
      if (identical(changed, d)) return d;
      return journal.touch(changed, RecordKind.word, id);
    });
  }

  /// Manually reset a card's schedule back to "new".
  void resetSrs(String id) {
    _commit((d) {
      final changed = _replaceWord(
        d,
        id,
        (cur) => cur.copyWith(
          srs: null,
          clearSrs: true,
          status: WordStatus.new_,
          updatedAt: _clock(),
        ),
      );
      if (identical(changed, d)) return d;
      return journal.touch(changed, RecordKind.word, id);
    });
  }

  /* ---------------------------------------------------------------- */
  /* Settings & data                                                   */
  /* ---------------------------------------------------------------- */

  void updateSettings(Settings Function(Settings current) patch) {
    _commit((d) => journal.touchSettings(d.copyWith(settings: patch(d.settings)), _clock()));
  }

  Future<void> wipeAll() async {
    await _persistence.clear();
    final now = _clock();
    // A wipe has to travel like any other delete. Dropping the records silently
    // would leave no tombstones, so the next sign-in would pull the whole library
    // straight back from the server. Every id that goes away is therefore buried
    // in the fresh snapshot.
    var wiped = withDefaultList(emptyData(), now);
    for (final word in _data.words) {
      wiped = journal.bury(wiped, RecordKind.word, word.id, now);
    }
    for (final log in _data.logs) {
      wiped = journal.bury(wiped, RecordKind.log, log.id, now);
    }
    for (final list in _data.lists) {
      if (list.id != DEFAULT_LIST_ID) {
        wiped = journal.bury(wiped, RecordKind.list, list.id, now);
      }
    }
    // The fresh snapshot recreates the default list under this same fixed id, so
    // that id is not deleted — a tombstone would tell the server to drop the list
    // we just made, and the echoed delete would remove it locally too. It is
    // pushed as an edit instead, which also resets the name.
    wiped = journal.touch(wiped, RecordKind.list, DEFAULT_LIST_ID);
    _data = wiped;
    _notify();
    _scheduleSave();
  }

  /* ---------------------------------------------------------------- */
  /* Sync bridge (the round itself lives in `data/sync.dart`)           */
  /* ---------------------------------------------------------------- */

  /// How many records still need pushing. Surfaced by the sidebar badge.
  int pendingChangeCount() => journal.pendingTotal(_data);

  /// Install an already-merged snapshot. The settle-then-merge order belongs to
  /// `sync_merge.dart`; this is the write half.
  void applyMerged(AppData merged) {
    // Deliberately not a user edit: a round is the server talking, so it must not
    // re-mark anything pending — that would schedule another round every push.
    _data = merged;
    _notify();
    _scheduleSave();
  }
}

/* ------------------------------------------------------------------ */
/* Selectors (pure: take the snapshot, return a projection)            */
/* ------------------------------------------------------------------ */

/// Cards the flashcard page should show: everything learned-but-not-mastered that
/// has come due, plus every card that was never scheduled at all.
List<Word> dueWords(AppData d, [int? now]) {
  final at = now ?? _systemClock();
  return d.words.where((w) {
    if (w.status == WordStatus.mastered) return false;
    final s = w.srs;
    if (s == null) return true;
    return s.dueAt <= at;
  }).toList();
}

/// A word whose term already exists, for the duplicate guard on the edit form.
Word? findDuplicate(AppData d, String term, [String? listId]) {
  final key = normalizeTerm(term);
  for (final w in d.words) {
    if (normalizeTerm(w.term) != key) continue;
    if (listId != null && w.listId != listId) continue;
    return w;
  }
  return null;
}
