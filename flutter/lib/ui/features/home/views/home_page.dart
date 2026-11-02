/// The home dashboard.
///
/// A *summary* screen: it answers "what do I do now?" and nothing else. Every
/// figure comes from [HomeViewModel]; this file only spells labels and lays out
/// widgets. There is no arithmetic here for the same reason there is none on the
/// stats page — the ring, the headline and the sparkline must not be able to
/// disagree about what "today" means.
///
/// The page performs no writes at all. Every intent is a navigation, so the
/// dashboard stays a read-only projection of the snapshot and there is nothing
/// here that can fail half-way.
library;

// `Card` is ours (ui/core/widgets/widgets.dart), not Material's — Material's
// `Card` brings an elevation and a ripple, both of which this design forbids.
import 'package:flutter/material.dart' hide Card;

import '../../../../app/scope.dart';
import '../../../../domain/models/quiz.dart' show QUIZ_CHOICES;
import '../../../../domain/models/types.dart' show WordList;
import '../../../core/context_feedback.dart';
import '../../../core/tokens.dart';
import '../../../core/widgets/controls.dart';
import '../../../core/widgets/entrance.dart';
import '../../../core/widgets/lex_icon.dart';
import '../../../core/widgets/widgets.dart';
import '../view_models/home_view_model.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.controller});

  /// Owned by the shell, so the page scroll position survives a page switch.
  final ScrollController? controller;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// The screen's state and every derivation behind it. The page keeps only the
  /// lifecycle wiring around it.
  late final HomeViewModel _vm;

  @override
  void initState() {
    super.initState();
    // `context.store` reads the scope without registering a dependency, which is
    // what makes it legal here; the widget itself never needs to rebuild from a
    // snapshot change, because the view model listens to the store and this
    // page rebuilds from the view model.
    _vm = HomeViewModel(
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
        final String title = context.t('home.title');
        final String subtitle = context.t('home.subtitle');

        /* A dashboard of zeroes teaches nothing, so an empty library becomes one
           card that says what to do first — the same shape the stats page uses
           for the same situation. */
        if (vm.isEmpty) {
          return PageShell(
            title: title,
            subtitle: subtitle,
            controller: widget.controller,
            children: <Widget>[
              EmptyState(
                icon: Ic.words,
                title: context.t('home.emptyTitle'),
                text: context.t('home.emptyHint'),
                action: vm.canNavigate
                    ? LexButton(
                        label: context.t('home.addWords'),
                        kind: BtnKind.primary,
                        onPressed: vm.addWords,
                      )
                    : null,
              ),
            ],
          );
        }

        return PageShell(
          title: title,
          subtitle: subtitle,
          controller: widget.controller,
          // The dashboard is a stack of lists, not a stack of boxes: every band
          // below runs edge to edge with hairlines between its rows, and the
          // accent rule marks the two lists that are actually lists of things.
          bleed: true,
          children: _stacked(<Widget>[
            _gutter(_Hero(vm: vm)),
            _ListBlock(
              title: context.t('home.todayTitle'),
              children: _todayRows(context, vm),
            ),
            if (vm.focusList != null && vm.focusDue > 0)
              _ListBlock(
                title: context.t('home.focusTitle'),
                rule: false,
                children: <Widget>[_Focus(vm: vm)],
              ),
            _ListBlock(
              title: context.t('home.weekTitle'),
              rule: false,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (vm.hasReviews)
                    Text(
                      context.t('home.weekTotal', {'n': vm.seriesTotal}),
                      style: TextStyle(
                        fontFamily: Fonts.mono,
                        fontSize: Fs.xs,
                        height: Lh.tight,
                        color: Palette.of(context).ink4,
                      ),
                    ),
                  if (vm.canNavigate) ...<Widget>[
                    const SizedBox(width: Sp.x3),
                    LexButton(
                      label: context.t('home.openStats'),
                      kind: BtnKind.ghost,
                      size: BtnSize.sm,
                      onPressed: vm.openStats,
                    ),
                  ],
                ],
              ),
              children: <Widget>[_WeekCard(vm: vm)],
            ),
            if (vm.listCount > 0)
              _ListBlock(
                title: context.t('home.listsTitle'),
                children: _libraryRows(context, vm),
              ),
          ]),
        );
      },
    );
  }
}

