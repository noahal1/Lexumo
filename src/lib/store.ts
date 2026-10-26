/**
 * Application store: a tiny observable snapshot store with
 * useSyncExternalStore, plus all mutations (words, lists, reviews, settings).
 *
 * All writes go through `commit`, which bumps `updatedAt`, notifies
 * subscribers, and schedules a debounced persistence write.
 *
 * Every mutation also records what changed in `data.pending` so the sync
 * engine knows what still has to be pushed, and deletions leave a tombstone in
 * `data.tombstones` (a delete must be an explicit record — otherwise another
 * device would simply upload the record again).
 */
import { useSyncExternalStore } from "react";
import { loadSnapshot, saveSnapshot, clearSnapshot } from "./db";
import { emitLocalChange } from "./localChanges";
import { applyGrade, statusForInterval, freshSrs } from "./srs";
import { seedData } from "./seed";
import { collectChanges, pendingCount, applyRemote } from "./syncMerge";
import type {
  AppData,
  ChangeSet,
  Grade,
  ReviewLog,
  Settings,
  SrsState,
  Tombstones,
  Word,
  WordList,
  WordStatus,
} from "./types";
import {
  DATA_VERSION,
  DEFAULT_LIST_ID,
  DEFAULT_SETTINGS,
  EMPTY_PENDING,
  EMPTY_TOMBSTONES,
} from "./types";
import { normalizeTerm, uid } from "./utils";

export { DEFAULT_SETTINGS, DEFAULT_LIST_ID };

const cloneTombstones = (t: Tombstones): Tombstones => ({
  words: { ...t.words },
  lists: { ...t.lists },
  logs: { ...t.logs },
});

export function emptyData(): AppData {
  return {
    version: DATA_VERSION,
    lists: [],
    words: [],
    logs: [],
    settings: { ...DEFAULT_SETTINGS },
    settingsUpdatedAt: 0,
    tombstones: cloneTombstones(EMPTY_TOMBSTONES),
    pending: { ...EMPTY_PENDING, words: [], lists: [], logs: [] },
  };
}

/**
 * Bring any older snapshot up to the current shape. Data written before sync
 * existed (version 1) simply gains empty tombstones/pending and an `updatedAt`
 * on each list — nothing is dropped.
 */
export function migrateSnapshot(raw: unknown): AppData | null {
  if (!raw || typeof raw !== "object") return null;
  const snap = raw as Partial<AppData> & { version?: number };
  if (!Array.isArray(snap.words) || !Array.isArray(snap.lists)) return null;
  if (typeof snap.version !== "number" || snap.version > DATA_VERSION) return null;
  const base = emptyData();
  return {
    ...base,
    ...snap,
    version: DATA_VERSION,
    logs: Array.isArray(snap.logs) ? snap.logs : [],
    settings: { ...DEFAULT_SETTINGS, ...(snap.settings ?? {}) },
    settingsUpdatedAt: snap.settingsUpdatedAt ?? 0,
    lists: snap.lists.map((l) => ({ ...l, updatedAt: l.updatedAt ?? l.createdAt ?? Date.now() })),
    tombstones: { ...base.tombstones, ...(snap.tombstones ?? {}) },
    pending: { ...base.pending, ...(snap.pending ?? {}) },
  };
}

let data: AppData = emptyData();
let ready = false;
const listeners = new Set<() => void>();
let saveTimer: ReturnType<typeof setTimeout> | null = null;

function notify() {
  for (const fn of listeners) fn();
}

function scheduleSave() {
  if (saveTimer) clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    saveTimer = null;
    void saveSnapshot(data);
  }, 220);
}

function commit(mutator: (draft: AppData) => void) {
  const draft: AppData = {
    ...data,
    lists: data.lists.slice(),
    words: data.words.slice(),
    logs: data.logs.slice(),
    settings: { ...data.settings },
    tombstones: cloneTombstones(data.tombstones),
    pending: {
      words: data.pending.words.slice(),
      lists: data.pending.lists.slice(),
      logs: data.pending.logs.slice(),
      settings: data.pending.settings,
    },
  };
  mutator(draft);
  data = draft;
  notify();
  emitLocalChange();
  scheduleSave();
}

