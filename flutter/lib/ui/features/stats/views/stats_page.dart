/// The insights dashboard.
///
/// Ports `src/pages/stats/StatsPage.tsx`. Every figure, bucket and flag comes
/// from [StatsViewModel]; this file only spells labels and lays out widgets.
/// One `summarize` call inside the view model owns the headline figures — the
/// arithmetic must not be re-derived here or the sidebar, the words header and
/// this page will disagree. Only the two range-dependent series (daily volume
/// and grade mix) are bucketed, and the view model does that too, exactly as
/// the TS did.
///
/// The activity chart is drawn from the port's own primitives: flex columns of
/// bottom-aligned bars, a dashed average rule and a positioned label track.
/// There is no chart package and no Material chart default — a stats page reads
/// as designed only when the figures sit on a real grid.
library;

// `Card` is ours (ui/widgets.dart), not Material's. `Axis` is the chart's tick
// value class (view_models/stats_view_model.dart), not Material's scroll axis.
import 'package:flutter/material.dart' hide Axis, Card;

import '../../../../app/scope.dart';
import '../../../core/context_feedback.dart';
import '../../../core/tokens.dart';
import '../../../../domain/models/srs.dart';
import '../../../../domain/models/types.dart';
import '../../../../domain/use_cases/word_query.dart';
import '../../../core/widgets/controls.dart';
import '../../../core/widgets/entrance.dart';
import '../../../core/widgets/lex_icon.dart';
import '../../../core/widgets/widgets.dart';
import '../view_models/stats_view_model.dart';

/// The three windows the range selector offers, in days.
const List<int> _kRanges = <int>[7, 30, 90];

class StatsPage extends StatefulWidget {
  const StatsPage({super.key, this.controller});

  /// Owned by the shell, so the page scroll position survives a page switch.
  final ScrollController? controller;

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  /// The screen's state and every derivation behind it. The page keeps only the
  /// lifecycle wiring around it.
  late final StatsViewModel _vm;

  @override
  void initState() {
    super.initState();
    _vm = StatsViewModel(
      store: context.store,
      feedback: ContextFeedback(context),
    );
  }

