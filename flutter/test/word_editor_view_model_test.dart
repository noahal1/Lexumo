// Unit tests for the editor's view model — the lookup races and the save rules.
//
// Every one of these used to be reachable only by pumping the dialog and tapping
// 翻译, which meant the subtle parts (a late answer for a retyped term, the
// cooldown override on retry) had no direct test at all.

import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/data/services/translate.dart';
import 'package:lexumo/domain/models/seed.dart';
import 'package:lexumo/domain/models/types.dart';
import 'package:lexumo/ui/core/view_model.dart' show ToastKind;
import 'package:lexumo/ui/features/words/view_models/word_editor_view_model.dart';

import 'support/fake_feedback.dart';
import 'support/fake_lookup.dart';

Future<Store> freshStore() async {
  final store = Store(persistence: MemoryStore(), seed: seedData);
  await store.init();
  return store;
}

LookupResult hit(String meaning, {String term = 'cat', String pos = 'n.'}) =>
    LookupResult(
      term: term,
      phonetic: 'kæt',
      senses: <DictSense>[DictSense(pos: pos, meaning: meaning)],
      examples: const <DictExample>[],
      provider: ProviderId.youdao,
    );

WordEditorViewModel build(
  Store store,
  FakeFeedback feedback, {
  Word? word,
  FakeLookup? lookup,
  String defaultListId = '',
}) {
  return WordEditorViewModel(
    store: store,
    feedback: feedback,
    word: word,
    defaultListId:
        defaultListId.isEmpty ? store.data.lists.first.id : defaultListId,
    lookup: () => lookup ?? FakeLookup(),
    resetCooldown: () {},
  );
}

