import { describe, expect, it } from "vitest";
import { applyRemote, collectChanges } from "./syncMerge";
import { decodeChangeSet, encodeAppData, encodeChangeSet } from "./wire";
import { exportJson, parseImport } from "./transfer";
import {
  DATA_VERSION,
  DEFAULT_LIST_ID,
  DEFAULT_SETTINGS,
  type AppData,
  type Word,
  type WordList,
} from "./types";

/* ------------------------------------------------------------------ */
/* Fixtures                                                            */
/* ------------------------------------------------------------------ */

function word(id: string, updatedAt: number, patch: Partial<Word> = {}): Word {
  return {
    id,
    term: id,
    definition: "",
    definition2: "",
    example: "",
    note: "",
    status: "new",
    favorite: false,
    tags: [],
    listId: DEFAULT_LIST_ID,
    sourceLang: "en",
    targetLang: "zh-CN",
    listenCount: 0,
    srs: null,
    createdAt: 1_000,
    updatedAt,
    ...patch,
  };
}

function list(id: string, updatedAt: number, patch: Partial<WordList> = {}): WordList {
  return {
    id,
    name: id,
    sourceLang: "en",
    targetLang: "zh-CN",
    createdAt: 1_000,
    updatedAt,
    ...patch,
  };
}

function data(patch: Partial<AppData> = {}): AppData {
  return {
    version: DATA_VERSION,
    lists: [],
    words: [],
    logs: [],
    settings: { ...DEFAULT_SETTINGS },
    settingsUpdatedAt: 0,
    tombstones: { words: {}, lists: {}, logs: {} },
    pending: { words: [], lists: [], logs: [], settings: false },
    ...patch,
  };
}

/** What the server actually answers: every record stamped with its revision. */
function wireWord(id: string, updatedAt: number, rev = 11): Word & { _rev: number } {
  return { ...word(id, updatedAt), _rev: rev };
}

const hasRev = (value: unknown): boolean => JSON.stringify(value).includes("_rev");

/* ------------------------------------------------------------------ */
/* decode: server bookkeeping never reaches the snapshot               */
/* ------------------------------------------------------------------ */

describe("decodeChangeSet strips server bookkeeping", () => {
  it("removes _rev from every record kind", () => {
    const decoded = decodeChangeSet({
      words: [wireWord("w1", 10), { id: "w2", updatedAt: 20, deleted: true, _rev: 12 }],
      lists: [{ ...list("l1", 30), _rev: 13 }],
      logs: [
        { id: "g1", wordId: "w1", grade: "good", at: 40, intervalBefore: 1, intervalAfter: 2, _rev: 14 },
        { id: "g2", at: 50, deleted: true, _rev: 15 },
      ],
      settings: { ...DEFAULT_SETTINGS, updatedAt: 60, _rev: 16 },
    });

    expect(hasRev(decoded)).toBe(false);
    expect(decoded.words).toEqual([word("w1", 10), { id: "w2", updatedAt: 20, deleted: true }]);
    expect(decoded.lists).toEqual([list("l1", 30)]);
    expect(decoded.logs).toEqual([
      { id: "g1", wordId: "w1", grade: "good", at: 40, intervalBefore: 1, intervalAfter: 2 },
      { id: "g2", at: 50, deleted: true },
    ]);
    expect(decoded.settings).toEqual({ ...DEFAULT_SETTINGS, updatedAt: 60 });
  });

  it("drops unknown keys instead of copying them", () => {
    const decoded = decodeChangeSet({
      words: [{ ...wireWord("w1", 10), mystery: "nope" }],
      lists: [{ ...list("l1", 20), mystery: "nope" }],
      logs: [
        {
          id: "g1",
          wordId: "w1",
          grade: "good",
          at: 30,
          intervalBefore: 1,
          intervalAfter: 2,
          mystery: "nope",
        },
      ],
      settings: { ...DEFAULT_SETTINGS, updatedAt: 40, mystery: "nope" },
    });

    expect(JSON.stringify(decoded)).not.toContain("mystery");
    expect(decoded.words[0]).not.toHaveProperty("mystery");
    expect(decoded.settings).not.toHaveProperty("mystery");
  });

  it("fills optional fields a sparse record omits with domain defaults", () => {
    const decoded = decodeChangeSet({
      words: [{ id: "w1", term: "hola", updatedAt: 10 }],
      settings: { updatedAt: 20 },
    });

    // A sparse record must not reach the snapshot with `undefined` fields: the
    // UI and the JSON backup read these unconditionally.
    const w = decoded.words[0] as Word;
    expect(w).toMatchObject({ id: "w1", term: "hola", updatedAt: 10 });
    expect(w.definition).toBe("");
    expect(w.tags).toEqual([]);
    expect(w.srs).toBeNull();
    expect(w.status).toBe("new");
    expect(decoded.settings).toMatchObject({ updatedAt: 20, theme: "system" });
    expect(Object.values(decoded.settings ?? {})).not.toContain(undefined);
  });
});