/// Join [blocks] with the dashboard's vertical rhythm, and stagger them in.
///
/// The dashboard is the one screen that arrives as a sequence: the greeting
/// first, then the figures, then the way out of the page. The delay is capped at
/// [_staggeredBlocks] so the last block never lags far enough behind the first to
/// feel broken, and it is a single controller per block rather than a timer, so
/// `pumpAndSettle` still returns.
List<Widget> _stacked(List<Widget> blocks) {
  final out = <Widget>[];
  for (var i = 0; i < blocks.length; i++) {
    if (i > 0) out.add(const SizedBox(height: Sp.x2));
    out.add(
      FadeRise(
        offset: 8,
        delay: Motion.stagger * (i < _staggeredBlocks ? i : _staggeredBlocks),
        child: blocks[i],
      ),
    );
  }
  return out;
}

/// The page's own horizontal gutter.
///
/// The shell is [PageShell.bleed] here so the hairline lists can reach the window
/// edge; everything that is not a list has to re-add the gutter by hand, and it
/// has to be the same [Sp.x6] the lists use or the headings stop aligning with
/// the content under them.
Widget _gutter(Widget child) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x6),
      child: child,
    );

/// How many blocks keep staggering before the delay stops growing.
///
/// Four is the web build's cap for dashboard tiles (`nth-child(1)…(4)`), and it
/// is also where the eye stops attributing the movement to the content: past
/// this the entrance reads as the page being slow.
const int _staggeredBlocks = 4;

/* ------------------------------------------------------------------ */
/* Named sections                                                      */
/* ------------------------------------------------------------------ */

/// A named block: a small heading, then a hairline list of rows.
///
/// The dashboard used to lay five unnamed bands on top of each other, and the
/// only thing separating one idea from the next was the border of whichever card
/// happened to be there — which is why the page read as a stack of boxes rather
/// than as a set of answers. A block that says its own name can be found without
/// being read.
///
/// The rows are separated by hairlines rather than enclosed in a box, so the
/// block reads as a run of items on the page. [rule] adds the vertical accent
/// down the left for the blocks that really are lists of things.
class _ListBlock extends StatelessWidget {
  const _ListBlock({
    required this.title,
    required this.children,
    this.trailing,
    this.rule = true,
  });

  final String title;
  final List<Widget> children;
  final Widget? trailing;

  /// Paint the accent rule down the left edge of the list.
  final bool rule;

  @override
  Widget build(BuildContext context) {
    // HairlineList owns the horizontal gutter, so the heading sits in the same
    // [Sp.x6] and lines up with the list's own left edge. The rule then runs
    // inside that gutter, which is what puts it in the page margin.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SectionTitle(label: title, trailing: trailing),
        HairlineList(rule: rule, children: children),
      ],
    );
  }
}

/* ------------------------------------------------------------------ */
/* Hero                                                                */
/* ------------------------------------------------------------------ */

/// Who you are, what time it is, what is left — and, on a wide window, the way
/// out of the page.
///
/// It carries no card. A card is a grouping of *things*, and a greeting is the
/// page speaking rather than a container of content; putting it in a box made it
/// read as a widget among widgets instead of as the answer to "what now?".
///
/// The two action buttons used to be a band of their own: two 551dp-wide
/// controls under the cards, which is not a button, it is a stripe. Beside the
/// headline they get a sane width, the page saves ~90dp of vertical space (which
/// is exactly the height that was pushing 「我的词库」 under the fold), and the
/// answer sits next to the question.
class _Hero extends StatelessWidget {
  const _Hero({required this.vm});

  final HomeViewModel vm;

  /// Below this the actions drop under the headline instead of beside it: the
  /// headline needs ~460dp to stay on one line and the pair needs ~280dp.
  static const double _kSideBySide = 820;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final String greeting = switch (vm.hourOfDay) {
      < 12 => context.t('home.greetingMorning'),
      < 18 => context.t('home.greetingAfternoon'),
      _ => context.t('home.greetingEvening'),
    };
    final String headline = vm.dueCount > 0
        ? context.t('home.dueHeadline', {'n': vm.dueCount})
        : context.t('home.dueClear');