function markWordDirty(d: AppData, id: string) {
  if (!d.pending.words.includes(id)) d.pending.words.push(id);
}

function markListDirty(d: AppData, id: string) {
  if (!d.pending.lists.includes(id)) d.pending.lists.push(id);
}

function markLogDirty(d: AppData, id: string) {
  if (!d.pending.logs.includes(id)) d.pending.logs.push(id);
}

/** Load the snapshot once at boot; first run seeds a demo deck. */
export async function initStore(): Promise<void> {
  const snapshot = await loadSnapshot();
  const migrated = snapshot ? migrateSnapshot(snapshot) : null;
  if (migrated) {
    data = migrated;
  } else {
    data = seedData();
  }
  if (data.lists.length === 0) {
    const now = Date.now();
    data.lists = [
      {
        id: DEFAULT_LIST_ID,
        name: "我的词库",
        sourceLang: "en",
        targetLang: "zh-CN",
        createdAt: now,
        updatedAt: now,
      },
    ];
  }
  ready = true;
  notify();
  scheduleSave();
}

export function isReady() {
  return ready;
}

export function getData(): AppData {
  return data;
}

function subscribe(fn: () => void) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

function getSnapshot(): AppData {
  return data;
}

/** Subscribe a component to the whole snapshot (cheap: shallow object identity). */
export function useAppData(): AppData {
  return useSyncExternalStore(subscribe, getSnapshot, getSnapshot);
}

export function useSettings(): Settings {
  return useAppData().settings;
}

/* ------------------------------------------------------------------ */
/* Lists                                                               */
/* ------------------------------------------------------------------ */

export function createList(input: {
  name: string;
  sourceLang: string;
  targetLang: string;
}): WordList {
  const now = Date.now();
  const list: WordList = {
    id: uid("list"),
    name: input.name.trim() || "未命名词库",
    sourceLang: input.sourceLang,
    targetLang: input.targetLang,
    createdAt: now,
    updatedAt: now,
  };
  commit((d) => {
    d.lists.push(list);
    markListDirty(d, list.id);
  });
  return list;
}

export function renameList(id: string, name: string) {
  commit((d) => {
    const list = d.lists.find((l) => l.id === id);
    if (!list) return;
    list.name = name.trim() || list.name;
    list.updatedAt = Date.now();
    markListDirty(d, id);
  });
}

export function deleteList(id: string) {
  const now = Date.now();
  commit((d) => {
    const doomed = d.words.filter((w) => w.listId === id);
    d.lists = d.lists.filter((l) => l.id !== id);
    d.words = d.words.filter((w) => w.listId !== id);
    for (const w of doomed) {
      d.tombstones.words[w.id] = now;
      markWordDirty(d, w.id);
    }
    d.tombstones.lists[id] = now;
    markListDirty(d, id);
  });
}

/* ------------------------------------------------------------------ */
/* Words                                                               */
/* ------------------------------------------------------------------ */

export interface NewWordInput {
  term: string;
  definition?: string;
  definition2?: string;
  example?: string;
  note?: string;
  tags?: string[];
  listId: string;
  status?: WordStatus;
  favorite?: boolean;
}

export function addWord(input: NewWordInput): Word {
  const list = data.lists.find((l) => l.id === input.listId) ?? data.lists[0];
  const now = Date.now();
  const word: Word = {
    id: uid("w"),
    term: input.term.trim(),
    definition: (input.definition ?? "").trim(),
    definition2: (input.definition2 ?? "").trim(),
    example: (input.example ?? "").trim(),
    note: (input.note ?? "").trim(),
    status: input.status ?? "new",
    favorite: input.favorite ?? false,
    tags: dedupeTags(input.tags ?? []),
    listId: list?.id ?? DEFAULT_LIST_ID,
    sourceLang: list?.sourceLang ?? "en",
    targetLang: list?.targetLang ?? "zh-CN",
    listenCount: 0,
    srs: null,
    createdAt: now,
    updatedAt: now,
  };
  commit((d) => {
    d.words.unshift(word);
    markWordDirty(d, word.id);
  });
  return word;
}

export function updateWord(id: string, patch: Partial<Word>) {
  commit((d) => {
    const w = d.words.find((x) => x.id === id);
    if (!w) return;
    Object.assign(w, patch, { updatedAt: Date.now() });
    if (patch.tags) w.tags = dedupeTags(patch.tags);
    markWordDirty(d, id);
  });
}

