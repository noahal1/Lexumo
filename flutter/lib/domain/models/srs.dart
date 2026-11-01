/// SM-2 style spaced repetition, mirroring the scheduling rules of the
/// reference app (Lingueez) so behaviour feels familiar:
///
///   Easy  → interval × ease × 1.5, ease +0.15
///   Good  → interval × ease,       ease +0.10
///   Hard  → interval = 1,          ease −0.20
///
/// Ease is clamped to [1.3, 2.5]; intervals to [1, 3650] days. Status is derived
/// from the earned interval (not from answer counts) and then only ever
/// promoted, never demoted — see [nextStatus].
///
/// Ported line-for-line from `src/lib/srs.ts`. The constants and the grade table
/// are not tunable here, they *are* the app's existing behaviour: a snapshot
/// reviewed by the web build and one reviewed here must land on the same
/// schedule. Any change belongs in both files until the web build is retired.
library;

import 'types.dart';

const int DAY_MS = 86400000;

const double INITIAL_EASE = 2.5;
const double MAX_EASE = 2.5;
const double MIN_EASE = 1.3;

const int MAX_INTERVAL_DAYS = 3650;

/// A card at or above this interval is "learning".
const int LEARNING_INTERVAL_DAYS = 7;

/// A card at or above this interval is "mastered".
const int MASTERED_INTERVAL_DAYS = 21;

/// Difficulty per grade. Easy (1) and Good (3) count as recalls; only Hard (5)
/// is a lapse.
const Map<Grade, int> GRADE_DIFFICULTY = {
  Grade.easy: 1,
  Grade.good: 3,
  Grade.hard: 5,
};

/// Ladder order. Mirrors `STATUS_ORDER` in `types.ts`; [WordStatus.rank] is this
/// index, so the never-demote rule cannot drift when a status is added.
const List<WordStatus> STATUS_ORDER = [
  WordStatus.new_,
  WordStatus.reviewing,
  WordStatus.learning,
  WordStatus.mastered,
];

/// A card that has never been reviewed.
SrsState freshSrs(int now) => SrsState(
      ease: INITIAL_EASE,
      intervalDays: 0,
      dueAt: now,
      reviewCount: 0,
      correctCount: 0,
      lastReviewedAt: null,
    );

/// Advance a schedule by one grade.
SrsState applyGrade(SrsState? current, Grade grade, int now) {
  final difficulty = GRADE_DIFFICULTY[grade]!;
  final correct = difficulty <= 3;

  // First review of a new card: the interval is one day whatever the grade,
  // and the ease is not moved — there is no history to move it from.
  if (current == null || current.reviewCount == 0) {
    return SrsState(
      ease: INITIAL_EASE,
      intervalDays: 1,
      dueAt: now + DAY_MS,
      reviewCount: 1,
      correctCount: correct ? 1 : 0,
      lastReviewedAt: now,
    );
  }

  var ease = current.ease == 0 ? INITIAL_EASE : current.ease;
  var interval = current.intervalDays == 0 ? 1 : current.intervalDays;
  final reviewCount = current.reviewCount + 1;
  var correctCount = current.correctCount;

  if (correct) {
    correctCount += 1;
    if (difficulty == 1) {
      interval = (interval * ease * 1.5).truncate();
      ease = ease + 0.15 > MAX_EASE ? MAX_EASE : ease + 0.15;
    } else {
      interval = (interval * ease).truncate();
      ease = ease + 0.1 > MAX_EASE ? MAX_EASE : ease + 0.1;
    }
  } else {
    interval = 1;
    ease = ease - 0.2 < MIN_EASE ? MIN_EASE : ease - 0.2;
  }

  interval = interval < 1 ? 1 : (interval > MAX_INTERVAL_DAYS ? MAX_INTERVAL_DAYS : interval);

  return SrsState(
    // Four decimals, matching the TS rounding, so repeated grades in either
    // build produce byte-identical snapshots.
    ease: (ease * 10000).round() / 10000,
    intervalDays: interval,
    dueAt: now + interval * DAY_MS,
    reviewCount: reviewCount,
    correctCount: correctCount,
    lastReviewedAt: now,
  );
}

