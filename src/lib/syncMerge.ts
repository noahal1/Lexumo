/**
 * Pure helpers that translate between the local `AppData` snapshot and the
 * wire `ChangeSet` used by the sync server. No I/O here — everything is a
 * function of its inputs, which keeps the merge rules unit-testable.
 *
 * Conflict rules (mirrors docs/sync-protocol.md):
 * - words / lists / settings: last-write-wins on `updatedAt`
 * - review logs: append-only, deduplicated by `id`, deletions propagate as tombstones
 * - a local record that is still pending and newer than the server copy wins
 */
import type {
  AppData,
  ChangeSet,
  ListRecord,
  LogRecord,
  SettingsRecord,
  Tombstone,
  WordRecord,
} from "./types";
import { pendingTotal } from "./journal";

const tombstone = (id: string, updatedAt: number): Tombstone => ({ id, updatedAt, deleted: true });

/** Build the outbound change set from everything currently marked pending. */
export function collectChanges(data: AppData): ChangeSet {
  const words: WordRecord[] = [];
  for (const id of data.pending.words) {
    const at = data.tombstones.words[id];
    if (at) {
      words.push(tombstone(id, at));
      continue;
    }
    const word = data.words.find((w) => w.id === id);
    if (word) words.push(word);
  }

  const lists: ListRecord[] = [];
  for (const id of data.pending.lists) {
    const at = data.tombstones.lists[id];
    if (at) {
      lists.push(tombstone(id, at));
      continue;
    }
    const list = data.lists.find((l) => l.id === id);
    if (list) lists.push(list);
  }

  const logs: LogRecord[] = [];
  for (const id of data.pending.logs) {
    const at = data.tombstones.logs[id];
    if (at) {
      logs.push({ id, at, deleted: true });
      continue;
    }
    const log = data.logs.find((l) => l.id === id);
    if (log) logs.push(log);
  }

  const settings: SettingsRecord | null = data.pending.settings
    ? { ...data.settings, updatedAt: data.settingsUpdatedAt }
    : null;

  return { words, lists, logs, settings };
}

/** True when there is nothing to push. */
export function hasChanges(changes: ChangeSet): boolean {
  return (
    changes.words.length > 0 ||
    changes.lists.length > 0 ||
    changes.logs.length > 0 ||
    changes.settings !== null
  );
}

/**
 * Number of records still waiting to be pushed (drives the UI badge).
 *
 * Delegates to the journal, which owns the bookkeeping. Settling pending flags
 * is *not* here: it is version-guarded and lives in `journal.settle`, because a
 * naive "clear everything we sent" loses edits made during the request.
 */
export const pendingCount = pendingTotal;

const isTombstone = (r: unknown): r is Tombstone =>
  (r as { deleted?: unknown }).deleted === true;

const isLogTombstone = (r: LogRecord): r is { id: string; at: number; deleted: true } =>
  (r as { deleted?: unknown }).deleted === true;

/**
 * Merge a server change set into the local snapshot.
 *
 * A local record wins over the incoming one when it is still pending *and*
 * strictly newer — that happens when the user edited something between the
 * push being built and the response arriving; it will be pushed next round.
 */
export function applyRemote(data: AppData, changes: ChangeSet): AppData {
  const pendingWords = new Set(data.pending.words);
  const pendingLists = new Set(data.pending.lists);
  const pendingLogs = new Set(data.pending.logs);

  // Records we deliberately keep because the local copy is newer must stay
  // pending, otherwise the next round would never upload them.
  const keptWords = new Set<string>();
  const keptLists = new Set<string>();
  const keptLogs = new Set<string>();

  const tombstones = {
    words: { ...data.tombstones.words },
    lists: { ...data.tombstones.lists },
    logs: { ...data.tombstones.logs },
  };

  let words = data.words.slice();
  for (const record of changes.words) {
    const local = words.find((w) => w.id === record.id);
    if (isTombstone(record)) {
      const localTs = local?.updatedAt ?? tombstones.words[record.id] ?? 0;
      if (pendingWords.has(record.id) && localTs > record.updatedAt) {
        keptWords.add(record.id);
        continue;
      }
      words = words.filter((w) => w.id !== record.id);
      tombstones.words[record.id] = record.updatedAt;
      continue;
    }
    const remote = record as Exclude<WordRecord, Tombstone>;
    // Last-write-wins on `updatedAt`, whichever side is pending.
    if (local && local.updatedAt > remote.updatedAt) {
      if (pendingWords.has(record.id)) keptWords.add(record.id);
      continue;
    }
    // A tombstone we still hold means the record was deleted here more recently.
    if (tombstones.words[record.id] && tombstones.words[record.id] > remote.updatedAt) {
      keptWords.add(record.id);
      continue;
    }
    if (local) {
      words = words.map((w) => (w.id === record.id ? remote : w));
    } else {
      words.push(remote);
    }
    delete tombstones.words[record.id];
  }

  let lists = data.lists.slice();
  for (const record of changes.lists) {
    const local = lists.find((l) => l.id === record.id);
    if (isTombstone(record)) {
      const localTs = local?.updatedAt ?? tombstones.lists[record.id] ?? 0;
      if (pendingLists.has(record.id) && localTs > record.updatedAt) {
        keptLists.add(record.id);
        continue;
      }
      lists = lists.filter((l) => l.id !== record.id);
      tombstones.lists[record.id] = record.updatedAt;
      continue;
    }
    const remote = record as Exclude<ListRecord, Tombstone>;
    if (local && local.updatedAt > remote.updatedAt) {
      if (pendingLists.has(record.id)) keptLists.add(record.id);
      continue;
    }
    if (tombstones.lists[record.id] && tombstones.lists[record.id] > remote.updatedAt) {
      keptLists.add(record.id);
      continue;
    }
    if (local) {
      lists = lists.map((l) => (l.id === record.id ? remote : l));
    } else {
      lists.push(remote);
    }
    delete tombstones.lists[record.id];
  }

  let logs = data.logs.slice();
  for (const record of changes.logs) {
    if (isLogTombstone(record)) {
      const at = record.at ?? 0;
      const localTs = tombstones.logs[record.id] ?? 0;
      if (pendingLogs.has(record.id) && localTs > at) {
        keptLogs.add(record.id);
        continue;
      }
      logs = logs.filter((l) => l.id !== record.id);
      tombstones.logs[record.id] = at;
      continue;
    }
    if (!logs.some((l) => l.id === record.id) && !tombstones.logs[record.id]) {
      logs.push(record as Exclude<LogRecord, { deleted: true }>);
    }
  }

  let settings = data.settings;
  let settingsUpdatedAt = data.settingsUpdatedAt;
  let settingsPending = data.pending.settings;
  if (changes.settings && changes.settings.updatedAt > settingsUpdatedAt) {
    const { updatedAt, ...rest } = changes.settings;
    settings = { ...data.settings, ...rest };
    settingsUpdatedAt = updatedAt;
    settingsPending = false;
  }

  return {
    ...data,
    words,
    lists,
    logs,
    settings,
    settingsUpdatedAt,
    tombstones,
    pending: {
      words: data.pending.words.filter(
        (id) => keptWords.has(id) || !changes.words.some((r) => r.id === id),
      ),
      lists: data.pending.lists.filter(
        (id) => keptLists.has(id) || !changes.lists.some((r) => r.id === id),
      ),
      logs: data.pending.logs.filter(
        (id) => keptLogs.has(id) || !changes.logs.some((r) => r.id === id),
      ),
      settings: settingsPending,
    },
  };
}
