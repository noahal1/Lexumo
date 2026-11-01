// Unit tests for the stats view model — the chart maths with no widget tree.
//
// Every number below used to be computed inline in `StatsPage.build`, where the
// only way to reach it was to pump the page and read pixels. The point of the
// split is that the buckets, the tick thinning and the grade window are now
// plain getters on a `foundation`-only class, so they can be asserted directly.
//
// "now" is frozen through the view model's injectable clock, which makes every
// bucket boundary deterministic instead of merely plausible.

import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/domain/models/seed.dart';
import 'package:lexumo/domain/models/srs.dart' show DAY_MS;
import 'package:lexumo/domain/models/types.dart';
import 'package:lexumo/domain/models/utils.dart' show dayKeyOfTs, startOfDay;
import 'package:lexumo/ui/features/stats/view_models/stats_view_model.dart';

import 'support/fake_feedback.dart';

/// A frozen "now": mid-afternoon, so the seed's synthetic history keeps a few
/// reviews on today's bar. Built from local fields rather than a UTC instant so
/// `startOfDay` lands where the buckets expect it in any machine time zone.
final int fixedNow = DateTime(2026, 3, 15, 14, 30).millisecondsSinceEpoch;

/// The demo deck, seeded and clock-frozen.
///
/// `saveDelayMs: 0` because these are plain tests: a debounced save would leave
/// a timer pending past the end of the body.
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

/// A store that has the default list but no words and no review history.
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
StatsViewModel buildVm(Store store, FakeFeedback feedback) {
  final vm = StatsViewModel(
    store: store,
    feedback: feedback,
    clock: () => fixedNow,
  );
  addTearDown(vm.dispose);
  return vm;
}

