/// Pure helpers that translate between the local [AppData] snapshot and the
/// domain [ChangeSet] that is merged into it.
///
/// Ported from `src/lib/syncMerge.ts` (262 lines). No I/O here — everything is
/// a function of its inputs, which keeps the merge rules unit-testable.
///
/// The wire format lives in `data/wire.dart`: records reach these functions
/// already decoded (no `_rev`, no unknown keys), which is what lets the merge
/// rules be stated purely in terms of the domain types.
///
/// Conflict rules (mirrors docs/sync-protocol.md):
///
///   · words / lists / settings — last-write-wins on `updatedAt`;
///   · review logs — append-only, deduplicated by `id`, deletions propagate as
///     tombstones;
///   · a local record that is still pending **and** newer than the server copy
///     wins, and stays pending so the next round uploads it.
///
/// The Dart port differs from the TS in shape only: [AppData] is immutable, so
/// where the TS cloned a draft and mutated it, these functions build a new
/// snapshot. The rules themselves are transcribed line for line, including the
/// TS's truthiness checks on tombstone stamps (see [collectChanges]).
library;

import '../../domain/models/types.dart';
import 'journal.dart' as journal;
import 'wire.dart';

/// Nothing to send and nothing to merge — also what an idle round transmits.
const ChangeSet EMPTY_CHANGES = ChangeSet.empty;

/// The two halves of one sync round: what we pushed, what the server answered.
class SyncRound {
  const SyncRound({required this.sent, required this.received});

  final ChangeSet sent;
  final ChangeSet received;

  /// A round that pushed and received nothing.
  static const SyncRound idle = SyncRound(sent: ChangeSet.empty, received: ChangeSet.empty);
}

/// Build the outbound change set from everything currently marked pending.
///
/// An id that is pending *and* has a tombstone travels as the tombstone: the
/// record itself is already gone from the snapshot, and absence cannot express
/// a delete — the other device would just upload it again. An id that is
/// pending but exists in neither place is skipped rather than sent as a blank
/// record; that state is reachable (a delete that lost its tombstone) and
/// pushing a half-record would be worse than pushing nothing.
///
/// **Ported TS quirk, kept deliberately.** The TS wrote `const at = tombstones[id]; if (at)`,
/// and `0` is falsy, so a tombstone stamped `0` is treated as absent. The port
/// reproduces that (`at != null && at != 0`) so the two builds agree; it is
/// reported as a TS bug rather than fixed here, because a stamp of 0 never
/// occurs in practice (epoch ms) and changing the rule would silently alter
/// merge behaviour for the web build too.
ChangeSet collectChanges(AppData data) {
  final words = <WordRecord>[];
  for (final id in data.pending.words) {
    final at = data.tombstones.words[id];
    if (at != null && at != 0) {
      words.add(WordTombstone(id: id, updatedAt: at));
      continue;
    }
    final word = data.words.where((w) => w.id == id).firstOrNull;
    if (word != null) words.add(WordEdit(word));
  }

  final lists = <ListRecord>[];
  for (final id in data.pending.lists) {
    final at = data.tombstones.lists[id];
    if (at != null && at != 0) {
      lists.add(ListTombstone(id: id, updatedAt: at));
      continue;
    }
    final list = data.lists.where((l) => l.id == id).firstOrNull;
    if (list != null) lists.add(ListEdit(list));
  }

  final logs = <LogRecord>[];
  for (final id in data.pending.logs) {
    final at = data.tombstones.logs[id];
    if (at != null && at != 0) {
      logs.add(LogTombstone(id: id, at: at));
      continue;
    }
    final log = data.logs.where((l) => l.id == id).firstOrNull;
    if (log != null) logs.add(LogEntry(log));
  }

  final settings = data.pending.settings
      ? SettingsRecord(settings: data.settings, updatedAt: data.settingsUpdatedAt)
      : null;

  return ChangeSet(words: words, lists: lists, logs: logs, settings: settings);
}

/// True when there is something to push.
bool hasChanges(ChangeSet changes) => !changes.isEmpty;