  @override
  void dispose() {
    _vm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _vm,
      builder: (BuildContext context, Widget? _) {
        final vm = _vm;

        final title = context.t('stats.title');
        final subtitle = context.t('stats.subtitle');

        /* The whole-page empty state. A dashboard of zeroes teaches nothing, so
           the page becomes one card that says what to do first. */
        if (vm.isEmpty) {
          return PageShell(
            title: title,
            subtitle: subtitle,
            controller: widget.controller,
            children: [
              Card(
                child: EmptyState(
                  icon: Ic.words,
                  title: context.t('stats.noData'),
                  text: context.t('stats.emptyHint'),
                  action: vm.canNavigate
                      ? LexButton(
                          label: context.t('stats.addWords'),
                          kind: BtnKind.primary,
                          onPressed: vm.goToWords,
                        )
                      : null,
                ),
              ),
            ],
          );
        }

        final summary = vm.summary;
        final total = vm.total;
        final days = vm.days;

        final blocks = <Widget>[
          _TileGrid(tiles: [
            StatTile(
              label: context.t('stats.totalWords'),
              value: '$total',
              sub: context.t('stats.listsCount', {'n': vm.listCount}),
            ),
            StatTile(
              label: context.t('stats.mastered'),
              value: '${summary.mastered}',
              sub: context.t('stats.masteryShare', {'n': summary.masteryPct}),
            ),
            StatTile(
              label: context.t('stats.reviewsToday'),
              value: '${summary.today}',
              sub: summary.reached
                  ? context.t('stats.goalReached')
                  : context.t('stats.remainingToGoal', {'n': summary.remaining}),
              accent: summary.today > 0 ? Palette.of(context).accent : null,
            ),
            StatTile(
              label: context.t('stats.streak'),
              value: '${summary.streak}',
              sub: context.t('stats.streakUnit'),
            ),
          ]),
          _Split(children: [
            _HeadCard(
              title: context.t('stats.dailyGoal'),
              sub: context.t('stats.todayProgress', {'n': summary.today, 'goal': summary.goal}),
              child: _GoalRow(summary: summary),
            ),
            _HeadCard(
              title: context.t('stats.statusDistribution'),
              sub: context.t('stats.wordsInTotal', {'n': total}),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < STATUS_ORDER.length; i++) ...[
                    if (i > 0) const SizedBox(height: Sp.x4),
                    _DistRow(
                      name: context.t('status.${STATUS_ORDER[i].wire}'),
                      count: vm.statusCount(STATUS_ORDER[i]),
                      pct: vm.statusPct(STATUS_ORDER[i]),
                      color: _statusColor(Palette.of(context), STATUS_ORDER[i]),
                    ),
                  ],
                ],
              ),
            ),
          ]),
          _HeadCard(
            title: context.t('stats.reviewsLastDays', {'n': days}),
            sub: vm.hasReviews
                ? context.t('stats.windowTotal', {'total': vm.seriesTotal, 'n': days})
                : null,
            trailing: Segmented<int>(
              value: days,
              options: [
                for (final r in _kRanges)
                  SegOption<int>(value: r, label: context.t('stats.rangeDays', {'n': r})),
              ],
              onChanged: vm.setDays,
            ),
            child: vm.hasReviews
                ? _ActivityChart(
                    series: vm.series,
                    axis: vm.axis,
                    peak: vm.seriesPeak,
                    max: vm.seriesMax,
                    avg: vm.seriesAvg,
                    dense: vm.chartDense,
                    summary: context.t('stats.chartSummary', {
                      'days': days,
                      'total': vm.seriesTotal,
                      'peak': vm.seriesPeak,
                    }),
                    reviewLabel: (n) => context.t('stats.reviewCount', {'n': n}),
                    foot: [
                      (context.t('stats.dailyAvg'), vm.seriesAvg.toStringAsFixed(1)),
                      (context.t('stats.peakDay'), '${vm.seriesPeak}'),
                      (context.t('stats.allReviews'), '${vm.allReviews}'),
                    ],
                  )
                : Padding(
                    padding: const EdgeInsets.only(top: Sp.x4, bottom: Sp.x2),
                    child: EmptyState(
                      icon: Ic.cards,
                      title: context.t('stats.noReviews'),
                      text: context.t('stats.noReviewsHint'),
                      action: vm.canNavigate
                          ? LexButton(
                              label: context.t('stats.startReviewing'),
                              kind: BtnKind.primary,
                              onPressed: vm.goToFlashcards,
                            )
                          : null,
                    ),
                  ),
          ),
          _Split(children: [
            _HeadCard(
              title: context.t('stats.gradeMix'),
              sub: context.t('stats.lastDays', {'n': days}),
              child: vm.gradeTotal > 0
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < _gradeOrder.length; i++) ...[
                          if (i > 0) const SizedBox(height: Sp.x4),
                          _DistRow(
                            name: context.t(_gradeOrder[i].labelKey),
                            count: vm.gradeCount(_gradeOrder[i].grade),
                            pct: vm.gradePct(_gradeOrder[i].grade),
                            color: _gradeColor(Palette.of(context), _gradeOrder[i].grade),
                          ),
                        ],
                      ],
                    )
                  : Padding(
                      padding: const EdgeInsets.only(top: Sp.x4, bottom: Sp.x2),
                      child: EmptyState(
                        icon: Ic.quiz,
                        title: context.t('stats.noGrades'),
                        text: context.t('stats.noGradesHint'),
                      ),
                    ),
            ),
            _HeadCard(
              title: context.t('stats.retention'),
              sub: context.t('stats.retentionSub'),
              child: _Retention(
                summary: summary,
                total: total,
                avgInterval: vm.avgInterval,
              ),
            ),
          ]),
        ];

        return PageShell(
          title: title,
          subtitle: subtitle,
          wide: true,
          controller: widget.controller,
          actions: summary.dueToday > 0 && vm.canNavigate
              ? LexButton(
                  label: context.t('stats.reviewWithCount', {'n': summary.dueToday}),
                  kind: BtnKind.primary,
                  onPressed: vm.goToFlashcards,
                )
              : null,
          children: _stacked(blocks),
        );
      },
    );
  }
}

