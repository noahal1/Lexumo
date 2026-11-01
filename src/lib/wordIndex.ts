/**
 * Word index — the one owner of the derivations the words and stats screens
 * used to each hand-roll: per-list buckets, status counts, tag pools and the
 * filtered/sorted query.
 *
 * Deliberately pure: no React, no DOM and no store import (types only), so the
 * pages and the tests can share exactly one implementation. That is what stops
 * the header, the filter controls and the stats page from disagreeing.
 */
import type { AppData, Word, WordStatus } from "./types";
import { startOfDay } from "./utils";
import { statusRank } from "./srs";
import { reviewsToday, streakDays } from "./dayStats";

export type StatusFilter = "all" | WordStatus;
export type SortKey = "recent" | "alpha" | "due" | "status";

/* The status ordering is owned by srs.ts (the never-demote rule needs it);
   re-exported so the index's callers and tests keep one import site. */
export { statusRank };

interface WordIndex {
  /** Words of one list, in snapshot order. */
  byList: Map<string, Word[]>;
  /** Status tallies per list, including the "all" bucket. */
  countsByList: Map<string, Record<StatusFilter, number>>;
  /** Global due bucket (same predicate as store.dueWords). */
  due: Word[];
  /** Due bucket per list, so a page can show a list-scoped count. */
  dueByList: Map<string, Word[]>;
}

export interface WordQuery {
  listId: string;
  query?: string;
  status?: StatusFilter;
  favoriteOnly?: boolean;
  sort?: SortKey;
  /** Locale for term collation; the UI passes the active UI language. */
  lang?: string;
}

interface StatsSummary {
  total: number;
  statusCounts: Record<WordStatus, number>;
  mastered: number;
  today: number;
  streak: number;
  goal: number;
  goalPct: number;
  reached: boolean;
  remaining: number;
  masteryPct: number;
  retention: number | null;
  avgInterval: number;
  overdue: number;
  dueToday: number;
  /* Raw sums the retention / interval captions need, kept here so the page
     never re-derives them and cannot drift from the percentages above. */
  reviewSum: number;
  correctSum: number;
  reviewedWords: number;
  scheduled: number;
}

/** Same predicate as store.dueWords: mastered cards are never due, a card
 *  that was never reviewed always is. */
function isDue(word: Word, now: number): boolean {
  if (word.status === "mastered") return false;
  if (!word.srs) return true;
  return word.srs.dueAt <= now;
}

function emptyCounts(): Record<StatusFilter, number> {
  return { all: 0, new: 0, reviewing: 0, learning: 0, mastered: 0 };
}

export function buildWordIndex(data: AppData, now = Date.now()): WordIndex {
  const byList = new Map<string, Word[]>();
  const countsByList = new Map<string, Record<StatusFilter, number>>();
  const due: Word[] = [];
  const dueByList = new Map<string, Word[]>();

  // Seed declared lists so an empty list still has a bucket and zero counts.
  for (const list of data.lists) {
    byList.set(list.id, []);
    countsByList.set(list.id, emptyCounts());
  }

  // One pass over the words fills every bucket at once.
  for (const word of data.words) {
    let words = byList.get(word.listId);
    if (!words) {
      words = [];
      byList.set(word.listId, words);
    }
    words.push(word);

    let counts = countsByList.get(word.listId);
    if (!counts) {
      counts = emptyCounts();
      countsByList.set(word.listId, counts);
    }
    counts.all += 1;
    counts[word.status] += 1;

    if (isDue(word, now)) {
      due.push(word);
      const bucket = dueByList.get(word.listId);
      if (bucket) bucket.push(word);
      else dueByList.set(word.listId, [word]);
    }
  }

  return { byList, countsByList, due, dueByList };
}

export function queryWords(index: WordIndex, filter: WordQuery): Word[] {
  const base = index.byList.get(filter.listId) ?? [];
  const needle = (filter.query ?? "").trim().toLocaleLowerCase();

  let out = base;
  if (needle) {
    out = out.filter(
      (w) =>
        w.term.toLocaleLowerCase().includes(needle) ||
        w.definition.toLocaleLowerCase().includes(needle) ||
        w.definition2.toLocaleLowerCase().includes(needle) ||
        w.note.toLocaleLowerCase().includes(needle),
    );
  }
  const status = filter.status;
  if (status && status !== "all") out = out.filter((w) => w.status === status);
  if (filter.favoriteOnly) out = out.filter((w) => w.favorite);

  const lang = filter.lang;
  const sorted = out.slice();
  switch (filter.sort) {
    case "alpha":
      sorted.sort((a, b) => a.term.localeCompare(b.term, lang));
      break;
    case "due":
      sorted.sort(
        (a, b) =>
          (a.srs?.dueAt ?? 0) - (b.srs?.dueAt ?? 0) ||
          statusRank(a.status) - statusRank(b.status),
      );
      break;
    case "status":
      sorted.sort(
        (a, b) =>
          statusRank(a.status) - statusRank(b.status) ||
          a.term.localeCompare(b.term, lang),
      );
      break;
    case "recent":
    default:
      sorted.sort((a, b) => b.createdAt - a.createdAt);
      break;
  }
  return sorted;
}

/**
 * The whole stats headline in one object. The arithmetic is copied verbatim
 * from the old StatsPage accumulator so no number moves.
 */
export function summarize(data: AppData, now = Date.now()): StatsSummary {
  const words = data.words;
  const total = words.length;

  const statusCounts: Record<WordStatus, number> = {
    new: 0,
    reviewing: 0,
    learning: 0,
    mastered: 0,
  };
  let reviewSum = 0;
  let correctSum = 0;
  let reviewedWords = 0;
  let intervalSum = 0;
  let scheduled = 0;
  let overdue = 0;
  const todayStart = startOfDay(now);
  const dueToday = words.filter((w) => isDue(w, now)).length;

  for (const w of words) {
    statusCounts[w.status] += 1;
    const srs = w.srs;
    if (srs) {
      if (w.status !== "mastered" && srs.dueAt < todayStart) overdue += 1;
      if (srs.reviewCount > 0) {
        reviewedWords += 1;
        reviewSum += srs.reviewCount;
        correctSum += srs.correctCount;
        intervalSum += srs.intervalDays;
        scheduled += 1;
      }
    }
  }

  const mastered = statusCounts.mastered;
  const today = reviewsToday(data, now);
  const streak = streakDays(data, now);
  const goal = Math.max(1, data.settings.dailyGoal);
  const goalPct = Math.min(1, today / goal);
  const reached = today >= goal;
  const remaining = Math.max(0, goal - today);
  const masteryPct = total > 0 ? Math.round((mastered / total) * 100) : 0;
  const retention = reviewSum > 0 ? Math.round((correctSum / reviewSum) * 100) : null;
  const avgInterval = scheduled > 0 ? intervalSum / scheduled : 0;

  return {
    total,
    statusCounts,
    mastered,
    today,
    streak,
    goal,
    goalPct,
    reached,
    remaining,
    masteryPct,
    retention,
    avgInterval,
    overdue,
    dueToday,
    reviewSum,
    correctSum,
    reviewedWords,
    scheduled,
  };
}
