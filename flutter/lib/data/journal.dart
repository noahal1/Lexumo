/// The change journal — the single owner of `pending` and `tombstones`.
///
/// Ported from `src/lib/journal.ts`. Two invariants govern sync, and neither can
/// be expressed by remembering to call `markWordDirty` at the right moment:
///
///   1. every local edit must be recorded as pending, otherwise another device
///      will never learn about it;
///   2. every local delete must leave a tombstone, otherwise another device
///      will simply upload the record again.
///
/// Before the TS module existed both rules were re-applied by hand in thirteen
/// mutation bodies (21 calls), and one had already been forgotten: `deleteList`
/// removed a list's words without removing their review logs, so deleted
/// reviews kept inflating the streak and were pushed forever. Bookkeeping that
/// lives here cannot be forgotten by a new domain operation.
///
/// The Dart port is a set of pure `AppData -> AppData` functions rather than
/// mutating a draft, because [AppData] is immutable. The guarantees are the
/// same; the call sites read `d = journal.touch(d, 'word', id)`.
library;

import '../domain/types.dart';

enum RecordKind { word, list, log }

/// Record that a record was created or edited locally.
AppData touch(AppData d, RecordKind kind, String id) {
  return switch (kind) {
    RecordKind.word => d.copyWith(
        pending: PendingChanges(
          words: _pushOnce(d.pending.words, id),
          lists: d.pending.lists,
          logs: d.pending.logs,
          settings: d.pending.settings,
        ),
      ),
    RecordKind.list => d.copyWith(
        pending: PendingChanges(
          words: d.pending.words,
          lists: _pushOnce(d.pending.lists, id),
          logs: d.pending.logs,
          settings: d.pending.settings,
        ),
      ),
    RecordKind.log => d.copyWith(
        pending: PendingChanges(
          words: d.pending.words,
          lists: d.pending.lists,
          logs: _pushOnce(d.pending.logs, id),
          settings: d.pending.settings,
        ),
      ),
  };
}

List<String> _pushOnce(List<String> bucket, String id) {
  if (bucket.contains(id)) return bucket;
  return [...bucket, id];
}

/// Record that a record was deleted locally at [at].
///
/// Absence cannot express a delete: the other device would just re-upload the
/// record. The tombstone is what makes the removal travel.
AppData bury(AppData d, RecordKind kind, String id, int at) {
  final t = d.tombstones;
  final next = switch (kind) {
    RecordKind.word => Tombstones(
        words: {...t.words, id: at},
        lists: t.lists,
        logs: t.logs,
      ),
    RecordKind.list => Tombstones(
        words: t.words,
        lists: {...t.lists, id: at},
        logs: t.logs,
      ),
    RecordKind.log => Tombstones(
        words: t.words,
        lists: t.lists,
        logs: {...t.logs, id: at},
      ),
  };
  return touch(d.copyWith(tombstones: next), kind, id);
}

/// Record a settings edit, which is versioned as a whole rather than by id.
AppData touchSettings(AppData d, int at) {
  return d.copyWith(
    settingsUpdatedAt: at,
    pending: PendingChanges(
      words: d.pending.words,
      lists: d.pending.lists,
      logs: d.pending.logs,
      settings: true,
    ),
  );
}

/// Remove a set of words and everything hanging off them — their review logs —
/// in one declaration.
///
/// Every caller that deletes words goes through here (single delete, bulk
/// delete, and list delete), which is what stops the cascade from drifting
/// between them.
AppData purgeWords(AppData d, Iterable<String> ids, int at) {
  final doomed = ids.toSet();
  if (doomed.isEmpty) return d;

  final doomedLogs = d.logs
      .where((l) => doomed.contains(l.wordId))
      .map((l) => l.id)
      .toList();

  var next = d.copyWith(
    words: d.words.where((w) => !doomed.contains(w.id)).toList(),
    logs: d.logs.where((l) => !doomed.contains(l.wordId)).toList(),
  );
  for (final id in doomed) {
    next = bury(next, RecordKind.word, id, at);
  }
  for (final id in doomedLogs) {
    next = bury(next, RecordKind.log, id, at);
  }
  return next;
}

/// Drop the pending flags for records the server accepted.
///
/// A record only settles when the local copy is still the exact version that
/// was pushed. If the user edited it while the request was in flight, the newer
/// version must stay pending so the next round uploads it — settling it here
/// would silently lose the edit.
AppData settle(AppData d, PushedChanges pushed) {
  int wordStamp(String id) => d.words
          .where((w) => w.id == id)
          .map((w) => w.updatedAt)
          .firstOrNull ??
      d.tombstones.words[id] ??
      0;
  int listStamp(String id) => d.lists
          .where((l) => l.id == id)
          .map((l) => l.updatedAt)
          .firstOrNull ??
      d.tombstones.lists[id] ??
      0;
  int logStamp(String id) => d.logs
          .where((l) => l.id == id)
          .map((l) => l.at)
          .firstOrNull ??
      d.tombstones.logs[id] ??
      0;

  final settledWords = pushed.words
      .where((r) => wordStamp(r.id) == r.updatedAt)
      .map((r) => r.id)
      .toSet();
  final settledLists = pushed.lists
      .where((r) => listStamp(r.id) == r.updatedAt)
      .map((r) => r.id)
      .toSet();
  final settledLogs =
      pushed.logs.where((r) => logStamp(r.id) == r.at).map((r) => r.id).toSet();

  var next = d.copyWith(
    pending: PendingChanges(
      words: d.pending.words.where((id) => !settledWords.contains(id)).toList(),
      lists: d.pending.lists.where((id) => !settledLists.contains(id)).toList(),
      logs: d.pending.logs.where((id) => !settledLogs.contains(id)).toList(),
      settings: d.pending.settings &&
          !(pushed.settings != null &&
              d.settingsUpdatedAt == pushed.settings!.updatedAt),
    ),
  );
  return next;
}

/// How many records are still waiting to be pushed (drives the UI badge).
int pendingTotal(AppData d) =>
    d.pending.words.length +
    d.pending.lists.length +
    d.pending.logs.length +
    (d.pending.settings ? 1 : 0);

/// The three record shapes the wire format carries. Declared here (and in
/// `data/wire.dart` for parsing) because [settle] needs only the stamps.
class StampedRecord {
  const StampedRecord({required this.id, required this.updatedAt});
  final String id;
  final int updatedAt;
}

class StampedLog {
  const StampedLog({required this.id, required this.at});
  final String id;
  final int at;
}

class SettingsStamp {
  const SettingsStamp(this.updatedAt);
  final int updatedAt;
}

/// The subset of a push round that [settle] needs: ids and their stamps.
class PushedChanges {
  const PushedChanges({
    this.words = const [],
    this.lists = const [],
    this.logs = const [],
    this.settings,
  });

  final List<StampedRecord> words;
  final List<StampedRecord> lists;
  final List<StampedLog> logs;
  final SettingsStamp? settings;
}
