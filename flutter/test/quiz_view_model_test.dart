// Unit tests for the quiz screen's view model.
//
// The point of pulling the round out of `_QuizPageState` is that none of it
// needs a widget. These tests build a [QuizViewModel] over a real [Store] and a
// [FakeFeedback] and drive whole rounds — start, answer, advance, finish — with
// no pumped tree, no `BuildContext` and no TTS plugin in sight.
//
// The clock is injected, so "elapsed" is exact instead of a sleep. The one case
// that genuinely needs time to pass (the 900 ms auto-advance firing after a
// correct answer) uses `testWidgets` purely for its fake-async zone: nothing is
// pumped, and `tester.pump` only advances the clock.

import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/domain/models/quiz.dart';
import 'package:lexumo/domain/models/seed.dart';
import 'package:lexumo/domain/models/types.dart';
import 'package:lexumo/ui/features/quiz/view_models/quiz_view_model.dart';

import 'support/fake_feedback.dart';

/// A [Store] over the real seed deck, so a round has enough words to fill.
Future<Store> freshStore() async {
  final Store store = Store(persistence: MemoryStore(), seed: seedData);
  await store.init();
  return store;
}

/// The quiz measures a start time and an elapsed time, so it takes a clock.
/// Driving one here is what makes the elapsed assertions exact.
class FakeClock {
  int now = 1000;

  int call() => now;

  void advance(int ms) => now += ms;
}

/// Any option that is not the right one.
int wrongIndex(QuizQuestion question) =>
    (question.answerIndex + 1) % question.options.length;

