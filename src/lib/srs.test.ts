import { describe, expect, it } from "vitest";
import {
  DAY_MS,
  INITIAL_EASE,
  LEARNING_INTERVAL_DAYS,
  MASTERED_INTERVAL_DAYS,
  MAX_EASE,
  MAX_INTERVAL_DAYS,
  MIN_EASE,
  applyGrade,
  formatInterval,
  freshSrs,
  isDue,
  isNew,
  previewIntervals,
  statusForInterval,
} from "./srs";
import type { Grade, SrsState, WordStatus } from "./types";

const NOW = new Date(2024, 5, 10, 12, 0, 0).getTime();
const GRADES: Grade[] = ["easy", "good", "hard"];

/** A card that has already been reviewed at least once. */
function reviewed(
  intervalDays: number,
  ease: number,
  overrides: Partial<SrsState> = {},
): SrsState {
  return {
    ease,
    intervalDays,
    dueAt: NOW + intervalDays * DAY_MS,
    reviewCount: 1,
    correctCount: 1,
    lastReviewedAt: NOW - DAY_MS,
    ...overrides,
  };
}

describe("freshSrs", () => {
  it("返回全新卡片的初始状态", () => {
    expect(freshSrs(NOW)).toEqual({
      ease: INITIAL_EASE,
      intervalDays: 0,
      dueAt: NOW,
      reviewCount: 0,
      correctCount: 0,
      lastReviewedAt: null,
    });
  });
});

describe("applyGrade — 首次评分", () => {
  it.each(GRADES)("%s 首次评分 → 间隔 1 天、复习次数 1", (grade) => {
    const next = applyGrade(null, grade, NOW);
    expect(next.intervalDays).toBe(1);
    expect(next.reviewCount).toBe(1);
    expect(next.ease).toBe(INITIAL_EASE);
    expect(next.lastReviewedAt).toBe(NOW);
    expect(next.dueAt).toBe(NOW + DAY_MS);
  });

  it("reviewCount 为 0 的 freshSrs 同样按首次评分处理", () => {
    const next = applyGrade(freshSrs(NOW), "easy", NOW);
    expect(next.intervalDays).toBe(1);
    expect(next.reviewCount).toBe(1);
  });

  it("easy / good 计入 correctCount，hard 不计入", () => {
    expect(applyGrade(null, "easy", NOW).correctCount).toBe(1);
    expect(applyGrade(null, "good", NOW).correctCount).toBe(1);
    expect(applyGrade(null, "hard", NOW).correctCount).toBe(0);
  });
});

describe("applyGrade — good", () => {
  it("good 连续两次：1 → 2（trunc(1 × 2.5)）", () => {
    const first = applyGrade(null, "good", NOW);
    const second = applyGrade(first, "good", NOW);
    expect(first.intervalDays).toBe(1);
    expect(second.intervalDays).toBe(2);
    expect(second.reviewCount).toBe(2);
    expect(second.dueAt).toBe(NOW + 2 * DAY_MS);
  });

  it("good 第三次：2 → 5", () => {
    let s: SrsState = applyGrade(null, "good", NOW);
    s = applyGrade(s, "good", NOW);
    s = applyGrade(s, "good", NOW);
    expect(s.intervalDays).toBe(5);
  });

  // 回归：曾因 `correct = difficulty <= 2` 把 good 误判为 lapse，
  // 导致间隔恒为 1、correctCount 不增长。
  it("good 递增 correctCount", () => {
    const first = applyGrade(null, "good", NOW);
    expect(first.correctCount).toBe(1);
    const second = applyGrade(first, "good", NOW);
    expect(second.correctCount).toBe(2);
  });

  it("good 在 ease 未封顶时 +0.1", () => {
    const next = applyGrade(reviewed(5, 2.0), "good", NOW);
    expect(next.intervalDays).toBe(10);
    expect(next.ease).toBe(2.1);
  });

  it("good 的 ease 不超过上限", () => {
    expect(applyGrade(reviewed(1, 2.5), "good", NOW).ease).toBe(MAX_EASE);
  });
});

describe("applyGrade — easy", () => {
  it("easy 第二次：1 → 3，比 good 长", () => {
    const first = applyGrade(null, "easy", NOW);
    const second = applyGrade(first, "easy", NOW);
    expect(first.intervalDays).toBe(1);
    expect(second.intervalDays).toBe(3);
  });

  it("同一状态下 easy 的间隔大于 good", () => {
    const small = reviewed(1, 2.5);
    expect(applyGrade(small, "easy", NOW).intervalDays).toBeGreaterThan(
      applyGrade(small, "good", NOW).intervalDays,
    );
    const big = reviewed(10, 2.5);
    expect(applyGrade(big, "easy", NOW).intervalDays).toBe(37);
    expect(applyGrade(big, "good", NOW).intervalDays).toBe(25);
  });

  it("easy 在 ease 未封顶时 +0.15", () => {
    const next = applyGrade(reviewed(5, 2.0), "easy", NOW);
    expect(next.intervalDays).toBe(15);
    expect(next.ease).toBe(2.15);
  });

  it("easy 的 ease 不超过上限", () => {
    expect(applyGrade(reviewed(1, 2.5), "easy", NOW).ease).toBe(MAX_EASE);
  });
});

