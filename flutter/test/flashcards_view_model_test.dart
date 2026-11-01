// Unit tests for the flashcard view model — no widget tree, no `BuildContext`.
//
// That is the whole point of the split: the deck, the session in flight, the
// flip, the turn timers, the store-side undo stack and the auto-play latch all
// used to live in a `State`, so every one of them could only be reached by
// pumping the page and tapping pixels. Driving the view model directly means
// the interesting parts — a grade and its exact inverse, a skip that must not
// touch the store, a latch that must not repeat a clip — are assertable in
// isolation.
//
// Everything the view model cannot do itself arrives through a seam: [Feedback]
// answers dialogs and records toasts, and four plain closures stand in for the
// speech layer, which is why no `Speech` fake is needed here at all.

import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/domain/models/seed.dart';
import 'package:lexumo/domain/models/srs.dart' show isNew;
import 'package:lexumo/domain/models/types.dart';
import 'package:lexumo/ui/core/view_model.dart' show ToastKind;
import 'package:lexumo/ui/features/flashcards/view_models/flashcards_view_model.dart';

import 'support/fake_feedback.dart';

/// A frozen "now". The seed's whole schedule is relative to it, so "due today"
/// is a constant here rather than a race with the wall clock.
const int NOW = 1770000000000;

/// A store over a fresh seed, with no disk and the same frozen clock the view
/// model gets — otherwise a grade would land on a different day than the one
/// the deck was counted on.
Future<Store> freshStore() async {
  final Store store = Store(
    persistence: MemoryStore(),
    clock: () => NOW,
    seed: seedData,
    saveDelayMs: 0,
  );
  await store.init();
  return store;
}

/// What the speech ports were asked to do, so a test can count clips instead of
/// listening to them.
class SpeechLog {
  final List<String> spoken = <String>[];
  final List<String> autoPlayed = <String>[];
  int stopped = 0;
}

/// Build the view model the way the page does, with every dependency swapped
/// for something observable.
FlashcardsViewModel build(
  Store store,
  FakeFeedback feedback, {
  SpeechLog? speech,
  bool engine = true,
}) {
  final SpeechLog log = speech ?? SpeechLog();
  return FlashcardsViewModel(
    store: store,
    feedback: feedback,
    speakWord: (Word word, {VoidCallback? onEnd}) async => log.spoken.add(word.term),
    speakTerm: (Word word, {VoidCallback? onEnd}) async => log.autoPlayed.add(word.term),
    stopSpeech: () => log.stopped++,
    speechAvailable: () => engine,
    clock: () => NOW,
  );
}

/// Wait for [predicate] to hold.
///
/// The turn timers are real 125 ms / 190 ms waits, so a fixed sleep would be a
/// race under load; polling keeps the assertions about *ordering* rather than
/// about how fast this machine happens to be.
Future<void> settle(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final Stopwatch watch = Stopwatch()..start();
  while (!predicate() && watch.elapsed < timeout) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(predicate(), isTrue, reason: 'the view model never reached the state');
}

