import { describe, expect, it } from "vitest";
import { applyRemote, collectChanges, hasChanges, pendingCount } from "./syncMerge";
import {
  DATA_VERSION,
  DEFAULT_SETTINGS,
  EMPTY_PENDING,
  EMPTY_TOMBSTONES,
  type AppData,
  type ChangeSet,
  type ReviewLog,
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
    listId: "list_default",
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

function log(id: string, at: number, patch: Partial<ReviewLog> = {}): ReviewLog {
  return {
    id,
    wordId: "w1",
    grade: "good",
    at,
    intervalBefore: 1,
    intervalAfter: 2,
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
    tombstones: { ...EMPTY_TOMBSTONES, words: {}, lists: {}, logs: {} },
    pending: { ...EMPTY_PENDING, words: [], lists: [], logs: [] },
    ...patch,
  };
}

function emptyChanges(): ChangeSet {
  return { words: [], lists: [], logs: [], settings: null };
}

/* ------------------------------------------------------------------ */
/* collectChanges                                                      */
/* ------------------------------------------------------------------ */

describe("collectChanges", () => {
  it("returns nothing when nothing is pending", () => {
    const changes = collectChanges(data({ words: [word("w1", 5)] }));
    expect(hasChanges(changes)).toBe(false);
    expect(pendingCount(data())).toBe(0);
  });

  it("includes pending words, lists, logs and settings", () => {
    const d = data({
      words: [word("w1", 5)],
      lists: [list("l1", 6)],
      logs: [log("g1", 7)],
      settingsUpdatedAt: 8,
      pending: { words: ["w1"], lists: ["l1"], logs: ["g1"], settings: true },
    });
    const changes = collectChanges(d);
    expect(changes.words).toHaveLength(1);
    expect(changes.lists).toHaveLength(1);
    expect(changes.logs).toHaveLength(1);
    expect(changes.settings?.updatedAt).toBe(8);
    expect(pendingCount(d)).toBe(4);
  });

  it("turns a deleted word into a tombstone record", () => {
    const d = data({
      words: [],
      tombstones: { words: { w9: 42 }, lists: {}, logs: {} },
      pending: { words: ["w9"], lists: [], logs: [], settings: false },
    });
    const changes = collectChanges(d);
    expect(changes.words).toEqual([{ id: "w9", updatedAt: 42, deleted: true }]);
  });

  it("turns a deleted review log into a log tombstone", () => {
    const d = data({
      tombstones: { words: {}, lists: {}, logs: { g9: 33 } },
      pending: { words: [], lists: [], logs: ["g9"], settings: false },
    });
    expect(collectChanges(d).logs).toEqual([{ id: "g9", at: 33, deleted: true }]);
  });

  it("skips ids that are pending but no longer exist", () => {
    const d = data({ pending: { words: ["ghost"], lists: [], logs: [], settings: false } });
    expect(collectChanges(d).words).toHaveLength(0);
  });
});

/* ------------------------------------------------------------------ */
/* applyRemote — words                                                 */
/* ------------------------------------------------------------------ */

describe("applyRemote words", () => {
  it("adds a word the device has never seen", () => {
    const next = applyRemote(data(), { ...emptyChanges(), words: [word("w1", 10)] });
    expect(next.words.map((w) => w.id)).toEqual(["w1"]);
  });

  it("takes the newer remote copy (LWW)", () => {
    const next = applyRemote(data({ words: [word("w1", 5, { definition: "old" })] }), {
      ...emptyChanges(),
      words: [word("w1", 9, { definition: "new" })],
    });
    expect(next.words[0].definition).toBe("new");
  });

  it("ignores an older remote copy", () => {
    const next = applyRemote(data({ words: [word("w1", 9, { definition: "mine" })] }), {
      ...emptyChanges(),
      words: [word("w1", 5, { definition: "theirs" })],
    });
    expect(next.words[0].definition).toBe("mine");
  });

  it("keeps a pending local edit that is newer than the pushed echo", () => {
    const local = data({
      words: [word("w1", 20, { definition: "edited during sync" })],
      pending: { ...EMPTY_PENDING, words: ["w1"] },
    });
    const next = applyRemote(local, { ...emptyChanges(), words: [word("w1", 10)] });
    expect(next.words[0].definition).toBe("edited during sync");
    expect(next.pending.words).toContain("w1");
  });

  it("applies a remote tombstone", () => {
    const next = applyRemote(data({ words: [word("w1", 5)] }), {
      ...emptyChanges(),
      words: [{ id: "w1", updatedAt: 9, deleted: true }],
    });
    expect(next.words).toHaveLength(0);
    expect(next.tombstones.words.w1).toBe(9);
  });

  it("keeps a local word that was deleted more recently than the remote edit", () => {
    const local = data({
      words: [],
      tombstones: { words: { w1: 30 }, lists: {}, logs: {} },
    });
    const next = applyRemote(local, { ...emptyChanges(), words: [word("w1", 20)] });
    expect(next.words).toHaveLength(0);
  });

  it("resurrects a word when the remote edit is newer than the local tombstone", () => {
    const local = data({ tombstones: { words: { w1: 5 }, lists: {}, logs: {} } });
    const next = applyRemote(local, { ...emptyChanges(), words: [word("w1", 40)] });
    expect(next.words.map((w) => w.id)).toEqual(["w1"]);
    expect(next.tombstones.words.w1).toBeUndefined();
  });

  it("clears the pending flag once a record is settled", () => {
    const local = data({
      words: [word("w1", 5)],
      pending: { ...EMPTY_PENDING, words: ["w1"] },
    });
    const next = applyRemote(local, { ...emptyChanges(), words: [word("w1", 5)] });
    expect(next.pending.words).not.toContain("w1");
  });
});

/* ------------------------------------------------------------------ */
/* applyRemote — lists                                                 */
/* ------------------------------------------------------------------ */

describe("applyRemote lists", () => {
  it("adds, updates and deletes lists", () => {
    let next = applyRemote(data(), { ...emptyChanges(), lists: [list("l1", 1, { name: "A" })] });
    expect(next.lists[0].name).toBe("A");

    next = applyRemote(next, { ...emptyChanges(), lists: [list("l1", 2, { name: "B" })] });
    expect(next.lists[0].name).toBe("B");

    next = applyRemote(next, {
      ...emptyChanges(),
      lists: [{ id: "l1", updatedAt: 3, deleted: true }],
    });
    expect(next.lists).toHaveLength(0);
    expect(next.tombstones.lists.l1).toBe(3);
  });

  it("ignores a stale list edit", () => {
    const next = applyRemote(data({ lists: [list("l1", 10, { name: "mine" })] }), {
      ...emptyChanges(),
      lists: [list("l1", 2, { name: "theirs" })],
    });
    expect(next.lists[0].name).toBe("mine");
  });
});

/* ------------------------------------------------------------------ */
/* applyRemote — logs                                                  */
/* ------------------------------------------------------------------ */

describe("applyRemote logs", () => {
  it("unions review logs by id", () => {
    const local = data({ logs: [log("g1", 1)] });
    const next = applyRemote(local, { ...emptyChanges(), logs: [log("g1", 1), log("g2", 2)] });
    expect(next.logs.map((l) => l.id).sort()).toEqual(["g1", "g2"]);
  });

  it("applies a log tombstone", () => {
    const local = data({ logs: [log("g1", 1), log("g2", 2)] });
    const next = applyRemote(local, {
      ...emptyChanges(),
      logs: [{ id: "g1", at: 5, deleted: true }],
    });
    expect(next.logs.map((l) => l.id)).toEqual(["g2"]);
    expect(next.tombstones.logs.g1).toBe(5);
  });

  it("does not re-add a log that a tombstone removed", () => {
    const local = data({ tombstones: { words: {}, lists: {}, logs: { g1: 5 } } });
    const next = applyRemote(local, { ...emptyChanges(), logs: [log("g1", 1)] });
    expect(next.logs).toHaveLength(0);
  });

  it("keeps a pending log tombstone that is newer than the remote one", () => {
    const local = data({
      logs: [],
      tombstones: { words: {}, lists: {}, logs: { g1: 20 } },
      pending: { ...EMPTY_PENDING, logs: ["g1"] },
    });
    const next = applyRemote(local, {
      ...emptyChanges(),
      logs: [{ id: "g1", at: 5, deleted: true }],
    });
    expect(next.pending.logs).toContain("g1");
  });
});

/* ------------------------------------------------------------------ */
/* applyRemote — settings                                              */
/* ------------------------------------------------------------------ */

describe("applyRemote settings", () => {
  it("takes newer remote settings", () => {
    const local = data({ settings: { ...DEFAULT_SETTINGS, dailyGoal: 5 }, settingsUpdatedAt: 1 });
    const next = applyRemote(local, {
      ...emptyChanges(),
      settings: { ...DEFAULT_SETTINGS, dailyGoal: 99, updatedAt: 2 },
    });
    expect(next.settings.dailyGoal).toBe(99);
    expect(next.settingsUpdatedAt).toBe(2);
  });

  it("keeps newer local settings", () => {
    const local = data({ settings: { ...DEFAULT_SETTINGS, dailyGoal: 42 }, settingsUpdatedAt: 10 });
    const next = applyRemote(local, {
      ...emptyChanges(),
      settings: { ...DEFAULT_SETTINGS, dailyGoal: 1, updatedAt: 2 },
    });
    expect(next.settings.dailyGoal).toBe(42);
    expect(next.settingsUpdatedAt).toBe(10);
  });

  it("replaces the whole settings record (settings sync as one unit)", () => {
    const local = data({ settings: { ...DEFAULT_SETTINGS, uiLang: "en" }, settingsUpdatedAt: 1 });
    const next = applyRemote(local, {
      ...emptyChanges(),
      settings: { ...DEFAULT_SETTINGS, dailyGoal: 33, updatedAt: 2 },
    });
    expect(next.settings.dailyGoal).toBe(33);
    // The remote record is the newer full snapshot, so its values win wholesale.
    expect(next.settings.uiLang).toBe("zh-CN");
  });
});

/* ------------------------------------------------------------------ */
/* Immutability                                                        */
/* ------------------------------------------------------------------ */

describe("applyRemote immutability", () => {
  it("does not mutate the input snapshot", () => {
    const local = data({ words: [word("w1", 5)] });
    const snapshot = JSON.parse(JSON.stringify(local)) as AppData;
    applyRemote(local, { ...emptyChanges(), words: [word("w1", 99), word("w2", 99)] });
    expect(local).toEqual(snapshot);
  });
});
