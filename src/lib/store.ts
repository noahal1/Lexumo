/**
 * Application store: a tiny observable snapshot store with
 * useSyncExternalStore, plus all mutations (words, lists, reviews, settings).
 *
 * All writes go through `commit`, which bumps `updatedAt`, notifies
 * subscribers, and schedules a debounced persistence write.
 */
import { useSyncExternalStore } from "react";
import { loadSnapshot, saveSnapshot, clearSnapshot } from "./db";
import { applyGrade, statusForInterval, freshSrs } from "./srs";
import { seedData } from "./seed";
import type {
  AppData,
  Grade,
  ReviewLog,
  Settings,
  SrsState,
  Word,
  WordList,
  WordStatus,
} from "./types";
import { DATA_VERSION, DEFAULT_LIST_ID, DEFAULT_SETTINGS } from "./types";
import { normalizeTerm, uid } from "./utils";

export { DEFAULT_SETTINGS, DEFAULT_LIST_ID };

export function emptyData(): AppData {
  return {
    version: DATA_VERSION,
    lists: [],
    words: [],
    logs: [],
    settings: { ...DEFAULT_SETTINGS },
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
  };
  mutator(draft);
  data = draft;
  notify();
  scheduleSave();
}

/** Load the snapshot once at boot; first run seeds a demo deck. */
export async function initStore(): Promise<void> {
  const snapshot = await loadSnapshot();
  if (snapshot && snapshot.version === DATA_VERSION) {
    data = {
      ...emptyData(),
      ...snapshot,
      settings: { ...DEFAULT_SETTINGS, ...snapshot.settings },
    };
  } else {
    data = seedData();
  }
  if (data.lists.length === 0) {
    data.lists = [
      {
        id: DEFAULT_LIST_ID,
        name: "我的词库",
        sourceLang: "en",
        targetLang: "zh-CN",
        createdAt: Date.now(),
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
  const list: WordList = {
    id: uid("list"),
    name: input.name.trim() || "未命名词库",
    sourceLang: input.sourceLang,
    targetLang: input.targetLang,
    createdAt: Date.now(),
  };
  commit((d) => {
    d.lists.push(list);
  });
  return list;
}

export function renameList(id: string, name: string) {
  commit((d) => {
    const list = d.lists.find((l) => l.id === id);
    if (list) list.name = name.trim() || list.name;
  });
}

export function deleteList(id: string) {
  commit((d) => {
    d.lists = d.lists.filter((l) => l.id !== id);
    d.words = d.words.filter((w) => w.listId !== id);
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
  });
  return word;
}

export function updateWord(id: string, patch: Partial<Word>) {
  commit((d) => {
    const w = d.words.find((x) => x.id === id);
    if (!w) return;
    Object.assign(w, patch, { updatedAt: Date.now() });
    if (patch.tags) w.tags = dedupeTags(patch.tags);
  });
}

export function deleteWord(id: string) {
  commit((d) => {
    d.words = d.words.filter((w) => w.id !== id);
    d.logs = d.logs.filter((l) => l.wordId !== id);
  });
}

export function deleteWords(ids: string[]) {
  const set = new Set(ids);
  commit((d) => {
    d.words = d.words.filter((w) => !set.has(w.id));
    d.logs = d.logs.filter((l) => !set.has(l.wordId));
  });
}

export function toggleFavorite(id: string) {
  commit((d) => {
    const w = d.words.find((x) => x.id === id);
    if (w) {
      w.favorite = !w.favorite;
      w.updatedAt = Date.now();
    }
  });
}

export function bumpListen(id: string) {
  commit((d) => {
    const w = d.words.find((x) => x.id === id);
    if (w) w.listenCount += 1;
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
  });
  return { srs: next, status };
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
    }
  });
}

/* ------------------------------------------------------------------ */
/* Settings & data                                                     */
/* ------------------------------------------------------------------ */

export function updateSettings(patch: Partial<Settings>) {
  commit((d) => {
    d.settings = { ...d.settings, ...patch };
  });
}

export function replaceAll(next: AppData) {
  data = {
    ...emptyData(),
    ...next,
    settings: { ...DEFAULT_SETTINGS, ...next.settings },
  };
  notify();
  scheduleSave();
}

export async function wipeAll() {
  await clearSnapshot();
  data = emptyData();
  data.lists = [
    {
      id: DEFAULT_LIST_ID,
      name: "我的词库",
      sourceLang: "en",
      targetLang: "zh-CN",
      createdAt: Date.now(),
    },
  ];
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
