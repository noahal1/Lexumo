/// Word index — the one owner of the derivations the words and stats screens
/// used to each hand-roll: per-list buckets, status counts and the
/// filtered/sorted query.
///
/// Ported from `src/lib/wordIndex.ts`. Deliberately pure: no Flutter, no DOM
/// and no store import (types only), so the pages and the tests share exactly
/// one implementation. That is what stops the header, the filter controls and
/// the stats page from disagreeing.
library;

import 'day_stats.dart';
import '../models/srs.dart';
import '../models/types.dart';
import '../models/utils.dart';

/* The status ordering is owned by srs.dart (the never-demote rule needs it);
   re-exported so the index's callers and tests keep one import site. */
export '../models/srs.dart' show statusRank;

/// Sort orders the words screen offers.
enum SortKey {
  recent('recent'),
  alpha('alpha'),
  due('due'),
  status('status');

  const SortKey(this.wire);
  final String wire;
}

/// The keys of a bucket's status tally: `all` plus every [WordStatus].
///
/// String keys (rather than fields) because `new` is not a usable Dart
/// identifier; these are exactly the wire names the TS `Record` used, and
/// [WordStatus.wire] for each status is checked against them in the tests.
const List<String> STATUS_FILTER_KEYS = [
  'all',
  'new',
  'reviewing',
  'learning',
  'mastered',
];

/// Status tallies for one list, keyed by [STATUS_FILTER_KEYS].
typedef StatusCounts = Map<String, int>;

/// The words screen's filter state.
///
/// [status] uses `null` for the TS's `"all"` / `undefined`: both mean "do not
/// filter", and there is no third meaning to preserve.
class WordQuery {
  const WordQuery({
    required this.listId,
    this.query,
    this.status,
    this.favoriteOnly = false,
    this.sort,
    this.lang,
  });

  final String listId;
  final String? query;
  final WordStatus? status;
  final bool favoriteOnly;
  final SortKey? sort;

  /// Locale for term collation; the UI passes the active UI language.
  ///
  /// Dart has no locale-sensitive collation in the core library, so the port
  /// sorts with plain `String.compareTo` (code-unit order). See [queryWords].
  final String? lang;
}

/// Per-list word buckets, status tallies and the due buckets.
class WordIndex {
  WordIndex({
    required this.byList,
    required this.countsByList,
    required this.due,
    required this.dueByList,
  });

  /// Words of one list, in snapshot order.
  final Map<String, List<Word>> byList;

  /// Status tallies per list, including the "all" bucket.
  final Map<String, StatusCounts> countsByList;

  /// Global due bucket (same predicate as the store's due list).
  final List<Word> due;

  /// Due bucket per list, so a page can show a list-scoped count.
  final Map<String, List<Word>> dueByList;
}

/// The whole stats headline in one object.
class StatsSummary {
  const StatsSummary({
    required this.total,
    required this.statusCounts,
    required this.mastered,
    required this.today,
    required this.streak,
    required this.goal,
    required this.goalPct,
    required this.reached,
    required this.remaining,
    required this.masteryPct,
    required this.retention,
    required this.avgInterval,
    required this.overdue,
    required this.dueToday,
    required this.reviewSum,
    required this.correctSum,
    required this.reviewedWords,
    required this.scheduled,
  });

  final int total;

  /// Keyed by [WordStatus] wire name — `new`, `reviewing`, `learning`,
  /// `mastered`.
  final Map<String, int> statusCounts;
  final int mastered;
  final int today;
  final int streak;
  final int goal;
  final double goalPct;
  final bool reached;
  final int remaining;
  final int masteryPct;

  /// Percent correct over all reviews, or null when nothing is computable.
  final int? retention;
  final double avgInterval;
  final int overdue;
  final int dueToday;

  /* Raw sums the retention / interval captions need, kept here so the page
     never re-derives them and cannot drift from the percentages above. */
  final int reviewSum;
  final int correctSum;
  final int reviewedWords;
  final int scheduled;
}

/// Due-ness for the index: mastered cards are never due, a card that was never
/// reviewed always is.
///
/// This is *not* `srs.dart`'s [isDue] — the TS keeps two predicates on purpose:
/// `srs.ts` answers "is this card's clock up?", while the list and the stats
/// exclude mastered cards entirely. Ported verbatim from `wordIndex.ts`.
bool _isDue(Word word, int now) {
  if (word.status == WordStatus.mastered) return false;
  final srs = word.srs;
  if (srs == null) return true;
  return srs.dueAt <= now;
}

StatusCounts _emptyCounts() => {for (final k in STATUS_FILTER_KEYS) k: 0};

