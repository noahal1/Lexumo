// Unit tests for the home dashboard's view model — every figure with no widget
// tree in sight.
//
// The dashboard is a summary screen, which makes it the place where a wrong
// number is hardest to notice: nobody checks the greeting against the ring. So
// each derivation is asserted directly here rather than through a pumped page,
// and "now" is frozen through the view model's injectable clock so the day
// boundaries are exact instead of merely plausible.
//
// The seed facts these tests lean on (`flutter/lib/domain/models/seed.dart`):
// 14 demo words in one list, 3 of them mastered, 3 never scheduled (always due),
// 4 with `daysUntilDue: 0` (due now) and 7 not yet due — so 7 cards are waiting.
// The synthetic history is anchored at most 22 days back and its *newest* log is
// two days old, which is why a freshly seeded store has a streak of 0: nothing
// was reviewed today or yesterday.

import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/domain/models/seed.dart';
import 'package:lexumo/domain/models/srs.dart' show DAY_MS;
import 'package:lexumo/domain/models/types.dart';
import 'package:lexumo/domain/models/utils.dart' show dayKeyOfTs, startOfDay;
import 'package:lexumo/ui/features/home/view_models/home_view_model.dart';

import 'support/fake_feedback.dart';

/// A frozen "now": mid-afternoon, so "today" is unambiguous. Built from local
/// fields rather than a UTC instant because `startOfDay` is local — a UTC
/// literal would shift the day boundary on a non-UTC host and every bucket
/// assertion below would fail for the wrong reason.
final int fixedNow = DateTime(2026, 3, 15, 14, 30).millisecondsSinceEpoch;

/// The demo deck, seeded and clock-frozen.
///
/// `saveDelayMs: 0` because these are plain tests: the store's default 220ms
/// save debounce would leave a timer pending past the end of the body.
Future<Store> seededStore() async {
  final store = Store(
    persistence: MemoryStore(),
    seed: seedData,
    clock: () => fixedNow,
    saveDelayMs: 0,
  );
  await store.init();
  return store;
}

/// A store with the default list but no words and no review history.
Future<Store> emptyStore() async {
  final store = Store(
    persistence: MemoryStore(),
    seed: (int now) => emptyData(),
    clock: () => fixedNow,
    saveDelayMs: 0,
  );
  await store.init();
  return store;
}

/// Build a view model over [store] with a frozen clock, disposed after the test.
HomeViewModel buildVm(Store store, FakeFeedback feedback) {
  final vm = HomeViewModel(
    store: store,
    feedback: feedback,
    clock: () => fixedNow,
  );
  addTearDown(vm.dispose);
  return vm;
}

