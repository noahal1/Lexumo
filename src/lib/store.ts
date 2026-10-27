/**
 * Application store: an observable snapshot (via useSyncExternalStore) plus the
 * domain operations — words, lists, reviews, settings.
 *
 * Shape of the module:
 *
 * - `createStore` builds an isolated instance from a persistence adapter and a
 *   clock. The app uses one instance; tests build their own, so a unit test can
 *   drive real mutations instead of hand-assembling snapshots.
 * - every write goes through `commit`: clone the snapshot, let the operation
 *   edit the clone, then notify and schedule persistence. Cloning the arrays
 *   only works because operations *replace* records rather than mutating them
 *   in place — `patchWord`/`patchList` are the only ways a record changes.
 * - sync bookkeeping (`pending` + `tombstones`) is written only by
 *   `./journal`, so a new operation cannot forget to mark its change.
 */
import { useSyncExternalStore } from "react";
import { loadSnapshot, saveSnapshot, clearSnapshot } from "./db";
import { emitLocalChange } from "./localChanges";
import { freshSrs, reviewCard, undoGrade } from "./srs";
import { seedData } from "./seed";
import {
  applyRound as applyRoundToData,
  collectChanges,
  pendingCount,
  type SyncRound,
} from "./syncMerge";
import * as journal from "./journal";
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

/** Where the snapshot lives. Narrow on purpose: swapping IndexedDB for SQLite
 * means writing one more object of these three functions. */
export interface Persistence {
  load(): Promise<AppData | null>;
  save(data: AppData): Promise<void>;
  clear(): Promise<void>;
}

export interface StoreOptions {
  persistence: Persistence;
  /** Injectable so tests can freeze time. */
  clock?: () => number;
  /** First-run content; defaults to the demo deck. */
  seed?: (now: number) => AppData;
  /** Persistence debounce in ms. `0` saves immediately (tests). */
  saveDelayMs?: number;
}

export interface NewWordInput {
  term: string;
  phonetic?: string;
  definition?: string;
  definition2?: string;
  example?: string;
  /** Translation of `example`; same optionality as `phonetic`. */
  exampleZh?: string;
  note?: string;
  tags?: string[];
  listId: string;
  status?: WordStatus;
  favorite?: boolean;
}

export interface GradeResult {
  srs: SrsState;
  status: WordStatus;
  /** Id of the review log entry this grade appended, so it can be undone. */
  logId: string;
}

export interface Store {
  init(): Promise<void>;
  isReady(): boolean;
  get(): AppData;
  subscribe(fn: () => void): () => void;

  createList(input: { name: string; sourceLang: string; targetLang: string }): WordList;
  renameList(id: string, name: string): void;
  deleteList(id: string): void;

  addWord(input: NewWordInput): Word;
  updateWord(id: string, patch: Partial<Word>): void;
  deleteWord(id: string): void;
  deleteWords(ids: string[]): void;
  /** Undo a delete: put the word back together with the review logs it lost. */
  restoreWord(word: Word, logs?: ReviewLog[]): void;
  toggleFavorite(id: string): void;
  bumpListen(id: string): void;

  gradeWord(id: string, grade: Grade, now?: number): GradeResult | null;
  undoReview(
    id: string,
    prevSrs: SrsState | null,
    prevStatus: WordStatus,
    logId: string,
    now?: number,
  ): void;
  setWordStatus(id: string, status: WordStatus): void;
  resetSrs(id: string): void;

  updateSettings(patch: Partial<Settings>): void;
  wipeAll(): Promise<void>;

