// Regression tests for `Store.undoReview` — the persistence half of "undo a
// grade", with no view model and no widget tree in the way.
//
// These exist because the operation had a real bug that nothing caught: it
// passed a hard `clearSrs: true` next to the snapshot it had just restored, and
// `Word.copyWith` gives `clearSrs` precedence over `srs`. So undoing a grade on
// a card that already had a schedule silently threw that schedule away —
// `reviewCount`, `dueAt`, ease, all of it — while the log was correctly removed
// and the status was correctly put back, which is why it looked like it worked.
// The reference implementation (`src/lib/store.ts:458`) patches `srs` with no
// clear flag at all; the port had drifted.
//
// The view-model tests could only assert this indirectly (through the deck's
// idea of "the word I just graded"), so the assertion lives here as well, on
// the store's own surface.

import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/domain/models/seed.dart';
import 'package:lexumo/domain/models/types.dart';

/// A frozen "now" so the seed's schedule is a constant, not a race.
const int NOW = 1770000000000;

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

void main() {
  group('Store.undoReview', () {
    test('restores the schedule a card already had, not just its absence', () async {
      final Store store = await freshStore();

      // A card that is already in rotation — it has a real schedule to lose.
      final Word before = store.data.words.firstWhere(
        (Word w) => w.srs != null && w.status != WordStatus.new_,
      );

      final GradeResult result = store.gradeWord(before.id, Grade.good)!;
      final Word graded = store.data.words.firstWhere((Word w) => w.id == before.id);
      // The grade must actually have moved something, or the test proves nothing.
      expect(graded.srs!.reviewCount, before.srs!.reviewCount + 1);

      store.undoReview(before.id, before.srs, before.status, result.logId);

      final Word after = store.data.words.firstWhere((Word w) => w.id == before.id);
      expect(after.srs, isNotNull, reason: 'undo must not wipe a restored schedule');
      expect(after.srs!.reviewCount, before.srs!.reviewCount);
      expect(after.srs!.dueAt, before.srs!.dueAt);
      expect(after.srs!.ease, before.srs!.ease);
      expect(after.srs!.intervalDays, before.srs!.intervalDays);
      expect(after.srs!.correctCount, before.srs!.correctCount);
      expect(after.status, before.status);
    });

    test('leaves a never-reviewed card unscheduled, as it was', () async {
      final Store store = await freshStore();

      // A brand-new card: no schedule before the grade, so none after the undo.
      final Word before = store.data.words.firstWhere((Word w) => w.srs == null);

      final GradeResult result = store.gradeWord(before.id, Grade.good)!;
      expect(
        store.data.words.firstWhere((Word w) => w.id == before.id).srs,
        isNotNull,
      );

      store.undoReview(before.id, before.srs, before.status, result.logId);

      final Word after = store.data.words.firstWhere((Word w) => w.id == before.id);
      // This is the case `clearSrs` exists for: `copyWith(srs: null)` alone
      // would keep the current value, so the flag has to be true here.
      expect(after.srs, isNull);
      expect(after.status, WordStatus.new_);
    });

    test('drops exactly the one log it was given', () async {
      final Store store = await freshStore();

      final Word before = store.data.words.firstWhere((Word w) => w.srs != null);
      final List<String> logsBefore =
          store.data.logs.map((ReviewLog l) => l.id).toList();

      final GradeResult result = store.gradeWord(before.id, Grade.easy)!;
      expect(store.data.logs.length, logsBefore.length + 1);

      store.undoReview(before.id, before.srs, before.status, result.logId);

      expect(store.data.logs.map((ReviewLog l) => l.id).toList(), logsBefore);
    });
  });
}