void main() {
  group('HomeViewModel', () {
    group('empty library', () {
      test('still derives a sane summary instead of dividing by zero', () async {
        final vm = buildVm(await emptyStore(), FakeFeedback());

        expect(vm.isEmpty, isTrue);
        expect(vm.hasData, isFalse);

        expect(vm.total, 0);
        expect(vm.mastered, 0);
        expect(vm.masteryPct, 0);
        expect(vm.retention, isNull);
        expect(vm.dueCount, 0);
        expect(vm.dueToday, 0);
        expect(vm.streak, 0);

        // The goal is floored at 1 by `summarize`, so the ring's denominator is
        // never zero and the percentage is a real 0..1 fraction.
        expect(vm.goal, 20);
        expect(vm.today, 0);
        expect(vm.goalPct, 0.0);
        expect(vm.reached, isFalse);
        expect(vm.remaining, 20);
      });

      test('has seven empty bars, and seriesMax is floored at 1', () async {
        final vm = buildVm(await emptyStore(), FakeFeedback());

        expect(vm.series, hasLength(7));
        expect(vm.series.every((b) => b.count == 0), isTrue);
        expect(vm.seriesTotal, 0);
        // Floored so the view can divide a bar height by it without a guard.
        expect(vm.seriesMax, 1);
        expect(vm.hasReviews, isFalse);
      });

      test('the default list still exists, so the strip is never empty', () async {
        final vm = buildVm(await emptyStore(), FakeFeedback());

        // `Store.init` gives a listless snapshot a default list, which is why
        // this is 1 and not 0 even though there is not a single word.
        expect(vm.listCount, 1);
        expect(vm.lists.single.id, DEFAULT_LIST_ID);
        expect(vm.listWords(DEFAULT_LIST_ID), 0);
        expect(vm.listDue(DEFAULT_LIST_ID), 0);

        // The suggestion falls back to the first list, with nothing due.
        expect(vm.focusList?.id, DEFAULT_LIST_ID);
        expect(vm.focusDue, 0);
      });
    });

    group('seeded library', () {
      test('counts the cards that are actually waiting', () async {
        final store = await seededStore();
        final vm = buildVm(store, FakeFeedback());

        // The view model's due count and the summary's must be the same
        // predicate over the same snapshot — that is the whole point of taking
        // both from one clock reading.
        expect(vm.dueCount, 7);
        expect(vm.summary.dueToday, vm.dueCount);
        expect(vm.dueCount, dueWords(store.data, fixedNow).length);
      });

      test('headline figures match the snapshot', () async {
        final vm = buildVm(await seededStore(), FakeFeedback());

        expect(vm.total, 14);
        expect(vm.mastered, 3);
        expect(vm.masteryPct, 21); // 3/14 rounded the way the TS build rounds
        expect(vm.retention, isNotNull);
        expect(vm.hourOfDay, 14);
      });

      test('a freshly seeded store has no streak, because its history is stale',
          () async {
        final vm = buildVm(await seededStore(), FakeFeedback());

        // The demo history's newest log is two days old, so today and yesterday
        // are both empty and `streakDays` reports 0 rather than a phantom run.
        expect(vm.summary.today, 0);
        expect(vm.streak, 0);
      });

      test('reviewing a card today starts the streak and moves the ring',
          () async {
        final store = await seededStore();
        final vm = buildVm(store, FakeFeedback());

        store.gradeWord(store.data.words.first.id, Grade.good, fixedNow);

        expect(vm.summary.today, 1);
        expect(vm.streak, 1);
        expect(vm.remaining, vm.goal - 1);
        expect(vm.series.last.count, 1);
      });

      test('the per-list counts add up to the library', () async {
        final vm = buildVm(await seededStore(), FakeFeedback());

        final summed = vm.lists.fold<int>(0, (n, l) => n + vm.listWords(l.id));
        expect(summed, vm.total);
        expect(vm.listWords(DEFAULT_LIST_ID), 14);
        expect(vm.listDue(DEFAULT_LIST_ID), vm.dueCount);
      });

      test('the continue-studying suggestion is the list with the most due',
          () async {
        final store = await seededStore();
        final vm = buildVm(store, FakeFeedback());

        // One list, so it wins by default — but the due figure has to be that
        // list's, not the library's total.
        expect(vm.focusList?.id, DEFAULT_LIST_ID);
        expect(vm.focusDue, 7);
        expect(vm.focusDue, vm.listDue(DEFAULT_LIST_ID));
      });

      test('a second, busier list takes the suggestion over', () async {
        final store = await seededStore();
        final second = store.createList(
          name: '我的生词',
          sourceLang: 'en',
          targetLang: 'zh-CN',
        );
        // More waiting cards than the demo deck's 7, so the suggestion has to
        // move. A newly added word is never scheduled, so every one of these is
        // due immediately.
        for (var i = 0; i < 9; i++) {
          store.addWord(NewWordInput(term: 'newword$i', listId: second.id));
        }
        final vm = buildVm(store, FakeFeedback());

        expect(vm.listCount, 2);
        expect(vm.listWords(second.id), 9);
        expect(vm.focusList?.id, second.id);
        // Not "the first list", and not the library total either.
        expect(vm.focusDue, 9);
      });
    });

    group('seven-day series', () {
      test('one bar per day, oldest first, today last', () async {
        final vm = buildVm(await seededStore(), FakeFeedback());

        expect(vm.series, hasLength(7));
        expect(vm.series.last.key, dayKeyOfTs(fixedNow));
        expect(vm.series.last.isToday, isTrue);
        expect(vm.series.where((b) => b.isToday), hasLength(1));
        expect(vm.series.first.isToday, isFalse);

        final firstTs = startOfDay(fixedNow) - 6 * DAY_MS;
        expect(vm.series.first.key, dayKeyOfTs(firstTs));
      });

      test('the bars sum to seriesTotal and to the logs inside the window',
          () async {
        final store = await seededStore();
        final vm = buildVm(store, FakeFeedback());

        final summed = vm.series.fold<int>(0, (n, b) => n + b.count);
        expect(summed, vm.seriesTotal);
        expect(vm.hasReviews, isTrue);

        final firstTs = startOfDay(fixedNow) - 6 * DAY_MS;
        final inWindow =
            store.data.logs.where((l) => l.at >= firstTs && l.at <= fixedNow);
        expect(vm.seriesTotal, inWindow.length);
        expect(vm.seriesTotal, greaterThan(0));
      });

      test('seriesMax is the tallest bar, never below 1', () async {
        final vm = buildVm(await seededStore(), FakeFeedback());

        final tallest = vm.series.fold<int>(0, (n, b) => b.count > n ? b.count : n);
        expect(vm.seriesMax, tallest < 1 ? 1 : tallest);
        expect(vm.seriesMax, greaterThanOrEqualTo(1));
      });

      test('a review logged now lands in today\'s bar and in summary.today',
          () async {
        final store = await seededStore();
        final vm = buildVm(store, FakeFeedback());

        final before = vm.series.last.count;
        store.gradeWord(store.data.words[1].id, Grade.easy, fixedNow);

        expect(vm.series.last.count, before + 1);
        expect(vm.summary.today, vm.series.last.count);
      });

      test('the bar labels are the month/day their buckets were built from',
          () async {
        final vm = buildVm(await seededStore(), FakeFeedback());

        final today = DateTime.fromMillisecondsSinceEpoch(fixedNow);
        expect(vm.series.last.label, '${today.month}/${today.day}');

        final first = DateTime.fromMillisecondsSinceEpoch(
          startOfDay(fixedNow) - 6 * DAY_MS,
        );
        expect(vm.series.first.label, '${first.month}/${first.day}');
      });
    });

    group('one clock reading', () {
      test('every figure comes from a single reading, so nothing straddles '
          'midnight', () async {
        final store = await seededStore();
        // A clock that jumps a day on the second read. If the view model read it
        // per getter, the ring's "today" and the sparkline's last bar would
        // describe different days — and the test would pass by accident during
        // the day and fail at midnight. Reading once makes it impossible.
        var calls = 0;
        final vm = HomeViewModel(
          store: store,
          feedback: FakeFeedback(),
          clock: () => calls++ == 0 ? fixedNow : fixedNow + DAY_MS,
        );
        addTearDown(vm.dispose);

        expect(calls, 1);

        expect(vm.summary.today, vm.series.last.count);
        expect(vm.series.last.key, dayKeyOfTs(fixedNow));
        expect(vm.series.last.isToday, isTrue);

        // A store write re-derives, and re-derives from one reading again.
        store.gradeWord(store.data.words.first.id, Grade.good, fixedNow);
        expect(calls, 2);
        expect(vm.series.last.key, dayKeyOfTs(fixedNow + DAY_MS));
      });
    });

    group('intents', () {
      test('each navigation lands on its page id', () async {
        final feedback = FakeFeedback();
        final vm = buildVm(await seededStore(), feedback);

        vm.startReview();
        vm.startQuiz();
        vm.addWords();
        vm.openStats();

        expect(
          feedback.navigations,
          <String>['flashcards', 'quiz', 'words', 'stats'],
        );
      });

      test('opening a list lands on the library, the only page it can reach',
          () async {
        final feedback = FakeFeedback();
        final vm = buildVm(await seededStore(), feedback);

        vm.openList(DEFAULT_LIST_ID);

        // Documented limitation rather than a bug: the words page owns its own
        // selected list and has no route parameter to seed it with, so a per-list
        // deep link would be a promise the destination cannot keep.
        expect(feedback.navigations, <String>['words']);
      });

      test('canNavigate mirrors the feedback port', () async {
        final vm = buildVm(await seededStore(), FakeFeedback());
        expect(vm.canNavigate, isTrue);
      });
    });

    group('store subscription', () {
      test('a write from elsewhere shows up on the next read', () async {
        final store = await seededStore();
        final feedback = FakeFeedback();
        final vm = buildVm(store, feedback);
        var notified = 0;
        vm.addListener(() => notified += 1);

        expect(vm.total, 14);

        // Not a view-model intent: some other screen adds a word, and the
        // dashboard has to notice on its own.
        store.addWord(NewWordInput(term: 'quixotic', listId: DEFAULT_LIST_ID));

        expect(vm.total, 15);
        expect(vm.listWords(DEFAULT_LIST_ID), 15);
        expect(notified, greaterThan(0));
        // The new word was never scheduled, so it is due immediately.
        expect(vm.dueCount, 8);
      });

      test('a disposed view model survives a late store write', () async {
        final store = await seededStore();
        // Built by hand rather than through `buildVm`: this test disposes the
        // view model itself, and a second dispose from `addTearDown` would trip
        // `ChangeNotifier`'s disposed-twice assertion instead of exercising the
        // thing under test.
        final vm = HomeViewModel(
          store: store,
          feedback: FakeFeedback(),
          clock: () => fixedNow,
        );
        var notified = 0;
        vm.addListener(() => notified += 1);

        vm.dispose();
        // The write lands after the page was popped. A view model that notified
        // through a disposed ChangeNotifier would throw here; `refresh` checks
        // `isDisposed` first, and the store listener is detached in `dispose`.
        expect(
          () => store.gradeWord(store.data.words.first.id, Grade.good, fixedNow),
          returnsNormally,
        );
        expect(notified, 0);
      });
    });
  });
}