export function deleteWord(id: string) {
  const now = Date.now();
  commit((d) => {
    const gone = d.logs.filter((l) => l.wordId === id);
    d.words = d.words.filter((w) => w.id !== id);
    d.logs = d.logs.filter((l) => l.wordId !== id);
    d.tombstones.words[id] = now;
    markWordDirty(d, id);
    for (const log of gone) {
      d.tombstones.logs[log.id] = now;
      markLogDirty(d, log.id);
    }
  });
}

export function deleteWords(ids: string[]) {
  const set = new Set(ids);
  const now = Date.now();
  commit((d) => {
    const goneLogs = d.logs.filter((l) => set.has(l.wordId));
    d.words = d.words.filter((w) => !set.has(w.id));
    d.logs = d.logs.filter((l) => !set.has(l.wordId));
    for (const id of ids) {
      d.tombstones.words[id] = now;
      markWordDirty(d, id);
    }
    for (const log of goneLogs) {
      d.tombstones.logs[log.id] = now;
      markLogDirty(d, log.id);
    }
  });
}

export function toggleFavorite(id: string) {
  commit((d) => {
    const w = d.words.find((x) => x.id === id);
    if (w) {
      w.favorite = !w.favorite;
      w.updatedAt = Date.now();
      markWordDirty(d, id);
    }
  });
}

export function bumpListen(id: string) {
  commit((d) => {
    const w = d.words.find((x) => x.id === id);
    if (w) {
      w.listenCount += 1;
      w.updatedAt = Date.now();
      markWordDirty(d, id);
    }
  });
}

function dedupeTags(tags: string[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const raw of tags) {
    const tag = raw.trim();
    if (!tag) continue;
    const key = tag.toLocaleLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(tag);
  }
  return out.slice(0, 12);
}

/* ------------------------------------------------------------------ */
/* Reviewing                                                           */
/* ------------------------------------------------------------------ */

export interface GradeResult {
  srs: SrsState;
  status: WordStatus;
  /** Id of the review log entry this grade appended, so it can be undone. */
  logId: string;
}

/** Grade a card and persist the new schedule + review log. */
export function gradeWord(id: string, grade: Grade, now = Date.now()): GradeResult | null {
  const word = data.words.find((w) => w.id === id);
  if (!word) return null;
  const before = word.srs?.intervalDays ?? 0;
  const next = applyGrade(word.srs, grade, now);
  const status = statusForInterval(next.intervalDays);
  const log: ReviewLog = {
    id: uid("r"),
    wordId: id,
    grade,
    at: now,
    intervalBefore: before,
    intervalAfter: next.intervalDays,
  };
  commit((d) => {
    const w = d.words.find((x) => x.id === id);
    if (!w) return;
    w.srs = next;
    // Never demote: keep the highest status the word has earned.
    if (rank(status) > rank(w.status)) w.status = status;
    w.updatedAt = now;
    d.logs.push(log);
    markWordDirty(d, id);
    markLogDirty(d, log.id);
  });
  return { srs: next, status, logId: log.id };
}

/**
 * Roll back a single grade: restore the schedule the word had before, put the
 * status back exactly as it was (including the "never demote" behaviour, which
 * a plain recompute would get wrong) and drop the review log entry.
 */
export function undoReview(
  id: string,
  prevSrs: SrsState | null,
  prevStatus: WordStatus,
  logId: string,
  now = Date.now(),
) {
  commit((d) => {
    const w = d.words.find((x) => x.id === id);
    if (!w) return;
    w.srs = prevSrs;
    w.status = prevStatus;
    w.updatedAt = now;
    markWordDirty(d, id);
    const at = d.logs.findIndex((log) => log.id === logId);
    if (at >= 0) d.logs.splice(at, 1);
    d.tombstones.logs[logId] = now;
    markLogDirty(d, logId);
  });
}

function rank(status: WordStatus): number {
  return { new: 0, reviewing: 1, learning: 2, mastered: 3 }[status];
}

export function setWordStatus(id: string, status: WordStatus) {
  commit((d) => {
    const w = d.words.find((x) => x.id === id);
    if (w) {
      w.status = status;
      w.updatedAt = Date.now();
      markWordDirty(d, id);
    }
  });
}

