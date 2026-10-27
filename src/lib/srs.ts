/**
 * SM-2 style spaced repetition, mirroring the scheduling rules of the
 * reference app (Lingueez) so behaviour feels familiar:
 *
 *   Easy  → interval × ease × 1.5, ease +0.15
 *   Good  → interval × ease,       ease +0.10
 *   Hard  → interval = 1,          ease −0.20
 *
 * Ease is clamped to [1.3, 2.5]; intervals are clamped to [1, 3650] days.
 * Status is derived from the earned interval (not from answer counts) and then
 * only ever promoted, never demoted — see `nextStatus`.
 */
import {
  STATUS_ORDER,
  type Grade,
  type ReviewLog,
  type SrsState,
  type WordStatus,
} from "./types";

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

/** Status ladder derived from the interval a card has earned. */
export function statusForInterval(intervalDays: number): WordStatus {
  if (intervalDays >= MASTERED_INTERVAL_DAYS) return "mastered";
  if (intervalDays >= LEARNING_INTERVAL_DAYS) return "learning";
  if (intervalDays > 0) return "reviewing";
  return "new";
}

/* ------------------------------------------------------------------ */
/* The review decision: schedule + status + log                        */
/* ------------------------------------------------------------------ */

/**
 * Position on the status ladder. Derived from `STATUS_ORDER` instead of a
 * second hand-written table, so adding a status in types.ts cannot leave the
 * never-demote rule silently out of date.
 */
export function statusRank(status: WordStatus): number {
  return STATUS_ORDER.indexOf(status);
}

/**
 * The "never demote" rule: a grade may promote a card but must not push it
 * back down the ladder. Hard resets the interval to one day, so without this a
 * mastered word would lose its badge after a single slip.
 */
export function nextStatus(earned: WordStatus, current: WordStatus): WordStatus {
  return statusRank(earned) > statusRank(current) ? earned : current;
}

/** The card fields the decision reads; mirrors the matching `Word` fields. */
export interface CardState {
  srs: SrsState | null;
  status: WordStatus;
}

/**
 * One grade's decision. Shared by `reviewCard` (what gets stored) and
 * `previewGrades` (what the buttons show), so the preview and the applied
 * grade cannot disagree.
 */
function decide(
  card: CardState,
  grade: Grade,
  now: number,
): { srs: SrsState; status: WordStatus } {
  const srs = applyGrade(card.srs, grade, now);
  const earned = statusForInterval(srs.intervalDays);
  return { srs, status: nextStatus(earned, card.status) };
}

/**
 * Apply one grade to a card: the new schedule, the promoted status, and the
 * review-log entry to append. Pure — the caller supplies the ids (rather than
 * minting them here) and owns persistence.
 */
export function reviewCard(
  card: CardState,
  grade: Grade,
  now: number,
  ids: { wordId: string; logId: string },
): { srs: SrsState; status: WordStatus; log: ReviewLog } {
  const { srs, status } = decide(card, grade, now);
  const log: ReviewLog = {
    id: ids.logId,
    wordId: ids.wordId,
    grade,
    at: now,
    intervalBefore: card.srs?.intervalDays ?? 0,
    intervalAfter: srs.intervalDays,
  };
  return { srs, status, log };
}

/**
 * The exact inverse of `reviewCard`: restore the previous card verbatim and
 * hand back the log id to drop.
 *
 * It must NOT recompute the schedule from the grade. A recompute would demote
 * a mastered word that just lapsed — the never-demote rule already swallowed
 * that demotion when the grade was applied — so the only correct undo is the
 * snapshot the caller took before grading. `log` is only read for its id,
 * hence the `Pick`; a whole `ReviewLog` satisfies it.
 */
export function undoGrade(
  prev: CardState,
  log: Pick<ReviewLog, "id">,
): { srs: SrsState | null; status: WordStatus; removedLogId: string } {
  return { srs: prev.srs, status: prev.status, removedLogId: log.id };
}

/**
 * What each grade would do, for the buttons' preview. Returns the same status
 * the grade would store, not just the interval, so a mastered card previews
 * as "stays mastered" rather than as the interval's raw status.
 */
export function previewGrades(
  card: CardState,
  now = Date.now(),
): Record<Grade, { intervalDays: number; status: WordStatus }> {
  const preview = (grade: Grade) => {
    const { srs, status } = decide(card, grade, now);
    return { intervalDays: srs.intervalDays, status };
  };
  return { hard: preview("hard"), good: preview("good"), easy: preview("easy") };
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
