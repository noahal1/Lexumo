import { describe, expect, it } from "vitest";
import { buildWordIndex, queryWords, statusRank, summarize } from "./wordIndex";
import {
  DEFAULT_SETTINGS,
  type AppData,
  type Grade,
  type ReviewLog,
  type SrsState,
  type Word,
  type WordList,
  type WordStatus,
} from "./types";

/* ------------------------------------------------------------------ */
/* Plain fixtures — no store, no React                                 */
/* ------------------------------------------------------------------ */

const DAY = 86_400_000;
/** Local noon so "today" is unambiguous in every timezone the test runs in. */
const NOW = new Date(2024, 5, 10, 12, 0, 0).getTime();
const TODAY_START = new Date(2024, 5, 10, 0, 0, 0, 0).getTime();

function list(id: string): WordList {
  return { id, name: id, sourceLang: "en", targetLang: "zh-CN", createdAt: 0, updatedAt: 0 };
}

function word(id: string, over: Partial<Word> = {}): Word {
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
    listId: "a",
    sourceLang: "en",
    targetLang: "zh-CN",
    listenCount: 0,
    srs: null,
    createdAt: 0,
    updatedAt: 0,
    ...over,
  };
}

function srs(over: Partial<SrsState> = {}): SrsState {
  return {
    ease: 2.5,
    intervalDays: 1,
    dueAt: NOW,
    reviewCount: 1,
    correctCount: 1,
    lastReviewedAt: NOW,
    ...over,
  };
}

function log(at: number, grade: Grade = "good"): ReviewLog {
  return { id: `log_${at}`, wordId: "w", grade, at, intervalBefore: 1, intervalAfter: 2 };
}

function appData(
  words: Word[],
  opts: { lists?: WordList[]; logs?: ReviewLog[]; dailyGoal?: number } = {},
): AppData {
  return {
    version: 2,
    lists: opts.lists ?? [list("a"), list("b")],
    words,
    logs: opts.logs ?? [],
    settings: { ...DEFAULT_SETTINGS, dailyGoal: opts.dailyGoal ?? DEFAULT_SETTINGS.dailyGoal },
    settingsUpdatedAt: 0,
    tombstones: { words: {}, lists: {}, logs: {} },
    pending: { words: [], lists: [], logs: [], settings: false },
  };
}

/* ------------------------------------------------------------------ */
/* statusRank                                                          */
/* ------------------------------------------------------------------ */

describe("statusRank", () => {
  it("四种状态只有一个顺序：new < reviewing < learning < mastered", () => {
    const order: WordStatus[] = ["new", "reviewing", "learning", "mastered"];
    expect(order.map(statusRank)).toEqual([0, 1, 2, 3]);
  });
});

/* ------------------------------------------------------------------ */
/* buildWordIndex — buckets, counts, tags                              */
/* ------------------------------------------------------------------ */

describe("buildWordIndex — 分库计数", () => {
  it("每个词库都有 all 与四种状态的计数，空词库也在", () => {
    const words = [
      word("a1", { listId: "a", status: "new" }),
      word("a2", { listId: "a", status: "reviewing" }),
      word("a3", { listId: "a", status: "mastered" }),
      word("b1", { listId: "b", status: "learning" }),
    ];
    const index = buildWordIndex(
      appData(words, { lists: [list("a"), list("b"), list("c")] }),
      NOW,
    );

    expect(index.countsByList.get("a")).toEqual({
      all: 3,
      new: 1,
      reviewing: 1,
      learning: 0,
      mastered: 1,
    });
    expect(index.countsByList.get("b")).toEqual({
      all: 1,
      new: 0,
      reviewing: 0,
      learning: 1,
      mastered: 0,
    });
    // A declared but empty list still gets a zeroed bucket.
    expect(index.countsByList.get("c")).toEqual({
      all: 0,
      new: 0,
      reviewing: 0,
      learning: 0,
      mastered: 0,
    });
    expect(index.byList.get("a")!.map((w) => w.id)).toEqual(["a1", "a2", "a3"]);
    expect(index.byList.get("c")).toEqual([]);
  });
});

