/**
 * Tests for `applyRound` — one sync round is "settle what we sent, then merge
 * what came back", and the round owns that order so no caller can run the two
 * halves backwards or forget one of them.
 *
 * Like journal.test.ts these drive a real store with a mutable clock: the
 * properties under test are about what the store does with a whole round, not
 * about a pure function in isolation. The clock matters because the version
 * guard compares `updatedAt` values, and a frozen clock would make "the edit
 * bumped the version" vacuous.
 */
import { describe, expect, it } from "vitest";
import { createStore, emptyData, type Persistence, type Store } from "./store";
import { EMPTY_CHANGES } from "./syncMerge";
import { pendingTotal } from "./journal";
import { onLocalChange } from "./localChanges";
import { DEFAULT_LIST_ID, type AppData, type Word } from "./types";

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
    advance(ms = 1_000) {
      now += ms;
      return now;
    },
  };
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

describe("applyRound settles the half we sent", () => {
  it("clears every pending flag for the versions the round sent", async () => {
    const { store, advance } = await freshStore();
    const list = store.createList({ name: "Deck", sourceLang: "en", targetLang: "zh-CN" });
    const word = store.addWord({ term: "a", listId: list.id });
    advance();
    store.gradeWord(word.id, "good");
    advance();
    store.updateSettings({ dailyGoal: 7 });

    expect(pendingTotal(store.get())).toBeGreaterThan(0);

    store.applyRound({ sent: store.getChangesToPush(), received: EMPTY_CHANGES });

    expect(pendingTotal(store.get())).toBe(0);
    expect(store.getChangesToPush()).toEqual(EMPTY_CHANGES);
  });

  it("settles nothing when the round sent nothing", async () => {
    const { store } = await freshStore();
    const word = store.addWord({ term: "a", listId: DEFAULT_LIST_ID });

    // A round that pushed nothing has no versions to settle; a naive "clear
    // everything" would silently drop this edit.
    store.applyRound({ sent: EMPTY_CHANGES, received: EMPTY_CHANGES });

    expect(store.get().pending.words).toContain(word.id);
  });

  it("keeps a record pending when it was edited after the push was built", async () => {
    const { store, advance } = await freshStore();
    const word = store.addWord({ term: "before", listId: DEFAULT_LIST_ID });
    advance();
    const sent = store.getChangesToPush();

    advance();
    store.updateWord(word.id, { term: "after" });
    store.applyRound({ sent, received: EMPTY_CHANGES });

    // The guard must compare against the version that was actually pushed.
    // Clearing merely because the id is in `sent` would drop the newer edit.
    expect(store.get().pending.words).toContain(word.id);
    const local = store.get().words.find((w) => w.id === word.id)!;
    expect(local.term).toBe("after");
    expect(local.updatedAt).toBeGreaterThan(sent.words[0].updatedAt);
  });

  it("does not settle an edit the round never sent", async () => {
    const { store, advance } = await freshStore();
    store.addWord({ term: "already pending", listId: DEFAULT_LIST_ID });
    const sent = store.getChangesToPush();

    advance();
    const fresh = store.addWord({ term: "added mid-flight", listId: DEFAULT_LIST_ID });
    store.applyRound({ sent, received: EMPTY_CHANGES });

    expect(store.get().pending.words).toEqual([fresh.id]);
  });

  it("keeps a settings edit that landed after the push was built", async () => {
    const { store, advance } = await freshStore();
    store.updateSettings({ dailyGoal: 5 });
    advance();
    const sent = store.getChangesToPush();

    advance();
    store.updateSettings({ dailyGoal: 9 });
    store.applyRound({ sent, received: EMPTY_CHANGES });

    expect(store.get().settings.dailyGoal).toBe(9);
    expect(store.get().pending.settings).toBe(true);
  });
});

