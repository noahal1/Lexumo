/** Core domain types for Lexumo. Persisted as a single versioned snapshot. */

import type { MessageKey } from "@/i18n/locales/zh-CN";

export type WordStatus = "new" | "reviewing" | "learning" | "mastered";
export type Grade = "hard" | "good" | "easy";
export type ThemeMode = "light" | "dark" | "system";
export type UiLang = "zh-CN" | "en";

export interface SrsState {
  /** SM-2 ease factor, clamped to [1.3, 2.5]. */
  ease: number;
  /** Current interval in days. */
  intervalDays: number;
  /** Epoch ms when the card is next due. */
  dueAt: number;
  reviewCount: number;
  correctCount: number;
  lastReviewedAt: number | null;
}

export interface Word {
  id: string;
  term: string;
  /**
   * IPA transcription without the slashes, when known. Filled by auto-translate
   * and shown in the list and on the flashcard back. Optional because records
   * written before it existed have none.
   */
  phonetic?: string;
  /** Primary meaning in the target language. */
  definition: string;
  /** Secondary definition / nuance / example translation. */
  definition2: string;
  /** Example sentence using the term. */
  example: string;
  note: string;
  status: WordStatus;
  favorite: boolean;
  tags: string[];
  listId: string;
  sourceLang: string;
  targetLang: string;
  /** Times the word was played as audio (drives the listening ladder). */
  listenCount: number;
  srs: SrsState | null;
  createdAt: number;
  updatedAt: number;
}

export interface WordList {
  id: string;
  name: string;
  sourceLang: string;
  targetLang: string;
  createdAt: number;
  updatedAt: number;
}

export interface ReviewLog {
  id: string;
  wordId: string;
  grade: Grade;
  /** Epoch ms of the review. */
  at: number;
  intervalBefore: number;
  intervalAfter: number;
}

export interface Settings {
  theme: ThemeMode;
  uiLang: UiLang;
  dailyGoal: number;
  ttsRate: number;
  ttsVoiceURI: string;
  autoPlayAudio: boolean;
  /** Show the translation on the flashcard front (listening mode). */
  audioFirst: boolean;
  newCardsPerDay: number;
  reviewOrder: "due" | "random";
  /** Look the term up online and prefill the meaning when adding a word. */
  autoTranslate: boolean;
  /** Push/pull changes automatically while signed in. */
  autoSync: boolean;
}

/**
 * Deletion tombstones. A delete cannot be expressed by absence (the other
 * device would just re-upload the record), so removals are recorded here with
 * the time they happened and pushed to the server like any other change.
 */
export interface Tombstones {
  words: Record<string, number>;
  lists: Record<string, number>;
  logs: Record<string, number>;
}

/** Records that changed locally and still need to be pushed to the server. */
export interface PendingChanges {
  words: string[];
  lists: string[];
  logs: string[];
  settings: boolean;
}

export interface AppData {
  version: number;
  lists: WordList[];
  words: Word[];
  logs: ReviewLog[];
  settings: Settings;
  /** Epoch ms of the last local edit to `settings` (drives LWW on sync). */
  settingsUpdatedAt: number;
  tombstones: Tombstones;
  pending: PendingChanges;
}

export const DATA_VERSION = 2;

export const EMPTY_TOMBSTONES: Tombstones = { words: {}, lists: {}, logs: {} };

export const EMPTY_PENDING: PendingChanges = {
  words: [],
  lists: [],
  logs: [],
  settings: false,
};

/* ------------------------------------------------------------------ */
/* Sync wire format (see docs/sync-protocol.md)                        */
/* ------------------------------------------------------------------ */

/** Minimal record that says "this id was deleted at this time". */
export interface Tombstone {
  id: string;
  updatedAt: number;
  deleted: true;
}

export type WordRecord = Word | Tombstone;
export type ListRecord = WordList | Tombstone;
export type LogRecord = ReviewLog | { id: string; at: number; deleted: true };

export interface SettingsRecord extends Settings {
  updatedAt: number;
}

export interface ChangeSet {
  lists: ListRecord[];
  words: WordRecord[];
  logs: LogRecord[];
  settings: SettingsRecord | null;
}

export const DEFAULT_LIST_ID = "list_default";

export const DEFAULT_SETTINGS: Settings = {
  theme: "system",
  uiLang: "zh-CN",
  dailyGoal: 20,
  ttsRate: 0.95,
  ttsVoiceURI: "",
  autoPlayAudio: true,
  audioFirst: false,
  newCardsPerDay: 15,
  reviewOrder: "due",
  autoTranslate: true,
  autoSync: true,
};

export const STATUS_ORDER: WordStatus[] = ["new", "reviewing", "learning", "mastered"];

export const STATUS_LABEL_KEY: Record<WordStatus, MessageKey> = {
  new: "status.new",
  reviewing: "status.reviewing",
  learning: "status.learning",
  mastered: "status.mastered",
};