/* ------------------------------------------------------------------ */
/* decode: malformed records are dropped, not merged                   */
/* ------------------------------------------------------------------ */

describe("decodeChangeSet rejects malformed records", () => {
  it("drops records without an id or without their merge stamp", () => {
    const decoded = decodeChangeSet({
      words: [
        { term: "no id", updatedAt: 1 },
        { id: "", term: "empty id", updatedAt: 1 },
        { id: "w1", term: "no stamp" },
        { id: "w2", term: "bad stamp", updatedAt: "soon" },
      ],
    });

    expect(decoded.words).toEqual([]);
  });

  it("drops records of the wrong kind", () => {
    const decoded = decodeChangeSet({
      // A review log in the words bucket has no `term`; a word in the logs
      // bucket has no `wordId`/`at`. Neither can be merged by its bucket's rule.
      words: [{ id: "g1", wordId: "w1", grade: "good", at: 5 }],
      lists: [{ id: "l1", updatedAt: 5 }],
      logs: [word("w1", 5)],
    });

    expect(decoded.words).toEqual([]);
    expect(decoded.lists).toEqual([]);
    expect(decoded.logs).toEqual([]);
  });

  it("drops a malformed settings record", () => {
    expect(decodeChangeSet({ settings: { dailyGoal: 5 } }).settings).toBeNull();
    expect(decodeChangeSet({ settings: "nope" }).settings).toBeNull();
  });

  it("never throws on garbage", () => {
    expect(decodeChangeSet(null)).toEqual({ words: [], lists: [], logs: [], settings: null });
    expect(decodeChangeSet([1, 2, 3])).toEqual({ words: [], lists: [], logs: [], settings: null });
    expect(decodeChangeSet({ words: "nope", lists: 5, logs: {}, settings: 7 })).toEqual({
      words: [],
      lists: [],
      logs: [],
      settings: null,
    });
    expect(decodeChangeSet({ words: [null, 3, {}] }).words).toEqual([]);
  });
});

/* ------------------------------------------------------------------ */
/* encode: nothing leaves the client that is not domain data           */
/* ------------------------------------------------------------------ */

describe("encodeChangeSet", () => {
  it("never emits _rev, even from a snapshot persisted before the fix", () => {
    const polluted = { ...word("w1", 5), _rev: 7 } as unknown as Word;
    const pollutedList = { ...list("l1", 6), _rev: 8 } as unknown as WordList;
    const d = data({
      words: [polluted],
      lists: [pollutedList],
      pending: { words: ["w1"], lists: ["l1"], logs: [], settings: false },
    });

    const encoded = encodeChangeSet(collectChanges(d));

    expect(hasRev(encoded)).toBe(false);
    expect(encoded.words).toEqual([word("w1", 5)]);
    expect(encoded.lists).toEqual([list("l1", 6)]);
    // Settle compares these stamps against the local copy, so rebuilding must
    // preserve them exactly.
    expect((encoded.words[0] as Word).updatedAt).toBe(5);
  });

  it("is idempotent after decode", () => {
    const raw = {
      words: [wireWord("w1", 10)],
      lists: [{ ...list("l1", 20), _rev: 3 }],
      logs: [{ id: "g1", wordId: "w1", grade: "easy", at: 30, intervalBefore: 1, intervalAfter: 2, _rev: 4 }],
      settings: { ...DEFAULT_SETTINGS, updatedAt: 40, _rev: 5 },
    };

    const decoded = decodeChangeSet(raw);
    const once = encodeChangeSet(decoded);
    const twice = encodeChangeSet(once);

    expect(once).toEqual(decoded);
    expect(twice).toEqual(once);
    expect(hasRev(twice)).toBe(false);
  });
});

