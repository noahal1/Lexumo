/**
 * Tests for the change journal — the invariant that "every local edit is
 * pending, every local delete leaves a tombstone".
 *
 * These run against a real `createStore` instance with an in-memory
 * persistence adapter, which is the point of the store factory: the invariant
 * is asserted over actual domain operations instead of hand-built snapshots.
 *
 * The clock is a mutable holder so a test can move time forward between two
 * operations — without that, `updatedAt` comparisons are vacuous (a frozen
 * clock makes "the edit bumped the timestamp" true no matter what).
 */
import { describe, expect, it } from "vitest";
import { createStore, emptyData, type Persistence, type Store } from "./store";
import { pendingTotal, settle } from "./journal";
import { onLocalChange } from "./localChanges";
import { DEFAULT_LIST_ID, type AppData, type ChangeSet, type Word } from "./types";

const T0 = 1_700_000_000_000;

function memoryPersistence(initial: AppData | null = null): Persistence {
  return {
    load: async () => initial,
    save: async () => {},
    clear: async () => {},
  };
}

interface Harness {
  store: Store;
  /** Move the injected clock forward; returns the new "now". */
  advance(ms?: number): number;
  now(): number;
}

async function freshStore(start = T0): Promise<Harness> {
  let now = start;
  const store = createStore({
    persistence: memoryPersistence(emptyData()),
    clock: () => now,
    saveDelayMs: 0,
  });
  await store.init();
  return {
    store,
    now: () => now,
    advance(ms = 1_000) {
      now += ms;
      return now;
    },
  };
}

function pendingOf(store: Store) {
  return store.get().pending;
}

function emptyChanges(): ChangeSet {
  return { words: [], lists: [], logs: [], settings: null };
}

function wordRecord(over: Partial<Word> = {}): Word {
  return {
    id: "w_remote",
    term: "remote",
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
    createdAt: T0,
    updatedAt: T0,
    ...over,
  };
}

describe("every local edit becomes pending", () => {
  it("adding a word marks it pending", async () => {
    const { store } = await freshStore();
    const word = store.addWord({ term: "serendipity", listId: DEFAULT_LIST_ID });
    expect(pendingOf(store).words).toContain(word.id);
    expect(pendingTotal(store.get())).toBeGreaterThan(0);
  });

  it("editing a word marks it pending and bumps updatedAt", async () => {
    const { store, advance } = await freshStore();
    const word = store.addWord({ term: "a", listId: DEFAULT_LIST_ID });
    expect(store.get().words[0].updatedAt).toBe(T0);

    advance();
    store.updateWord(word.id, { definition: "first letter" });

    expect(pendingOf(store).words).toContain(word.id);
    // Must be *after* T0: a frozen clock would make this pass even if
    // updateWord never wrote a timestamp at all.
    expect(store.get().words[0].updatedAt).toBe(T0 + 1_000);
    expect(store.get().words[0].updatedAt).toBeGreaterThan(T0);
  });

  it("grading a word marks the word and its review log pending", async () => {
    const { store, advance } = await freshStore();
    const word = store.addWord({ term: "a", listId: DEFAULT_LIST_ID });
    store.markPushed(store.getChangesToPush());
    expect(pendingTotal(store.get())).toBe(0);

    advance();
    const result = store.gradeWord(word.id, "good");
    expect(result).not.toBeNull();
    expect(pendingOf(store).words).toContain(word.id);
    expect(pendingOf(store).logs).toContain(result!.logId);
    expect(store.get().logs[0].at).toBe(T0 + 1_000);
  });

  it("changing settings marks the settings pending", async () => {
    const { store, advance } = await freshStore();
    advance();
    store.updateSettings({ dailyGoal: 42 });
    expect(pendingOf(store).settings).toBe(true);
    expect(store.get().settingsUpdatedAt).toBe(T0 + 1_000);
  });

  it("creating a list marks it pending", async () => {
    const { store } = await freshStore();
    const list = store.createList({ name: "Deck", sourceLang: "en", targetLang: "zh-CN" });
    expect(pendingOf(store).lists).toContain(list.id);
  });

  it("renaming a list marks it pending and bumps updatedAt", async () => {
    const { store, advance } = await freshStore();
    const list = store.createList({ name: "Deck", sourceLang: "en", targetLang: "zh-CN" });
    store.markPushed(store.getChangesToPush());

    advance();
    store.renameList(list.id, "Renamed");

    expect(pendingOf(store).lists).toContain(list.id);
    const renamed = store.get().lists.find((l) => l.id === list.id)!;
    expect(renamed.name).toBe("Renamed");
    expect(renamed.updatedAt).toBe(T0 + 1_000);
  });

  it("toggling a favorite and counting a listen mark the word pending", async () => {
    const { store, advance } = await freshStore();
    const word = store.addWord({ term: "a", listId: DEFAULT_LIST_ID });
    store.markPushed(store.getChangesToPush());

    advance();
    store.toggleFavorite(word.id);
    expect(store.get().words[0].favorite).toBe(true);
    expect(pendingOf(store).words).toContain(word.id);

    store.markPushed(store.getChangesToPush());
    advance();
    store.bumpListen(word.id);
    expect(store.get().words[0].listenCount).toBe(1);
    expect(pendingOf(store).words).toContain(word.id);
  });

  it("setting a status and resetting a schedule mark the word pending", async () => {
    const { store, advance } = await freshStore();
    const word = store.addWord({ term: "a", listId: DEFAULT_LIST_ID });
    store.markPushed(store.getChangesToPush());

    advance();
    store.setWordStatus(word.id, "mastered");
    expect(store.get().words[0].status).toBe("mastered");
    expect(pendingOf(store).words).toContain(word.id);

    store.markPushed(store.getChangesToPush());
    advance();
    store.resetSrs(word.id);
    expect(store.get().words[0].srs).toBeNull();
    expect(store.get().words[0].status).toBe("new");
    expect(pendingOf(store).words).toContain(word.id);
  });

  it("undoing a review marks the word and tombstones the dropped log", async () => {
    const { store, advance } = await freshStore();
    const word = store.addWord({ term: "a", listId: DEFAULT_LIST_ID });
    store.markPushed(store.getChangesToPush());

    advance();
    const graded = store.gradeWord(word.id, "good")!;
    store.markPushed(store.getChangesToPush());
    expect(pendingTotal(store.get())).toBe(0);

    advance();
    store.undoReview(word.id, null, "new", graded.logId);

    const data = store.get();
    expect(data.logs).toHaveLength(0);
    expect(data.words[0].srs).toBeNull();
    expect(data.words[0].status).toBe("new");
    expect(pendingOf(store).words).toContain(word.id);
    expect(pendingOf(store).logs).toContain(graded.logId);
    // Absence alone cannot travel; the tombstone is what tells other devices.
    expect(data.tombstones.logs[graded.logId]).toBeTruthy();
  });
});

