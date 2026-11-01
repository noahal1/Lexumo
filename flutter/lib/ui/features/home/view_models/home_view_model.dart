// The two private fields below cannot be initializing formals: a named
// parameter may not start with an underscore, which is the whole point of the
// field. Same reason, and the same suppression, as
// `lib/data/repositories/store.dart:3` — every view model in this repo that
// takes a store carries it.
// ignore_for_file: prefer_initializing_formals
/// The home dashboard's state, and every derivation behind it.
///
/// The landing page is a *summary* screen: it answers "what do I do now?" and
/// nothing else. So this view model owns no mutable state of its own — no
/// filter, no selection, no session. Every getter is a projection of one
/// [AppData] snapshot plus one clock reading, which is exactly the shape
/// [StatsViewModel] already has.
///
/// **One clock reading per read.** Two numbers on this page describe the same
/// moment (the ring's "today" count and the sparkline's last bar; the due count
/// and the summary's `dueToday`). Reading the wall clock once per getter would
/// let the page print 19 reviews beside a bar of 20 if the reads straddled
/// midnight, and no amount of testing in the daytime would catch it. So
/// [_derive] reads [_clock] exactly once and every figure below is computed
/// from that single `now`.
///
/// Pure of the widget layer on purpose — it does not import `material` *or*
/// `foundation`, because it never needs either: `ViewModel` brings the
/// `ChangeNotifier` it extends, and every getter here is arithmetic over an
/// `AppData` snapshot. That is what makes the arithmetic unit-testable without
/// pumping a tree. The four things a view model cannot do itself (translate,
/// toast, confirm, navigate) arrive through [Feedback].
library;

import '../../../../data/repositories/store.dart';
import '../../../../domain/models/srs.dart' show DAY_MS;
import '../../../../domain/models/types.dart';
import '../../../../domain/models/utils.dart' show dayKeyOfTs, startOfDay;
import '../../../../domain/use_cases/word_query.dart';
import '../../../core/view_model.dart';

/// One day of the seven-day review sparkline.
///
/// A small immutable value class rather than a record: the view iterates it,
/// and a named type keeps `bar.isToday` readable at the call site.
class HomeBar {
  const HomeBar({
    required this.key,
    required this.label,
    required this.count,
    required this.isToday,
  });

  /// `YYYY-MM-DD` in local time — the bucket this bar counts.
  final String key;

  /// `M/D`, the same tick label the stats chart uses.
  final String label;

  final int count;
  final bool isToday;
}

/// The home screen's state.
class HomeViewModel extends ViewModel {
  HomeViewModel({
    required Store store,
    required Feedback feedback,
    int Function()? clock,
  })  : _store = store,
        _feedback = feedback,
        _clock = clock ?? _systemClock {
    _derive();
    _detach = _store.addListener(refresh);
  }

  static int _systemClock() => DateTime.now().millisecondsSinceEpoch;

  /// Days the sparkline covers. Hardcoded rather than selectable: the home page
  /// is a glance, and the stats page is where you pick a window.
  static const int _kDays = 7;

  final Store _store;
  final Feedback _feedback;
  final int Function() _clock;
  late final void Function() _detach;

  late StatsSummary _summary;
  List<HomeBar> _series = const <HomeBar>[];
  int _seriesMax = 1;
  int _seriesTotal = 0;
  int _dueCount = 0;
  int _hourOfDay = 0;

  List<WordList> _lists = const <WordList>[];
  Map<String, int> _wordsByList = const <String, int>{};
  Map<String, int> _dueByList = const <String, int>{};
  WordList? _focusList;
  int _focusDue = 0;

  /* ---------------------------------------------------------------- */
  /* State the view reads                                             */
  /* ---------------------------------------------------------------- */

  /// The whole headline figure set, from one `summarize` call.
  StatsSummary get summary => _summary;

  /// Share of today's goal already done, 0..1.
  double get goalPct => _summary.goalPct;

  /// Reviews logged since local midnight.
  int get today => _summary.today;

  /// The daily goal, floored at 1 by `summarize`.
  int get goal => _summary.goal;

  /// True once today's goal is met.
  bool get reached => _summary.reached;

  /// Reviews still missing from today's goal; 0 once reached.
  int get remaining => _summary.remaining;

  /// Consecutive days with at least one review.
  int get streak => _summary.streak;

  /// Share of the library marked mastered, 0..100.
  int get masteryPct => _summary.masteryPct;

  /// Percent correct over every review, or null when nothing is computable.
  int? get retention => _summary.retention;

  /// Words in the library.
  int get total => _summary.total;

  /// Words marked mastered.
  int get mastered => _summary.mastered;

  /// Cards due right now.
  int get dueToday => _summary.dueToday;

  /// Cards whose scheduled day has already passed.
  int get overdue => _summary.overdue;

  /// The flashcard queue's length — the same predicate the session will use,
  /// taken off the same clock reading as everything else here.
  int get dueCount => _dueCount;

  /// Local hour (0..23) of the snapshot's `now`, so the view can pick a
  /// greeting without touching the wall clock itself.
  int get hourOfDay => _hourOfDay;

  /// One bar per day of the last seven, oldest first.
  List<HomeBar> get series => _series;

  /// Tallest bar, floored at 1 so a bar height is always a real fraction.
  int get seriesMax => _seriesMax;

