import { describe, expect, it } from "vitest";
import { reviewsToday, streakDays } from "./dayStats";
import { DEFAULT_SETTINGS, type AppData, type Grade, type ReviewLog } from "./types";

/* Local noon so "today" is unambiguous in every timezone the test runs in. */
const NOW = new Date(2024, 5, 10, 12, 0, 0).getTime();

function log(at: number, grade: Grade = "good"): ReviewLog {
  return { id: `log_${at}`, wordId: "w", grade, at, intervalBefore: 1, intervalAfter: 2 };
}

function appData(logs: ReviewLog[]): AppData {
  return {
    version: 2,
    lists: [],
    words: [],
    logs,
    settings: { ...DEFAULT_SETTINGS },
    settingsUpdatedAt: 0,
    tombstones: { words: {}, lists: {}, logs: {} },
    pending: { words: [], lists: [], logs: [], settings: false },
  };
}

/** Local midnight `n` days before today's. */
function daysAgo(n: number): number {
  const d = new Date(2024, 5, 10, 0, 0, 0, 0);
  d.setDate(d.getDate() - n);
  return d.getTime();
}

describe("reviewsToday", () => {
  it("counts only reviews since local midnight", () => {
    const data = appData([log(daysAgo(1) + 12 * 3_600_000), log(daysAgo(0)), log(NOW)]);
    expect(reviewsToday(data, NOW)).toBe(2);
  });

  it("counts a review at exactly midnight as today", () => {
    expect(reviewsToday(appData([log(daysAgo(0))]), NOW)).toBe(1);
  });

  it("is zero without logs", () => {
    expect(reviewsToday(appData([]), NOW)).toBe(0);
  });
});

describe("streakDays", () => {
  it("counts consecutive days ending today", () => {
    const data = appData([log(daysAgo(0)), log(daysAgo(1)), log(daysAgo(2))]);
    expect(streakDays(data, NOW)).toBe(3);
  });

  it("does not break the streak when today is still empty", () => {
    // Yesterday and the day before, nothing yet today: the streak is still 2.
    const data = appData([log(daysAgo(1)), log(daysAgo(2))]);
    expect(streakDays(data, NOW)).toBe(2);
  });

  it("stops at the first missing day", () => {
    const data = appData([log(daysAgo(0)), log(daysAgo(1)), log(daysAgo(3))]);
    expect(streakDays(data, NOW)).toBe(2);
  });

  it("counts several reviews on one day once", () => {
    const data = appData([log(daysAgo(0) + 3_600_000), log(NOW)]);
    expect(streakDays(data, NOW)).toBe(1);
  });

  it("is zero with no logs, and zero when the last review is older than yesterday", () => {
    expect(streakDays(appData([]), NOW)).toBe(0);
    expect(streakDays(appData([log(daysAgo(3))]), NOW)).toBe(0);
  });

  it("keeps month and day apart (0-based months must not collide)", () => {
    // Jan 31 → Feb 1 is a real consecutive pair; a key that concatenated the
    // unpadded numbers would still work here, but a padded one must too.
    const jan31 = new Date(2024, 0, 31, 12).getTime();
    const feb01 = new Date(2024, 1, 1, 12).getTime();
    expect(streakDays(appData([log(jan31), log(feb01)]), feb01)).toBe(2);
  });
});