  getChangesToPush(): ChangeSet;
  pendingChangeCount(): number;
  /** Apply one finished round: settle what we sent, then merge the answer. */
  applyRound(round: SyncRound): void;
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

function withDefaultList(d: AppData, now: number): AppData {
  return {
    ...d,
    lists: [
      {
        id: DEFAULT_LIST_ID,
        name: "我的词库",
        sourceLang: "en",
        targetLang: "zh-CN",
        createdAt: now,
        updatedAt: now,
      },
    ],
  };
}

export function createStore(options: StoreOptions): Store {
  const { persistence, clock = () => Date.now(), seed = seedData } = options;
  const saveDelayMs = options.saveDelayMs ?? 220;

  let data: AppData = emptyData();
  let ready = false;
  let saveTimer: ReturnType<typeof setTimeout> | null = null;
  const listeners = new Set<() => void>();

  function notify() {
    for (const fn of listeners) fn();
  }

  function scheduleSave() {
    if (saveDelayMs <= 0) {
      void persistence.save(data);
      return;
    }
    if (saveTimer) clearTimeout(saveTimer);
    saveTimer = setTimeout(() => {
      saveTimer = null;
      void persistence.save(data);
    }, saveDelayMs);
  }

  function cloneSnapshot(d: AppData): AppData {
    return {
      ...d,
      lists: d.lists.slice(),
      words: d.words.slice(),
      logs: d.logs.slice(),
      settings: { ...d.settings },
      tombstones: cloneTombstones(d.tombstones),
      pending: {
        words: d.pending.words.slice(),
        lists: d.pending.lists.slice(),
        logs: d.pending.logs.slice(),
        settings: d.pending.settings,
      },
    };
  }

  function commit(mutator: (draft: AppData) => void) {
    const draft = cloneSnapshot(data);
    mutator(draft);
    data = draft;
    notify();
    emitLocalChange();
    scheduleSave();
  }

  /** Replace a word rather than mutating it, so older snapshots stay valid. */
  function patchWord(d: AppData, id: string, patch: Partial<Word>): Word | null {
    const at = d.words.findIndex((w) => w.id === id);
    if (at < 0) return null;
    const next = { ...d.words[at], ...patch };
    d.words[at] = next;
    return next;
  }

  function patchList(d: AppData, id: string, patch: Partial<WordList>): WordList | null {
    const at = d.lists.findIndex((l) => l.id === id);
    if (at < 0) return null;
    const next = { ...d.lists[at], ...patch };
    d.lists[at] = next;
    return next;
  }

  async function init(): Promise<void> {
    const snapshot = await persistence.load();
    const migrated = snapshot ? migrateSnapshot(snapshot) : null;
    data = migrated ?? seed(clock());
    if (data.lists.length === 0) data = withDefaultList(data, clock());
    ready = true;
    notify();
    scheduleSave();
  }

  return {
    init,
    isReady: () => ready,
    get: () => data,
    subscribe(fn) {
      listeners.add(fn);
      return () => {
        listeners.delete(fn);
      };
    },

    /* ---------------------------------------------------------------- */
    /* Lists                                                             */
    /* ---------------------------------------------------------------- */

    createList(input) {
      const now = clock();
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
        journal.touch(d, "list", list.id);
      });
      return list;
    },

    renameList(id, name) {
      commit((d) => {
        const list = d.lists.find((l) => l.id === id);
        if (!list) return;
        patchList(d, id, { name: name.trim() || list.name, updatedAt: clock() });
        journal.touch(d, "list", id);
      });
    },

    deleteList(id) {
      const now = clock();
      commit((d) => {
        const doomed = d.words.filter((w) => w.listId === id).map((w) => w.id);
        d.lists = d.lists.filter((l) => l.id !== id);
        // One cascade for words *and* their review logs — the same declaration
        // every other delete uses.
        journal.purgeWords(d, doomed, now);
        journal.bury(d, "list", id, now);
      });
    },

    /* ---------------------------------------------------------------- */
    /* Words                                                             */
    /* ---------------------------------------------------------------- */