/** Manually reset a card's schedule back to "new". */
export function resetSrs(id: string) {
  commit((d) => {
    const w = d.words.find((x) => x.id === id);
    if (w) {
      w.srs = null;
      w.status = "new";
      w.updatedAt = Date.now();
      markWordDirty(d, id);
    }
  });
}

/* ------------------------------------------------------------------ */
/* Settings & data                                                     */
/* ------------------------------------------------------------------ */

export function updateSettings(patch: Partial<Settings>) {
  commit((d) => {
    d.settings = { ...d.settings, ...patch };
    d.settingsUpdatedAt = Date.now();
    d.pending.settings = true;
  });
}

export function replaceAll(next: AppData) {
  const migrated = migrateSnapshot(next) ?? emptyData();
  data = migrated;
  notify();
  scheduleSave();
}

export async function wipeAll() {
  await clearSnapshot();
  const now = Date.now();
  data = emptyData();
  data.lists = [
    {
      id: DEFAULT_LIST_ID,
      name: "我的词库",
      sourceLang: "en",
      targetLang: "zh-CN",
      createdAt: now,
      updatedAt: now,
    },
  ];
  notify();
  scheduleSave();
}

/* ------------------------------------------------------------------ */
/* Sync bridge                                                         */
/* ------------------------------------------------------------------ */

/** What still needs to be pushed to the server. */
export function getChangesToPush(): ChangeSet {
  return collectChanges(data);
}

export function pendingChangeCount(): number {
  return pendingCount(data);
}

/**
 * Mark records as accepted by the server (called after a successful push).
 *
 * Only clears a pending flag when the local copy is still the exact version we
 * sent — if the user edited the record while the request was in flight, the
 * newer version must stay pending so the next round uploads it.
 */
export function markPushed(pushed: ChangeSet) {
  commit((d) => {
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
  });
}

/** Merge a server change set into the local snapshot. */
export function applyRemoteChanges(changes: ChangeSet) {
  data = applyRemote(data, changes);
  notify();
  scheduleSave();
}

/* ------------------------------------------------------------------ */
/* Selectors                                                           */
/* ------------------------------------------------------------------ */

export function wordsOfList(d: AppData, listId: string): Word[] {
  return d.words.filter((w) => w.listId === listId);
}

export function dueWords(d: AppData, now = Date.now()): Word[] {
  return d.words.filter((w) => {
    if (w.status === "mastered") return false;
    if (!w.srs) return true;
    return w.srs.dueAt <= now;
  });
}

export function tagPool(d: AppData): string[] {
  const counts = new Map<string, number>();
  for (const w of d.words) {
    for (const t of w.tags) counts.set(t, (counts.get(t) ?? 0) + 1);
  }
  return [...counts.entries()]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .map(([t]) => t);
}

export function reviewsToday(d: AppData, now = Date.now()): number {
  const start = new Date(now);
  start.setHours(0, 0, 0, 0);
  const t0 = start.getTime();
  return d.logs.filter((l) => l.at >= t0).length;
}

export function streakDays(d: AppData, now = Date.now()): number {
  const days = new Set<string>();
  for (const l of d.logs) {
    const dt = new Date(l.at);
    days.add(`${dt.getFullYear()}-${dt.getMonth()}-${dt.getDate()}`);
  }
  let streak = 0;
  const cursor = new Date(now);
  // Allow today to be empty without breaking yesterday's streak.
  const todayKey = `${cursor.getFullYear()}-${cursor.getMonth()}-${cursor.getDate()}`;
  if (!days.has(todayKey)) cursor.setDate(cursor.getDate() - 1);
  for (;;) {
    const key = `${cursor.getFullYear()}-${cursor.getMonth()}-${cursor.getDate()}`;
    if (!days.has(key)) break;
    streak += 1;
    cursor.setDate(cursor.getDate() - 1);
  }
  return streak;
}

export function findDuplicate(d: AppData, term: string, listId?: string): Word | undefined {
  const key = normalizeTerm(term);
  return d.words.find(
    (w) => normalizeTerm(w.term) === key && (!listId || w.listId === listId),
  );
}

export { freshSrs };
