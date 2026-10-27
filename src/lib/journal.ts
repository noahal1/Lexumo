/**
 * The change journal — the single owner of `pending` and `tombstones`.
 *
 * Two invariants govern sync, and neither can be expressed by remembering to
 * call `markWordDirty` at the right moment:
 *
 *   1. every local edit must be recorded as pending, otherwise another device
 *      will never learn about it;
 *   2. every local delete must leave a tombstone, otherwise another device
 *      will simply upload the record again.
 *
 * Before this module existed both rules were re-applied by hand in thirteen
 * mutation bodies (21 calls), and one of them had already been forgotten:
 * `deleteList` removed a list's words without removing their review logs, so
 * deleted reviews kept inflating the streak and were pushed to the server
 * forever. Bookkeeping that lives here cannot be forgotten by a new domain
 * operation.
 *
 * Nothing in this module performs I/O or knows about React; every function
 * edits the draft snapshot it is handed.
 */
import type { AppData, ChangeSet } from "./types";

export type RecordKind = "word" | "list" | "log";

/** `pending` and `tombstones` use the same three buckets. */
const BUCKET = {
  word: "words",
  list: "lists",
  log: "logs",
} as const;

/** Record that a record was created or edited locally. */
export function touch(d: AppData, kind: RecordKind, id: string): void {
  const bucket = d.pending[BUCKET[kind]];
  if (!bucket.includes(id)) bucket.push(id);
}

/**
 * Record that a record was deleted locally at `at`.
 *
 * Absence cannot express a delete: the other device would just re-upload the
 * record. The tombstone is what makes the removal travel.
 */
export function bury(d: AppData, kind: RecordKind, id: string, at: number): void {
  d.tombstones[BUCKET[kind]][id] = at;
  touch(d, kind, id);
}

/** Record a settings edit, which is versioned as a whole rather than by id. */
export function touchSettings(d: AppData, at: number): void {
  d.settingsUpdatedAt = at;
  d.pending.settings = true;
}

/**
 * Remove a set of words and everything hanging off them — their review logs —
 * in one declaration.
 *
 * Every caller that deletes words goes through here (single delete, bulk
 * delete, and list delete), which is what stops the cascade from drifting
 * between them.
 */
export function purgeWords(d: AppData, ids: readonly string[], at: number): void {
  if (ids.length === 0) return;
  const doomed = new Set(ids);
  const doomedLogs = d.logs.filter((l) => doomed.has(l.wordId)).map((l) => l.id);
  d.words = d.words.filter((w) => !doomed.has(w.id));
  d.logs = d.logs.filter((l) => !doomed.has(l.wordId));
  for (const id of doomed) bury(d, "word", id, at);
  for (const id of doomedLogs) bury(d, "log", id, at);
}

/**
 * Drop the pending flags for records the server accepted.
 *
 * A record only settles when the local copy is still the exact version that
 * was pushed. If the user edited it while the request was in flight, the newer
 * version must stay pending so the next round uploads it — settling it here
 * would silently lose the edit.
 */
export function settle(d: AppData, pushed: ChangeSet): void {
  const wordStamp = (id: string) =>
    d.words.find((w) => w.id === id)?.updatedAt ?? d.tombstones.words[id] ?? 0;
  const listStamp = (id: string) =>
    d.lists.find((l) => l.id === id)?.updatedAt ?? d.tombstones.lists[id] ?? 0;
  const logStamp = (id: string) =>
    d.logs.find((l) => l.id === id)?.at ?? d.tombstones.logs[id] ?? 0;

  const settledWords = new Set(
    pushed.words.filter((r) => wordStamp(r.id) === r.updatedAt).map((r) => r.id),
  );
  const settledLists = new Set(
    pushed.lists.filter((r) => listStamp(r.id) === r.updatedAt).map((r) => r.id),
  );
  const settledLogs = new Set(pushed.logs.filter((r) => logStamp(r.id) === r.at).map((r) => r.id));

  d.pending.words = d.pending.words.filter((id) => !settledWords.has(id));
  d.pending.lists = d.pending.lists.filter((id) => !settledLists.has(id));
  d.pending.logs = d.pending.logs.filter((id) => !settledLogs.has(id));
  if (pushed.settings && d.settingsUpdatedAt === pushed.settings.updatedAt) {
    d.pending.settings = false;
  }
}

/** How many records are still waiting to be pushed (drives the UI badge). */
export function pendingTotal(d: AppData): number {
  return (
    d.pending.words.length +
    d.pending.lists.length +
    d.pending.logs.length +
    (d.pending.settings ? 1 : 0)
  );
}
