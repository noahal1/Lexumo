/// One study session's bookkeeping: which card is up, what has been answered,
/// and what a mis-tap should roll back.
///
/// Ported from `src/lib/session.ts`. It lives outside the pages because both
/// study modes run the same state machine, and because the "hard is reviewed
/// but not recalled" rule used to be written twice in opposite directions
/// (once when grading, once when undoing). Keeping it here means the counters
/// and the SRS schedule cannot drift apart.
///
/// Deliberately free of Flutter, the store and the DOM so it can be unit-tested
/// and reused by any page.
library;

import 'types.dart';
import 'utils.dart';

/// A reversible step. [Session.undo] hands the step back so a page can also
/// revert the side effect it performed outside this module — the flashcard
/// page needs the card id to restore the schedule it snapshotted before
/// calling `gradeWord`.
sealed class Step {
  const Step(this.id);

  /// The card this step was taken on.
  final String id;
}

final class RecordStep extends Step {
  const RecordStep(super.id, {required this.correct});

  final bool correct;

  @override
  bool operator ==(Object other) =>
      other is RecordStep && other.id == id && other.correct == correct;

  @override
  int get hashCode => Object.hash('record', id, correct);

  @override
  String toString() => 'RecordStep(id: $id, correct: $correct)';
}

final class SkipStep extends Step {
  const SkipStep(super.id);

  @override
  bool operator ==(Object other) => other is SkipStep && other.id == id;

  @override
  int get hashCode => Object.hash('skip', id);

  @override
  String toString() => 'SkipStep(id: $id)';
}

/// The counters a session's progress strip and result card read.
class SessionProgress {
  const SessionProgress({
    required this.index,
    required this.total,
    required this.reviewed,
    required this.correct,
    required this.skipped,
    required this.accuracy,
    required this.done,
  });

  /// How many cards have been passed; also the index of the current card.
  final int index;
  final int total;

  /// Cards answered (grades only — skips are not reviews).
  final int reviewed;
  final int correct;
  final int skipped;

  /// correct / reviewed, and 0 (not NaN) before the first answer.
  final double accuracy;

  /// True once every card has been passed, by grade or by skip.
  final bool done;

  @override
  bool operator ==(Object other) =>
      other is SessionProgress &&
      other.index == index &&
      other.total == total &&
      other.reviewed == reviewed &&
      other.correct == correct &&
      other.skipped == skipped &&
      other.accuracy == accuracy &&
      other.done == done;

  @override
  int get hashCode =>
      Object.hash(index, total, reviewed, correct, skipped, accuracy, done);

  @override
  String toString() => 'SessionProgress(index: $index, total: $total, '
      'reviewed: $reviewed, correct: $correct, skipped: $skipped, '
      'accuracy: $accuracy, done: $done)';
}

/// The session state machine the pages drive.
abstract class Session {
  /// The card to show now, or null once the session is done.
  String? current();

  SessionProgress progress();

  /// Record a graded answer and advance to the next card.
  void record({required bool correct});

  /// Pass on the current card without counting it as reviewed.
  void skip();

  /// Roll back the last step, or null when there is nothing to undo.
  Step? undo();

  /// Back to the first card, with no history.
  void reset();

  bool canUndo();
}

/// The single place the "hard counts as reviewed but not recalled" rule lives.
/// It mirrors the scheduling rule in `srs.dart` (hard is a lapse, easy/good are
/// recalls) so the session accuracy and the word's SRS correctCount can never
/// disagree.
bool gradeCountsAsCorrect(Grade grade) => grade != Grade.hard;

/// Percentage label shared by the in-session strip and the result card.
String formatAccuracy(double accuracy) => '${jsRound(accuracy * 100)}%';

/// Build a session over [ids], in the order given.
Session createSession({required List<String> ids}) => _Session(ids);

class _Session implements Session {
  _Session(List<String> ids) : cards = List<String>.unmodifiable(ids);

  final List<String> cards;
  int _index = 0;
  int _reviewed = 0;
  int _correct = 0;
  int _skipped = 0;
  final List<Step> _steps = [];

  @override
  String? current() => _index < cards.length ? cards[_index] : null;

  @override
  SessionProgress progress() => SessionProgress(
        index: _index,
        total: cards.length,
        reviewed: _reviewed,
        correct: _correct,
        skipped: _skipped,
        accuracy: _reviewed > 0 ? _correct / _reviewed : 0,
        done: _index >= cards.length,
      );

  @override
  void record({required bool correct}) {
    if (_index >= cards.length) return;
    _steps.add(RecordStep(cards[_index], correct: correct));
    _index += 1;
    _reviewed += 1;
    if (correct) _correct += 1;
  }

  @override
  void skip() {
    if (_index >= cards.length) return;
    _steps.add(SkipStep(cards[_index]));
    _index += 1;
    _skipped += 1;
  }

  @override
  Step? undo() {
    if (_steps.isEmpty) return null;
    final step = _steps.removeLast();
    _index -= 1;
    if (step is RecordStep) {
      _reviewed -= 1;
      if (step.correct) _correct -= 1;
    } else {
      _skipped -= 1;
    }
    return step;
  }

  @override
  void reset() {
    _index = 0;
    _reviewed = 0;
    _correct = 0;
    _skipped = 0;
    _steps.clear();
  }

  @override
  bool canUndo() => _steps.isNotEmpty;
}