    addWord(input) {
      const list = data.lists.find((l) => l.id === input.listId) ?? data.lists[0];
      const now = clock();
      const word: Word = {
        id: uid("w"),
        term: input.term.trim(),
        phonetic: (input.phonetic ?? "").trim(),
        definition: (input.definition ?? "").trim(),
        definition2: (input.definition2 ?? "").trim(),
        example: (input.example ?? "").trim(),
        exampleZh: (input.exampleZh ?? "").trim() || undefined,
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
        journal.touch(d, "word", word.id);
      });
      return word;
    },

    updateWord(id, patch) {
      commit((d) => {
        const next: Partial<Word> = { ...patch, updatedAt: clock() };
        if (patch.tags) next.tags = dedupeTags(patch.tags);
        if (!patchWord(d, id, next)) return;
        journal.touch(d, "word", id);
      });
    },

    deleteWord(id) {
      const now = clock();
      commit((d) => journal.purgeWords(d, [id], now));
    },

    deleteWords(ids) {
      const now = clock();
      commit((d) => journal.purgeWords(d, ids, now));
    },

    restoreWord(word, logs = []) {
      const now = clock();
      commit((d) => {
        // Already back (double-clicked undo, or the word was re-added by hand).
        if (d.words.some((w) => w.id === word.id)) return;
        // Undo has to un-bury what the delete buried, or the next sync round
        // would push a tombstone for a word the user can see in the list.
        delete d.tombstones.words[word.id];
        d.words.unshift({ ...word, updatedAt: now });
        journal.touch(d, "word", word.id);
        for (const log of logs) {
          if (d.logs.some((l) => l.id === log.id)) continue;
          delete d.tombstones.logs[log.id];
          d.logs.push({ ...log });
          journal.touch(d, "log", log.id);
        }
      });
    },

    toggleFavorite(id) {
      commit((d) => {
        const w = d.words.find((x) => x.id === id);
        if (!w) return;
        patchWord(d, id, { favorite: !w.favorite, updatedAt: clock() });
        journal.touch(d, "word", id);
      });
    },

    bumpListen(id) {
      commit((d) => {
        const w = d.words.find((x) => x.id === id);
        if (!w) return;
        patchWord(d, id, { listenCount: w.listenCount + 1, updatedAt: clock() });
        journal.touch(d, "word", id);
      });
    },

    /* ---------------------------------------------------------------- */
    /* Reviewing                                                         */
    /* ---------------------------------------------------------------- */

    gradeWord(id, grade, now = clock()) {
      const word = data.words.find((w) => w.id === id);
      if (!word) return null;
      // The whole decision (schedule, never-demote, log contents) is srs.ts's;
      // this wrapper only persists it.
      const { srs, status, log } = reviewCard(
        { srs: word.srs, status: word.status },
        grade,
        now,
        { wordId: id, logId: uid("r") },
      );
      commit((d) => {
        if (!patchWord(d, id, { srs, status, updatedAt: now })) return;
        d.logs = [...d.logs, log];
        journal.touch(d, "word", id);
        journal.touch(d, "log", log.id);
      });
      // `status` is the promoted status that was stored, not the raw interval
      // status — callers should see the same value the snapshot now holds.
      return { srs, status, logId: log.id };
    },

    /**
     * Roll back a single grade: restore the schedule the word had before, put
     * the status back exactly as it was (including the "never demote"
     * behaviour, which a plain recompute would get wrong) and drop the log.
     * The inverse lives in `srs.undoGrade`; this is the persistence half.
     */
    undoReview(id, prevSrs, prevStatus, logId, now = clock()) {
      const restored = undoGrade({ srs: prevSrs, status: prevStatus }, { id: logId });
      commit((d) => {
        if (
          !patchWord(d, id, {
            srs: restored.srs,
            status: restored.status,
            updatedAt: now,
          })
        ) {
          return;
        }
        journal.touch(d, "word", id);
        d.logs = d.logs.filter((log) => log.id !== restored.removedLogId);
        journal.bury(d, "log", restored.removedLogId, now);
      });
    },

    setWordStatus(id, status) {
      commit((d) => {
        if (!patchWord(d, id, { status, updatedAt: clock() })) return;
        journal.touch(d, "word", id);
      });
    },

    /** Manually reset a card's schedule back to "new". */
    resetSrs(id) {
      commit((d) => {
        if (!patchWord(d, id, { srs: null, status: "new", updatedAt: clock() })) return;
        journal.touch(d, "word", id);
      });
    },

    /* ---------------------------------------------------------------- */
    /* Settings & data                                                   */
    /* ---------------------------------------------------------------- */

    updateSettings(patch) {
      commit((d) => {
        d.settings = { ...d.settings, ...patch };
        journal.touchSettings(d, clock());
      });
    },

    async wipeAll() {
      await persistence.clear();
      const now = clock();
      // A wipe has to travel like any other delete. Dropping the records
      // silently would leave no tombstones, so the next sign-in would pull the
      // whole library straight back from the server. Every id that goes away
      // is therefore buried in the fresh snapshot.
      const wiped = withDefaultList(emptyData(), now);
      for (const word of data.words) journal.bury(wiped, "word", word.id, now);
      for (const log of data.logs) journal.bury(wiped, "log", log.id, now);
      for (const list of data.lists) {
        if (list.id !== DEFAULT_LIST_ID) journal.bury(wiped, "list", list.id, now);
      }
      // The fresh snapshot recreates the default list under this same fixed id,
      // so that id is not deleted — a tombstone would tell the server to drop
      // the list we just made, and the echoed delete would remove it locally
      // too. It is pushed as an edit instead, which also resets the name.
      journal.touch(wiped, "list", DEFAULT_LIST_ID);
      data = wiped;
      notify();
      scheduleSave();
    },

    /* ---------------------------------------------------------------- */
    /* Sync bridge                                                       */
    /* ---------------------------------------------------------------- */

    getChangesToPush: () => collectChanges(data),
    pendingChangeCount: () => journal.pendingTotal(data),

    /**
     * Apply one finished sync round. The settle-then-merge order lives in
     * `applyRound`, so no caller can get it wrong.
     */
    applyRound(round) {
      // Deliberately no `emitLocalChange`: a round is the server talking, not
      // the user, and echoing it would schedule another 2.5s round every push.
      data = applyRoundToData(data, round);
      notify();
      scheduleSave();
    },
  };
}

