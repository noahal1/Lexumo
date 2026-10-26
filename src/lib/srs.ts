/**
 * SM-2 style spaced repetition, mirroring the scheduling rules of the
 * reference app (Lingueez) so behaviour feels familiar:
 *
 *   Easy  → interval × ease × 1.5, ease +0.15
 *   Good  → interval × ease,       ease +0.10
 *   Hard  → interval = 1,          ease −0.20
 *
 * Ease is clamped to [1.3, 2.5]; intervals are clamped to [1, 3650] days.
 * Status is derived from the earned interval, not from answer counts.
 */
import type { Grade, SrsState, WordStatus } from "./types";

export const INITIAL_EASE = 2.5;
export const MAX_EASE = 2.5;
export const MIN_EASE = 1.3;
export const MAX_INTERVAL_DAYS = 3650;
export const LEARNING_INTERVAL_DAYS = 7;
export const MASTERED_INTERVAL_DAYS = 21;

export const DAY_MS = 86_400_000;

const GRADE_DIFFICULTY: Record<Grade, number> = { easy: 1, good: 3, hard: 5 };

export function freshSrs(now = Date.now()): SrsState {
  return {
    ease: INITIAL_EASE,
    intervalDays: 0,
    dueAt: now,
    reviewCount: 0,
    correctCount: 0,
    lastReviewedAt: null,
  };
}

export function applyGrade(
  current: SrsState | null,
  grade: Grade,
  now = Date.now(),
): SrsState {
  const difficulty = GRADE_DIFFICULTY[grade];
  // Easy (1) and Good (3) count as recalls; only Hard (5) is a lapse.
  const correct = difficulty <= 3;

  if (!current || current.reviewCount === 0) {
    return {
      ease: INITIAL_EASE,
      intervalDays: 1,
      dueAt: now + DAY_MS,
      reviewCount: 1,
      correctCount: correct ? 1 : 0,
      lastReviewedAt: now,
    };
  }

  let ease = current.ease || INITIAL_EASE;
  let interval = current.intervalDays || 1;
  const reviewCount = current.reviewCount + 1;
  let correctCount = current.correctCount || 0;

  if (correct) {
    correctCount += 1;
    if (difficulty === 1) {
      interval = Math.trunc(interval * ease * 1.5);
      ease = Math.min(ease + 0.15, MAX_EASE);
    } else {
      interval = Math.trunc(interval * ease);
      ease = Math.min(ease + 0.1, MAX_EASE);
    }
  } else {
    interval = 1;
    ease = Math.max(ease - 0.2, MIN_EASE);
  }

  interval = Math.max(1, Math.min(interval, MAX_INTERVAL_DAYS));

  return {
    ease: Math.round(ease * 10_000) / 10_000,
    intervalDays: interval,
    dueAt: now + interval * DAY_MS,
    reviewCount,
    correctCount,
    lastReviewedAt: now,
  };
}

/** What each grade would schedule, for the buttons' interval preview. */
export function previewIntervals(current: SrsState | null, now = Date.now()) {
  return {
    hard: applyGrade(current, "hard", now).intervalDays,
    good: applyGrade(current, "good", now).intervalDays,
    easy: applyGrade(current, "easy", now).intervalDays,
  };
}

/** Status ladder derived from the interval a card has earned. */
export function statusForInterval(intervalDays: number): WordStatus {
  if (intervalDays >= MASTERED_INTERVAL_DAYS) return "mastered";
  if (intervalDays >= LEARNING_INTERVAL_DAYS) return "learning";
  if (intervalDays > 0) return "reviewing";
  return "new";
}

export function isDue(srs: SrsState | null, now = Date.now()): boolean {
  if (!srs) return true;
  return srs.dueAt <= now;
}

export function isNew(srs: SrsState | null): boolean {
  return !srs || srs.reviewCount === 0;
}

/** Human-friendly interval label: 1天 / 3天 / 2月 / 1年. */
export function formatInterval(days: number): string {
  if (days < 1) return "<1天";
  if (days < 30) return `${days}天`;
  if (days < 365) return `${Math.round(days / 30)}月`;
  const years = days / 365;
  return `${years >= 10 ? Math.round(years) : years.toFixed(1).replace(/\.0$/, "")}年`;
}
