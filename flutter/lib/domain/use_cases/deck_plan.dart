/// What a review round is made of: which pool it draws from, how many cards
/// the pool holds, and the ordered list of card ids one sitting would use.
///
/// This used to live inside `flashcards/view_models/flashcards_view_model.dart`,
/// which was fine while the flashcard page owned the "组卡方式" picker. The
/// practice screen now asks the same questions *before* a session exists — the
/// big number on its front page is a deck size, and 开始复习 has to know whether
/// the round is empty before it hands over — so the rules moved here, where a
/// page can read them without constructing a view model and a session can be
/// planned without a widget tree.
///
/// Deliberately pure: no Flutter, no store. It takes the snapshot and a clock
/// and returns values, which is what makes the counts on the front page and the
/// cards in the session provably the same computation.
library;

import '../models/quiz.dart' show QUIZ_CHOICES;
import '../models/srs.dart';
import '../models/types.dart';
import '../models/utils.dart' show shuffle, startOfDay;

/// Sorting sentinel for a card with no schedule — `Number.MAX_SAFE_INTEGER` in
/// the TS, kept identical so an unscheduled card sorts last.
const int _kNoDueAt = 9007199254740991;

/// Where the cards in a session come from. `new` is a reserved word in Dart, so
/// the enum member is [fresh] while the wire value and the i18n key stay `new`.
enum DeckSource { due, fresh, all, favorites }

/// The round size used when a stored one is missing or nonsensical.
///
/// `_cleanSettings` decodes an absent numeric field as 0 (it must — the server
/// document is the truth, and inventing a default would overwrite a real local
/// value). 0 cards is not a round anybody chose, so the planner treats every
/// non-positive size as "use the default" instead of handing the session an
/// empty deck that the UI would then explain as "nothing due".
const int kDefaultRoundSize = 20;

/// How many brand-new cards the daily allowance still has room for.
int newCardsLeft(AppData data, int now) {
  final int start = startOfDay(now);
  /* A card counts as "introduced today" when its earliest review log is from
     today. Deriving this from logs (rather than reviewCount == 1) keeps the
     count stable even if a fresh card is graded twice in one day, and undoing a
     first grade restores the allowance naturally. */
  final Map<String, int> firstReviewAt = <String, int>{};
  for (final ReviewLog log in data.logs) {
    final int? prev = firstReviewAt[log.wordId];
    if (prev == null || log.at < prev) firstReviewAt[log.wordId] = log.at;
  }
  final int introduced = data.words.where((Word word) {
    final int? at = firstReviewAt[word.id];
    return at != null && at >= start;
  }).length;
  final int left = data.settings.newCardsPerDay - introduced;
  return left < 0 ? 0 : left;
}

/// The number of cards one sitting should hold: the requested size, but never
/// more than the pool can supply.
int deckRoundSize(Settings settings, int poolSize) {
  final int wanted = settings.roundSize > 0 ? settings.roundSize : kDefaultRoundSize;
  return wanted < poolSize ? wanted : poolSize;
}

/// The number of questions one quiz should hold.
///
/// Same clamp as [deckRoundSize] and for the same reason — but with one extra
/// floor: a quiz needs [QUIZ_CHOICES] words before it can offer four options at
/// all, so a round smaller than that is a round the quiz cannot build. The
/// practice screen reads [canStart] off this rather than off a bare count.
int quizRoundSize(Settings settings, int poolSize) {
  final int wanted = settings.roundSize > 0 ? settings.roundSize : kDefaultRoundSize;
  final int capped = wanted < poolSize ? wanted : poolSize;
  return capped < QUIZ_CHOICES ? 0 : capped;
}

/// Card ids for a session, ordered by the user's review-order setting.
///
/// [limit] caps the round. Null means "the whole pool", which is what the
/// flashcard page used to do and what a caller that has already chosen a size
/// passes explicitly.
List<String> buildDeck(
  AppData data,
  int now,
  DeckSource source, {
  int? limit,
}) {
  final List<Word> picked;
  switch (source) {
    case DeckSource.all:
      picked = shuffle(data.words);
    case DeckSource.favorites:
      picked = shuffle(data.words.where((Word w) => w.favorite).toList());
    case DeckSource.fresh:
      picked = data
          .words
          .where((Word w) => isNew(w.srs))
          .take(newCardsLeft(data, now))
          .toList();
    case DeckSource.due:
      final List<Word> due = dueWords(data.words, now);
      final List<Word> review = due.where((Word w) => !isNew(w.srs)).toList();
      final List<Word> fresh = due
          .where((Word w) => isNew(w.srs))
          .take(newCardsLeft(data, now))
          .toList();
      if (data.settings.reviewOrder == 'random') {
        picked = shuffle(<Word>[...review, ...fresh]);
      } else {
        final List<Word> ordered = review.toList()
          ..sort((Word a, Word b) {
            final int x = a.srs?.dueAt ?? _kNoDueAt;
            final int y = b.srs?.dueAt ?? _kNoDueAt;
            return x.compareTo(y);
          });
        picked = <Word>[...ordered, ...fresh];
      }
  }
  final List<Word> capped = limit == null || limit >= picked.length
      ? picked
      : picked.take(limit).toList();
  return capped.map((Word w) => w.id).toList();
}

/// How big each deck is, and the two things the front page says about it.
///
/// [counts] is per [DeckSource]; [dueReview] is the "待复习" figure the practice
/// screen prints, which counts scheduled cards only — a brand-new card is not
/// something you are behind on, so it must not inflate the number the user
/// reads as a backlog.
class DeckSummary {
  const DeckSummary({
    required this.counts,
    required this.dueReview,
    required this.hasNewWords,
    required this.caughtUp,
    required this.capReached,
  });

  final Map<DeckSource, int> counts;
  final int dueReview;
  final bool hasNewWords;
  final bool caughtUp;
  final bool capReached;
}

/// Derive the summary from a snapshot. Cheap enough to call on every read: the
/// view models do exactly that rather than caching it, so a grade written to the
/// store immediately changes what "due today" means.
DeckSummary summarizeDeck(AppData data, int now) {
  final Settings settings = data.settings;
  final List<Word> due = dueWords(data.words, now);
  final int dueReviewCount = due.where((Word w) => !isNew(w.srs)).length;
  final int dueFreshCount = due.where((Word w) => isNew(w.srs)).length;
  final int freshLeft = newCardsLeft(data, now);
  final int newWordCount = data.words.where((Word w) => isNew(w.srs)).length;
  final bool hasNewWords = newWordCount > 0;
  final bool caughtUp = due.isEmpty;
  final bool capReached =
      settings.newCardsPerDay > 0 && freshLeft == 0 && hasNewWords;

  int atMost(int a, int b) => a < b ? a : b;

  return DeckSummary(
    counts: <DeckSource, int>{
      DeckSource.due: dueReviewCount + atMost(dueFreshCount, freshLeft),
      DeckSource.fresh: atMost(newWordCount, freshLeft),
      DeckSource.all: data.words.length,
      DeckSource.favorites: data.words.where((Word w) => w.favorite).length,
    },
    dueReview: dueReviewCount,
    hasNewWords: hasNewWords,
    caughtUp: caughtUp,
    capReached: capReached,
  );
}