void main() {
  group('QuizViewModel', () {
    late Store store;
    late FakeFeedback feedback;
    late FakeClock clock;
    late QuizViewModel vm;

    setUp(() async {
      store = await freshStore();
      feedback = FakeFeedback();
      clock = FakeClock();
    });

    tearDown(() {
      if (!vm.isDisposed) vm.dispose();
    });

    QuizViewModel make({Future<void> Function(Word word)? speak}) {
      vm = QuizViewModel(
        store: store,
        feedback: feedback,
        speak: speak,
        clock: clock.call,
      );
      return vm;
    }

    /// Answer the question on screen correctly and move on, cancelling the
    /// 900 ms advance timer so the test stays deterministic.
    void answerCorrectly() {
      vm.choose(vm.current!.answerIndex);
      vm.goNext();
    }

    test('starts idle, and start() opens a full round', () {
      make();
      expect(vm.phase, QuizPhase.idle);
      expect(vm.progress, isNull);
      expect(vm.questionCount, 0);

      vm.start(QuizDirection.termToDef);

      expect(vm.phase, QuizPhase.active);
      expect(vm.questionCount, QUIZ_ROUND);
      expect(vm.progress, isNotNull);
      expect(vm.progress!.total, QUIZ_ROUND);
      expect(vm.answeredCount, 0);
      expect(vm.score, 0);
      expect(vm.current, isNotNull);
      expect(vm.questionNumber, 1);
    });

    test('a correct answer scores and sets selected', () {
      make();
      vm.start(QuizDirection.termToDef);
      final QuizQuestion question = vm.current!;

      vm.choose(question.answerIndex);

      expect(vm.answered, isTrue);
      expect(vm.selected, question.answerIndex);
      expect(vm.score, 1);
      expect(vm.answeredCount, 1);
    });

    test('a wrong answer sets selected but does not score', () {
      make();
      vm.start(QuizDirection.termToDef);
      final QuizQuestion question = vm.current!;
      final int wrong = wrongIndex(question);

      vm.choose(wrong);

      expect(vm.answered, isTrue);
      expect(vm.selected, wrong);
      expect(vm.score, 0);
      expect(vm.answeredCount, 1);
    });

    test('answering twice does not double-count', () {
      make();
      vm.start(QuizDirection.termToDef);
      final QuizQuestion question = vm.current!;
      final int wrong = wrongIndex(question);

      vm.choose(wrong);
      // A second tap on a different option must be ignored, not re-recorded.
      vm.choose(question.answerIndex);

      expect(vm.selected, wrong);
      expect(vm.score, 0);
      expect(vm.answeredCount, 1);
    });

    test('goNext() clears the selection, and the last one finishes the round',
        () {
      make();
      vm.start(QuizDirection.termToDef);
      final QuizQuestion first = vm.current!;

      vm.choose(first.answerIndex);
      expect(vm.answered, isTrue);

      vm.goNext();
      expect(vm.selected, isNull);
      expect(vm.answered, isFalse);
      expect(vm.phase, QuizPhase.active);
      expect(vm.questionNumber, 2);

      // Walk the rest correctly; the tenth goNext() has nowhere to advance to.
      for (int i = 1; i < QUIZ_ROUND; i++) {
        expect(vm.phase, QuizPhase.active);
        answerCorrectly();
      }

      expect(vm.phase, QuizPhase.done);
      expect(vm.answeredCount, QUIZ_ROUND);
      expect(vm.score, QUIZ_ROUND);
      expect(vm.perfect, isTrue);
      expect(vm.endedEarly, isFalse);
    });

    test('requestFinish() mid-round asks first, and a dismissal changes nothing',
        () async {
      make();
      vm.start(QuizDirection.termToDef);
      vm.choose(vm.current!.answerIndex);
      vm.goNext();

      feedback.confirmAnswer = false;
      await vm.requestFinish();

      expect(feedback.confirmations, hasLength(1));
      // The wording is the page's, unchanged: title, subtitle, confirm label.
      expect(feedback.confirmations.single.title, feedback.t('quiz.exitTitle'));
      expect(
        feedback.confirmations.single.subtitle,
        feedback.t('quiz.exitConfirm'),
      );
      expect(
        feedback.confirmations.single.confirmLabel,
        feedback.t('quiz.exit'),
      );

      expect(vm.phase, QuizPhase.active);
      expect(feedback.toasts, isEmpty);
    });

    test('requestFinish() with nothing answered finishes without asking',
        () async {
      make();
      vm.start(QuizDirection.termToDef);

      await vm.requestFinish();

      expect(feedback.confirmations, isEmpty);
      expect(feedback.toasts, isEmpty);
      expect(vm.phase, QuizPhase.done);
      // An unanswered round ends early, and is not "perfect".
      expect(vm.answeredCount, 0);
      expect(vm.perfect, isFalse);
      expect(vm.endedEarly, isFalse);
    });

    test('exitToIdle() resets to a clean idle screen', () {
      make();
      vm.start(QuizDirection.termToDef);
      vm.choose(vm.current!.answerIndex);

      vm.exitToIdle();

      expect(vm.phase, QuizPhase.idle);
      expect(vm.questionCount, 0);
      expect(vm.progress, isNull);
      expect(vm.selected, isNull);
      expect(vm.current, isNull);
      expect(vm.mistakes, isEmpty);
    });

    test('mistakes are exactly the misses, with the option that was picked', () {
      make();
      vm.start(QuizDirection.termToDef);

      // A finished round: miss questions 2 and 5, get the other eight right.
      final Set<String> missedIds = <String>{};
      final Map<String, int> picked = <String, int>{};
      for (int i = 0; i < QUIZ_ROUND; i++) {
        final QuizQuestion question = vm.current!;
        if (i == 1 || i == 4) {
          final int wrong = wrongIndex(question);
          missedIds.add(question.wordId);
          picked[question.wordId] = wrong;
          vm.choose(wrong);
        } else {
          vm.choose(question.answerIndex);
        }
        vm.goNext();
      }

      expect(vm.phase, QuizPhase.done);
      expect(vm.score, QUIZ_ROUND - 2);

      final List<QuizMistake> mistakes = vm.mistakes;
      expect(mistakes, hasLength(2));
      expect(
        mistakes.map((QuizMistake m) => m.question.wordId).toSet(),
        missedIds,
      );
      // Each carries the option actually picked, not just "wrong".
      for (final QuizMistake mistake in mistakes) {
        expect(mistake.answer, picked[mistake.question.wordId]);
        expect(mistake.answer, isNot(mistake.question.answerIndex));
      }
    });

    test('an unanswered question counts as a miss with no option', () async {
      make();
      vm.start(QuizDirection.termToDef);
      final QuizQuestion first = vm.current!;
      vm.choose(wrongIndex(first));
      vm.goNext();

      // Leave the rest open, then bail out. Every question in the round is in
      // `mistakes` — the ones never reached are misses with a null answer, so
      // the results card can list them as `quiz.unanswered` rather than hiding
      // them. That is the page's existing behaviour, pinned here.
      await vm.requestFinish();

      final List<QuizMistake> mistakes = vm.mistakes;
      expect(mistakes, hasLength(QUIZ_ROUND));
      expect(mistakes.first.question.wordId, first.wordId);
      expect(mistakes.first.answer, isNot(first.answerIndex));
      expect(mistakes[1].answer, isNull);
    });

    test('setDirection() switches, and the next round is built in it', () {
      make();
      expect(vm.direction, QuizDirection.termToDef);

      final Set<String> terms =
          store.data.words.map((Word w) => w.term).toSet();
      final Set<String> definitions =
          store.data.words.map((Word w) => w.definition).toSet();

      vm.start(QuizDirection.termToDef);
      // A term→definition round asks with the term.
      expect(terms, contains(vm.current!.prompt));
      expect(definitions, isNot(contains(vm.current!.prompt)));

      vm.exitToIdle();
      vm.setDirection(QuizDirection.defToTerm);
      expect(vm.direction, QuizDirection.defToTerm);

      vm.start(vm.direction);
      // A definition→term round asks with the gloss.
      expect(definitions, contains(vm.current!.prompt));
      expect(terms, isNot(contains(vm.current!.prompt)));
    });

    test('elapsed comes from the injected clock and freezes at finish',
        () async {
      make();
      vm.start(QuizDirection.termToDef);
      expect(vm.elapsed, 0);

      clock.advance(5000);
      await vm.requestFinish();

      expect(vm.phase, QuizPhase.done);
      expect(vm.elapsed, 5000);

      // The result card must not keep counting after the round is over.
      clock.advance(9000);
      expect(vm.elapsed, 5000);
    });

    test('playWord() speaks through the injected port, not a BuildContext',
        () async {
      final List<Word> spoken = <Word>[];
      make(speak: (Word word) async => spoken.add(word));

      vm.start(QuizDirection.termToDef);
      final Word word = vm.wordFor(vm.current!)!;

      vm.playWord(word);
      await Future<void>.delayed(Duration.zero);

      expect(spoken, <Word>[word]);
    });

    test('playWord() is a no-op when no speech port was supplied', () {
      make();
      vm.start(QuizDirection.termToDef);
      final Word word = vm.wordFor(vm.current!)!;

      expect(() => vm.playWord(word), returnsNormally);
    });

    // These two are the only cases that need a fake-async zone: the view model
    // arms a real 900 ms `Timer` on a correct answer, and `testWidgets` gives
    // the test body one. Nothing is pumped or laid out — `pump` here is only a
    // way to advance time.
    testWidgets('dispose() cancels the pending 900 ms advance timer',
        (WidgetTester tester) async {
      make();
      vm.start(QuizDirection.termToDef);
      final QuizQuestion question = vm.current!;

      // A correct answer arms the glide-on timer.
      vm.choose(question.answerIndex);
      expect(vm.answered, isTrue);

      // Deliberately do NOT pump past the 900 ms: the timer is still pending
      // when the body ends, and the test binding fails a test that leaves a
      // timer running. So this assertion is the leak check — drop
      // `_cancelAdvance()` from `dispose()` and this test fails.
      expect(vm.dispose, returnsNormally);
      expect(vm.isDisposed, isTrue);
    });

    testWidgets('a timer that does fire into a disposed model is harmless',
        (WidgetTester tester) async {
      make();
      vm.start(QuizDirection.termToDef);
      vm.choose(vm.current!.answerIndex);

      vm.dispose();

      // Even if a callback were already in flight, `update`/`notifyListeners`
      // must not reach a disposed notifier.
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });

    test('the store subscription is dropped on dispose', () {
      make();
      vm.start(QuizDirection.termToDef);
      final int before = vm.answeredCount;

      vm.dispose();

      // A store write after dispose must not reach the view model; if the
      // listener were still attached this would throw on a disposed notifier.
      expect(() => store.bumpListen('seed_0'), returnsNormally);
      expect(vm.answeredCount, before);
    });
  });
}