describe("buildWordIndex — 标签池顺序", () => {
  it("按使用次数降序；次数相同用 localeCompare 兜底（不靠插入顺序）", () => {
    // "zeta" is inserted before "alpha" and both have count 2: only the
    // localeCompare tie-break can put "alpha" first. Without it the stable
    // sort keeps insertion order and this assertion fails.
    const words = [
      word("w1", { listId: "a", tags: ["zeta", "alpha"] }),
      word("w2", { listId: "a", tags: ["zeta", "alpha"] }),
      word("w3", { listId: "b", tags: ["beta"] }),
    ];
    const index = buildWordIndex(appData(words), NOW);

    expect(index.tagsByList.get("a")).toEqual(["alpha", "zeta"]);
    expect(index.tagsByList.get("b")).toEqual(["beta"]);
    // Global pool: alpha/zeta (2 each, alpha first by tie-break) then beta (1).
    expect(index.tags).toEqual(["alpha", "zeta", "beta"]);
  });
});

/* ------------------------------------------------------------------ */
/* buildWordIndex — due buckets                                        */
/* ------------------------------------------------------------------ */

describe("buildWordIndex — 到期判定", () => {
  it("已掌握排除；无 srs 计入；未来到期排除；到期边界含等于", () => {
    const words = [
      word("masteredPast", { status: "mastered", srs: srs({ dueAt: NOW - DAY }) }),
      word("nullSrs", { srs: null }),
      word("dueNow", { status: "reviewing", srs: srs({ dueAt: NOW }) }),
      word("future", { status: "reviewing", srs: srs({ dueAt: NOW + DAY }) }),
      word("past", { status: "learning", srs: srs({ dueAt: NOW - DAY }) }),
      word("masteredNull", { listId: "b", status: "mastered", srs: null }),
    ];
    const index = buildWordIndex(appData(words), NOW);

    // Snapshot order is preserved; mastered words are never due, even with a
    // past dueAt or a missing srs.
    expect(index.due.map((w) => w.id)).toEqual(["nullSrs", "dueNow", "past"]);
    expect(index.dueByList.get("a")!.map((w) => w.id)).toEqual([
      "nullSrs",
      "dueNow",
      "past",
    ]);
    expect(index.dueByList.get("b")).toBeUndefined();
  });
});

/* ------------------------------------------------------------------ */
/* queryWords                                                          */
/* ------------------------------------------------------------------ */

function queryFixture(): Word[] {
  return [
    word("zebra", { term: "zebra", definition: "striped equine", createdAt: 100 }),
    word("apple", {
      term: "apple",
      definition2: "a hidden meaning",
      favorite: true,
      createdAt: 400,
    }),
    word("boat", {
      term: "boat",
      note: "sails on water",
      status: "reviewing",
      tags: ["vehicle"],
      createdAt: 300,
    }),
    word("cat", {
      term: "cat",
      definition: "small animal",
      status: "mastered",
      tags: ["animal"],
      createdAt: 200,
    }),
  ];
}

describe("queryWords — 搜索", () => {
  const index = buildWordIndex(appData(queryFixture()), NOW);
  const ids = (q: string) => queryWords(index, { listId: "a", query: q }).map((w) => w.id);

  it("大小写不敏感地匹配 term", () => {
    expect(ids("ZEBRA")).toEqual(["zebra"]);
  });

  it("匹配 definition / definition2 / note", () => {
    expect(ids("striped")).toEqual(["zebra"]);
    expect(ids("HIDDEN")).toEqual(["apple"]);
    expect(ids("sails")).toEqual(["boat"]);
  });

  it("匹配 tags", () => {
    expect(ids("animal")).toEqual(["cat"]);
  });

  it("忽略首尾空白；无匹配返回空", () => {
    expect(ids("  zebra  ")).toEqual(["zebra"]);
    expect(ids("nope")).toEqual([]);
    expect(ids("   ")).toHaveLength(4);
  });
});

