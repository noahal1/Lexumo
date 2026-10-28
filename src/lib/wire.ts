/**
 * The sync wire edge: the only module that knows what the server sends.
 *
 * The server stamps `_rev` onto every record it returns (docs/sync-protocol.md
 * says clients may ignore it, and this is what ignoring it means). The merge
 * used to put the raw record straight into the snapshot, so `_rev` was
 * persisted as if it were domain data, re-uploaded by the next push, and
 * written into the user's JSON backup.
 *
 * Everything that crosses the network boundary is therefore rebuilt here from
 * the fields the domain types declare. Unknown keys cannot reach `AppData`, and
 * a record that does not look like the record it claims to be is dropped
 * instead of being merged in — one malformed row must not corrupt a snapshot.
 *
 * Pure: no I/O, no module state. `sync.ts` calls this; `syncMerge.applyRemote`
 * only ever sees the decoded result.
 */
import type {
  AppData,
  ChangeSet,
  Grade,
  ListRecord,
  LogRecord,
  ReviewLog,
  Settings,
  SettingsRecord,
  SrsState,
  ThemeMode,
  UiLang,
  Word,
  WordList,
  WordRecord,
  WordStatus,
} from "./types";
import { STATUS_ORDER } from "./types";

type Raw = Record<string, unknown>;

function asRecord(value: unknown): Raw | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Raw)
    : null;
}

/* ------------------------------------------------------------------ */
/* Coercion                                                            */
/* ------------------------------------------------------------------ */

const str = (value: unknown): string => (typeof value === "string" ? value : "");
/**
 * Optional text. Absent, non-string and empty all collapse to `undefined` so a
 * decoded record compares equal to one that never had the field, and so
 * `JSON.stringify` drops the key instead of writing `""`.
 */
const optStr = (value: unknown): string | undefined =>
  typeof value === "string" && value.length > 0 ? value : undefined;
const num = (value: unknown): number =>
  typeof value === "number" && Number.isFinite(value) ? value : 0;
const bool = (value: unknown): boolean => value === true;
const strList = (value: unknown): string[] =>
  Array.isArray(value) ? value.filter((item): item is string => typeof item === "string") : [];

const isStamp = (value: unknown): value is number =>
  typeof value === "number" && Number.isFinite(value);
const hasId = (value: unknown): value is string => typeof value === "string" && value.length > 0;

const GRADES: Grade[] = ["hard", "good", "easy"];
const asGrade = (value: unknown): Grade =>
  GRADES.includes(value as Grade) ? (value as Grade) : "good";

const asStatus = (value: unknown): WordStatus =>
  STATUS_ORDER.includes(value as WordStatus) ? (value as WordStatus) : "new";

const asTheme = (value: unknown): ThemeMode =>
  value === "light" || value === "dark" || value === "system" ? value : "system";

const asUiLang = (value: unknown): UiLang => (value === "en" ? "en" : "zh-CN");

const asSrs = (value: unknown): SrsState | null => {
  const raw = asRecord(value);
  if (!raw) return null;
  return {
    ease: num(raw.ease),
    intervalDays: num(raw.intervalDays),
    dueAt: num(raw.dueAt),
    reviewCount: num(raw.reviewCount),
    correctCount: num(raw.correctCount),
    lastReviewedAt: isStamp(raw.lastReviewedAt) ? raw.lastReviewedAt : null,
  };
};

/* ------------------------------------------------------------------ */
/* Record rebuilders                                                   */
/*                                                                     */
/* These never throw and never copy unknown keys: they are the whole    */
/* reason `_rev` cannot reach the snapshot. Decode validates first,     */
/* encode simply trusts the domain type but rebuilds anyway — a         */
/* snapshot written before this module existed can still carry `_rev`.  */
/* ------------------------------------------------------------------ */

function cleanWord(value: unknown): Word {
  const raw = asRecord(value) ?? {};
  return {
    id: str(raw.id),
    term: str(raw.term),
    phonetic: optStr(raw.phonetic),
    pos: optStr(raw.pos),
    definition: str(raw.definition),
    definition2: str(raw.definition2),
    example: str(raw.example),
    exampleZh: optStr(raw.exampleZh),
    note: str(raw.note),
    status: asStatus(raw.status),
    favorite: bool(raw.favorite),
    tags: strList(raw.tags),
    listId: str(raw.listId),
    sourceLang: str(raw.sourceLang),
    targetLang: str(raw.targetLang),
    listenCount: num(raw.listenCount),
    srs: asSrs(raw.srs),
    createdAt: num(raw.createdAt),
    updatedAt: num(raw.updatedAt),
  };
}

function cleanWordRecord(value: unknown): WordRecord {
  const raw = asRecord(value) ?? {};
  if (raw.deleted === true) {
    return { id: str(raw.id), updatedAt: num(raw.updatedAt), deleted: true };
  }
  return cleanWord(raw);
}

function cleanList(value: unknown): WordList {
  const raw = asRecord(value) ?? {};
  return {
    id: str(raw.id),
    name: str(raw.name),
    sourceLang: str(raw.sourceLang),
    targetLang: str(raw.targetLang),
    createdAt: num(raw.createdAt),
    updatedAt: num(raw.updatedAt),
  };
}

function cleanListRecord(value: unknown): ListRecord {
  const raw = asRecord(value) ?? {};
  if (raw.deleted === true) {
    return { id: str(raw.id), updatedAt: num(raw.updatedAt), deleted: true };
  }
  return cleanList(raw);
}

