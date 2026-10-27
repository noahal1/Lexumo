/**
 * Per-day activity helpers: how much was reviewed today, and how many days in
 * a row the user has studied.
 *
 * They live outside the store because two very different consumers need the
 * same numbers — the sidebar reads them through the store, and the pure word
 * index builds the stats headline from them. A second copy is exactly how the
 * two screens drift apart, so there is one definition here.
 *
 * Pure: types and date helpers only.
 */
import type { AppData } from "./types";
import { dayKey, startOfDay } from "./utils";

/** Reviews recorded since local midnight. */
export function reviewsToday(data: AppData, now = Date.now()): number {
  const t0 = startOfDay(now);
  return data.logs.filter((l) => l.at >= t0).length;
}

/**
 * Consecutive days with at least one review, counting back from today.
 *
 * Today being empty does not break the streak — it just starts the count from
 * yesterday, so an unfinished day never looks like a lost streak.
 */
export function streakDays(data: AppData, now = Date.now()): number {
  const days = new Set<string>();
  for (const log of data.logs) days.add(dayKey(log.at));

  let streak = 0;
  const cursor = new Date(now);
  if (!days.has(dayKey(cursor.getTime()))) cursor.setDate(cursor.getDate() - 1);
  for (;;) {
    if (!days.has(dayKey(cursor.getTime()))) break;
    streak += 1;
    cursor.setDate(cursor.getDate() - 1);
  }
  return streak;
}
