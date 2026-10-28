/**
 * Snapshot migration.
 *
 * These are the only tests covering `migrateSnapshot`, which is the one code
 * path every existing user's data passes through exactly once per version
 * bump — and the one place a bad edit silently loses a library instead of
 * throwing. The cases below are the ones that actually happened: fields added
 * (sync bookkeeping), and one field removed (`Word.tags` in version 3).
 */
import { describe, expect, it } from "vitest";
import { migrateSnapshot } from "./store";
import { DATA_VERSION, DEFAULT_LIST_ID } from "./types";

function snapshot(over: Record<string, unknown> = {}) {
  return {
    version: 2,
    lists: [{ id: DEFAULT_LIST_ID, name: "库", sourceLang: "en", targetLang: "zh-CN" }],
    words: [],
    logs: [],
    settings: {},
    settingsUpdatedAt: 0,
    ...over,
  };
}

function legacyWord(over: Record<string, unknown> = {}) {
  return {
    id: "w1",
    term: "serendipity",
    definition: "意外发现美好事物的运气",
    definition2: "",
    example: "",
    note: "",
    status: "new",
    favorite: false,
    tags: ["抽象", "文学"],
    listId: DEFAULT_LIST_ID,
    sourceLang: "en",
    targetLang: "zh-CN",
    listenCount: 0,
    srs: null,
    createdAt: 1,
    updatedAt: 2,
    ...over,
  };
}

describe("migrateSnapshot — 版本与形状", () => {
  it("旧版本号被拉齐到当前版本，数据一条不丢", () => {
    const out = migrateSnapshot(snapshot({ version: 1, words: [legacyWord()] }))!;
    expect(out.version).toBe(DATA_VERSION);
    expect(out.words.map((w) => w.term)).toEqual(["serendipity"]);
    expect(out.lists.map((l) => l.id)).toEqual([DEFAULT_LIST_ID]);
  });

  it("高于当前版本的快照被拒绝，而不是猜测着读", () => {
    expect(migrateSnapshot(snapshot({ version: DATA_VERSION + 1 }))).toBeNull();
  });

  it("缺 words / lists 或不是对象都返回 null", () => {
    expect(migrateSnapshot(null)).toBeNull();
    expect(migrateSnapshot("nope")).toBeNull();
    expect(migrateSnapshot({ version: 2, lists: [] })).toBeNull();
    expect(migrateSnapshot({ version: 2, words: [] })).toBeNull();
  });
});

describe("migrateSnapshot — 补齐同步簿记", () => {
  it("version 1（同步之前）补上空 tombstones / pending 与各词的 updatedAt", () => {
    const out = migrateSnapshot(
      snapshot({
        version: 1,
        lists: [{ id: DEFAULT_LIST_ID, name: "库", createdAt: 7 }],
        words: [legacyWord()],
      }),
    )!;
    expect(out.tombstones).toEqual({ words: {}, lists: {}, logs: {} });
    expect(out.pending).toEqual({ words: [], lists: [], logs: [], settings: false });
    expect(out.lists[0].updatedAt).toBe(7);
  });
});

describe("migrateSnapshot — 移除的字段", () => {
  it("v3 删掉的 Word.tags 在载入时被丢掉，不会跟着备份走", () => {
    const out = migrateSnapshot(snapshot({ words: [legacyWord()] }))!;
    expect("tags" in out.words[0]).toBe(false);
    // Everything else on the record survives untouched.
    expect(out.words[0]).toMatchObject({
      id: "w1",
      term: "serendipity",
      definition: "意外发现美好事物的运气",
      updatedAt: 2,
    });
  });

  it("没有 tags 的记录原样返回（幂等，重复载入不改变它）", () => {
    const clean = legacyWord();
    delete (clean as Record<string, unknown>).tags;
    const out = migrateSnapshot(snapshot({ words: [clean] }))!;
    expect(out.words[0]).toEqual(clean);
    expect(migrateSnapshot(out)).toEqual(out);
  });
});