    final Widget text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          greeting,
          style: TextStyle(
            fontSize: Fs.sm,
            height: Lh.snug,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.02,
            color: p.ink3,
          ),
        ),
        const SizedBox(height: Sp.x1),
        ConstrainedBox(
          // The headline is one sentence; past ~620dp it stops being a
          // sentence and starts being a paragraph of display type.
          constraints: const BoxConstraints(maxWidth: 620),
          child: Text(
            headline,
            style: TextStyle(
              fontFamily: Fonts.display,
              // The page header is chrome at Fs.lg; the dashboard's own
              // statement has to sit clearly above it or the two compete. This
              // is the one place the display face is allowed to be large.
              fontSize: Fs.x2xl,
              height: Lh.tight,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.015,
              color: p.ink,
            ),
          ),
        ),
        const SizedBox(height: Sp.x3),
        // A `Wrap` rather than a `Row`: at a 2.0 text scale the streak pill can
        // outgrow the line, and a second run is the graceful answer where a
        // `Row` would paint the overflow stripe.
        Wrap(
          spacing: Sp.x2,
          runSpacing: Sp.x2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            _Pill(
              icon: Ic.flame,
              value: '${vm.streak}',
              unit: context.t('home.streakUnit'),
            ),
            if (vm.overdue > 0)
              Text(
                context.t('stats.overdueCount', {'n': vm.overdue}),
                style: TextStyle(
                  fontFamily: Fonts.mono,
                  fontSize: Fs.xs,
                  height: Lh.snug,
                  color: p.warn,
                ),
              ),
          ],
        ),
      ],
    );

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth < _kSideBySide) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              text,
              const SizedBox(height: Sp.x4),
              _Actions(vm: vm),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Expanded(child: text),
            const SizedBox(width: Sp.x6),
            _Actions(vm: vm, compact: true),
          ],
        );
      },
    );
  }
}

/// A small tinted pill: icon, figure, unit. Used for the streak.
class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.value, required this.unit});

  final String icon;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x2, vertical: Sp.x1),
      decoration: BoxDecoration(
        color: p.accentSoft,
        borderRadius: R.borderSm,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          LexIcon(icon, size: 14, color: p.accentInk),
          const SizedBox(width: Sp.x1),
          Text(
            value,
            style: TextStyle(
              fontFamily: Fonts.mono,
              fontSize: Fs.sm,
              height: Lh.tight,
              fontWeight: FontWeight.w600,
              color: p.accentInk,
            ),
          ),
          const SizedBox(width: Sp.x1),
          Text(
            unit,
            style: TextStyle(fontSize: Fs.xs, height: Lh.tight, color: p.accentInk),
          ),
        ],
      ),
    );
  }
}

/* ------------------------------------------------------------------ */
/* Today: the goal, then the two headline figures                       */
/* ------------------------------------------------------------------ */

/// The three things "today" means, as rows of one hairline list.
///
/// The old arrangement was a centred ring in a card twice the width of its two
/// neighbours, with `IntrinsicHeight` stretching all three to the ring's height
/// — so the two figures were half empty and the ring floated in 75% dead width.
/// A row per fact needs no other row to agree with it: each is as tall as its
/// own content, and they align because they share a left edge, not a height.
List<Widget> _todayRows(BuildContext context, HomeViewModel vm) {
  final p = Palette.of(context);
  final bool done = vm.reached;
  return <Widget>[
    // The goal first: it is the answer to "what now", and it is the only row
    // with a proportion you can read without doing arithmetic.
    HairlineRow(
      child: Row(
        children: <Widget>[
          Ring(
            value: vm.goalPct,
            max: 1,
            size: 56,
            stroke: 6,
            children: <Widget>[
              Text(
                '${vm.today}',
                style: TextStyle(
                  fontFamily: Fonts.mono,
                  fontSize: Fs.md,
                  height: Lh.title,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                  color: p.ink,
                ),
              ),
            ],
          ),
          const SizedBox(width: Sp.x4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  context.t('home.todayGoal'),
                  style: TextStyle(
                    fontSize: Fs.xs,
                    height: Lh.tight,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.02,
                    color: p.ink3,
                  ),
                ),
                const SizedBox(height: Sp.x1),
                Text(
                  done
                      ? context.t('home.goalDone')
                      : context.t('home.goalRemaining', {'n': vm.remaining}),
                  style: TextStyle(
                    fontSize: Fs.md,
                    height: Lh.snug,
                    fontWeight: FontWeight.w500,
                    // The accent marks the one thing that is *good news* on
                    // this page. A missed goal is stated in ordinary ink rather
                    // than in a warning colour: it is not an error, Tuesday.
                    color: done ? p.accent : p.ink,
                  ),
                ),
              ],
            ),
          ),
          Text(
            '/ ${vm.goal}',
            style: TextStyle(
              fontFamily: Fonts.mono,
              fontSize: Fs.xs,
              height: Lh.tight,
              color: p.ink3,
            ),
          ),
        ],
      ),
    ),
    HairlineRow(
      child: _FigureRow(
        icon: Ic.flame,
        label: context.t('stats.streak'),
        value: '${vm.streak}',
        sub: context.t('home.streakUnit'),
        accent: vm.streak > 0 ? p.accent : null,
      ),
    ),
    HairlineRow(
      last: true,
      child: _FigureRow(
        icon: Ic.target,
        label: context.t('stats.mastered'),
        value: '${vm.masteryPct}%',
        sub: context.t('stats.masteryShare', {'n': vm.masteryPct}),
      ),
    ),
  ];
}

