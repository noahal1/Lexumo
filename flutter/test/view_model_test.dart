// Unit tests for the view models — no widget tree, no `BuildContext`.
//
// That is the whole point of the layering: everything a view model cannot do
// itself (translate, toast, confirm, navigate) arrives through [Feedback], and
// everything it reads or writes arrives through [Store]. Swapping both for a
// fake and a `MemoryStore` means a test can drive a screen's logic directly.
//
// These tests are deliberately about *behaviour that used to live in a widget's
// State*: the filter atom, the delete-and-undo pair, the select-all rule, the
// "ask before discarding a dirty draft" guard. Before the split they could only
// be reached by tapping pixels.

import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/domain/models/seed.dart';
import 'package:lexumo/domain/models/types.dart';
import 'package:lexumo/domain/use_cases/word_query.dart';
import 'package:lexumo/ui/core/view_model.dart';
import 'package:lexumo/ui/features/words/view_models/words_view_model.dart';

import 'support/fake_feedback.dart';

/// A store over a fresh seed with no disk.
Future<Store> freshStore() async {
  final store = Store(persistence: MemoryStore(), seed: seedData);
  await store.init();
  return store;
}

WordsViewModel build(Store store, FakeFeedback feedback, {int? now}) {
  return WordsViewModel(
    store: store,
    feedback: feedback,
    clock: now == null ? null : () => now,
  );
}

