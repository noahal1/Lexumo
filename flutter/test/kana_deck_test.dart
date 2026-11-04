// Tests for the ready-made kana decks: the gojuon chart itself, the templates
// that turn it into a list, and the store call that writes one in a single
// commit.
//
// Three separate things can go wrong here and each fails differently, so they
// are asserted separately: the chart can lose a row or duplicate a sound; the
// template can map the chart onto the wrong word fields (a card whose answer is
// printed on its own front face); and the store call can notify once per word
// instead of once per deck, which would repaint the list manager 46 times while
// its dialog is still open.

import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/domain/models/kana.dart';
import 'package:lexumo/domain/models/seed.dart';
import 'package:lexumo/domain/models/types.dart';
import 'package:lexumo/domain/use_cases/deck_templates.dart';

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
  group('the kana chart', () {
    test('has the five vowel rows plus n for both scripts', () {
      for (final KanaScript script in KanaScript.values) {
        final List<Kana> chart = kanaFor(script);
        expect(chart.length, 46,
            reason: '${script.wire} should cover the chart');
      }
    });

    test('never repeats a glyph', () {
      for (final KanaScript script in KanaScript.values) {
        final List<String> glyphs =
            kanaFor(script).map((Kana k) => k.kana).toList();
        expect(glyphs.toSet().length, glyphs.length,
            reason: '${script.wire} has a duplicated kana');
      }
    });

    test('never repeats a romanisation', () {
      // Two kana with the same romaji would make the answer ambiguous: the card
      // asks "which sound is this" and the back says `ji`, but the two kana that
      // both romanise as ji are not the same kana. Only the 46 basic sounds are
      // in the chart, where the romaji happen to be unique -- that is worth
      // pinning, because adding dakuten later would break it.
      for (final KanaScript script in KanaScript.values) {
        final List<String> romaji =
            kanaFor(script).map((Kana k) => k.romaji).toList();
        expect(romaji.toSet().length, romaji.length,
            reason: '${script.wire} has a duplicated romaji');
      }
    });

    test('every entry names its row and carries an example word', () {
      for (final KanaScript script in KanaScript.values) {
        for (final Kana k in kanaFor(script)) {
          expect(k.row, isNotEmpty, reason: '${k.kana} has no row');
          expect(k.word, isNotEmpty, reason: '${k.kana} has no example word');
          expect(k.wordZh, isNotEmpty,
              reason: '${k.kana} has no example translation');
          expect(k.romaji, isNotEmpty, reason: '${k.kana} has no romaji');
        }
      }
    });

    test('the two scripts cover the same sounds', () {
      // Hiragana and katakana are the same 46 sounds in two shapes. If one list
      // gained a row the other lacks, a learner who starts with katakana would
      // silently get a different curriculum.
      final List<String> hira =
          kanaFor(KanaScript.hiragana).map((Kana k) => k.romaji).toList();
      final List<String> kata =
          kanaFor(KanaScript.katakana).map((Kana k) => k.romaji).toList();
      expect(kata, hira);
    });
  });

  group('deckTemplates', () {
    test('offers one deck per script, both Japanese', () {
      final List<DeckTemplate> decks = deckTemplates();
      expect(decks.length, 2);
      for (final DeckTemplate deck in decks) {
        expect(deck.sourceLang, 'ja');
        expect(deck.targetLang, 'zh-CN');
        expect(deck.count, 46);
        expect(deck.id, isNotEmpty);
        expect(deck.name, isNotEmpty);
      }
      expect(decks.map((DeckTemplate d) => d.id).toSet().length, 2,
          reason: 'deck ids are what the dialog switches its label on');
    });

    test('puts the romaji where the front face cannot show it', () {
      // This is the one mapping that matters: `phonetic` is not drawn before the
      // reveal, `definition` is. If the romaji went into `definition` alone the
      // card would print its own answer on the question side; if it went into
      // neither, the back would have nothing to say.
      final DeckTemplate deck = deckTemplates().first;
      for (final NewWordInput word in deck.words) {
        expect(word.phonetic, isNotEmpty,
            reason: '${word.term} lost its romaji');
        expect(word.definition, word.phonetic,
            reason: '${word.term}: the back face should print the romaji');
        expect(word.term, isNot(word.definition),
            reason: '${word.term}: the answer must not be the question');
      }
    });

    test('does not repeat the example translation as a second definition', () {
      // `definition2` and `exampleZh` would both be drawn on the back, so a
      // filled-in `definition2` prints the same Chinese twice per card.
      for (final DeckTemplate deck in deckTemplates()) {
        for (final NewWordInput word in deck.words) {
          expect(word.definition2, isEmpty,
              reason: '${word.term} duplicates its example translation');
          expect(word.example, isNotEmpty);
          expect(word.exampleZh, isNotEmpty);
        }
      }
    });

    test('leaves the list id to the store', () {
      // The template cannot know the list id -- the store mints it. Passing a
      // real-looking id here would make `addWord`'s "fall back to lists[0]"
      // branch look like the normal path.
      for (final DeckTemplate deck in deckTemplates()) {
        for (final NewWordInput word in deck.words) {
          expect(word.listId, isEmpty);
        }
      }
    });
  });

  group('Store.createListWithWords', () {
    test('writes the list and every word', () async {
      final Store store = await freshStore();
      final DeckTemplate deck = deckTemplates().first;
      final int listsBefore = store.data.lists.length;

      final WordList created = store.createListWithWords(
        name: deck.name,
        sourceLang: deck.sourceLang,
        targetLang: deck.targetLang,
        words: deck.words,
      );

      expect(store.data.lists.length, listsBefore + 1);
      expect(store.data.lists.last.id, created.id);
      expect(created.sourceLang, 'ja');
      expect(created.targetLang, 'zh-CN');

      final List<Word> mine =
          store.data.words.where((Word w) => w.listId == created.id).toList();
      expect(mine.length, deck.count);
      for (final Word word in mine) {
        expect(word.sourceLang, 'ja');
        expect(word.targetLang, 'zh-CN');
        expect(word.status, WordStatus.new_);
        expect(word.srs, isNull);
      }
    });

    test('notifies its listeners once, not once per word', () async {
      // The reason this method exists at all. `createList` + 46 x `addWord`
      // would fire 47 notifications and queue 47 saves; the list manager dialog
      // is still on screen for all of them.
      final Store store = await freshStore();
      int notifications = 0;
      final void Function() unsubscribe =
          store.addListener(() => notifications++);
      addTearDown(unsubscribe);

      final DeckTemplate deck = deckTemplates().first;
      store.createListWithWords(
        name: deck.name,
        sourceLang: deck.sourceLang,
        targetLang: deck.targetLang,
        words: deck.words,
      );

      expect(notifications, 1, reason: 'a deck is one change, so one repaint');
    });

    test('marks the list and every word pending for sync', () async {
      final Store store = await freshStore();
      final int before = store.pendingChangeCount();
      final DeckTemplate deck = deckTemplates().first;

      final WordList created = store.createListWithWords(
        name: deck.name,
        sourceLang: deck.sourceLang,
        targetLang: deck.targetLang,
        words: deck.words,
      );

      // One journal entry for the list, one per word -- the same accounting a
      // hand-built list would have produced, so a sync round carries it.
      expect(store.pendingChangeCount(), before + 1 + deck.count);
      expect(store.data.pending.lists, contains(created.id));
      for (final Word word
          in store.data.words.where((Word w) => w.listId == created.id)) {
        expect(store.data.pending.words, contains(word.id),
            reason: '${word.term} did not enter the pending set');
      }
    });

    test('falls back to a placeholder name when given blanks', () async {
      final Store store = await freshStore();
      final WordList created = store.createListWithWords(
        name: '   ',
        sourceLang: 'ja',
        targetLang: 'zh-CN',
        words: const <NewWordInput>[],
      );
      expect(created.name, isNotEmpty);
      expect(store.data.lists.last.name, created.name);
    });

    test('an empty deck still creates the list', () async {
      final Store store = await freshStore();
      final int listsBefore = store.data.lists.length;
      store.createListWithWords(
        name: 'empty deck',
        sourceLang: 'ja',
        targetLang: 'zh-CN',
        words: const <NewWordInput>[],
      );
      expect(store.data.lists.length, listsBefore + 1);
    });
  });
}