/* ------------------------------------------------------------------ */
/* The leak that motivated this module                                 */
/* ------------------------------------------------------------------ */

describe("applyRemote consumes decoded records", () => {
  it("does not persist _rev into the snapshot", () => {
    const raw = {
      words: [wireWord("w1", 10)],
      lists: [{ ...list("l1", 20), _rev: 3 }],
      logs: [{ id: "g1", wordId: "w1", grade: "good", at: 30, intervalBefore: 1, intervalAfter: 2, _rev: 4 }],
      settings: { ...DEFAULT_SETTINGS, dailyGoal: 42, updatedAt: 40, _rev: 5 },
    };

    const next = applyRemote(data(), decodeChangeSet(raw));

    expect(hasRev(next)).toBe(false);
    expect(next.words[0].term).toBe("w1");
    expect(next.lists[0].name).toBe("l1");
    expect(next.logs[0].id).toBe("g1");
    expect(next.settings.dailyGoal).toBe(42);
  });
});

/* ------------------------------------------------------------------ */
/* JSON backup                                                         */
/* ------------------------------------------------------------------ */

describe("JSON backup", () => {
  it("exports only the user's data, never sync bookkeeping", () => {
    const polluted = { ...word("w1", 5, { term: "hola" }), _rev: 9 } as unknown as Word;
    const d = data({
      words: [polluted],
      tombstones: { words: { gone: 1 }, lists: {}, logs: {} },
      pending: { words: ["w1"], lists: [], logs: [], settings: false },
    });

    const text = exportJson(d);
    const parsed = JSON.parse(text) as Record<string, unknown>;

    expect(Object.keys(parsed).sort()).toEqual([
      "lists",
      "logs",
      "settings",
      "settingsUpdatedAt",
      "version",
      "words",
    ]);
    expect(parsed.pending).toBeUndefined();
    expect(parsed.tombstones).toBeUndefined();
    expect(hasRev(parsed)).toBe(false);
    expect((parsed.words as Word[])[0].term).toBe("hola");
  });

  it("still imports a backup written before pending/tombstones were dropped", () => {
    const legacy = JSON.stringify({
      version: DATA_VERSION,
      lists: [list("l1", 1)],
      words: [word("w1", 2, { term: "hola" })],
      logs: [],
      settings: { ...DEFAULT_SETTINGS },
      settingsUpdatedAt: 3,
      tombstones: { words: { gone: 1 }, lists: {}, logs: {} },
      pending: { words: ["w1"], lists: [], logs: [], settings: false },
    });

    const result = parseImport(legacy, DEFAULT_LIST_ID);

    expect(result.format).toBe("json");
    expect(result.skipped).toBe(0);
    expect(result.words).toHaveLength(1);
    expect(result.words[0].term).toBe("hola");
  });

  it("round-trips its own export", () => {
    const d = data({ words: [word("w1", 5, { term: "hola" }), word("w2", 6, { term: "adios" })] });

    const result = parseImport(exportJson(d), DEFAULT_LIST_ID);

    expect(result.words.map((w) => w.term)).toEqual(["hola", "adios"]);
  });
});

/* ------------------------------------------------------------------ */
/* Snapshot projection                                                 */
/* ------------------------------------------------------------------ */

describe("encodeAppData", () => {
  it("scrubs server keys from every record but keeps the snapshot shape", () => {
    const polluted = { ...word("w1", 5), _rev: 9 } as unknown as Word;
    const d = data({
      words: [polluted],
      tombstones: { words: { gone: 1 }, lists: {}, logs: {} },
      pending: { words: ["w1"], lists: [], logs: [], settings: false },
    });

    const clean = encodeAppData(d);

    expect(hasRev(clean.words)).toBe(false);
    expect(clean.words).toEqual([word("w1", 5)]);
    // Sync bookkeeping is not the backup's business, but this projection is
    // not the place that decides it — transfer omits it.
    expect(clean.pending.words).toEqual(["w1"]);
    expect(clean.tombstones.words.gone).toBe(1);
  });
});