void main() {
  group('FlashcardsViewModel', () {
    late Store store;
    late FakeFeedback feedback;
    late SpeechLog speech;
    late FlashcardsViewModel vm;

    setUp(() async {
      store = await freshStore();
      feedback = FakeFeedback();
      speech = SpeechLog();
      vm = build(store, feedback, speech: speech);
    });

    tearDown(() {
      vm.dispose();
    });

    /* ---------------------------------------------------------------- */
    /* The deck                                                          */
    /* ---------------------------------------------------------------- */

    test('opens on the due deck and counts what the store says is due', () {
      expect(vm.deck, DeckSource.due);

      final List<Word> due = dueWords(store.data, NOW);
      // The seed ships 14 cards; at [NOW] seven are due — four already in
      // rotation and three that have never been scheduled.
      expect(due.length, 7);
      expect(vm.summary.counts[DeckSource.due], due.length);
      expect(vm.summary.dueReview, due.where((Word w) => !isNew(w.srs)).length);
      expect(vm.summary.dueReview, 4);
      expect(vm.summary.counts[DeckSource.all], store.data.words.length);
      expect(vm.summary.counts[DeckSource.all], 14);
      expect(vm.summary.counts[DeckSource.favorites], 2);
      expect(vm.summary.counts[DeckSource.fresh], 3);
      expect(vm.deckSize, 7);
      expect(vm.summary.caughtUp, isFalse);
      expect(vm.summary.hasNewWords, isTrue);
      // Nothing has been introduced at [NOW], so the allowance cannot be spent.
      expect(vm.summary.capReached, isFalse);
    });

    test('setDeck switches which counts the picker reads', () {
      vm.setDeck(DeckSource.all);
      expect(vm.deck, DeckSource.all);
      expect(vm.deckSize, store.data.words.length);

      vm.setDeck(DeckSource.favorites);
      expect(vm.deck, DeckSource.favorites);
      expect(
        vm.deckSize,
        store.data.words.where((Word w) => w.favorite).length,
      );
      expect(vm.deckSize, 2);

      vm.setDeck(DeckSource.fresh);
      expect(vm.deckSize, 3);
    });

    test('the summary follows a grade written behind its back', () {
      final int before = vm.summary.counts[DeckSource.due]!;
      // The first card in the due deck, graded straight through the store: the
      // deck is derived on read, so no second source of truth has to be told.
      final Word card = dueWords(store.data, NOW).firstWhere(
        (Word w) => !isNew(w.srs),
      );
      store.gradeWord(card.id, Grade.good);
      expect(vm.summary.counts[DeckSource.due], before - 1);
    });

    /* ---------------------------------------------------------------- */
    /* Starting and leaving a session                                    */
    /* ---------------------------------------------------------------- */

    test('startSession walks the deck and exitSession drops it', () {
      expect(vm.inProgress, isFalse);
      expect(vm.progress, isNull);
      expect(vm.word, isNull);

      vm.startSession();

      expect(vm.inProgress, isTrue);
      expect(vm.progress!.total, 7);
      expect(vm.progress!.index, 0);
      expect(vm.progress!.reviewed, 0);
      expect(vm.word, isNotNull);
      expect(vm.remaining, 7);
      expect(vm.preview, isNotNull);

      vm.exitSession();

      expect(vm.inProgress, isFalse);
      expect(vm.progress, isNull);
      expect(vm.word, isNull);
      expect(vm.canUndo, isFalse);
      expect(vm.remaining, 0);
    });

    /* ---------------------------------------------------------------- */
    /* The flip                                                          */
    /* ---------------------------------------------------------------- */

    test('reveal turns the card over through the two turn timers', () async {
      vm.startSession();
      expect(vm.flipped, isFalse);
      expect(vm.turn, isNull);

      vm.reveal(reduceMotion: false);
      // The front is still showing: the answer only arrives once it has turned
      // away, which is what makes the flip read as a flip.
      expect(vm.flipped, isFalse);
      expect(vm.turn, 'out');

      await settle(() => vm.flipped);
      expect(vm.turn, 'in');

      await settle(() => vm.turn == null);
      expect(vm.flipped, isTrue);
    });

    test('reveal with reduced motion flips at once and starts no timer', () {
      vm.startSession();

      vm.reveal(reduceMotion: true);

      // The flag is what the layout reads; only the animation differs.
      expect(vm.flipped, isTrue);
      expect(vm.turn, isNull);
    });

    test('resetFlip returns to the front and cancels a turn in flight', () async {
      vm.startSession();
      vm.reveal(reduceMotion: false);
      expect(vm.turn, 'out');

      vm.resetFlip();
      expect(vm.flipped, isFalse);
      expect(vm.turn, isNull);

      // The cancelled timer must not flip the card after the fact.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(vm.flipped, isFalse);
      expect(vm.turn, isNull);
    });

    /* ---------------------------------------------------------------- */
    /* Grading and undo                                                  */
    /* ---------------------------------------------------------------- */

    test('grade writes the review through the store and stacks an undo step', () {
      vm.startSession();
      final Word before = vm.word!;
      final int logsBefore = store.data.logs.length;

      vm.grade(Grade.good);

      final Word after = store.data.words.firstWhere(
        (Word w) => w.id == before.id,
      );
      expect(store.data.logs.length, logsBefore + 1);
      final ReviewLog log = store.data.logs.last;
      expect(log.wordId, before.id);
      expect(log.grade, Grade.good);
      expect(after.srs!.reviewCount, (before.srs?.reviewCount ?? 0) + 1);
      expect(after.srs!.intervalDays, greaterThan(before.srs?.intervalDays ?? 0));
      expect(after.status.rank, greaterThanOrEqualTo(before.status.rank));

      expect(vm.canUndo, isTrue);
      expect(vm.flipped, isFalse);
      expect(vm.progress!.reviewed, 1);
      expect(vm.progress!.index, 1);
    });

    test('undo puts a new card back exactly as it was', () {
      // The fresh deck, so the card in hand has no schedule yet: that is the
      // case where the store-side snapshot can be restored byte for byte.
      vm.setDeck(DeckSource.fresh);
      vm.startSession();
      final Word before = vm.word!;
      expect(before.srs, isNull);
      final List<String> logIdsBefore = store.data.logs
          .map((ReviewLog l) => l.id)
          .toList();

      vm.grade(Grade.good);
      expect(store.data.logs.length, logIdsBefore.length + 1);

      vm.undo();

      final Word after = store.data.words.firstWhere(
        (Word w) => w.id == before.id,
      );
      expect(store.data.logs.map((ReviewLog l) => l.id).toList(), logIdsBefore);
      expect(after.srs, isNull);
      expect(after.status, before.status);
      expect(vm.progress!.reviewed, 0);
      expect(vm.progress!.index, 0);
      expect(vm.word!.id, before.id);
      // Undo re-reveals the card it rolled back, as the page did.
      expect(vm.flipped, isTrue);
    });

    test('undo drops the log and restores the status of a card in rotation', () {
      vm.startSession();
      final Word before = vm.word!;
      expect(before.srs, isNotNull);
      final List<String> logIdsBefore = store.data.logs
          .map((ReviewLog l) => l.id)
          .toList();

      vm.grade(Grade.good);
      vm.undo();

      final Word after = store.data.words.firstWhere(
        (Word w) => w.id == before.id,
      );
      expect(store.data.logs.map((ReviewLog l) => l.id).toList(), logIdsBefore);
      expect(after.status, before.status);
      // The schedule must come back exactly, including on a card that already
      // had one. This used to fail: `undoReview` passed a hard `clearSrs: true`
      // next to the restored snapshot, and `Word.copyWith` gives `clearSrs`
      // precedence — so undoing a grade silently wiped the `reviewCount` /
      // `dueAt` / ease it had just restored. `store.dart` now derives the flag
      // from the snapshot (`clearSrs: restored.srs == null`), which is also what
      // `src/lib/store.ts:458` does by simply not passing it.
      expect(after.srs, before.srs);
      expect(after.srs!.reviewCount, before.srs!.reviewCount);
      expect(after.srs!.dueAt, before.srs!.dueAt);
      expect(after.srs!.ease, before.srs!.ease);
    });

    test('undo with nothing to undo is a no-op', () {
      vm.startSession();
      final List<String> logIdsBefore = store.data.logs
          .map((ReviewLog l) => l.id)
          .toList();

      vm.undo();

      expect(vm.progress!.index, 0);
      expect(store.data.logs.map((ReviewLog l) => l.id).toList(), logIdsBefore);
    });

    test('skip advances without grading, so the store is untouched', () {
      vm.startSession();
      final Word before = vm.word!;
      final int logsBefore = store.data.logs.length;

      vm.skip();

      expect(store.data.logs.length, logsBefore);
      final Word after = store.data.words.firstWhere(
        (Word w) => w.id == before.id,
      );
      expect(after.srs?.toJson(), before.srs?.toJson());
      expect(after.status, before.status);
      expect(vm.progress!.index, 1);
      expect(vm.progress!.skipped, 1);
      expect(vm.progress!.reviewed, 0);

      // The session keeps the skip as a reversible step, but it carries no
      // store-side snapshot — undoing it must write nothing at all.
      vm.undo();
      expect(store.data.logs.length, logsBefore);
      expect(vm.word!.id, before.id);
      expect(vm.progress!.skipped, 0);
    });

    /* ---------------------------------------------------------------- */
    /* Audio                                                             */
    /* ---------------------------------------------------------------- */

    test('the auto-play latch speaks a face once however often it is asked', () {
      vm.startSession();
      vm.reveal(reduceMotion: true);
      expect(speech.autoPlayed, isEmpty);

      vm.maybeAutoPlay();
      expect(speech.autoPlayed, <String>[vm.word!.term]);
      expect(speech.stopped, 1);

      // A repaint of the same face must not repeat the clip; the page calls
      // this from a post-frame callback, so it fires on every frame.
      vm.maybeAutoPlay();
      vm.maybeAutoPlay();
      expect(speech.autoPlayed.length, 1);
      expect(speech.stopped, 1);
    });

    test('the latch is per card, so the next one is spoken', () {
      vm.startSession();
      vm.reveal(reduceMotion: true);
      vm.maybeAutoPlay();
      final String first = vm.word!.term;

      vm.grade(Grade.good);
      vm.reveal(reduceMotion: true);
      vm.maybeAutoPlay();

      expect(speech.autoPlayed.length, 2);
      expect(speech.autoPlayed.first, first);
      expect(speech.autoPlayed.last, vm.word!.term);
      expect(speech.autoPlayed.last, isNot(first));
    });

    test('nothing is auto-played on a face that is meant to be read', () {
      vm.startSession();
      // The front of an ordinary card is silent until it is revealed.
      vm.maybeAutoPlay();
      expect(speech.autoPlayed, isEmpty);
      expect(speech.stopped, 0);
    });

    test('no engine means no auto-play at all', () {
      final FlashcardsViewModel muted = build(store, feedback, engine: false);
      addTearDown(muted.dispose);

      muted.startSession();
      muted.reveal(reduceMotion: true);
      muted.maybeAutoPlay();

      expect(speech.autoPlayed, isEmpty);
      expect(speech.stopped, 0);
    });

    test('playWord hands the word to the speaking port', () {
      vm.startSession();
      final Word word = vm.word!;

      vm.playWord(word);

      expect(speech.spoken, <String>[word.term]);
    });

    /* ---------------------------------------------------------------- */
    /* Leaving                                                           */
    /* ---------------------------------------------------------------- */

    test('requestExit asks before dropping a session with progress', () async {
      vm.startSession();
      vm.grade(Grade.good);
      expect(vm.progress!.reviewed, 1);

      feedback.confirmAnswer = false;
      await vm.requestExit();

      expect(feedback.confirmations, hasLength(1));
      expect(feedback.confirmations.single.title, feedback.t('flashcards.exit'));
      expect(
        feedback.confirmations.single.subtitle,
        feedback.t('flashcards.exitConfirm', <String, Object>{'n': 6}),
      );
      expect(vm.inProgress, isTrue);
      expect(feedback.toasts, isEmpty);

      feedback.confirmAnswer = true;
      await vm.requestExit();

      expect(feedback.confirmations, hasLength(2));
      expect(vm.inProgress, isFalse);
      expect(feedback.toasts.single.kind, ToastKind.ok);
      expect(
        feedback.toasts.single.text,
        feedback.t('flashcards.exitSaved', <String, Object>{'n': 1}),
      );
    });

    test('requestExit drops a session with no progress without asking', () async {
      vm.startSession();

      await vm.requestExit();

      expect(feedback.confirmations, isEmpty);
      expect(vm.inProgress, isFalse);
      expect(feedback.toasts, isEmpty);
    });

    /* ---------------------------------------------------------------- */
    /* Lifecycle                                                         */
    /* ---------------------------------------------------------------- */

    test('follows the store, so a write from elsewhere repaints', () {
      int notified = 0;
      vm.addListener(() => notified++);

      store.gradeWord(store.data.words.first.id, Grade.easy);

      expect(notified, greaterThan(0));
    });

    test('disposing mid-turn cancels the flip timers instead of firing them', () async {
      final FlashcardsViewModel mid = build(store, feedback);
      mid.startSession();
      mid.reveal(reduceMotion: false);
      expect(mid.turn, 'out');

      mid.dispose();

      // A timer that survived would call `update` on a disposed notifier and
      // throw out of the event loop, failing this test.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(mid.isDisposed, isTrue);
    });
  });
}