  /// Reviews across the seven days.
  int get seriesTotal => _seriesTotal;

  /// True when at least one review has ever been logged. When false the view
  /// shows a hint instead of a row of zero-height bars — an empty chart reads
  /// as a broken chart.
  bool get hasReviews => _store.data.logs.isNotEmpty;

  /// Every declared list, in snapshot order.
  List<WordList> get lists => _lists;

  /// How many lists there are.
  int get listCount => _lists.length;

  /// The list to continue studying: the one with the most due cards, falling
  /// back to the first list so the card is never empty while a list exists.
  WordList? get focusList => _focusList;

  /// Due cards in [focusList]; 0 when there is no list.
  int get focusDue => _focusDue;

  /// True when the library has no words at all — the page's empty state.
  bool get isEmpty => _summary.total == 0;

  /// The complement of [isEmpty]. Both names exist because the view reads one
  /// in each of its two branches, and `!isEmpty` at a call site hides which
  /// branch is the happy path.
  bool get hasData => !isEmpty;

  /// Words filed under [listId]; 0 for an unknown id.
  int listWords(String listId) => _wordsByList[listId] ?? 0;

  /// Cards due in [listId]; 0 for an unknown id.
  int listDue(String listId) => _dueByList[listId] ?? 0;

  /// True when a shell is above this page, i.e. when the intents would work.
  bool get canNavigate => _feedback.canNavigate;

  /* ---------------------------------------------------------------- */
  /* Intents                                                          */
  /* ---------------------------------------------------------------- */

  /// Open the flashcard session. The page never writes: every intent is a
  /// navigation, which is what keeps the dashboard a read-only projection.
  void startReview() => _feedback.goTo('flashcards');

  /// Open the quiz.
  void startQuiz() => _feedback.goTo('quiz');

  /// Open the word library — the empty state's call to action.
  void addWords() => _feedback.goTo('words');

  /// Open the insights dashboard.
  void openStats() => _feedback.goTo('stats');

  /// Open a library.
  ///
  /// The words page has no per-list deep link yet (it owns its own selected
  /// list, and there is no route parameter to seed it with), so this lands on
  /// the library rather than pretending to open one list. Wiring it to a list
  /// id would be a promise the destination cannot keep.
  void openList(String listId) => _feedback.goTo('words');

  /* ---------------------------------------------------------------- */
  /* Derivation                                                       */
  /* ---------------------------------------------------------------- */

  /// Recompute everything from the current snapshot and one clock reading.
  void _derive() {
    final AppData data = _store.data;
    final int now = _clock();
    final int todayStart = startOfDay(now);

    _hourOfDay = DateTime.fromMillisecondsSinceEpoch(now).hour;
    _summary = summarize(data, now);
    _dueCount = dueWords(data, now).length;

    /* Seven-day volume ---------------------------------------------- */
    final Map<String, int> countByDay = <String, int>{};
    for (final log in data.logs) {
      final String key = dayKeyOfTs(log.at);
      countByDay[key] = (countByDay[key] ?? 0) + 1;
    }
    final series = <HomeBar>[];
    var seriesMax = 1;
    var seriesTotal = 0;
    for (var i = 0; i < _kDays; i++) {
      final int ts = todayStart - (_kDays - 1 - i) * DAY_MS;
      final DateTime date = DateTime.fromMillisecondsSinceEpoch(ts);
      final String key = dayKeyOfTs(ts);
      final int count = countByDay[key] ?? 0;
      series.add(HomeBar(
        key: key,
        label: '${date.month}/${date.day}',
        count: count,
        isToday: i == _kDays - 1,
      ));
      if (count > seriesMax) seriesMax = count;
      seriesTotal += count;
    }
    _series = series;
    _seriesMax = seriesMax;
    _seriesTotal = seriesTotal;

    /* Per-list word and due counts, and the "continue" suggestion ----- */
    //
    // One `buildWordIndex` pass rather than a second walk over the words: it is
    // the same bucketing the words page and the stats page read, so the numbers
    // on this card cannot drift from the ones on those screens.
    final WordIndex index = buildWordIndex(data, now);
    final wordsByList = <String, int>{};
    final dueByList = <String, int>{};
    WordList? focus;
    var bestDue = -1;
    for (final WordList list in data.lists) {
      final int words = index.countsByList[list.id]?['all'] ?? 0;
      final int due = index.dueByList[list.id]?.length ?? 0;
      wordsByList[list.id] = words;
      dueByList[list.id] = due;
      // `>` not `>=`, so equal lists keep snapshot order; starting at -1 means
      // a list with nothing due still wins over "no list at all".
      if (due > bestDue) {
        bestDue = due;
        focus = list;
      }
    }
    _lists = data.lists;
    _wordsByList = wordsByList;
    _dueByList = dueByList;
    _focusList = focus;
    _focusDue = bestDue < 0 ? 0 : bestDue;
  }

  /// Re-derive, then repaint.
  ///
  /// The store listener is `refresh` (as the constructor says), so this is
  /// where a snapshot write is turned into fresh figures. Overriding the hook
  /// rather than adding a private listener keeps the subscription in one place;
  /// the alternative — listening to a bare `refresh` — would notify the view
  /// while every getter above still described the previous snapshot.
  @override
  void refresh() {
    if (isDisposed) return;
    _derive();
    super.refresh();
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }
}