/// Join [blocks] with the dashboard's vertical rhythm (`.dash` gap).
List<Widget> _stacked(List<Widget> blocks) {
  final out = <Widget>[];
  for (var i = 0; i < blocks.length; i++) {
    if (i > 0) out.add(const SizedBox(height: Sp.x5));
    out.add(blocks[i]);
  }
  return out;
}

/* ------------------------------------------------------------------ */
/* Colour: one progress ramp, no six-hue legend                        */
/* ------------------------------------------------------------------ */

Color _statusColor(Palette p, WordStatus status) => switch (status) {
      WordStatus.new_ => p.ink4,
      WordStatus.reviewing => Color.lerp(p.surface, p.accent, 0.34)!,
      WordStatus.learning => Color.lerp(p.surface, p.accent, 0.64)!,
      WordStatus.mastered => p.accent,
    };

Color _gradeColor(Palette p, Grade grade) => switch (grade) {
      Grade.hard => p.ink3,
      Grade.good => Color.lerp(p.surface, p.accent, 0.55)!,
      Grade.easy => p.accent,
    };

const List<({Grade grade, String labelKey})> _gradeOrder = [
  (grade: Grade.hard, labelKey: 'flashcards.gradeHard'),
  (grade: Grade.good, labelKey: 'flashcards.gradeGood'),
  (grade: Grade.easy, labelKey: 'flashcards.gradeEasy'),
];

/* ------------------------------------------------------------------ */
/* Cards and layout                                                    */
/* ------------------------------------------------------------------ */

/// A card whose head (title, optional sub, optional control) sits above a
/// hairline — `.card` + `.card-head` + `.card-pad` in the web build.
class _HeadCard extends StatelessWidget {
  const _HeadCard({required this.title, this.sub, this.trailing, required this.child});

  final String title;
  final String? sub;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final Widget heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: Fs.md,
            height: Lh.tight,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.005,
            color: p.ink,
          ),
        ),
        if (sub != null) ...[
          const SizedBox(height: 2),
          Text(
            sub!,
            style: TextStyle(fontSize: Fs.sm, height: Lh.snug, color: p.ink3),
          ),
        ],
      ],
    );
    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: R.borderLg,
        border: Border.all(color: p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Sp.x5, Sp.x4, Sp.x5, Sp.x4),
            // A head with no control has no arrangement to decide, so it skips
            // the builder below. That is not just one widget saved: a
            // LayoutBuilder cannot report an intrinsic height, and `_Split`
            // wraps these cards in an `IntrinsicHeight` to give a pair of them
            // one shared height. A builder in that path throws "LayoutBuilder
            // does not support returning intrinsic dimensions" and the whole
            // dashboard fails to lay out.
            child: trailing == null
                ? heading
                // A trailing control sits on the title's line on a wide window
                // and takes the line below it on a phone. Side by side on a
                // 363dp card the window picker is 224dp of the 323dp inside the
                // padding, which left 85dp for a 128dp heading and a 159dp
                // sub-line: "近 30 天复习" broke after "近" and the count broke
                // mid-phrase. Stacking costs one line of height and gives both
                // the width they need.
                : LayoutBuilder(
                    builder: (BuildContext context, BoxConstraints constraints) {
                      if (constraints.maxWidth < 520) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            heading,
                            const SizedBox(height: Sp.x3),
                            trailing!,
                          ],
                        );
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(child: heading),
                          const SizedBox(width: Sp.x3),
                          trailing!,
                        ],
                      );
                    },
                  ),
          ),
          Container(height: 1, color: p.line),
          Padding(padding: const EdgeInsets.all(Sp.x5), child: child),
        ],
      ),
    );
  }
}