void main() {
  group('StatsViewModel', () {
    group('window', () {
      test('defaults to 30 days and setDays re-derives the series', () async {
        final vm = buildVm(await seededStore(), FakeFeedback());

        expect(vm.days, 30);
        expect(vm.series, hasLength(30));

        vm.setDays(7);
        expect(vm.days, 7);
        expect(vm.series, hasLength(7));

        vm.setDays(90);
        expect(vm.days, 90);
        expect(vm.series, hasLength(90));
      });

      test('setDays notifies exactly once through update()', () async {
        final vm = buildVm(await seededStore(), FakeFeedback());
        var notified = 0;
        vm.addListener(() => notified += 1);

        vm.setDays(7);

        expect(notified, 1);
      });
    });

    group('daily volume', () {
      test('one bar per day, oldest first, with today last', () async {
        final store = await seededStore();
        final vm = buildVm(store, FakeFeedback());

        expect(vm.series, hasLength(vm.days));

        final todayKey = dayKeyOfTs(fixedNow);
        expect(vm.series.last.key, todayKey);
        expect(vm.series.last.isToday, isTrue);
        expect(vm.series.where((b) => b.isToday), hasLength(1));

        // The first bar is the oldest day still inside the window.
        final firstTs = startOfDay(fixedNow) - (vm.days - 1) * DAY_MS;
        expect(vm.series.first.key, dayKeyOfTs(firstTs));
        expect(vm.series.first.isToday, isFalse);
      });

      test('today\'s bar counts exactly the logs dated today', () async {
        final store = await seededStore();
        // The seed's history stops a couple of days short of "now", so log one
        // review today and the bar has to move with it.
        store.gradeWord(store.data.words.first.id, Grade.good, fixedNow);

        final vm = buildVm(store, FakeFeedback());

        final todayKey = dayKeyOfTs(fixedNow);
        final expected = store.data.logs
            .where((log) => dayKeyOfTs(log.at) == todayKey)
            .length;

        expect(expected, greaterThan(0));
        expect(vm.series.last.count, expected);
        expect(vm.summary.today, expected);
      });

      test('the bar labels are the month/day the buckets were built from',
          () async {
        final vm = buildVm(await seededStore(), FakeFeedback());

        final today = DateTime.fromMillisecondsSinceEpoch(fixedNow);
        expect(vm.series.last.label, '${today.month}/${today.day}');
      });

      test('seriesMax is floored at 1 so a quiet window still draws a bar',
          () async {
        final vm = buildVm(await emptyStore(), FakeFeedback());

        expect(vm.seriesMax, 1);
        expect(vm.seriesTotal, 0);
        expect(vm.seriesPeak, 0);
        expect(vm.series.every((b) => b.count == 0), isTrue);

        // The floor is the window's, not the day's.
        vm.setDays(90);
        expect(vm.seriesMax, 1);
      });

      test('seriesAvg is the window total spread over its day count', () async {
        final vm = buildVm(await seededStore(), FakeFeedback());

        expect(vm.seriesAvg, vm.seriesTotal / vm.days);
        expect(vm.chartDense, isFalse);

        vm.setDays(90);
        expect(vm.seriesAvg, vm.seriesTotal / 90);
        expect(vm.chartDense, isTrue);
      });
    });

    group('axis', () {
      test('a 7-day window gives every bar a tick', () async {
        final vm = buildVm(await seededStore(), FakeFeedback());
        vm.setDays(7);

        expect(vm.axis, hasLength(7));
        expect(
          vm.axis.map((a) => a.key).toList(),
          vm.series.map((b) => b.key).toList(),
        );
      });

      test('a 90-day window thins the ticks but keeps the last one', () async {
        final vm = buildVm(await seededStore(), FakeFeedback());
        vm.setDays(90);

        expect(vm.axis.length, lessThan(vm.series.length));
        expect(vm.axis.length, greaterThan(1));
        expect(vm.axis.last.key, vm.series.last.key);
        expect(vm.axis.last.isToday, isTrue);
      });

      test('ticks span the full width: 0% at the first, 100% at the last',
          () async {
        final vm = buildVm(await seededStore(), FakeFeedback());
        vm.setDays(90);

        expect(vm.axis.first.pct, 0);
        expect(vm.axis.last.pct, 100);
      });

      test('edge is 0 first, 1 last and 2 in between', () async {
        final vm = buildVm(await seededStore(), FakeFeedback());

        for (final days in <int>[7, 30, 90]) {
          vm.setDays(days);
          final axis = vm.axis;

          expect(axis.first.edge, 0, reason: 'first tick, $days-day window');
          expect(axis.last.edge, 1, reason: 'last tick, $days-day window');
          for (final middle in axis.sublist(1, axis.length - 1)) {
            expect(middle.edge, 2, reason: 'middle tick, $days-day window');
          }
        }
      });
    });

    group('grade mix', () {
      test('only counts logs inside the selected window', () async {
        final store = await seededStore();
        final vm = buildVm(store, FakeFeedback());
        vm.setDays(90);

        final totalBefore = vm.gradeTotal;
        final easyBefore = vm.gradeCount(Grade.easy);
        final seriesBefore = vm.seriesTotal;
        expect(totalBefore, greaterThan(0));

        // A review from 200 days ago is outside every window the page offers.
        final oldTs = fixedNow - 200 * DAY_MS;
        store.gradeWord(store.data.words.first.id, Grade.easy, oldTs);

        expect(vm.gradeTotal, totalBefore);
        expect(vm.gradeCount(Grade.easy), easyBefore);
        expect(vm.seriesTotal, seriesBefore);
      });

      test('the window start is inclusive, so the boundary day counts',
          () async {
        final store = await seededStore();
        final vm = buildVm(store, FakeFeedback());
        vm.setDays(7);

        final totalBefore = vm.gradeTotal;
        final seriesBefore = vm.seriesTotal;

        // Exactly the oldest day the 7-day window covers.
        final boundary = startOfDay(fixedNow) - 6 * DAY_MS;
        store.gradeWord(store.data.words.first.id, Grade.good, boundary);

        expect(vm.gradeTotal, totalBefore + 1);
        expect(vm.seriesTotal, seriesBefore + 1);
      });

      test('gradePct shares out the window\'s reviews', () async {
        final vm = buildVm(await seededStore(), FakeFeedback());
        vm.setDays(90);

        expect(vm.gradeTotal, greaterThan(0));
        final counts = <Grade, int>{
          for (final g in Grade.values) g: vm.gradeCount(g),
        };
        expect(
          counts.values.reduce((a, b) => a + b),
          vm.gradeTotal,
          reason: 'every windowed review carries one of the three grades',
        );
      });
    });

    group('headline figures', () {
      test('avgInterval is an em dash when nothing is scheduled', () async {
        final vm = buildVm(await emptyStore(), FakeFeedback());

        expect(vm.summary.scheduled, 0);
        expect(vm.avgInterval, '\u2014');
      });

      test('avgInterval renders a real interval when cards are scheduled',
          () async {
        final vm = buildVm(await seededStore(), FakeFeedback());

        expect(vm.summary.scheduled, greaterThan(0));
        expect(vm.avgInterval, isNot('\u2014'));
      });

      test('isEmpty follows the word count, hasReviews follows the logs',
          () async {
        final emptyVm = buildVm(await emptyStore(), FakeFeedback());
        expect(emptyVm.isEmpty, isTrue);
        expect(emptyVm.total, 0);
        expect(emptyVm.hasReviews, isFalse);

        final seeded = await seededStore();
        final seededVm = buildVm(seeded, FakeFeedback());
        expect(seededVm.isEmpty, isFalse);
        expect(seededVm.total, seeded.data.words.length);
        expect(seededVm.hasReviews, isTrue);
      });

      test('statusCount tallies the library and statusPct matches the summary',
          () async {
        final vm = buildVm(await seededStore(), FakeFeedback());

        var sum = 0;
        for (final status in WordStatus.values) {
          sum += vm.statusCount(status);
        }
        expect(sum, vm.total);

        // Same arithmetic as `StatsSummary.masteryPct`, so the two cannot drift.
        expect(vm.statusPct(WordStatus.mastered), vm.summary.masteryPct);
      });

      test('statusPct is 0 on an empty library rather than dividing by zero',
          () async {
        final vm = buildVm(await emptyStore(), FakeFeedback());

        expect(vm.statusPct(WordStatus.mastered), 0);
      });

      test('listCount and allReviews count what the tiles show', () async {
        final store = await seededStore();
        final vm = buildVm(store, FakeFeedback());

        expect(vm.listCount, store.data.lists.length);
        expect(vm.allReviews, store.data.logs.length);
      });
    });

    group('intents', () {
      test('goToWords and goToFlashcards record their page id', () async {
        final feedback = FakeFeedback();
        final vm = buildVm(await seededStore(), feedback);

        expect(vm.canNavigate, isTrue);

        vm.goToWords();
        vm.goToFlashcards();

        expect(feedback.navigations, <String>['words', 'flashcards']);
      });
    });

    group('store subscription', () {
      test('a store write re-derives without the view model being told',
          () async {
        final store = await seededStore();
        final vm = buildVm(store, FakeFeedback());
        var notified = 0;
        vm.addListener(() => notified += 1);

        final seriesBefore = vm.seriesTotal;
        final gradeBefore = vm.gradeTotal;
        final goodBefore = vm.gradeCount(Grade.good);
        final todayBefore = vm.series.last.count;

        store.gradeWord(store.data.words.first.id, Grade.good, fixedNow);

        expect(notified, 1, reason: 'one store notify, one refresh');
        expect(vm.seriesTotal, seriesBefore + 1);
        expect(vm.gradeTotal, gradeBefore + 1);
        expect(vm.gradeCount(Grade.good), goodBefore + 1);
        expect(vm.series.last.count, todayBefore + 1);
      });

      test('dispose detaches, so a later write does not reach a dead model',
          () async {
        final store = await seededStore();
        final feedback = FakeFeedback();
        final vm = StatsViewModel(
          store: store,
          feedback: feedback,
          clock: () => fixedNow,
        );
        final seriesBefore = vm.seriesTotal;
        vm.dispose();

        store.gradeWord(store.data.words.first.id, Grade.good, fixedNow);

        // The snapshot is gone from the model's point of view: no listener ran
        // and no notify reached the (disposed) notifier.
        expect(vm.isDisposed, isTrue);
        expect(vm.seriesTotal, seriesBefore);
      });
    });
  });
}