function cleanLog(value: unknown): ReviewLog {
  const raw = asRecord(value) ?? {};
  return {
    id: str(raw.id),
    wordId: str(raw.wordId),
    grade: asGrade(raw.grade),
    at: num(raw.at),
    intervalBefore: num(raw.intervalBefore),
    intervalAfter: num(raw.intervalAfter),
  };
}

function cleanLogRecord(value: unknown): LogRecord {
  const raw = asRecord(value) ?? {};
  if (raw.deleted === true) {
    return { id: str(raw.id), at: num(raw.at), deleted: true };
  }
  return cleanLog(raw);
}

function cleanSettings(value: unknown): Settings {
  const raw = asRecord(value) ?? {};
  return {
    theme: asTheme(raw.theme),
    uiLang: asUiLang(raw.uiLang),
    dailyGoal: num(raw.dailyGoal),
    ttsRate: num(raw.ttsRate),
    ttsVoiceURI: str(raw.ttsVoiceURI),
    autoPlayAudio: bool(raw.autoPlayAudio),
    audioFirst: bool(raw.audioFirst),
    newCardsPerDay: num(raw.newCardsPerDay),
    reviewOrder: raw.reviewOrder === "random" ? "random" : "due",
    autoTranslate: bool(raw.autoTranslate),
    autoSync: bool(raw.autoSync),
  };
}

function cleanSettingsRecord(value: unknown): SettingsRecord {
  const raw = asRecord(value) ?? {};
  return { ...cleanSettings(raw), updatedAt: num(raw.updatedAt) };
}

/* ------------------------------------------------------------------ */
/* Decode                                                              */
/* ------------------------------------------------------------------ */

/*
 * Minimal shape checks. A record is admitted only when it carries the fields
 * its kind is merged by — a log-shaped object in `words` has no `term`, a
 * record with no `updatedAt` cannot participate in LWW, and neither belongs in
 * the snapshot. The server already rejects most of this (server/src/store.js),
 * so these guards are about the client not trusting a response it did not
 * validate.
 */
const isWord = (raw: Raw): boolean =>
  hasId(raw.id) &&
  (raw.deleted === true
    ? isStamp(raw.updatedAt)
    : typeof raw.term === "string" && isStamp(raw.updatedAt));

const isList = (raw: Raw): boolean =>
  hasId(raw.id) &&
  (raw.deleted === true
    ? isStamp(raw.updatedAt)
    : typeof raw.name === "string" && isStamp(raw.updatedAt));

const isLog = (raw: Raw): boolean =>
  hasId(raw.id) &&
  (raw.deleted === true
    ? isStamp(raw.at)
    : typeof raw.wordId === "string" && isStamp(raw.at) && GRADES.includes(raw.grade as Grade));

function decodeWordRecord(value: unknown): WordRecord | null {
  const raw = asRecord(value);
  return raw && isWord(raw) ? cleanWordRecord(raw) : null;
}

function decodeListRecord(value: unknown): ListRecord | null {
  const raw = asRecord(value);
  return raw && isList(raw) ? cleanListRecord(raw) : null;
}

function decodeLogRecord(value: unknown): LogRecord | null {
  const raw = asRecord(value);
  return raw && isLog(raw) ? cleanLogRecord(raw) : null;
}

const listOf = (value: unknown): unknown[] => (Array.isArray(value) ? value : []);

/**
 * Turn the raw `changes` of a sync response into a domain `ChangeSet`.
 *
 * Malformed records are dropped one by one rather than throwing: a bad row
 * should cost that row, not the whole round — and not the snapshot.
 */
export function decodeChangeSet(raw: unknown): ChangeSet {
  const body = asRecord(raw) ?? {};

  const words: WordRecord[] = [];
  for (const item of listOf(body.words)) {
    const record = decodeWordRecord(item);
    if (record) words.push(record);
  }

  const lists: ListRecord[] = [];
  for (const item of listOf(body.lists)) {
    const record = decodeListRecord(item);
    if (record) lists.push(record);
  }

  const logs: LogRecord[] = [];
  for (const item of listOf(body.logs)) {
    const record = decodeLogRecord(item);
    if (record) logs.push(record);
  }

  const settings = asRecord(body.settings);
  return {
    words,
    lists,
    logs,
    settings: settings && isStamp(settings.updatedAt) ? cleanSettingsRecord(settings) : null,
  };
}

/* ------------------------------------------------------------------ */
/* Encode                                                              */
/* ------------------------------------------------------------------ */

/**
 * The payload sent to the server.
 *
 * Rebuilding is what keeps `_rev` off the wire: `collectChanges` hands over the
 * snapshot's own objects, and a snapshot persisted before this module existed
 * may still contain the key. Rebuilding is also idempotent, so decoding a
 * change set and encoding it again produces the same value.
 */
export function encodeChangeSet(delta: ChangeSet): ChangeSet {
  return {
    words: delta.words.map(cleanWordRecord),
    lists: delta.lists.map(cleanListRecord),
    logs: delta.logs.map(cleanLogRecord),
    settings: delta.settings ? cleanSettingsRecord(delta.settings) : null,
  };
}

/**
 * Project a snapshot for persistence or backup: domain records only.
 *
 * `pending` and `tombstones` are sync bookkeeping and stay with the sync
 * engine; this exists so a backup file can never carry `_rev` even when the
 * snapshot it was taken from still does.
 */
export function encodeAppData(data: AppData): AppData {
  return {
    ...data,
    words: data.words.map(cleanWord),
    lists: data.lists.map(cleanList),
    logs: data.logs.map(cleanLog),
    settings: cleanSettings(data.settings),
  };
}
