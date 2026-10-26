/** Core domain types for Lexilo. Persisted as a single versioned snapshot. */

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
}

export interface AppData {
  version: number;
  lists: WordList[];
  words: Word[];
  logs: ReviewLog[];
  settings: Settings;
}

export const DATA_VERSION = 1;

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
};

export const STATUS_ORDER: WordStatus[] = ["new", "reviewing", "learning", "mastered"];

export const STATUS_LABEL_KEY: Record<WordStatus, string> = {
  new: "status.new",
  reviewing: "status.reviewing",
  learning: "status.learning",
  mastered: "status.mastered",
};