describe("queryWords — 筛选", () => {
  const index = buildWordIndex(appData(queryFixture()), NOW);

  it("按状态筛选", () => {
    expect(
      queryWords(index, { listId: "a", status: "reviewing" }).map((w) => w.id),
    ).toEqual(["boat"]);
    expect(
      queryWords(index, { listId: "a", status: "mastered" }).map((w) => w.id),
    ).toEqual(["cat"]);
    expect(queryWords(index, { listId: "a", status: "all" })).toHaveLength(4);
  });

  it("按标签筛选", () => {
    expect(queryWords(index, { listId: "a", tag: "animal" }).map((w) => w.id)).toEqual([
      "cat",
    ]);
  });

  it("只看收藏", () => {
    expect(queryWords(index, { listId: "a", favoriteOnly: true }).map((w) => w.id)).toEqual([
      "apple",
    ]);
  });

  it("未知词库返回空数组", () => {
    expect(queryWords(index, { listId: "nope" })).toEqual([]);
  });
});

describe("queryWords — 排序", () => {
  it("recent：createdAt 降序，且是默认排序", () => {
    const index = buildWordIndex(appData(queryFixture()), NOW);
    expect(queryWords(index, { listId: "a", sort: "recent" }).map((w) => w.id)).toEqual([
      "apple",
      "boat",
      "cat",
      "zebra",
    ]);
    expect(queryWords(index, { listId: "a" }).map((w) => w.id)).toEqual([
      "apple",
      "boat",
      "cat",
      "zebra",
    ]);
  });

  it("alpha：term 按 lang 排序", () => {
    const index = buildWordIndex(appData(queryFixture()), NOW);
    expect(
      queryWords(index, { listId: "a", sort: "alpha", lang: "en" }).map((w) => w.id),
    ).toEqual(["apple", "boat", "cat", "zebra"]);
  });

  it("status：先状态序，再 term 兜底", () => {
    const words = [
      word("s1", { term: "cat", status: "reviewing" }),
      word("s2", { term: "zebra", status: "new" }),
      word("s3", { term: "ant", status: "reviewing" }),
    ];
    const index = buildWordIndex(appData(words), NOW);
    // new (rank 0) first, then the two reviewing words by term: ant < cat.
    expect(
      queryWords(index, { listId: "a", sort: "status", lang: "en" }).map((w) => w.id),
    ).toEqual(["s2", "s3", "s1"]);
  });

  it("due：dueAt 升序，同到期时间用状态序兜底", () => {
    const words = [
      word("d1", { status: "mastered", srs: srs({ dueAt: NOW + 2 * DAY }) }),
      word("d2", { status: "mastered", srs: srs({ dueAt: NOW }) }),
      word("d3", { status: "new", srs: srs({ dueAt: NOW }) }),
      word("d4", { status: "reviewing", srs: null }),
    ];
    const index = buildWordIndex(appData(words), NOW);
    // d4 has no srs → dueAt 0 → first. d2/d3 tie on dueAt; new ranks before
    // mastered, so d3 comes first even though d2 was inserted first.
    expect(queryWords(index, { listId: "a", sort: "due" }).map((w) => w.id)).toEqual([
      "d4",
      "d3",
      "d2",
      "d1",
    ]);
  });
});

/* ------------------------------------------------------------------ */
/* summarize                                                           */
/* ------------------------------------------------------------------ */