/// Number of records still waiting to be pushed (drives the UI badge).
///
/// Delegates to the journal, which owns the bookkeeping. Settling pending flags
/// is *not* here: it is version-guarded and lives in `journal.settle`, because
/// a naive "clear everything we sent" loses edits made during the request.
int pendingCount(AppData data) => journal.pendingTotal(data);

/// The stamp half of [changes], for [journal.settle].
///
/// `settle` needs ids and versions only — it compares each one against the
/// local copy to decide whether the push it just acknowledged is still the
/// version on disk. Building it here keeps the conversion next to the merge
/// that consumes it, and keeps `journal.dart` free of wire types.
journal.PushedChanges pushedChangesOf(ChangeSet changes) {
  final settings = changes.settings;
  return journal.PushedChanges(
    words: [
      for (final r in changes.words)
        journal.StampedRecord(id: r.id, updatedAt: r.updatedAt),
    ],
    lists: [
      for (final r in changes.lists)
        journal.StampedRecord(id: r.id, updatedAt: r.updatedAt),
    ],
    logs: [
      for (final r in changes.logs) journal.StampedLog(id: r.id, at: r.at),
    ],
    settings: settings == null ? null : journal.SettingsStamp(settings.updatedAt),
  );
}

/// Merge a decoded server change set into the local snapshot.
///
/// Callers must pass records that already went through
/// [decodeChangeSet]: merging is a domain operation, and the snapshot must never
/// inherit wire bookkeeping such as `_rev`.
///
/// A local record wins over the incoming one when it is still pending *and*
/// strictly newer — that happens when the user edited something between the
/// push being built and the response arriving; it will be pushed next round.
///
/// The input snapshot is never mutated: every list and map that changes is
/// copied first. A caller may keep rendering the old snapshot while this runs.
AppData applyRemote(AppData data, ChangeSet changes) {
  final pendingWords = data.pending.words.toSet();
  final pendingLists = data.pending.lists.toSet();
  final pendingLogs = data.pending.logs.toSet();

  // Records we deliberately keep because the local copy is newer must stay
  // pending, otherwise the next round would never upload them.
  final keptWords = <String>{};
  final keptLists = <String>{};
  final keptLogs = <String>{};

  final tombstoneWords = Map<String, int>.of(data.tombstones.words);
  final tombstoneLists = Map<String, int>.of(data.tombstones.lists);
  final tombstoneLogs = Map<String, int>.of(data.tombstones.logs);

  var words = List<Word>.of(data.words);
  for (final record in changes.words) {
    final local = words.where((w) => w.id == record.id).firstOrNull;
    switch (record) {
      case WordTombstone():
        // A local copy (or a local tombstone) newer than the incoming delete
        // means the delete is stale: keep whatever we have and push it again.
        final localTs = local?.updatedAt ?? tombstoneWords[record.id] ?? 0;
        if (pendingWords.contains(record.id) && localTs > record.updatedAt) {
          keptWords.add(record.id);
          continue;
        }
        words = words.where((w) => w.id != record.id).toList();
        tombstoneWords[record.id] = record.updatedAt;
      case WordEdit(:final word):
        // Last-write-wins on `updatedAt`, whichever side is pending.
        if (local != null && local.updatedAt > word.updatedAt) {
          if (pendingWords.contains(record.id)) keptWords.add(record.id);
          continue;
        }
        // A tombstone we still hold means the record was deleted here more
        // recently. `buried != 0` reproduces the TS's truthiness test, which
        // also treats a stamp of 0 as "not buried".
        final buried = tombstoneWords[record.id];
        if (buried != null && buried != 0 && buried > word.updatedAt) {
          keptWords.add(record.id);
          continue;
        }
        if (local != null) {
          words = [
            for (final w in words) w.id == record.id ? word : w,
          ];
        } else {
          words.add(word);
        }
        tombstoneWords.remove(record.id);
    }
  }

  var lists = List<WordList>.of(data.lists);
  for (final record in changes.lists) {
    final local = lists.where((l) => l.id == record.id).firstOrNull;
    switch (record) {
      case ListTombstone():
        final localTs = local?.updatedAt ?? tombstoneLists[record.id] ?? 0;
        if (pendingLists.contains(record.id) && localTs > record.updatedAt) {
          keptLists.add(record.id);
          continue;
        }
        lists = lists.where((l) => l.id != record.id).toList();
        tombstoneLists[record.id] = record.updatedAt;
      case ListEdit(:final list):
        if (local != null && local.updatedAt > list.updatedAt) {
          if (pendingLists.contains(record.id)) keptLists.add(record.id);
          continue;
        }
        final buried = tombstoneLists[record.id];
        if (buried != null && buried != 0 && buried > list.updatedAt) {
          keptLists.add(record.id);
          continue;
        }
        if (local != null) {
          lists = [
            for (final l in lists) l.id == record.id ? list : l,
          ];
        } else {
          lists.add(list);
        }
        tombstoneLists.remove(record.id);
    }
  }

  var logs = List<ReviewLog>.of(data.logs);
  for (final record in changes.logs) {
    switch (record) {
      case LogTombstone():
        // A log is never edited, so the local copy contributes no stamp: only
        // our own tombstone can outrank the incoming delete.
        final localTs = tombstoneLogs[record.id] ?? 0;
        if (pendingLogs.contains(record.id) && localTs > record.at) {
          keptLogs.add(record.id);
          continue;
        }
        logs = logs.where((l) => l.id != record.id).toList();
        tombstoneLogs[record.id] = record.at;
      case LogEntry(:final log):
        // Append-only union: an id we already hold, or one we deleted, is not
        // re-added. `?? 0` reproduces the TS's `!tombstones.logs[id]`, which
        // also treats a stamp of 0 as "not buried".
        if (!logs.any((l) => l.id == log.id) &&
            (tombstoneLogs[log.id] ?? 0) == 0) {
          logs.add(log);
        }
    }
  }

  var settings = data.settings;
  var settingsUpdatedAt = data.settingsUpdatedAt;
  var settingsPending = data.pending.settings;
  final incoming = changes.settings;
  if (incoming != null && incoming.updatedAt > settingsUpdatedAt) {
    // Settings sync as one document, so the remote copy wins wholesale — no
    // per-field merge, and no "keep my dailyGoal, take their theme".
    settings = incoming.settings;
    settingsUpdatedAt = incoming.updatedAt;
    settingsPending = false;
  }

  return data.copyWith(
    words: words,
    lists: lists,
    logs: logs,
    settings: settings,
    settingsUpdatedAt: settingsUpdatedAt,
    tombstones: Tombstones(
      words: tombstoneWords,
      lists: tombstoneLists,
      logs: tombstoneLogs,
    ),
    pending: PendingChanges(
      words: data.pending.words
          .where((id) =>
              keptWords.contains(id) || !changes.words.any((r) => r.id == id))
          .toList(),
      lists: data.pending.lists
          .where((id) =>
              keptLists.contains(id) || !changes.lists.any((r) => r.id == id))
          .toList(),
      logs: data.pending.logs
          .where((id) =>
              keptLogs.contains(id) || !changes.logs.any((r) => r.id == id))
          .toList(),
      settings: settingsPending,
    ),
  );
}

/// Apply one completed round to a snapshot: settle what we sent, then merge
/// what came back.
///
/// The order is the point, and it is why both steps live in one place. `settle`
/// is version-guarded — it clears a pending flag only when the local record
/// still holds the exact version we pushed — so it has to run *before*
/// [applyRemote] replaces those local copies with the server's. A record edited
/// while the request was in flight therefore keeps its flag and goes out in the
/// next round instead of being silently marked as synced.
///
/// That order is also the one place it is observable: a server tombstone older
/// than a local copy that this round just settled *does* win, because by then
/// the record is no longer pending.
AppData applyRound(AppData data, SyncRound round) {
  // The TS handed `settle` a shallow copy of the bookkeeping because it
  // mutated in place. Here both halves are pure, so the copy is unnecessary —
  // and the input snapshot is untouched for free.
  final settled = journal.settle(data, pushedChangesOf(round.sent));
  return applyRemote(settled, round.received);
}