describe("applyGrade — hard", () => {
  it("hard 把间隔重置为 1", () => {
    expect(applyGrade(reviewed(10, 2.5), "hard", NOW).intervalDays).toBe(1);
  });

  it("hard 使 ease 下降 0.2", () => {
    expect(applyGrade(reviewed(10, 2.5), "hard", NOW).ease).toBe(2.3);
  });

  it("hard 的 ease 不低于下限 1.3", () => {
    expect(applyGrade(reviewed(10, 1.4), "hard", NOW).ease).toBe(MIN_EASE);
    expect(applyGrade(reviewed(10, 1.3), "hard", NOW).ease).toBe(MIN_EASE);
  });

  it("hard 不增加 correctCount", () => {
    expect(
      applyGrade(reviewed(10, 2.5, { correctCount: 4 }), "hard", NOW).correctCount,
    ).toBe(4);
  });

  it("连续 hard 后 ease 停在 1.3", () => {
    let s: SrsState = reviewed(10, 2.5);
    for (let i = 0; i < 10; i++) s = applyGrade(s, "hard", NOW);
    expect(s.ease).toBe(MIN_EASE);
  });
});

describe("applyGrade — 边界", () => {
  it("反复 easy 时 ease 恰好封顶在 2.5", () => {
    let s: SrsState = freshSrs(NOW);
    for (let i = 0; i < 50; i++) s = applyGrade(s, "easy", NOW);
    expect(s.ease).toBe(MAX_EASE);
    expect(s.ease).toBeLessThanOrEqual(MAX_EASE);
  });

  it("间隔不超过 3650 天", () => {
    expect(applyGrade(reviewed(3000, 2.5), "easy", NOW).intervalDays).toBe(
      MAX_INTERVAL_DAYS,
    );
    expect(applyGrade(reviewed(3000, 2.5), "good", NOW).intervalDays).toBe(
      MAX_INTERVAL_DAYS,
    );
  });

  it("hard 之后间隔至少为 1 天", () => {
    expect(applyGrade(reviewed(0, 2.5), "hard", NOW).intervalDays).toBe(1);
  });

  it("不修改传入的状态对象", () => {
    const current = reviewed(4, 2.0);
    const snapshot = { ...current };
    const next = applyGrade(current, "good", NOW);
    expect(current).toEqual(snapshot);
    expect(next).not.toBe(current);
  });
});

describe("previewIntervals", () => {
  it("新卡三个评分都预览 1 天", () => {
    expect(previewIntervals(null, NOW)).toEqual({ hard: 1, good: 1, easy: 1 });
  });

  it("已复习卡片按真实调度预览", () => {
    expect(previewIntervals(reviewed(1, 2.5), NOW)).toEqual({
      hard: 1,
      good: 2,
      easy: 3,
    });
  });
});

describe("statusForInterval", () => {
  it.each([
    [0, "new"],
    [-3, "new"],
    [1, "reviewing"],
    [LEARNING_INTERVAL_DAYS - 1, "reviewing"],
    [LEARNING_INTERVAL_DAYS, "learning"],
    [MASTERED_INTERVAL_DAYS - 1, "learning"],
    [MASTERED_INTERVAL_DAYS, "mastered"],
    [MAX_INTERVAL_DAYS, "mastered"],
  ] as Array<[number, WordStatus]>)("%i 天 → %s", (days, status) => {
    expect(statusForInterval(days)).toBe(status);
  });
});

describe("formatInterval", () => {
  it.each([
    [0, "<1天"],
    [-5, "<1天"],
    [1, "1天"],
    [6, "6天"],
    [29, "29天"],
    [30, "1月"],
    [45, "2月"],
    [364, "12月"],
    [365, "1年"],
    [547, "1.5年"],
    [730, "2年"],
    [3650, "10年"],
    [4015, "11年"],
  ] as Array<[number, string]>)("%i 天 → %s", (days, label) => {
    expect(formatInterval(days)).toBe(label);
  });
});

describe("isDue / isNew", () => {
  it("null 视为到期且是新卡", () => {
    expect(isDue(null, NOW)).toBe(true);
    expect(isNew(null)).toBe(true);
  });

  it("dueAt 小于等于 now 视为到期", () => {
    expect(isDue(reviewed(1, 2.5, { dueAt: NOW }), NOW)).toBe(true);
    expect(isDue(reviewed(1, 2.5, { dueAt: NOW + 1 }), NOW)).toBe(false);
  });

  it("复习过的卡片不再是新卡", () => {
    expect(isNew(freshSrs(NOW))).toBe(true);
    expect(isNew(reviewed(1, 2.5))).toBe(false);
  });
});
