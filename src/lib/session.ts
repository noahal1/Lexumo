/**
 * One study session's bookkeeping: which card is up, what has been answered,
 * and what a mis-tap should roll back.
 *
 * This lives outside the pages because both study modes run the same state
 * machine, and because the "hard is reviewed but not recalled" rule used to be
 * written twice in opposite directions (once when grading, once when undoing).
 * Keeping it here means the counters and the SRS schedule cannot drift apart.
 *
 * Deliberately free of React, the store and the DOM so it can be unit-tested
 * and reused by any page.
 */
import type { Grade } from "./types";

/**
 * A reversible step. `undo()` hands the step back so a page can also revert the
 * side effect it performed outside this module — the flashcard page needs the
 * card id to restore the schedule it snapshotted before calling gradeWord.
 */
type Step =
  | { kind: "record"; id: string; correct: boolean }
  | { kind: "skip"; id: string };

export interface SessionProgress {
  /** How many cards have been passed; also the index of the current card. */
  index: number;
  total: number;
  /** Cards answered (grades only — skips are not reviews). */
  reviewed: number;
  correct: number;
  skipped: number;
  /** correct / reviewed, and 0 (not NaN) before the first answer. */
  accuracy: number;
  /** True once every card has been passed, by grade or by skip. */
  done: boolean;
}

export interface Session {
  /** The card to show now, or null once the session is done. */
  current(): string | null;
  progress(): SessionProgress;
  /** Record a graded answer and advance to the next card. */
  record(outcome: { correct: boolean }): void;
  /** Pass on the current card without counting it as reviewed. */
  skip(): void;
  /** Roll back the last step, or null when there is nothing to undo. */
  undo(): Step | null;
  /** Back to the first card, with no history. */
  reset(): void;
  canUndo(): boolean;
}

/**
 * The single place the "hard counts as reviewed but not recalled" rule lives.
 * It mirrors applyGrade in srs.ts (hard is a lapse, easy/good are recalls) so
 * the session accuracy and the word's SRS correctCount can never disagree.
 */
export function gradeCountsAsCorrect(grade: Grade): boolean {
  return grade !== "hard";
}

/** Percentage label shared by the in-session strip and the result card. */
export function formatAccuracy(accuracy: number): string {
  return `${Math.round(accuracy * 100)}%`;
}

export function createSession({ ids }: { ids: readonly string[] }): Session {
  const cards = [...ids];
  let index = 0;
  let reviewed = 0;
  let correct = 0;
  let skipped = 0;
  const steps: Step[] = [];

  return {
    current() {
      return index < cards.length ? cards[index] : null;
    },

    progress() {
      return {
        index,
        total: cards.length,
        reviewed,
        correct,
        skipped,
        accuracy: reviewed > 0 ? correct / reviewed : 0,
        done: index >= cards.length,
      };
    },

    record({ correct: wasCorrect }) {
      if (index >= cards.length) return;
      steps.push({ kind: "record", id: cards[index], correct: wasCorrect });
      index += 1;
      reviewed += 1;
      if (wasCorrect) correct += 1;
    },

    skip() {
      if (index >= cards.length) return;
      steps.push({ kind: "skip", id: cards[index] });
      index += 1;
      skipped += 1;
    },

    undo() {
      const step = steps.pop();
      if (!step) return null;
      index -= 1;
      if (step.kind === "record") {
        reviewed -= 1;
        if (step.correct) correct -= 1;
      } else {
        skipped -= 1;
      }
      return step;
    },

    reset() {
      index = 0;
      reviewed = 0;
      correct = 0;
      skipped = 0;
      steps.length = 0;
    },

    canUndo() {
      return steps.length > 0;
    },
  };
}
