/**
 * Tests for the change journal — the invariant that "every local edit is
 * pending, every local delete leaves a tombstone".
 *
 * These run against a real `createStore` instance with an in-memory
 * persistence adapter, which is the point of the store factory: the invariant
 * is asserted over actual domain operations instead of hand-built snapshots.
 */
import { describe, expect, it } from "vitest";
import { createStore, emptyData, type Persistence, type Store } from "./store";
import { pendingTotal, settle } from "./journal";
import { DEFAULT_LIST_ID, type AppData, type ChangeSet } from "./types";

const T0 = 1_700_000_000_000;

function memoryPersistence(initial: AppData | null = null): Persistence {
  return {
    load: async () => initial,
    save: async () => {},
    clear: async () => {},
  };
}

async function freshStore(now = T0): Promise<Store> {
  const store = createStore({
    persistence: memoryPersistence(emptyData()),
    clock: () => now,
    saveDelayMs: 0,
  });
  await store.init();
  return store;
}

function pendingOf(store: Store) {
  return store.get().pending;
}

function emptyChanges(): ChangeSet {
  return { words: [], lists: [], logs: [], settings: null };
}

describe("every local edit becomes pending", () => {
  it("adding a word marks it pending", async () => {
    const store = await freshStore();
    const word = store.addWord({ term: "serendipity", listId: DEFAULT_LIST_ID });
    expect(pendingOf(store).words).toContain(word.id);
    expect(pendingTotal(store.get())).toBeGreaterThan(0);
  });

  it("editing a word marks it pending and bumps updatedAt", async () => {
    const store = await freshStore();
    const word = store.addWord({ term: "a", listId: DEFAULT_LIST_ID });
    store.markPushed(store.getChangesToPush());

    store.updateWord(word.id, { definition: "first letter" });
    expect(pendingOf(store).words).toContain(word.id);
    expect(store.get().words[0].updatedAt).toBe(T0);
  });

  it("grading a word marks the word and its review log pending", async () => {
    const store = await freshStore();
    const word = store.addWord({ term: "a", listId: DEFAULT_LIST_ID });
    store.markPushed(store.getChangesToPush());

    const result = store.gradeWord(word.id, "good");
    expect(result).not.toBeNull();
    expect(pendingOf(store).words).toContain(word.id);
    expect(pendingOf(store).logs).toContain(result!.logId);
  });

  it("changing settings marks the settings pending", async () => {
    const store = await freshStore();
    store.markPushed(store.getChangesToPush());

    store.updateSettings({ dailyGoal: 42 });
    expect(pendingOf(store).settings).toBe(true);
    expect(store.get().settingsUpdatedAt).toBe(T0);
  });

  it("creating a list marks it pending", async () => {
    const store = await freshStore();
    const list = store.createList({ name: "Deck", sourceLang: "en", targetLang: "zh-CN" });
    expect(pendingOf(store).lists).toContain(list.id);
  });
});

describe("deletes leave tombstones", () => {
  it("deleting a word tombstones the word and its review logs", async () => {
    const store = await freshStore();
    const word = store.addWord({ term: "a", listId: DEFAULT_LIST_ID });
    const result = store.gradeWord(word.id, "good")!;
    const now = T0 + 1_000;
    store.markPushed(store.getChangesToPush());

    store.deleteWord(word.id);
    const data = store.get();
    expect(data.words).toHaveLength(0);
    expect(data.logs).toHaveLength(0);
    expect(data.tombstones.words[word.id]).toBeTruthy();
    expect(data.tombstones.logs[result.logId]).toBeTruthy();
    expect(data.pending.words).toContain(word.id);
    expect(data.pending.logs).toContain(result.logId);
    expect(now).toBeGreaterThan(T0);
  });

  it("deleting a list cascades to its words AND their review logs", async () => {
    const store = await freshStore();
    const list = store.createList({ name: "Doomed", sourceLang: "en", targetLang: "zh-CN" });
    const word = store.addWord({ term: "a", listId: list.id });
    const result = store.gradeWord(word.id, "good")!;
    store.markPushed(store.getChangesToPush());

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
    const store = await freshStore();
    const a = store.addWord({ term: "a", listId: DEFAULT_LIST_ID });
    const b = store.addWord({ term: "b", listId: DEFAULT_LIST_ID });
    const logA = store.gradeWord(a.id, "good")!;
    store.markPushed(store.getChangesToPush());

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
    const store = await freshStore();
    store.addWord({ term: "original", listId: DEFAULT_LIST_ID });
    const before = store.get();

    store.updateWord(before.words[0].id, { term: "changed" });

    // The old snapshot is what React may still be rendering; it must be intact.
    expect(before.words[0].term).toBe("original");
    expect(store.get().words[0].term).toBe("changed");
    expect(store.get()).not.toBe(before);
  });
});

describe("settle is version-guarded", () => {
  function snapshot(over: Partial<AppData> = {}): AppData {
    return { ...emptyData(), ...over };
  }

  it("drops pending flags for the exact version that was pushed", () => {
    const d = snapshot({
      words: [
        {
          id: "w1",
          term: "a",
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
          createdAt: 1,
          updatedAt: 5,
        },
      ],
      pending: { words: ["w1"], lists: [], logs: [], settings: false },
    });
    const pushed: ChangeSet = { ...emptyChanges(), words: [d.words[0]] };

    settle(d, pushed);
    expect(d.pending.words).toEqual([]);
  });

  it("keeps a record pending when it was edited during the request", () => {
    const d = snapshot({
      words: [
        {
          id: "w1",
          term: "edited",
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
          createdAt: 1,
          updatedAt: 9,
        },
      ],
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