/// Two cards side by side on a wide window, stacked below [_kSplitBreakpoint].
///
/// The pair shares one height, which is what makes the two cards read as a row
/// rather than as two unrelated boxes — the taller one sets the height and the
/// shorter one fills it. Getting that requires `IntrinsicHeight`, and that
/// carries a constraint on what may be put inside: **no child of this widget
/// may contain a `LayoutBuilder`**. A builder cannot answer an intrinsic query
/// ("Calculating the intrinsic dimensions would require running the layout
/// callback speculatively"), and the failure is not local — the entire
/// dashboard fails to lay out with an error that names the builder rather than
/// the split. This is why [_HeadCard] only builds a `LayoutBuilder` when it has
/// a `trailing` control to arrange, and why it must stay that way: the cards in
/// here have no trailing control, so the builder is never in the path.
class _Split extends StatelessWidget {
  const _Split({required this.children});

  final List<Widget> children;

  /// The web build's `.dash-split` column breakpoint.
  static const double _kSplitBreakpoint = 980;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < _kSplitBreakpoint) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              children[0],
              const SizedBox(height: Sp.x5),
              children[1],
            ],
          );
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: children[0]),
              const SizedBox(width: Sp.x5),
              Expanded(child: children[1]),
            ],
          ),
        );
      },
    );
  }
}

/// Four headline tiles: one row on a wide window, 2×2 below 860.
/// How many tiles keep a growing entrance delay before it stops increasing.
const int _kStaggerTiles = 4;

class _TileGrid extends StatelessWidget {
  const _TileGrid({required this.tiles});

  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final perRow = constraints.maxWidth >= 860 ? 4 : 2;
        final rows = <Widget>[];
        for (var i = 0; i < tiles.length; i += perRow) {
          if (i > 0) rows.add(const SizedBox(height: Sp.x4));
          final row = tiles.sublist(i, (i + perRow).clamp(0, tiles.length));
          rows.add(
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var j = 0; j < row.length; j++) ...[
                    if (j > 0) const SizedBox(width: Sp.x4),
                    Expanded(
                      // The web's `tile-in` (`9px`, `dur-4`) staggered per tile
                      // by `--stagger`, capped at four so a long grid does not
                      // finish arriving after the user has already read it.
                      //
                      // Safe inside the `IntrinsicHeight` above: [FadeRise] wraps
                      // in `Opacity`/`Transform`, both of which proxy intrinsic
                      // dimensions straight through. A `LayoutBuilder` here would
                      // be the thing that throws.
                      child: FadeRise(
                        offset: 9,
                        duration: Motion.dur4,
                        delay: Motion.stagger * (i + j < _kStaggerTiles ? i + j : _kStaggerTiles),
                        child: row[j],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        );
      },
    );
  }
}

/* ------------------------------------------------------------------ */
/* Daily goal                                                          */
/* ------------------------------------------------------------------ */

class _GoalRow extends StatelessWidget {
  const _GoalRow({required this.summary});