WordIndex buildWordIndex(AppData data, int now) {
  final byList = <String, List<Word>>{};
  final countsByList = <String, StatusCounts>{};
  final due = <Word>[];
  final dueByList = <String, List<Word>>{};

  // Seed declared lists so an empty list still has a bucket and zero counts.
  for (final list in data.lists) {
    byList[list.id] = <Word>[];
    countsByList[list.id] = _emptyCounts();
  }

  // One pass over the words fills every bucket at once.
  for (final word in data.words) {
    final words = byList.putIfAbsent(word.listId, () => <Word>[]);
    words.add(word);

    final counts = countsByList.putIfAbsent(word.listId, _emptyCounts);
    counts['all'] = counts['all']! + 1;
    counts[word.status.wire] = counts[word.status.wire]! + 1;

    if (_isDue(word, now)) {
      due.add(word);
      dueByList.putIfAbsent(word.listId, () => <Word>[]).add(word);
    }
  }

  return WordIndex(
    byList: byList,
    countsByList: countsByList,
    due: due,
    dueByList: dueByList,
  );
}

/// The filtered, sorted words of one list.
///
/// Two deviations from `localeCompare`, both forced by the Dart core library
/// (no locale-sensitive collation):
///  - `alpha` and the `status` tie-break compare with `String.compareTo`, which
///    is code-unit order. Identical for ASCII; accented letters sort after `z`.
///  - ties are broken by input order via [stableSort], because the TS relied on
///    `Array.prototype.sort` being stable and `List.sort` is not.
List<Word> queryWords(WordIndex index, WordQuery filter) {
  final base = index.byList[filter.listId] ?? const <Word>[];
  final needle = (filter.query ?? '').trim().toLowerCase();

  var out = base;
  if (needle.isNotEmpty) {
    out = out
        .where((w) =>
            w.term.toLowerCase().contains(needle) ||
            w.definition.toLowerCase().contains(needle) ||
            w.definition2.toLowerCase().contains(needle) ||
            w.note.toLowerCase().contains(needle))
        .toList();
  }
  final status = filter.status;
  if (status != null) {
    out = out.where((w) => w.status == status).toList();
  }
  if (filter.favoriteOnly) {
    out = out.where((w) => w.favorite).toList();
  }

  final sorted = out.toList();
  switch (filter.sort ?? SortKey.recent) {
    case SortKey.alpha:
      stableSort(sorted, (a, b) => a.term.compareTo(b.term));
    case SortKey.due:
      stableSort(
        sorted,
        (a, b) {
          final d = (a.srs?.dueAt ?? 0) - (b.srs?.dueAt ?? 0);
          return d != 0 ? d : statusRank(a.status) - statusRank(b.status);
        },
      );
    case SortKey.status:
      stableSort(
        sorted,
        (a, b) {
          final r = statusRank(a.status) - statusRank(b.status);
          return r != 0 ? r : a.term.compareTo(b.term);
        },
      );
    case SortKey.recent:
      stableSort(sorted, (a, b) => b.createdAt - a.createdAt);
  }
  return sorted;
}

/// The whole stats headline in one object. The arithmetic is copied verbatim
/// from the old StatsPage accumulator so no number moves.
StatsSummary summarize(AppData data, int now) {
  final words = data.words;
  final total = words.length;

  final statusCounts = <String, int>{
    for (final s in WordStatus.values) s.wire: 0,
  };
  var reviewSum = 0;
  var correctSum = 0;
  var reviewedWords = 0;
  var intervalSum = 0;
  var scheduled = 0;
  var overdue = 0;
  final todayStart = startOfDay(now);
  final dueToday = words.where((w) => _isDue(w, now)).length;

  for (final w in words) {
    statusCounts[w.status.wire] = statusCounts[w.status.wire]! + 1;
    final srs = w.srs;
    if (srs != null) {
      if (w.status != WordStatus.mastered && srs.dueAt < todayStart) overdue += 1;
      if (srs.reviewCount > 0) {
        reviewedWords += 1;
        reviewSum += srs.reviewCount;
        correctSum += srs.correctCount;
        intervalSum += srs.intervalDays;
        scheduled += 1;
      }
    }
  }

  final mastered = statusCounts[WordStatus.mastered.wire]!;
  final today = reviewsToday(data, now);
  final streak = streakDays(data, now);
  final goal = data.settings.dailyGoal < 1 ? 1 : data.settings.dailyGoal;
  final goalPct = today / goal > 1 ? 1.0 : today / goal;
  final reached = today >= goal;
  final remaining = goal - today > 0 ? goal - today : 0;
  final masteryPct = total > 0 ? jsRound((mastered / total) * 100) : 0;
  final retention = reviewSum > 0 ? jsRound((correctSum / reviewSum) * 100) : null;
  final avgInterval = scheduled > 0 ? intervalSum / scheduled : 0.0;

  return StatsSummary(
    total: total,
    statusCounts: statusCounts,
    mastered: mastered,
    today: today,
    streak: streak,
    goal: goal,
    goalPct: goalPct,
    reached: reached,
    remaining: remaining,
    masteryPct: masteryPct,
    retention: retention,
    avgInterval: avgInterval,
    overdue: overdue,
    dueToday: dueToday,
    reviewSum: reviewSum,
    correctSum: correctSum,
    reviewedWords: reviewedWords,
    scheduled: scheduled,
  );
}