void main() {
  group('WordsViewModel', () {
    late Store store;
    late FakeFeedback feedback;
    late WordsViewModel vm;

    setUp(() async {
      store = await freshStore();
      feedback = FakeFeedback();
      vm = build(store, feedback);
    });

    tearDown(() {
      vm.dispose();
    });

    test('adopts the first list on the first read', () {
      expect(vm.listId, isEmpty);
      vm.ensureReady();
      expect(vm.listId, store.data.lists.first.id);
      // Every list the seed ships is reachable through the tabs.
      expect(vm.index.byList.keys.toSet(), store.data.lists.map((l) => l.id).toSet());
    });

    test('a second ensureReady keeps the list the user chose', () {
      vm.ensureReady();
      final String first = vm.listId;
      final String second = vm.createList(
        name: 'Second',
        sourceLang: 'en',
        targetLang: 'zh-CN',
      ).id;
      expect(second, isNot(first));
      expect(vm.listId, second);

      vm.ensureReady();

      expect(vm.listId, second, reason: 'the adoption step is one-shot');
    });

    test('a list deleted elsewhere moves the filter back to a live one', () {
      vm.ensureReady();
      final String extra = vm.createList(
        name: 'Doomed',
        sourceLang: 'en',
        targetLang: 'zh-CN',
      ).id;
      expect(vm.listId, extra);

      // Deleted from another screen (or merged away by a sync round) — the
      // store listener must notice, because `queryWords` would otherwise return
      // an empty table for a list that no longer exists.
      store.deleteList(extra);

      expect(store.data.lists.any((l) => l.id == extra), isFalse);
      expect(vm.listId, store.data.lists.first.id);
    });

    test('the query filter is trimmed and case-folded', () {
      vm.ensureReady();
      final Word target = store.data.words.firstWhere((w) => w.listId == vm.listId);

      vm.setQuery('  ${target.term.toUpperCase()}  ');

      expect(vm.trimmedQuery, target.term.toUpperCase());
      expect(vm.filtered.map((w) => w.id), contains(target.id));
    });

    test('a status filter narrows the table but not the list count', () {
      vm.ensureReady();
      final int all = vm.listCount;
      expect(all, greaterThan(0));

      vm.setStatus(WordStatus.new_);

      expect(vm.listCount, all, reason: 'the tab count is the whole list');
      expect(vm.filtered.every((w) => w.status == WordStatus.new_), isTrue);
      expect(vm.filtered.length, lessThanOrEqualTo(all));
    });

    test('resetFilters keeps the list and the sort', () {
      vm.ensureReady();
      vm.setSort(SortKey.alpha);
      vm.setQuery('zzz');
      vm.setStatus(WordStatus.learning);
      vm.toggleFavoriteOnly();

      vm.resetFilters();

      expect(vm.listId, store.data.lists.first.id);
      expect(vm.filters.sort, SortKey.alpha);
      expect(vm.filters.query, isNull);
      expect(vm.filters.status, isNull);
      expect(vm.filters.favoriteOnly, isFalse);
    });

    test('select-all covers exactly the visible rows', () {
      vm.ensureReady();
      vm.enterSelect();
      vm.selectAllVisible();

      expect(vm.selectedCount, vm.filtered.length);
      expect(vm.allVisibleSelected, isTrue);

      // Narrowing the filter drops the selection that is no longer visible.
      vm.setQuery('a');
      expect(vm.allVisibleSelected, isFalse);
    });

    test('deleting a word asks first, then offers undo that restores it', () async {
      vm.ensureReady();
      final Word victim = vm.filtered.first;
      final int before = vm.listCount;

      await vm.deleteWord(victim);

      expect(feedback.confirmations, hasLength(1));
      expect(feedback.confirmations.single.danger, isTrue);
      expect(vm.listCount, before - 1);

      final ToastRecord toast = feedback.toasts.last;
      expect(toast.kind, ToastKind.ok);
      expect(toast.actionLabel, isNotNull);
      toast.onAction!();

      expect(vm.listCount, before);
      expect(store.data.words.any((w) => w.id == victim.id), isTrue);
    });

    test('dismissing the delete dialog writes nothing', () async {
      vm.ensureReady();
      final Word victim = vm.filtered.first;
      final int before = vm.listCount;
      feedback.confirmAnswer = false;

      await vm.deleteWord(victim);

      expect(vm.listCount, before);
      expect(feedback.toasts, isEmpty);
    });

    test('deleting a selection removes every selected word in one journal step',
        () async {
      vm.ensureReady();
      vm.enterSelect();
      final List<Word> targets = vm.filtered.take(2).toList();
      expect(targets, hasLength(2));
      for (final Word w in targets) {
        vm.toggleSelected(w.id);
      }
      final int before = vm.listCount;

      await vm.deleteSelected();

      expect(vm.listCount, before - 2);
      expect(vm.selectMode, isFalse, reason: 'the selection ends with the delete');
    });

    test('favouriting a selection flips every selected row', () {
      vm.ensureReady();
      vm.enterSelect();
      final List<Word> targets =
          vm.filtered.where((w) => !w.favorite).take(2).toList();
      expect(targets, isNotEmpty);
      for (final Word w in targets) {
        vm.toggleSelected(w.id);
      }

      vm.favoriteSelected();

      for (final Word w in targets) {
        expect(
          store.data.words.firstWhere((x) => x.id == w.id).favorite,
          isTrue,
        );
      }
    });

    test('createList switches to the new list and toasts', () {
      vm.ensureReady();

      final WordList created = vm.createList(
        name: 'Fresh',
        sourceLang: 'en',
        targetLang: 'zh-CN',
      );

      expect(vm.listId, created.id);
      expect(store.data.lists.any((l) => l.id == created.id), isTrue);
      expect(feedback.toasts.last.kind, ToastKind.ok);
    });

    test('deleteList asks, then moves the filter off the deleted list', () async {
      vm.ensureReady();
      final WordList victim = vm.createList(
        name: 'Doomed',
        sourceLang: 'en',
        targetLang: 'zh-CN',
      );
      expect(vm.listId, victim.id);

      await vm.deleteList(victim);

      expect(feedback.confirmations, hasLength(1));
      expect(store.data.lists.any((l) => l.id == victim.id), isFalse);
      expect(vm.listId, isNot(victim.id));
    });

    test('dismissing the delete-list dialog keeps the list', () async {
      vm.ensureReady();
      final WordList victim = vm.createList(
        name: 'Keep',
        sourceLang: 'en',
        targetLang: 'zh-CN',
      );
      feedback.confirmAnswer = false;

      await vm.deleteList(victim);

      expect(store.data.lists.any((l) => l.id == victim.id), isTrue);
      expect(vm.listId, victim.id);
    });

    test('the store is the single source of truth for the table', () {
      vm.ensureReady();
      final int before = vm.listCount;
      final Word sample = vm.filtered.first;

      // A write from anywhere else in the app — a sync merge, another page —
      // must show up without the view model being told.
      store.deleteWord(sample.id);

      expect(vm.listCount, before - 1);
    });

    test('a disposed view model survives a late store write', () {
      vm.ensureReady();
      final Word sample = vm.filtered.first;
      vm.dispose();

      // Would throw "A ChangeNotifier was used after being disposed" without
      // the isDisposed guard in `update`/`refresh`.
      expect(() => store.deleteWord(sample.id), returnsNormally);

      // Rebuild a live one for tearDown's disposal.
      vm = build(store, feedback);
    });
  });
}