describe("a completed push settles the journal", () => {
  it("markPushed reaches journal.settle and clears every pending flag", async () => {
    const { store, advance } = await freshStore();
    const list = store.createList({ name: "Deck", sourceLang: "en", targetLang: "zh-CN" });
    const word = store.addWord({ term: "a", listId: list.id });
    advance();
    store.gradeWord(word.id, "good");
    advance();
    store.updateSettings({ dailyGoal: 7 });

    expect(pendingTotal(store.get())).toBeGreaterThan(0);

    store.markPushed(store.getChangesToPush());

    // If markPushed were a no-op this would still be non-zero — which is
    // exactly why asserting it here matters.
    expect(pendingTotal(store.get())).toBe(0);
    expect(store.get().pending.words).toEqual([]);
    expect(store.get().pending.lists).toEqual([]);
    expect(store.get().pending.logs).toEqual([]);
    expect(store.get().pending.settings).toBe(false);
  });

  it("keeps an edit that landed while the push was in flight", async () => {
    const { store, advance } = await freshStore();
    const word = store.addWord({ term: "a", listId: DEFAULT_LIST_ID });
    advance();
    const pushed = store.getChangesToPush();

    advance();
    store.updateWord(word.id, { term: "edited mid-flight" });
    store.markPushed(pushed);

    expect(pendingOf(store).words).toContain(word.id);
  });
});

describe("deletes leave tombstones", () => {
  it("deleting a word tombstones the word and its review logs", async () => {
    const { store, advance } = await freshStore();
    const word = store.addWord({ term: "a", listId: DEFAULT_LIST_ID });
    advance();
    const result = store.gradeWord(word.id, "good")!;
    store.markPushed(store.getChangesToPush());

    advance();
    store.deleteWord(word.id);

    const data = store.get();
    expect(data.words).toHaveLength(0);
    expect(data.logs).toHaveLength(0);
    expect(data.tombstones.words[word.id]).toBe(T0 + 2_000);
    expect(data.tombstones.logs[result.logId]).toBe(T0 + 2_000);
    expect(data.pending.words).toContain(word.id);
    expect(data.pending.logs).toContain(result.logId);
  });

  it("deleting a list cascades to its words AND their review logs", async () => {
    const { store, advance } = await freshStore();
    const list = store.createList({ name: "Doomed", sourceLang: "en", targetLang: "zh-CN" });
    const word = store.addWord({ term: "a", listId: list.id });
    advance();
    const result = store.gradeWord(word.id, "good")!;
    store.markPushed(store.getChangesToPush());

    advance();
    store.deleteList(list.id);
    const data = store.get();

    expect(data.lists.find((l) => l.id === list.id)).toBeUndefined();
    expect(data.words).toHaveLength(0);
    // The bug this journal exists to prevent: the logs used to survive.
    expect(data.logs).toHaveLength(0);
    expect(data.tombstones.lists[list.id]).toBeTruthy();
    expect(data.tombstones.words[word.id]).toBeTruthy();
    expect(data.tombstones.logs[result.logId]).toBeTruthy();
    expect(data.pending.logs).toContain(result.logId);
  });

  it("bulk delete tombstones every word and log in one pass", async () => {
    const { store, advance } = await freshStore();
    const a = store.addWord({ term: "a", listId: DEFAULT_LIST_ID });
    const b = store.addWord({ term: "b", listId: DEFAULT_LIST_ID });
    advance();
    const logA = store.gradeWord(a.id, "good")!;
    store.markPushed(store.getChangesToPush());

    advance();
    store.deleteWords([a.id, b.id]);
    const data = store.get();
    expect(data.words).toHaveLength(0);
    expect(data.tombstones.words[a.id]).toBeTruthy();
    expect(data.tombstones.words[b.id]).toBeTruthy();
    expect(data.tombstones.logs[logA.logId]).toBeTruthy();
  });
});