/// Status ladder derived from the interval a card has earned.
WordStatus statusForInterval(int intervalDays) {
  if (intervalDays >= MASTERED_INTERVAL_DAYS) return WordStatus.mastered;
  if (intervalDays >= LEARNING_INTERVAL_DAYS) return WordStatus.learning;
  if (intervalDays > 0) return WordStatus.reviewing;
  return WordStatus.new_;
}

/// Position on the status ladder, derived from [STATUS_ORDER] rather than a
/// second hand-written table.
int statusRank(WordStatus status) => STATUS_ORDER.indexOf(status);

/// The "never demote" rule: a grade may promote a card but must not push it
/// back down the ladder. Hard resets the interval to one day, so without this a
/// mastered word would lose its badge after a single slip.
WordStatus nextStatus(WordStatus earned, WordStatus current) =>
    statusRank(earned) > statusRank(current) ? earned : current;

/// The card fields the decision reads; mirrors the matching [Word] fields.
class CardState {
  const CardState({required this.srs, required this.status});
  final SrsState? srs;
  final WordStatus status;
}

/// One grade's decision. Shared by [reviewCard] (what gets stored) and
/// [previewGrades] (what the buttons show), so the preview and the applied grade
/// cannot disagree.
({SrsState srs, WordStatus status}) decide(CardState card, Grade grade, int now) {
  final srs = applyGrade(card.srs, grade, now);
  final earned = statusForInterval(srs.intervalDays);
  return (srs: srs, status: nextStatus(earned, card.status));
}

/// Apply one grade to a card: the new schedule, the promoted status, and the
/// review-log entry to append. Pure — the caller supplies the ids (rather than
/// minting them here) and owns persistence.
({SrsState srs, WordStatus status, ReviewLog log}) reviewCard(
  CardState card,
  Grade grade,
  int now, {
  required String wordId,
  required String logId,
}) {
  final decision = decide(card, grade, now);
  final log = ReviewLog(
    id: logId,
    wordId: wordId,
    grade: grade,
    at: now,
    intervalBefore: card.srs?.intervalDays ?? 0,
    intervalAfter: decision.srs.intervalDays,
  );
  return (srs: decision.srs, status: decision.status, log: log);
}

/// The exact inverse of [reviewCard]: restore the previous card verbatim and
/// hand back the log id to drop.
///
/// It must NOT recompute the schedule from the grade. A recompute would demote a
/// mastered word that just lapsed — the never-demote rule already swallowed that
/// demotion when the grade was applied — so the only correct undo is the
/// snapshot the caller took before grading.
({SrsState? srs, WordStatus status, String removedLogId}) undoGrade(
  CardState prev,
  String logId,
) =>
    (srs: prev.srs, status: prev.status, removedLogId: logId);

/// What each grade would do, for the buttons' preview. Returns the status the
/// grade would store, not just the interval, so a mastered card previews as
/// "stays mastered" rather than as the interval's raw status.
Map<Grade, ({int intervalDays, WordStatus status})> previewGrades(
  CardState card,
  int now,
) {
  ({int intervalDays, WordStatus status}) preview(Grade grade) {
    final d = decide(card, grade, now);
    return (intervalDays: d.srs.intervalDays, status: d.status);
  }

  return {
    Grade.hard: preview(Grade.hard),
    Grade.good: preview(Grade.good),
    Grade.easy: preview(Grade.easy),
  };
}

/// A card with no schedule, or one that has never been reviewed.
bool isNew(SrsState? srs) => srs == null || srs.reviewCount == 0;

/// Human-friendly interval label: `<1天` / `3天` / `2月` / `1年`.
String formatInterval(int days) {
  if (days < 1) return '<1天';
  if (days < 30) return '$days天';
  if (days < 365) return '${(days / 30).round()}月';
  final years = days / 365;
  if (years >= 10) return '${years.round()}年';
  // One decimal, with a trailing ".0" dropped — `toFixed(1).replace(/\.0$/,'')`.
  final oneDecimal = years.toStringAsFixed(1);
  return '${oneDecimal.endsWith('.0') ? oneDecimal.substring(0, oneDecimal.length - 2) : oneDecimal}年';
}

/// Due-ness at [now]. A card without a schedule is due. (Selectors in
/// `store.ts` apply this; kept next to the maths it belongs to.)
bool isDue(Word w, int now) {
  final srs = w.srs;
  if (srs == null) return true;
  return srs.dueAt <= now;
}