  final StatsSummary summary;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Ring(
          value: summary.goalPct,
          max: 1,
          size: 112,
          stroke: 9,
          children: [
            Text(
              '${summary.today}',
              style: TextStyle(
                fontFamily: Fonts.mono,
                fontSize: Fs.lg,
                height: Lh.title,
                fontWeight: FontWeight.w600,
                color: p.ink,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '/ ${summary.goal}',
              style: TextStyle(
                fontFamily: Fonts.mono,
                fontSize: Fs.xs,
                height: Lh.tight,
                color: p.ink2,
              ),
            ),
          ],
        ),
        const SizedBox(width: Sp.x5),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (summary.reached)
                Text(
                  context.t('stats.goalReached'),
                  style: TextStyle(
                    fontSize: Fs.sm,
                    height: Lh.snug,
                    fontWeight: FontWeight.w500,
                    color: p.accent,
                  ),
                )
              else
                Text(
                  context.t('stats.remainingReviews', {'n': summary.remaining}),
                  style: TextStyle(fontSize: Fs.sm, height: Lh.snug, color: p.ink2),
                ),
              const SizedBox(height: Sp.x2),
              Text(
                '${context.t('stats.dueToday')} · ${summary.dueToday}',
                style: TextStyle(fontFamily: Fonts.mono, fontSize: Fs.sm, height: Lh.snug, color: p.ink2),
              ),
              if (summary.overdue > 0) ...[
                const SizedBox(height: 2),
                Text(
                  context.t('stats.overdueCount', {'n': summary.overdue}),
                  style: TextStyle(fontFamily: Fonts.mono, fontSize: Fs.sm, height: Lh.snug, color: p.warn),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/* ------------------------------------------------------------------ */
/* Distribution rows                                                   */
/* ------------------------------------------------------------------ */

/// `name ——— count · pct%` over a thick progress rule. Used by both the status
/// distribution and the grade mix so the two read as one instrument.
class _DistRow extends StatelessWidget {
  const _DistRow({required this.name, required this.count, required this.pct, required this.color});

  final String name;
  final int count;
  final int pct;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: Fs.sm, height: Lh.snug, fontWeight: FontWeight.w500, color: p.ink2),
              ),
            ),
            const SizedBox(width: Sp.x2),
            Text(
              '$count · $pct%',
              style: TextStyle(fontFamily: Fonts.mono, fontSize: Fs.sm, height: Lh.snug, color: p.ink2),
            ),
          ],
        ),
        const SizedBox(height: Sp.x2),
        ProgressBar(value: pct.toDouble(), max: 100, thick: true, color: color),
      ],
    );
  }
}

/* ------------------------------------------------------------------ */
/* Retention                                                           */
/* ------------------------------------------------------------------ */

class _Retention extends StatelessWidget {
  const _Retention({required this.summary, required this.total, required this.avgInterval});

  final StatsSummary summary;
  final int total;

  /// The average interval, already rounded and formatted by the view model —
  /// `—` when nothing is scheduled.
  final String avgInterval;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final retention = summary.retention;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              retention == null ? '—' : '$retention%',
              style: TextStyle(
                fontFamily: Fonts.mono,
                fontSize: Fs.x2xl,
                height: Lh.display,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.02,
                color: retention == null ? p.ink4 : p.accent,
              ),
            ),
            const SizedBox(width: Sp.x2),
            Expanded(
              child: Text(
                retention == null
                    ? context.t('stats.notEnoughData')
                    : context.t('stats.retentionDetail', {
                        'reviews': summary.reviewSum,
                        'correct': summary.correctSum,
                      }),
                style: TextStyle(fontSize: Fs.xs, height: Lh.body, color: p.ink3),
              ),
            ),
          ],
        ),
        const SizedBox(height: Sp.x3),
        _KvRow(
          first: true,
          label: context.t('stats.overdueWords'),
          value: '${summary.overdue}',
          warn: summary.overdue > 0,
        ),
        _KvRow(
          label: context.t('stats.reviewedWords'),
          value: '${summary.reviewedWords} / $total',
        ),
        _KvRow(label: context.t('stats.dueToday'), value: '${summary.dueToday}'),
        _KvRow(label: context.t('stats.avgInterval'), value: avgInterval),
      ],
    );
  }
}

/// One key/value line of the retention card — the web build's `.kv-row`.
class _KvRow extends StatelessWidget {
  const _KvRow({required this.label, required this.value, this.warn = false, this.first = false});

  final String label;
  final String value;
  final bool warn;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: Sp.x2),
      decoration: BoxDecoration(
        border: first ? null : Border(top: BorderSide(color: p.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: TextStyle(fontSize: Fs.sm, height: Lh.snug, color: p.ink3)),
          ),
          const SizedBox(width: Sp.x4),
          Text(
            value,
            style: TextStyle(
              fontFamily: Fonts.mono,
              fontSize: Fs.sm,
              height: Lh.snug,
              fontWeight: FontWeight.w600,
              color: warn ? p.warn : p.ink,
            ),
          ),
        ],
      ),
    );
  }
}

/* ------------------------------------------------------------------ */
/* Activity chart                                                      */
/* ------------------------------------------------------------------ */