describe("snapshots are immutable across commits", () => {
  it("editing a word does not mutate the previous snapshot", async () => {
    const { store, advance } = await freshStore();
    store.addWord({ term: "original", listId: DEFAULT_LIST_ID });
    const before = store.get();

    advance();
    store.updateWord(before.words[0].id, { term: "changed" });

    // The old snapshot is what React may still be rendering; it must be intact.
    expect(before.words[0].term).toBe("original");
    expect(store.get().words[0].term).toBe("changed");
    expect(store.get()).not.toBe(before);
  });

  it("renaming a list does not mutate the previous snapshot", async () => {
    const { store, advance } = await freshStore();
    const list = store.createList({ name: "Before", sourceLang: "en", targetLang: "zh-CN" });
    const before = store.get();

    advance();
    store.renameList(list.id, "After");

    expect(before.lists.find((l) => l.id === list.id)!.name).toBe("Before");
    expect(store.get().lists.find((l) => l.id === list.id)!.name).toBe("After");
  });

  it("grading does not mutate the previous snapshot's srs", async () => {
    const { store, advance } = await freshStore();
    const word = store.addWord({ term: "a", listId: DEFAULT_LIST_ID });
    const before = store.get();

    advance();
    store.gradeWord(word.id, "good");

    expect(before.words[0].srs).toBeNull();
    expect(store.get().words[0].srs).not.toBeNull();
  });

  it("deleting does not mutate the previous snapshot's arrays", async () => {
    const { store, advance } = await freshStore();
    const word = store.addWord({ term: "a", listId: DEFAULT_LIST_ID });
    advance();
    store.gradeWord(word.id, "good");
    const before = store.get();

    advance();
    store.deleteWord(word.id);

    expect(before.words).toHaveLength(1);
    expect(before.logs).toHaveLength(1);
    expect(store.get().words).toHaveLength(0);
    expect(store.get().logs).toHaveLength(0);
  });
});

describe("applying a remote change set is not a local edit", () => {
  it("does not emit a local change, so it cannot schedule another sync round", async () => {
    const { store } = await freshStore();
    const events: number[] = [];
    const off = onLocalChange(() => events.push(1));
    try {
      store.applyRemoteChanges({
        ...emptyChanges(),
        words: [wordRecord({ id: "w_remote", term: "from server", updatedAt: T0 + 5_000 })],
      });
      expect(events).toHaveLength(0);
      expect(store.get().words.some((w) => w.id === "w_remote")).toBe(true);

      // Control: a real local edit does emit, so the assertion above is
      // not passing merely because the bus is broken.
      store.updateSettings({ dailyGoal: 3 });
      expect(events).toHaveLength(1);
    } finally {
      off();
    }
  });
});

describe("settle is version-guarded", () => {
  function snapshot(over: Partial<AppData> = {}): AppData {
    return { ...emptyData(), ...over };
  }

  it("drops pending flags for the exact version that was pushed", () => {
    const d = snapshot({
      words: [wordRecord({ id: "w1", updatedAt: 5 })],
      pending: { words: ["w1"], lists: [], logs: [], settings: false },
    });
    const pushed: ChangeSet = { ...emptyChanges(), words: [d.words[0]] };

    settle(d, pushed);
    expect(d.pending.words).toEqual([]);
  });

  it("keeps a record pending when it was edited during the request", () => {
    const d = snapshot({
      words: [wordRecord({ id: "w1", term: "edited", updatedAt: 9 })],
      pending: { words: ["w1"], lists: [], logs: [], settings: false },
    });
    // We pushed version 5; the local copy is already version 9.
    const pushed: ChangeSet = {
      ...emptyChanges(),
      words: [{ ...d.words[0], updatedAt: 5 }],
    };

    settle(d, pushed);
    expect(d.pending.words).toEqual(["w1"]);
  });

  it("clears the settings flag only for the pushed version", () => {
    const d = snapshot({
      settingsUpdatedAt: 7,
      pending: { words: [], lists: [], logs: [], settings: true },
    });
    settle(d, {
      ...emptyChanges(),
      settings: { ...d.settings, updatedAt: 7 },
    });
    expect(d.pending.settings).toBe(false);
  });
});
