/**
 * Data transfer helpers: JSON snapshots, CSV, and Anki TXT.
 *
 * Only *types* are imported from the store (`import type`), so this module
 * stays free of runtime store code and cannot create a circular dependency.
 * `wire` is a pure edge module with no imports of its own beyond types.
 */
import type { AppData, Word, WordStatus } from "./types";
import type { NewWordInput } from "./store";
import { encodeAppData } from "./wire";

export interface ImportResult {
  words: NewWordInput[];
  skipped: number;
  format: "json" | "csv" | "anki" | "unknown";
}

const CSV_COLUMNS = [
  "term",
  "pos",
  "definition",
  "definition2",
  "example",
  "exampleTranslation",
  "note",
  "status",
] as const;

/* ------------------------------------------------------------------ */
/* Export                                                              */
/* ------------------------------------------------------------------ */

/**
 * JSON backup: the user's data, and only the user's data.
 *
 * `pending` and `tombstones` belong to the sync engine — importing a file that
 * carried them would resurrect stale flags, and `_rev` is server bookkeeping
 * that must never be mistaken for a field of a word. The records are rebuilt
 * through the wire edge, which also scrubs `_rev` from snapshots saved before
 * the client stopped merging raw wire records.
 *
 * `parseImport` reads only `words`, so the extra fields it does not read are
 * dropped on import by construction; old backups that contain `pending` /
 * `tombstones` still import.
 */
export function exportJson(data: AppData): string {
  const clean = encodeAppData(data);
  return JSON.stringify(
    {
      version: clean.version,
      lists: clean.lists,
      words: clean.words,
      logs: clean.logs,
      settings: clean.settings,
      settingsUpdatedAt: clean.settingsUpdatedAt,
    },
    null,
    2,
  );
}

