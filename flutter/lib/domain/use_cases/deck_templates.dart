/// Ready-made decks: the gojūon chart, one list per script.
///
/// The app ships a single English sample list, and a learner starting Japanese
/// had to type 46 kana by hand before the flashcard and quiz screens had
/// anything to work on. This turns the chart in `domain/models/kana.dart` into
/// the `NewWordInput` rows the store already knows how to write.
///
/// Why a *list* and not a special "kana mode": every other screen — flashcards,
/// quiz, stats, the streak, sync — is written against lists and words. A second
/// content type would have to be taught to all of them, and the first thing it
/// would break is the daily new-card budget, which counts words. A generated
/// list is ordinary content, so nothing downstream needs to know where it came
/// from.
library;

import '../models/kana.dart';
import '../models/types.dart';

/// A deck the user can add with one press.
class DeckTemplate {
  const DeckTemplate({
    required this.id,
    required this.name,
    required this.sourceLang,
    required this.targetLang,
    required this.words,
  });

  /// Stable identifier; also used as the i18n key suffix for the label.
  final String id;

  /// The list name written into the store.
  final String name;

  final String sourceLang;
  final String targetLang;

  /// Built lazily on first access? No — these are 46 small records, and
  /// building them eagerly keeps [buildDeck] a pure function with no hidden
  /// state. The cost is measured in microseconds.
  final List<NewWordInput> words;

  /// How many cards the deck adds.
  int get count => words.length;
}

/// The kana chart as one deck per script.
///
/// `targetLang` is `zh-CN` because the meanings are written in Chinese: this
/// app's interface ships zh/en, and a kana deck whose answers are Chinese is
/// what a Chinese speaker learning Japanese actually needs. The interface
/// language does not change that — switching the UI to English should not
/// silently give you an English→Japanese deck with Chinese answers.
List<DeckTemplate> deckTemplates() => <DeckTemplate>[
      _kanaDeck(
        id: 'kana-hiragana',
        name: '五十音 · 平假名',
        script: KanaScript.hiragana,
      ),
      _kanaDeck(
        id: 'kana-katakana',
        name: '五十音 · 片假名',
        script: KanaScript.katakana,
      ),
    ];

DeckTemplate _kanaDeck({
  required String id,
  required String name,
  required KanaScript script,
}) {
  final List<Kana> chart = kanaFor(script);
  return DeckTemplate(
    id: id,
    name: name,
    sourceLang: 'ja',
    targetLang: 'zh-CN',
    words: <NewWordInput>[
      for (final Kana k in chart)
        NewWordInput(
          term: k.kana,
          // The romanisation is the one thing a beginner cannot infer from the
          // glyph, so it goes in `phonetic` — the field the editor shows under
          // the term and the flashcard keeps off the front face. That matters:
          // `phonetic` is NOT drawn before the reveal, so the answer is not on
          // the question.
          phonetic: k.romaji,
          // The row (あ行 / カ行) is the card's overline, so the learner always
          // knows which family is being asked about — and it is the one thing
          // the front face may carry, because it narrows the answer without
          // giving it.
          pos: k.row,
          // The romaji is the answer. `definition` is what the back face prints
          // in display type, so it is the romaji and not a Chinese gloss: the
          // question is "which sound is this", and `a` is the whole answer.
          definition: k.romaji,
          // Left empty on purpose. The example word below already carries its
          // meaning in `exampleZh`, and a second copy in `definition2` would
          // print the same Chinese twice on the back of every card.
          definition2: '',
          example: k.word,
          exampleZh: k.wordZh,
          note: '',
          listId: '',
        ),
    ],
  );
}