/* ------------------------------------------------------------------ */
/* The app's single instance                                          */
/* ------------------------------------------------------------------ */

const store = createStore({
  persistence: { load: loadSnapshot, save: saveSnapshot, clear: clearSnapshot },
  seed: seedData,
});

/** Load the snapshot once at boot; first run seeds a demo deck. */
export const initStore = store.init;
export const isReady = store.isReady;
export const getData = store.get;
export const createList = store.createList;
export const renameList = store.renameList;
export const deleteList = store.deleteList;
export const addWord = store.addWord;
export const updateWord = store.updateWord;
export const deleteWord = store.deleteWord;
export const deleteWords = store.deleteWords;
export const restoreWord = store.restoreWord;
export const toggleFavorite = store.toggleFavorite;
export const bumpListen = store.bumpListen;
export const gradeWord = store.gradeWord;
export const undoReview = store.undoReview;
export const setWordStatus = store.setWordStatus;
export const resetSrs = store.resetSrs;
export const updateSettings = store.updateSettings;
export const wipeAll = store.wipeAll;
export const getChangesToPush = store.getChangesToPush;
export const pendingChangeCount = store.pendingChangeCount;
export const applyRound = store.applyRound;

/** Subscribe a component to the whole snapshot (cheap: shallow object identity). */
export function useAppData(): AppData {
  return useSyncExternalStore(store.subscribe, store.get, store.get);
}

export function useSettings(): Settings {
  return useAppData().settings;
}

/* ------------------------------------------------------------------ */
/* Selectors (pure: take the snapshot, return a projection)            */
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

export function findDuplicate(d: AppData, term: string, listId?: string): Word | undefined {
  const key = normalizeTerm(term);
  return d.words.find(
    (w) => normalizeTerm(w.term) === key && (!listId || w.listId === listId),
  );
}

export { freshSrs, pendingCount };
/* Day activity lives in its own pure module (the word index needs it too);
   re-exported here so the sidebar and study pages keep one import site. */
export { reviewsToday, streakDays } from "./dayStats";