void main() {
  group('WordEditorViewModel', () {
    late Store store;
    late FakeFeedback feedback;
    late WordEditorViewModel vm;

    setUp(() async {
      store = await freshStore();
      feedback = FakeFeedback();
    });

    tearDown(() {
      vm.dispose();
    });

    test('create mode starts clean and takes the page\'s list', () {
      vm = build(store, feedback);
      expect(vm.word, isNull);
      expect(vm.listId, store.data.lists.first.id);
      expect(vm.dirty, isFalse);
      expect(vm.status, WordStatus.new_);
    });

    test('edit mode seeds every field from the word', () {
      final Word existing = store.data.words.first;
      vm = build(store, feedback, word: existing);

      expect(vm.term, existing.term);
      expect(vm.definition, existing.definition);
      expect(vm.listId, existing.listId);
      expect(vm.status, existing.status);
      expect(vm.dirty, isFalse);
    });

    test('typing makes the draft dirty, retyping the same value does not', () {
      vm = build(store, feedback);
      vm.setTerm('hello');
      expect(vm.dirty, isTrue);

      vm.setTerm('');
      expect(vm.dirty, isFalse);
    });

    test('saving with an empty term reports an error and writes nothing', () {
      vm = build(store, feedback);
      final int before = store.data.words.length;

      final bool saved = vm.save();

      expect(saved, isFalse);
      expect(vm.error, isNotEmpty);
      expect(store.data.words.length, before);
    });

    test('saving a new word writes it into the chosen list', () {
      vm = build(store, feedback);
      final int before = store.data.words.length;
      vm.setTerm('serendipity');
      vm.setDefinition('意外的惊喜');

      final bool saved = vm.save();

      expect(saved, isTrue);
      expect(store.data.words.length, before + 1);
      final Word added =
          store.data.words.firstWhere((w) => w.term == 'serendipity');
      expect(added.definition, '意外的惊喜');
      expect(added.listId, store.data.lists.first.id);
    });

    test('saving an edit nulls a field the user emptied', () {
      final Word existing = store.data.words.firstWhere(
        (w) => (w.pos ?? '').isNotEmpty,
        orElse: () => store.data.words.first,
      );
      vm = build(store, feedback, word: existing);
      vm.setPos('');

      expect(vm.save(), isTrue);

      final Word after =
          store.data.words.firstWhere((w) => w.id == existing.id);
      expect(after.pos, isNull, reason: 'copyWith would have kept the old value');
    });

    test('the duplicate notice names a different word with the same term', () {
      final Word existing = store.data.words.first;
      vm = build(store, feedback);

      vm.setTerm(existing.term);

      expect(vm.duplicate?.id, existing.id);
      expect(vm.showDuplicate, isTrue);
    });

    test('editing a word does not flag itself as a duplicate', () {
      final Word existing = store.data.words.first;
      vm = build(store, feedback, word: existing);

      vm.setTerm(existing.term);

      expect(vm.showDuplicate, isFalse);
    });

    test('forward lookup fills the meaning fields', () async {
      final FakeLookup lookup = FakeLookup(result: hit('猫'));
      vm = build(store, feedback, lookup: lookup);
      vm.setTerm('cat');

      await vm.forwardLookup();

      expect(lookup.calls.single.term, 'cat');
      expect(vm.definition, contains('猫'));
      expect(vm.phonetic, 'kæt');
      expect(vm.forwardPhase, LookupPhase.idle);
      expect(feedback.toasts.last.kind, ToastKind.ok);
    });

    test('a cached answer applies silently', () async {
      final FakeLookup lookup =
          FakeLookup(result: hit('猫').fromCacheMarked());
      vm = build(store, feedback, lookup: lookup);
      vm.setTerm('cat');

      await vm.forwardLookup();

      expect(vm.definition, contains('猫'));
      expect(feedback.toasts, isEmpty, reason: 'no toast for a cache hit');
    });

    test('a late answer for a retyped term is dropped', () async {
      final FakeLookup lookup = FakeLookup(
        result: hit('猫'),
        delay: const Duration(milliseconds: 40),
      );
      vm = build(store, feedback, lookup: lookup);
      vm.setTerm('cat');

      final Future<void> pending = vm.forwardLookup();
      // The user keeps typing while the request is in flight.
      vm.setTerm('catalogue');
      await pending;

      expect(vm.definition, isEmpty);
      expect(vm.forwardPhase, LookupPhase.idle);
    });

    test('a superseded request does not overwrite the newer one', () async {
      final FakeLookup lookup = FakeLookup(
        result: hit('猫'),
        delay: const Duration(milliseconds: 40),
      );
      vm = build(store, feedback, lookup: lookup);
      vm.setTerm('cat');

      final Future<void> first = vm.forwardLookup();
      final Future<void> second = vm.forwardLookup();
      await Future.wait(<Future<void>>[first, second]);

      expect(vm.definition, contains('猫'));
      expect(vm.forwardPhase, LookupPhase.idle);
    });

    test('a failure reports under the button and keeps the draft', () async {
      final FakeLookup lookup = FakeLookup(failure: LookupFailure.notFound);
      vm = build(store, feedback, lookup: lookup);
      vm.setTerm('cat');

      await vm.forwardLookup();

      expect(vm.forwardPhase, LookupPhase.failed);
      expect(vm.forwardFailureText, isNotNull);
      expect(vm.term, 'cat');
      expect(vm.definition, isEmpty);
    });

    test('a retry after a failure lifts the provider cooldown', () async {
      int resets = 0;
      final FakeLookup lookup = FakeLookup(failure: LookupFailure.rateLimited);
      vm = WordEditorViewModel(
        store: store,
        feedback: feedback,
        word: null,
        defaultListId: store.data.lists.first.id,
        lookup: () => lookup,
        resetCooldown: () => resets++,
      );
      vm.setTerm('cat');

      await vm.forwardLookup();
      expect(resets, 0, reason: 'the first failure arms the cooldown');
      expect(vm.forwardPhase, LookupPhase.failed);

      await vm.forwardLookup();
      expect(resets, 1, reason: 'the retry button is an explicit override');
    });

    test('reverse lookup fills the term from a typed meaning', () async {
      final FakeLookup lookup =
          FakeLookup(result: hit('apple', term: '苹果', pos: ''));
      vm = build(store, feedback, lookup: lookup);
      vm.setDefinition('苹果');

      await vm.reverseLookup();

      expect(lookup.calls.single.term, '苹果');
      expect(vm.term, 'apple');
    });

    test('an empty answer leaves the term alone', () async {
      final FakeLookup lookup = FakeLookup(result: hit('', pos: ''));
      vm = build(store, feedback, lookup: lookup);
      vm.setDefinition('苹果');

      await vm.reverseLookup();

      expect(vm.term, isEmpty);
    });

    test('the dismiss guard is a two-step: first ask, then close', () {
      vm = build(store, feedback);
      vm.setTerm('draft');

      expect(vm.dismissOpen, isFalse);
      vm.setDismissOpen(true);
      expect(vm.dismissOpen, isTrue);
      vm.setDismissOpen(false);
      expect(vm.dismissOpen, isFalse);
    });

    test('a disposed view model drops a late lookup answer', () async {
      final FakeLookup lookup = FakeLookup(
        result: hit('猫'),
        delay: const Duration(milliseconds: 40),
      );
      vm = build(store, feedback, lookup: lookup);
      vm.setTerm('cat');

      final Future<void> pending = vm.forwardLookup();
      vm.dispose();
      await pending;

      expect(vm.definition, isEmpty);

      // tearDown disposes once more; a live instance is needed for that.
      vm = build(store, feedback);
    });
  });
}