/// One figure as a list row: label and sub-line on the left, the number on the
/// right at display size.
///
/// The figure is the reason the row exists, so it takes the serif at the size a
/// heading would use; the label is the caption that tells you what it counts.
class _FigureRow extends StatelessWidget {
  const _FigureRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.sub,
    this.accent,
  });

  final String icon;
  final String label;
  final String value;
  final String sub;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Row(
      children: <Widget>[
        LexIcon(icon, size: 16, color: p.ink4),
        const SizedBox(width: Sp.x3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                label,
                style: TextStyle(
                  fontSize: Fs.sm,
                  height: Lh.tight,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.02,
                  color: p.ink2,
                ),
              ),
              const SizedBox(height: Sp.x1),
              Text(
                sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: Fs.xs,
                  height: Lh.snug,
                  color: p.ink3,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: Sp.x3),
        Text(
          value,
          style: TextStyle(
            fontFamily: Fonts.display,
            fontSize: Fs.xl,
            height: Lh.tight,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.01,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            color: accent ?? p.ink,
          ),
        ),
      ],
    );
  }
}

/* ------------------------------------------------------------------ */
/* Primary actions                                                     */
/* ------------------------------------------------------------------ */

/// Review and quiz, side by side wide and stacked on a phone.
/// The two things a learner came here to do.
///
/// Sits beside the headline when there is room and under it when there is not.
/// In the beside-form it takes a fixed column width instead of filling the row:
/// `block: true` would stretch each button to whatever the page happens to be,
/// and two 900dp-wide buttons on a desktop are not controls, they are banners.
class _Actions extends StatelessWidget {
  const _Actions({required this.vm, this.compact = false});

  final HomeViewModel vm;

  /// True when the pair sits to the right of the headline rather than below it.
  final bool compact;

  /// Below this the two buttons stack. Side by side each would get under 180dp,
  /// and `LexButton` clips its label rather than wrapping it — a truncated
  /// "开始复…" is worse than a second row.
  static const double _kBreakpoint = 480;

  /// Width of the beside-form. Enough for 「开始复习 · 12」 at `BtnSize.lg` with
  /// its icon, and it keeps the pair from swallowing the headline.
  static const double _kCompactWidth = 260;

  @override
  Widget build(BuildContext context) {
    // The quiz needs a full set of choices to build a round at all, so the
    // button is disabled below that rather than starting a session that
    // immediately reports a shortfall. `QUIZ_CHOICES` is the source of truth,
    // not a 4 typed here.
    final bool quizReady = vm.total >= QUIZ_CHOICES;
    final bool reviewReady = vm.dueCount > 0 && vm.canNavigate;

    final Widget review = LexButton(
      label: vm.dueCount > 0
          ? '${context.t('home.startReview')} · ${vm.dueCount}'
          : context.t('home.startReview'),
      // The one filled button on the screen. The fill *is* the signal — a second
      // primary would make neither of them primary.
      kind: BtnKind.primary,
      size: BtnSize.lg,
      icon: Ic.play,
      block: true,
      onPressed: reviewReady ? vm.startReview : null,
    );
    final Widget quiz = LexButton(
      label: context.t('home.startQuiz'),
      kind: BtnKind.normal,
      size: BtnSize.lg,
      icon: Ic.quiz,
      block: true,
      onPressed: quizReady && vm.canNavigate ? vm.startQuiz : null,
    );

    final Widget hint = quizReady
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(top: Sp.x2),
            child: Text(
              context.t('home.quizNeedsMore', {'n': QUIZ_CHOICES}),
              style: TextStyle(
                fontSize: Fs.xs,
                height: Lh.snug,
                color: Palette.of(context).ink3,
              ),
            ),
          );