describe("applyRound merges the half the server sent", () => {
  it("merges a remote record into the same snapshot", async () => {
    const { store } = await freshStore();

    store.applyRound({
      sent: EMPTY_CHANGES,
      received: { ...EMPTY_CHANGES, words: [wordRecord()] },
    });

    expect(store.get().words.map((w) => w.id)).toEqual(["w_remote"]);
    expect(store.get().pending.words).toEqual([]);
  });

  it("applies a remote tombstone and drops the local record", async () => {
    const { store, advance } = await freshStore();
    const word = store.addWord({ term: "a", listId: DEFAULT_LIST_ID });
    store.applyRound({ sent: store.getChangesToPush(), received: EMPTY_CHANGES });

    advance();
    store.applyRound({
      sent: EMPTY_CHANGES,
      received: {
        ...EMPTY_CHANGES,
        words: [{ id: word.id, updatedAt: T0 + 5_000, deleted: true }],
      },
    });

    expect(store.get().words).toHaveLength(0);
    expect(store.get().tombstones.words[word.id]).toBe(T0 + 5_000);
  });

  it("keeps a local edit that is newer than the server's copy", async () => {
    const { store, advance } = await freshStore();
    const word = store.addWord({ term: "local", listId: DEFAULT_LIST_ID });
    advance();
    store.updateWord(word.id, { term: "newer" });

    store.applyRound({
      sent: EMPTY_CHANGES,
      received: {
        ...EMPTY_CHANGES,
        words: [wordRecord({ id: word.id, term: "older", updatedAt: T0 + 500 })],
      },
    });

    expect(store.get().words[0].term).toBe("newer");
    expect(store.get().pending.words).toContain(word.id);
  });

  it("keeps a mid-flight edit when the server echoes the version we pushed", async () => {
    const { store, advance } = await freshStore();
    const word = store.addWord({ term: "before", listId: DEFAULT_LIST_ID });
    advance();
    const sent = store.getChangesToPush();

    advance();
    store.updateWord(word.id, { term: "after" });
    // The server answers with exactly what we pushed — the stale echo must not
    // win over the edit that landed while the request was in flight.
    store.applyRound({ sent, received: sent });

    expect(store.get().words[0].term).toBe("after");
    expect(store.get().pending.words).toContain(word.id);
  });

  it("stops protecting a record once this round settled its push", async () => {
    // Protocol rule (docs/sync-protocol.md, client step 4): only a record that
    // has NOT been pushed may outrank an incoming record by updatedAt. The
    // tombstone below is older than the local copy, yet it wins — and it only
    // wins because settle ran first. This is the one place the round's order
    // is observable, so it is what would fail if the halves were swapped.
    const { store, advance } = await freshStore();
    const word = store.addWord({ term: "a", listId: DEFAULT_LIST_ID });
    advance();
    store.updateWord(word.id, { term: "newer" });
    const sent = store.getChangesToPush();

    store.applyRound({
      sent,
      received: {
        ...EMPTY_CHANGES,
        words: [{ id: word.id, updatedAt: T0 + 500, deleted: true }],
      },
    });

    expect(store.get().words).toHaveLength(0);
    expect(store.get().tombstones.words[word.id]).toBe(T0 + 500);
  });

  it("does not duplicate a record the server echoes back", async () => {
    const { store } = await freshStore();
    store.addWord({ term: "a", listId: DEFAULT_LIST_ID });
    const sent = store.getChangesToPush();

    store.applyRound({ sent, received: sent });

    expect(store.get().words).toHaveLength(1);
    expect(store.get().words[0].updatedAt).toBe(sent.words[0].updatedAt);
    expect(pendingTotal(store.get())).toBe(0);
  });
});

describe("applyRound is not a local edit", () => {
  it("does not emit a local change for the round it applies", async () => {
    const { store } = await freshStore();
    const word = store.addWord({ term: "a", listId: DEFAULT_LIST_ID });
    const sent = store.getChangesToPush();

    const events: number[] = [];
    const off = onLocalChange(() => events.push(1));
    try {
      store.applyRound({ sent, received: sent });

      // A pushing round must not echo: emitting here is what scheduled a
      // wasted extra sync round after every push.
      expect(events).toHaveLength(0);
      expect(store.get().pending.words).toEqual([]);

      // Control: a real local edit does emit, so the assertion above is not
      // passing merely because the bus is broken.
      store.updateWord(word.id, { term: "edited" });
      expect(events).toHaveLength(1);
    } finally {
      off();
    }
  });
});

describe("applyRound keeps snapshots immutable", () => {
  it("does not mutate the snapshot that was current before the round", async () => {
    const { store } = await freshStore();
    const word = store.addWord({ term: "a", listId: DEFAULT_LIST_ID });
    const before = store.get();

    store.applyRound({ sent: store.getChangesToPush(), received: EMPTY_CHANGES });

    // `settle` rewrites `pending` in place, so the round has to hand it a copy;
    // `before` is what React may still be rendering.
    expect(before.pending.words).toContain(word.id);
    expect(store.get().pending.words).toEqual([]);
    expect(store.get()).not.toBe(before);
  });
});