describe("summarize — 统计头条", () => {
  it("一次算出全部头条数字，且沿用旧 StatsPage 的算法", () => {
    const words = [
      word("w1", { status: "new", srs: null }),
      word("w2", {
        status: "reviewing",
        srs: srs({ dueAt: TODAY_START - 1, reviewCount: 3, correctCount: 2, intervalDays: 5 }),
      }),
      word("w3", {
        status: "learning",
        // Due exactly at midnight: due today, but NOT overdue.
        srs: srs({ dueAt: TODAY_START, reviewCount: 2, correctCount: 2, intervalDays: 7 }),
      }),
      word("w4", {
        status: "mastered",
        srs: srs({ dueAt: TODAY_START - DAY, reviewCount: 10, correctCount: 9, intervalDays: 30 }),
      }),
      word("w5", { status: "mastered", srs: null }),
      word("w6", { status: "new", srs: null }),
    ];
    const logs = [log(NOW), log(NOW - DAY), log(NOW - 2 * DAY), log(NOW - 4 * DAY)];
    const summary = summarize(appData(words, { logs, dailyGoal: 2 }), NOW);

    expect(summary.total).toBe(6);
    expect(summary.statusCounts).toEqual({
      new: 2,
      reviewing: 1,
      learning: 1,
      mastered: 2,
    });
    expect(summary.mastered).toBe(2);
    expect(summary.masteryPct).toBe(33); // 2/6 = 33.33 → 33
    expect(summary.overdue).toBe(1); // only w2 is strictly before midnight
    expect(summary.dueToday).toBe(4); // w1, w2, w3 (midnight), w6
    expect(summary.today).toBe(1);
    expect(summary.streak).toBe(3); // today, yesterday, day before
    expect(summary.goal).toBe(2);
    expect(summary.goalPct).toBe(0.5);
    expect(summary.reached).toBe(false);
    expect(summary.remaining).toBe(1);
    expect(summary.reviewSum).toBe(15);
    expect(summary.correctSum).toBe(13);
    expect(summary.reviewedWords).toBe(3);
    expect(summary.scheduled).toBe(3);
    expect(summary.retention).toBe(87); // 13/15 = 86.66 → 87
    expect(summary.avgInterval).toBe(14); // (5 + 7 + 30) / 3
  });

  it("没有可计算的复习时 retention 为 null，avgInterval 为 0", () => {
    const summary = summarize(appData([word("w1", { srs: null })], { logs: [] }), NOW);
    expect(summary.retention).toBeNull();
    expect(summary.avgInterval).toBe(0);
    expect(summary.today).toBe(0);
    expect(summary.streak).toBe(0);
    expect(summary.reviewedWords).toBe(0);
    expect(summary.dueToday).toBe(1);
    expect(summary.goal).toBe(DEFAULT_SETTINGS.dailyGoal);
  });

  it("有 srs 但 reviewCount 为 0 时同样不计入留存率", () => {
    const summary = summarize(
      appData([word("w1", { srs: srs({ reviewCount: 0, correctCount: 0 }) })]),
      NOW,
    );
    expect(summary.retention).toBeNull();
    expect(summary.avgInterval).toBe(0);
    expect(summary.reviewedWords).toBe(0);
    expect(summary.dueToday).toBe(1);
  });

  it("overdue 用严格小于今天零点：零点整不算逾期", () => {
    expect(
      summarize(appData([word("w1", { srs: srs({ dueAt: TODAY_START }) })]), NOW).overdue,
    ).toBe(0);
    expect(
      summarize(appData([word("w1", { srs: srs({ dueAt: TODAY_START - 1 }) })]), NOW).overdue,
    ).toBe(1);
  });

  it("masteryPct 四舍五入（12.5% → 13%）", () => {
    const words = [
      word("m", { status: "mastered" }),
      ...Array.from({ length: 7 }, (_, i) => word(`n${i}`, { status: "new" })),
    ];
    expect(summarize(appData(words), NOW).masteryPct).toBe(13);
  });

  it("goal 至少为 1，goalPct 封顶 1", () => {
    const summary = summarize(appData([word("w1")], { dailyGoal: 0, logs: [log(NOW)] }), NOW);
    expect(summary.goal).toBe(1);
    expect(summary.goalPct).toBe(1);
    expect(summary.reached).toBe(true);
    expect(summary.remaining).toBe(0);
  });
});