    if (compact) {
      return SizedBox(
        width: _kCompactWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[review, const SizedBox(height: Sp.x2), quiz, hint],
        ),
      );
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth < _kBreakpoint) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              review,
              const SizedBox(height: Sp.x3),
              quiz,
              hint,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(child: review),
                const SizedBox(width: Sp.x3),
                Expanded(child: quiz),
              ],
            ),
            hint,
          ],
        );
      },
    );
  }
}

/* ------------------------------------------------------------------ */
/* Continue studying                                                   */
/* ------------------------------------------------------------------ */

/// The list with the most cards waiting, as one tappable row.
class _Focus extends StatelessWidget {
  const _Focus({required this.vm});

  final HomeViewModel vm;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final WordList list = vm.focusList!;
    return HairlineRow(
      last: true,
      onTap: () => vm.openList(list.id),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            '${vm.focusDue}',
            style: TextStyle(
              fontFamily: Fonts.display,
              fontSize: Fs.lg,
              height: Lh.title,
              fontWeight: FontWeight.w600,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              color: p.accent,
            ),
          ),
          const SizedBox(width: Sp.x2),
          LexIcon(Ic.chevronRight, size: 16, color: p.ink4),
        ],
      ),
      // The caption that used to sit here said 「接着上次的」, which is exactly
      // what the section heading above the list now says — the same sentence
      // twice, 70dp apart. The heading names the block, so the row names the
      // thing itself: the list, at the size its own name deserves.
      child: Text(
        list.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: Fonts.display,
          fontSize: Fs.lg,
          height: Lh.tight,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.005,
          color: p.ink,
        ),
      ),
    );
  }
}

/* ------------------------------------------------------------------ */
/* Seven-day sparkline                                                 */
/* ------------------------------------------------------------------ */

/// The week's review rhythm: seven bars, the ends labelled, nothing else.
///
/// Drawn from flex columns of bottom-aligned boxes — the same primitive the
/// stats chart uses. There is no chart package in this project and a sparkline
/// does not justify the first one.
class _WeekCard extends StatelessWidget {
  const _WeekCard({required this.vm});

  final HomeViewModel vm;

  /// Plot height. The strip carries a count over every bar, so it needs room for
  /// a label as well as a bar: 52dp of plot under a 20dp label row. It is still
  /// short on purpose — this is a rhythm strip, not a chart, and the stats page
  /// is one tap away for the real thing.
  static const double _plotH = Sp.x16 + Sp.x2;

  @override
  Widget build(BuildContext context) {
    // The title, the running total and the way out to the stats page all live in
    // the block heading above this row now, so the row holds only the plot.
    // Before, the same three facts were printed inside a card while the card had
    // no name at all — the heading repeated what the card said.
    return HairlineRow(
      last: true,
      // The plot needs the full width, so it skips the row's text column and
      // sits in `child` with no trailing widget.
      padding: const EdgeInsets.symmetric(
        vertical: Sp.x4,
        horizontal: Sp.x4,
      ),
      child: vm.hasReviews
          ? _Spark(series: vm.series, max: vm.seriesMax)
          : _NoReviews(vm: vm),
    );
  }
}

/// The bars themselves plus the two end labels.
class _Spark extends StatelessWidget {
  const _Spark({required this.series, required this.max});

