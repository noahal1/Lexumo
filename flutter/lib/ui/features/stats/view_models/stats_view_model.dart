/// The stats screen's state, and every derivation behind it.
///
/// Ports the accumulator that used to sit inline in `StatsPage.build`. One
/// [summarize] call owns every headline figure — the arithmetic must not be
/// re-derived in the view or the sidebar, the words header and this page will
/// disagree. Only the two range-dependent series (daily volume and grade mix)
/// are bucketed here, exactly as the TS did.
///
/// Everything the screen reads is a getter on this class: the selected window,
/// the headline summary, the daily series, its tick track, the grade mix and
/// the two empty-state flags. The view reads them and lays out widgets; it
/// derives nothing and holds no mutable state beyond its `ScrollController`.
///
/// Pure of the widget layer on purpose — `foundation` only, no `material` — so
/// the screen's arithmetic can be unit-tested without pumping a tree. The four
/// things a view model cannot do itself (translate, toast, confirm, navigate)
/// arrive through [Feedback].
library;

import 'package:flutter/foundation.dart';

import '../../../../data/repositories/store.dart';
import '../../../../domain/models/srs.dart';
import '../../../../domain/models/types.dart';
import '../../../../domain/models/utils.dart';
import '../../../../domain/use_cases/word_query.dart';
import '../../../core/view_model.dart';

/// One plotted day.
class Bar {
  const Bar({required this.key, required this.label, required this.count, required this.isToday});

  final String key;
  final String label;
  final int count;
  final bool isToday;
}

/// One tick under the plot. [edge] is 0 on the first day, 1 on the last and 2
/// in between, because an edge label has to be pinned inside the track instead
/// of centred on it.
class Axis {
  const Axis({required this.key, required this.label, required this.isToday, required this.pct, required this.edge});

  final String key;
  final String label;
  final bool isToday;
  final double pct;
  final int edge;
}

/// State and derivation for the insights dashboard.
///
/// Owns the window the range selector picks, the summary it feeds, the two
/// series that depend on it, the tick track under the activity chart and the
/// flags that choose between a card and an empty state. It listens to [Store]
/// itself and is therefore the single [Listenable] the page binds to.
class StatsViewModel extends ViewModel {
  StatsViewModel({
    required this._store,
    required this._feedback,
    int Function()? clock,
  }) : _clock = clock ?? _systemClock {
    _derive();
    _detach = _store.addListener(_onStore);
    refresh();
  }

  static int _systemClock() => DateTime.now().millisecondsSinceEpoch;

  final Store _store;
  final Feedback _feedback;
  final int Function() _clock;
  late final void Function() _detach;

  /// Selected window in days. Lives here because it only drives the two series
  /// below; the headline figures are window-independent.
  int _days = 30;

  late StatsSummary _summary;
  bool _hasReviews = false;
  List<Bar> _series = const <Bar>[];
  List<Axis> _axis = const <Axis>[];
  int _seriesMax = 1;
  int _seriesTotal = 0;
  int _seriesPeak = 0;
  double _seriesAvg = 0;
  Map<Grade, int> _gradeCounts = const <Grade, int>{};
  int _gradeTotal = 0;

  /* ---------------------------------------------------------------- */
  /* State the view reads                                             */
  /* ---------------------------------------------------------------- */

  /// The selected window, in days.
  int get days => _days;

  /// The whole headline figure set for the current snapshot.
  StatsSummary get summary => _summary;

  /// Words in the library — zero means the page is one empty card.
  int get total => _summary.total;

  /// True when there is nothing to chart, i.e. the whole-page empty state.
  bool get isEmpty => _summary.total == 0;

  /// True when at least one review has ever been logged.
  bool get hasReviews => _hasReviews;

  /// Declared lists, for the word-count tile's sub-line.
  int get listCount => _store.data.lists.length;

  /// Every review ever logged, for the chart's foot figure.
  int get allReviews => _store.data.logs.length;

  /// One bar per day of the selected window, oldest first.
  List<Bar> get series => _series;

  /// The ticks under the plot — already thinned out for long windows.
  List<Axis> get axis => _axis;

  /// Tallest bar in the window, floored at 1 so a bar can be sized.
  int get seriesMax => _seriesMax;

  /// Reviews inside the window.
  int get seriesTotal => _seriesTotal;

  /// The busiest day in the window.
  int get seriesPeak => _seriesPeak;

  /// Reviews per day across the window.
  double get seriesAvg => _seriesAvg;

  /// A 90-day window draws thinner bars and a tighter gap.
  bool get chartDense => _days >= 90;

  /// Tallies of the grade mix inside the window.
  Map<Grade, int> get gradeCounts => _gradeCounts;

  /// Reviews inside the window, the denominator of the grade mix.
  int get gradeTotal => _gradeTotal;