/// Daily review volume: one bar per day, a dashed average rule, the peak figure
/// pinned top-right, and a tick track that thins itself out on long windows.
class _ActivityChart extends StatelessWidget {
  const _ActivityChart({
    required this.series,
    required this.axis,
    required this.peak,
    required this.max,
    required this.avg,
    required this.dense,
    required this.summary,
    required this.reviewLabel,
    required this.foot,
  });

  final List<Bar> series;
  final List<Axis> axis;
  final int peak;
  final int max;
  final double avg;
  final bool dense;

  /// Accessibility sentence for the whole plot (`stats.chartSummary`).
  final String summary;
  final String Function(int count) reviewLabel;
  final List<(String, String)> foot;

  static const double _plotH = 128;
  static const double _axisH = 18;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final gap = dense ? 2.0 : Sp.x1;
    final radius = Radius.circular(dense ? 2 : R.x2xs);
    final avgFrac = max <= 0 ? 0.0 : (avg / max).clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          label: summary,
          child: SizedBox(
            height: _plotH,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final day in series)
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.symmetric(horizontal: gap / 2),
                            child: Tooltip(
                              message: '${day.label} · ${reviewLabel(day.count)}',
                              waitDuration: const Duration(milliseconds: 320),
                              child: Align(
                                alignment: Alignment.bottomCenter,
                                child: FractionallySizedBox(
                                  heightFactor: day.count == 0
                                      ? 0.02
                                      : (day.count / max).clamp(0.06, 1.0),
                                  widthFactor: 1,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: day.count == 0
                                          ? p.lineStrong.withValues(alpha: 0.6)
                                          : p.accent.withValues(alpha: day.isToday ? 1 : 0.8),
                                      borderRadius: BorderRadius.vertical(top: radius),
                                      border: day.isToday && day.count > 0
                                          ? Border.all(color: p.accentSoft)
                                          : null,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                /* The window average, so bar heights have a benchmark. */
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: (_plotH * avgFrac).clamp(0.0, _plotH - 1),
                  child: SizedBox(
                    height: 1,
                    child: CustomPaint(painter: _DashPainter(p.lineStrong)),
                  ),
                ),
                Positioned(
                  top: 0,
                  right: 2,
                  child: Text(
                    '$peak',
                    style: TextStyle(
                      fontFamily: Fonts.mono,
                      fontSize: Fs.xs,
                      height: Lh.none,
                      color: p.ink3,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Container(height: 1, color: p.line),
        SizedBox(
          height: _axisH,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  for (final label in axis)
                    Positioned(
                      top: 0,
                      left: label.edge == 0 ? 0 : (label.pct / 100) * w,
                      child: FractionalTranslation(
                        translation: Offset(label.edge == 0 ? 0 : (label.edge == 1 ? -1 : -0.5), 0),
                        child: Text(
                          label.label,
                          style: TextStyle(
                            fontFamily: Fonts.mono,
                            fontSize: Fs.xs,
                            height: Lh.none,
                            fontWeight: label.isToday ? FontWeight.w600 : FontWeight.w400,
                            color: label.isToday ? p.accent : p.ink3,
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: Sp.x2),
        Wrap(
          spacing: Sp.x5,
          runSpacing: Sp.x2,
          children: [
            for (final entry in foot)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(entry.$1, style: TextStyle(fontSize: Fs.sm, height: Lh.snug, color: p.ink2)),
                  const SizedBox(width: Sp.x2),
                  Text(
                    entry.$2,
                    style: TextStyle(
                      fontFamily: Fonts.mono,
                      fontSize: Fs.sm,
                      height: Lh.snug,
                      fontWeight: FontWeight.w600,
                      color: p.ink2,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

/// A hairline of evenly spaced dashes — the average rule.
class _DashPainter extends CustomPainter {
  const _DashPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const dash = 3.0;
    const stride = 6.0;
    var x = 0.0;
    while (x < size.width) {
      final end = x + dash > size.width ? size.width : x + dash;
      canvas.drawLine(Offset(x, 0.5), Offset(end, 0.5), paint);
      x += stride;
    }
  }

  @override
  bool shouldRepaint(_DashPainter old) => old.color != color;
}