  final List<HomeBar> series;
  final int max;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final List<HomeBar> bars = series;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          height: _WeekCard._plotH,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final HomeBar bar in bars)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Sp.x1 / 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        // The count sits on its own bar. A bar chart with no
                        // numbers on it can only be compared with itself, which
                        // is why the old strip read as decoration: five of the
                        // seven days were a stub and nothing said whether that
                        // meant zero or just a short day.
                        Text(
                          '${bar.count}',
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          style: TextStyle(
                            fontFamily: Fonts.mono,
                            fontSize: Fs.xs - 1,
                            height: Lh.none,
                            fontWeight:
                                bar.isToday ? FontWeight.w600 : FontWeight.w400,
                            color: bar.count == 0
                                ? p.ink4
                                : bar.isToday
                                    ? p.accent
                                    : p.ink2,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Expanded(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: FractionallySizedBox(
                              widthFactor: 1,
                              // A zero day still draws a stub, so the strip reads
                              // as a track with a quiet day in it rather than as a
                              // gap in the layout.
                              heightFactor: bar.count == 0
                                  ? 0.06
                                  : (bar.count / max).clamp(0.10, 1.0),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: bar.count == 0
                                      ? p.surfaceSunken
                                      : bar.isToday
                                          ? p.accent
                                          : p.accentSoft,
                                  borderRadius: BorderRadius.vertical(
                                    top: Radius.circular(R.xs),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: Sp.x2),
        Container(height: 1, color: p.line),
        const SizedBox(height: Sp.x2),
        // Ends only. Seven labels at 320dp is ~33dp each; `3/15` is 24dp of
        // monospace, so the middle five would be unreadable even when they fit.
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                bars.first.label,
                style: TextStyle(
                  fontFamily: Fonts.mono,
                  fontSize: Fs.xs,
                  height: Lh.none,
                  color: p.ink3,
                ),
              ),
            ),
            Expanded(
              child: Text(
                bars.last.label,
                textAlign: TextAlign.end,
                style: TextStyle(
                  fontFamily: Fonts.mono,
                  fontSize: Fs.xs,
                  height: Lh.none,
                  fontWeight: FontWeight.w600,
                  color: p.accent,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// What the plot becomes before the first review: a sentence, not seven
/// zero-height bars. An empty chart is indistinguishable from a broken one.
class _NoReviews extends StatelessWidget {
  const _NoReviews({required this.vm});

  final HomeViewModel vm;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          context.t('home.noReviews'),
          style: TextStyle(
            fontSize: Fs.sm,
            height: Lh.snug,
            fontWeight: FontWeight.w500,
            color: p.ink2,
          ),
        ),
        const SizedBox(height: Sp.x1),
        Text(
          context.t('home.noReviewsHint'),
          style: TextStyle(fontSize: Fs.xs, height: Lh.body, color: p.ink3),
        ),
      ],
    );
  }
}

/* ------------------------------------------------------------------ */
/* Libraries                                                           */
/* ------------------------------------------------------------------ */

/// Up to four libraries, one hairline row each.
///
/// The strip used to be four cards on a wide window and a stack of rows inside
/// one card on a phone — two different objects for the same four facts. A row
/// is right at both widths, so there is one arrangement now.
List<Widget> _libraryRows(BuildContext context, HomeViewModel vm) {
  final List<WordList> shown = vm.lists.take(_kShownLibraries).toList();
  return <Widget>[
    for (var i = 0; i < shown.length; i++)
      _ListRow(
        list: shown[i],
        words: vm.listWords(shown[i].id),
        due: vm.listDue(shown[i].id),
        last: i == shown.length - 1,
        onTap: () => vm.openList(shown[i].id),
      ),
  ];
}

/// How many lists the strip shows before it stops being a summary.
const int _kShownLibraries = 4;

/// One library: name and size on the left, how much of it is waiting on the
/// right.
class _ListRow extends StatelessWidget {
  const _ListRow({
    required this.list,
    required this.words,
    required this.due,
    required this.last,
    required this.onTap,
  });

  final WordList list;
  final int words;
  final int due;
  final bool last;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return HairlineRow(
      last: last,
      onTap: onTap,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            context.t('home.listMeta', {'words': words, 'due': due}),
            style: TextStyle(
              fontFamily: Fonts.mono,
              fontSize: Fs.xs,
              height: Lh.snug,
              color: due > 0 ? p.accent : p.ink3,
            ),
          ),
          const SizedBox(width: Sp.x2),
          LexIcon(Ic.chevronRight, size: 16, color: p.ink4),
        ],
      ),
      child: Text(
        list.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: Fs.md,
          height: Lh.snug,
          fontWeight: FontWeight.w500,
          color: p.ink,
        ),
      ),
    );
  }
}