function csvCell(value: string): string {
  return /[",\r\n]/.test(value) ? `"${value.replace(/"/g, '""')}"` : value;
}

/** CSV with a stable header row. */
export function exportCsv(words: Word[]): string {
  const rows: string[] = [CSV_COLUMNS.join(",")];
  for (const word of words) {
    rows.push(
      [
        csvCell(word.term),
        csvCell(word.pos ?? ""),
        csvCell(word.definition),
        csvCell(word.definition2),
        csvCell(word.example),
        csvCell(word.exampleZh ?? ""),
        csvCell(word.note),
        csvCell(word.status),
      ].join(","),
    );
  }
  // A BOM keeps Excel happy with CJK text; parseImport strips it again.
  return `\uFEFF${rows.join("\r\n")}\r\n`;
}

/* ------------------------------------------------------------------ */
/* Import                                                              */
/* ------------------------------------------------------------------ */

/** Detect the format of `text` and turn it into store-ready word inputs. */
export function parseImport(text: string, listId: string): ImportResult {
  const raw = text.replace(/^\uFEFF/, "").trim();
  if (!raw) return { words: [], skipped: 0, format: "unknown" };

  if (raw.startsWith("{") || raw.startsWith("[")) {
    const json = parseJsonImport(raw, listId);
    if (json) return json;
  }

  // Tabs are a strong Anki signal and must win over commas inside definitions.
  const firstLine = raw.split(/\r?\n/, 1)[0] ?? "";
  if (firstLine.includes("\t")) return parseAnkiImport(raw, listId);
  if (firstLine.includes(",")) return parseCsvImport(raw, listId);
  if (raw.includes("\t")) return parseAnkiImport(raw, listId);
  return { words: [], skipped: 0, format: "unknown" };
}

function parseJsonImport(text: string, listId: string): ImportResult | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return null;
  }

  const root = asRecord(parsed);
  const rawWords =
    root && Array.isArray(root.words) ? root.words : Array.isArray(parsed) ? parsed : null;
  if (!rawWords) return null;

  const words: NewWordInput[] = [];
  let skipped = 0;
  for (const item of rawWords) {
    const rec = asRecord(item);
    const term = rec ? asString(rec.term) : "";
    if (!term) {
      skipped += 1;
      continue;
    }
    words.push({
      term,
      pos: asString(rec?.pos) || undefined,
      definition: asString(rec?.definition),
      definition2: asString(rec?.definition2),
      example: asString(rec?.example),
      exampleZh: asString(rec?.exampleZh) || undefined,
      note: asString(rec?.note),
      status: asStatus(rec?.status),
      favorite: rec?.favorite === true,
      listId,
    });
  }
  return { words, skipped, format: "json" };
}

function parseCsvImport(text: string, listId: string): ImportResult {
  const rows = parseCsvRows(text);
  if (rows.length === 0) return { words: [], skipped: 0, format: "csv" };

  const header = rows[0].map((cell) => cell.trim().toLowerCase());
  const find = (...aliases: string[]) =>
    header.findIndex((cell) => aliases.includes(cell));

  const termIdx = find("term", "word", "词语", "单词");
  const posIdx = find("pos", "part of speech", "partofspeech", "词性");
  const defIdx = find("definition", "meaning", "释义", "意思");
  const def2Idx = find("definition2", "definition_2", "second definition", "补充释义");
  const exampleIdx = find("example", "sentence", "例句");
  const exampleZhIdx = find(
    "exampletranslation",
    "example_zh",
    "examplezh",
    "例句翻译",
    "例句译文",
  );
  const noteIdx = find("note", "notes", "备注", "笔记");
  const statusIdx = find("status", "状态");
  const start = termIdx >= 0 ? 1 : 0;

  const words: NewWordInput[] = [];
  let skipped = 0;
  for (let r = start; r < rows.length; r += 1) {
    const row = rows[r];
    const term = cellAt(row, termIdx >= 0 ? termIdx : 0);
    if (!term) {
      skipped += 1;
      continue;
    }
    words.push({
      term,
      pos: cellAt(row, posIdx) || undefined,
      definition: cellAt(row, defIdx),
      definition2: cellAt(row, def2Idx),
      example: cellAt(row, exampleIdx),
      exampleZh: cellAt(row, exampleZhIdx) || undefined,
      note: cellAt(row, noteIdx),
      status: asStatus(cellAt(row, statusIdx)),
      listId,
    });
  }
  return { words, skipped, format: "csv" };
}

/** RFC-4180-ish CSV reader: quoted fields, doubled quotes, CRLF or LF. */
function parseCsvRows(text: string): string[][] {
  const src = text.replace(/^\uFEFF/, "");
  const rows: string[][] = [];
  let row: string[] = [];
  let field = "";
  let inQuotes = false;

  for (let i = 0; i < src.length; i += 1) {
    const ch = src[i];
    if (inQuotes) {
      if (ch === '"') {
        if (src[i + 1] === '"') {
          field += '"';
          i += 1;
        } else {
          inQuotes = false;
        }
      } else {
        field += ch;
      }
    } else if (ch === '"') {
      inQuotes = true;
    } else if (ch === ",") {
      row.push(field);
      field = "";
    } else if (ch === "\n" || ch === "\r") {
      if (ch === "\r" && src[i + 1] === "\n") i += 1;
      row.push(field);
      field = "";
      rows.push(row);
      row = [];
    } else {
      field += ch;
    }
  }
  if (field.length > 0 || row.length > 0) {
    row.push(field);
    rows.push(row);
  }
  return rows;
}

function parseAnkiImport(text: string, listId: string): ImportResult {
  const words: NewWordInput[] = [];
  let skipped = 0;
  for (const line of text.split(/\r?\n/)) {
    if (!line.trim()) continue;
    const parts = line.split("\t");
    if (parts.length < 2) {
      skipped += 1;
      continue;
    }
    const term = stripHtml(parts[0]);
    const definition = stripHtml(parts.slice(1).join(" "));
    if (!term) {
      skipped += 1;
      continue;
    }
    words.push({
      term,
      definition,
      definition2: "",
      example: "",
      note: "",
      listId,
    });
  }
  return { words, skipped, format: "anki" };
}

/* ------------------------------------------------------------------ */
/* Small coercion helpers                                              */
/* ------------------------------------------------------------------ */

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function asString(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function asStatus(value: unknown): WordStatus | undefined {
  return value === "new" || value === "reviewing" || value === "learning" || value === "mastered"
    ? value
    : undefined;
}

function cellAt(row: string[], index: number): string {
  if (index < 0 || index >= row.length) return "";
  return (row[index] ?? "").trim();
}

function stripHtml(input: string): string {
  return input
    .replace(/<[^>]*>/g, " ")
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/g, "'")
    .replace(/\s+/g, " ")
    .trim();
}