  /// The average interval, formatted; `—` when nothing is scheduled.
  String get avgInterval =>
      _summary.scheduled > 0 ? formatInterval(jsRound(_summary.avgInterval)) : '—';

  /// True when a shell is above this page, i.e. when [goToWords] would work.
  bool get canNavigate => _feedback.canNavigate;

  /// Words of [status] in the library.
  int statusCount(WordStatus status) => _summary.statusCounts[status.wire] ?? 0;

  /// Share of the library in [status], rounded like the TS build.
  int statusPct(WordStatus status) {
    final total = _summary.total;
    return total > 0 ? jsRound((statusCount(status) / total) * 100) : 0;
  }

  /// Reviews of [grade] inside the window.
  int gradeCount(Grade grade) => _gradeCounts[grade] ?? 0;

  /// Share of the window's reviews that earned [grade].
  int gradePct(Grade grade) => jsRound((gradeCount(grade) / _gradeTotal) * 100);

  /* ---------------------------------------------------------------- */
  /* Intents                                                          */
  /* ---------------------------------------------------------------- */

  /// Switch the window. Only the two range-dependent series move.
  void setDays(int days) => update(() {
        _days = days;
        _derive();
      });

  /// Open the word library — the empty state's call to action.
  void goToWords() => _feedback.goTo('words');

  /// Start a review session — the empty chart and the page action.
  void goToFlashcards() => _feedback.goTo('flashcards');

  /* ---------------------------------------------------------------- */
  /* Derivation                                                       */
  /* ---------------------------------------------------------------- */

  /// Recompute everything from the current snapshot and the clock.
  ///
  /// One pass, verbatim from the page: the numbers here are the screen's
  /// behaviour, not an implementation detail.
  void _derive() {
    final data = _store.data;
    final now = _clock();
    final days = _days;
    final summary = summarize(data, now);
    final todayStart = startOfDay(now);

    _summary = summary;
    _hasReviews = data.logs.isNotEmpty;

    /* Daily volume -------------------------------------------------- */
    final countByDay = <String, int>{};
    for (final log in data.logs) {
      final key = dayKeyOfTs(log.at);
      countByDay[key] = (countByDay[key] ?? 0) + 1;
    }
    final series = <Bar>[];
    var seriesMax = 1;
    var seriesTotal = 0;
    var seriesPeak = 0;
    for (var i = 0; i < days; i++) {
      final ts = todayStart - (days - 1 - i) * DAY_MS;
      final date = DateTime.fromMillisecondsSinceEpoch(ts);
      final key = dayKeyOfTs(ts);
      final count = countByDay[key] ?? 0;
      series.add(Bar(
        key: key,
        label: '${date.month}/${date.day}',
        count: count,
        isToday: i == days - 1,
      ));
      if (count > seriesMax) seriesMax = count;
      seriesTotal += count;
      if (count > seriesPeak) seriesPeak = count;
    }

    /* Tick placement: a scheduled tick that would land within one step of the
       pinned "today" label is dropped rather than crowded against it. */
    final labelStep = days <= 7 ? 1 : (days <= 30 ? 5 : 15);
    final lastIdx = series.length - 1;
    final labelIdx = <int>[];
    for (var i = 0; i <= lastIdx; i += labelStep) {
      if (lastIdx - i >= labelStep) labelIdx.add(i);
    }
    if (labelIdx.isEmpty || labelIdx.last != lastIdx) labelIdx.add(lastIdx);
    final axis = <Axis>[
      for (final i in labelIdx)
        Axis(
          key: series[i].key,
          label: series[i].label,
          isToday: series[i].isToday,
          pct: lastIdx <= 0 ? 0 : (i / lastIdx) * 100,
          edge: i == 0 ? 0 : (i == lastIdx ? 1 : 2),
        ),
    ];

    /* Grade mix over the selected window ---------------------------- */
    final windowStart = todayStart - (days - 1) * DAY_MS;
    final gradeCounts = <Grade, int>{Grade.hard: 0, Grade.good: 0, Grade.easy: 0};
    var gradeTotal = 0;
    for (final log in data.logs) {
      if (log.at < windowStart) continue;
      gradeCounts[log.grade] = (gradeCounts[log.grade] ?? 0) + 1;
      gradeTotal += 1;
    }

    _series = series;
    _seriesMax = seriesMax;
    _seriesTotal = seriesTotal;
    _seriesPeak = seriesPeak;
    _seriesAvg = seriesTotal / days;
    _axis = axis;
    _gradeCounts = gradeCounts;
    _gradeTotal = gradeTotal;
  }

  /// A snapshot write re-reads everything; the page has no other trigger.
  void _onStore() {
    _derive();
    refresh();
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }
}
