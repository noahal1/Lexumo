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
              Card(
                child: EmptyState(
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
              ),
            ],
          );
        }

        return PageShell(
          title: title,
          subtitle: subtitle,
          controller: widget.controller,
          children: _stacked(<Widget>[
            _Hero(vm: vm),
            _Section(
              title: context.t('home.todayTitle'),
              child: _Today(vm: vm),
            ),
            if (vm.focusList != null && vm.focusDue > 0)
              _Section(
                title: context.t('home.focusTitle'),
                child: _Focus(vm: vm),
              ),
            _Section(
              title: context.t('home.weekTitle'),
              note: vm.hasReviews
                  ? context.t('home.weekTotal', {'n': vm.seriesTotal})
                  : null,
              action: vm.canNavigate
                  ? LexButton(
                      label: context.t('home.openStats'),
                      kind: BtnKind.ghost,
                      size: BtnSize.sm,
                      onPressed: vm.openStats,
                    )
                  : null,
              child: _WeekCard(vm: vm),
            ),
            if (vm.listCount > 0)
              _Section(
                title: context.t('home.listsTitle'),
                child: _Libraries(vm: vm),
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
    if (i > 0) out.add(const SizedBox(height: Sp.x5));
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

/// How many blocks keep staggering before the delay stops growing.
///
/// Four is the web build's cap for dashboard tiles (`nth-child(1)…(4)`), and it
/// is also where the eye stops attributing the movement to the content: past
/// this the entrance reads as the page being slow.
const int _staggeredBlocks = 4;

/* ------------------------------------------------------------------ */
/* Named sections                                                      */
/* ------------------------------------------------------------------ */

/// A named block: the heading, then the thing it names.
///
/// The dashboard used to lay five unnamed bands on top of each other, and the
/// only thing separating one idea from the next was the border of whichever card
/// happened to be there — which is why the page read as a stack of boxes rather
/// than as a set of answers. A block that says its own name can be found without
/// being read.
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.child,
    this.note,
    this.action,
  });

  final String title;
  final String? note;
  final Widget? action;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SectionHeading(title: title, note: note, action: action),
        const SizedBox(height: Sp.x3),
        child,
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

/// The goal and the two figures it sits beside.
///
/// The old arrangement put a centred 120dp ring in a card twice the width of its
/// two neighbours and then used `IntrinsicHeight` to make all three the same
/// height — so the two `StatTile`s were stretched to the ring's height and left
/// ~50% of themselves empty, while the ring floated in 75% dead width. The ring
/// is now 84dp and sits *beside* its numbers rather than above them, which makes
/// the three cards naturally similar in height, so nothing has to be stretched
/// and nothing is left blank.
class _Today extends StatelessWidget {
  const _Today({required this.vm});

  final HomeViewModel vm;

  /// Below this the ring card takes the full width and the two figures share the
  /// line under it; above, all three share one line at 2:1:1.
  static const double _kBreakpoint = 640;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final Widget goal = _GoalCard(vm: vm);
    final Widget figures = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: StatTile(
            label: context.t('stats.streak'),
            value: '${vm.streak}',
            sub: context.t('home.streakUnit'),
            icon: Ic.flame,
            accent: vm.streak > 0 ? p.accent : null,
          ),
        ),
        const SizedBox(width: Sp.x4),
        Expanded(
          child: StatTile(
            label: context.t('stats.mastered'),
            value: '${vm.masteryPct}%',
            sub: context.t('stats.masteryShare', {'n': vm.masteryPct}),
            icon: Ic.target,
          ),
        ),
      ],
    );

    // `LayoutBuilder` is safe here because nothing above asks this subtree for
    // an intrinsic size: it is a direct child of the page column. The reverse —
    // a `LayoutBuilder` *inside* an `IntrinsicHeight` — throws, which is why the
    // cards below are built without one.
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth < _kBreakpoint) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[goal, const SizedBox(height: Sp.x4), figures],
          );
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(flex: 2, child: goal),
              const SizedBox(width: Sp.x4),
              Expanded(flex: 3, child: figures),
            ],
          ),
        );
      },
    );
  }
}

/// The daily-goal card: a ring, the count, and one sentence.
///
/// Laid out horizontally — ring on the left, numbers on the right — because the
/// figure and its explanation belong on one line, and because a card that is
/// wide should use its width rather than centre a circle in it. The ring keeps
/// its job (a proportion you can read without doing arithmetic) at a size that
/// leaves room for the words that say what the proportion means.
class _GoalCard extends StatelessWidget {
  const _GoalCard({required this.vm});

  final HomeViewModel vm;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final bool done = vm.reached;
    return Card(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Ring(
            value: vm.goalPct,
            max: 1,
            size: 84,
            stroke: 8,
            children: <Widget>[
              Text(
                '${vm.today}',
                style: TextStyle(
                  fontFamily: Fonts.mono,
                  fontSize: Fs.lg,
                  height: Lh.title,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                  color: p.ink,
                ),
              ),
              const SizedBox(height: 2),
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
                const SizedBox(height: Sp.x1 + 2),
                Text(
                  done
                      ? context.t('home.goalDone')
                      : context.t('home.goalRemaining', {'n': vm.remaining}),
                  style: TextStyle(
                    fontSize: Fs.md,
                    height: Lh.snug,
                    fontWeight: FontWeight.w500,
                    // The accent marks the one thing that is *good news* on this
                    // page. A missed goal is stated in ordinary ink rather than
                    // in a warning colour: it is not an error, it is a Tuesday.
                    color: done ? p.accent : p.ink,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
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
    return _TapRow(
      onTap: () => vm.openList(list.id),
      child: Row(
        children: <Widget>[
          Expanded(
            // The caption that used to sit here said 「接着上次的」, which is
            // exactly what the section heading above the card now says — the
            // same sentence twice, 70dp apart, once as a heading and once as a
            // label. The heading names the block, so the card names the thing
            // itself: the list, at the size a row's own name deserves.
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
          ),
          const SizedBox(width: Sp.x3),
          Text(
            '${vm.focusDue}',
            style: TextStyle(
              fontFamily: Fonts.mono,
              fontSize: Fs.lg,
              height: Lh.title,
              fontWeight: FontWeight.w600,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              color: p.accent,
            ),
          ),
        ],
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
    // the section heading above this card now, so the card holds only the plot.
    // Before, the same three facts were printed inside the card while the card
    // had no name at all — the heading repeated what the card said.
    return Card(
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

/// Up to four libraries: a column of rows on a phone, a row of cards wide.
class _Libraries extends StatelessWidget {
  const _Libraries({required this.vm});

  final HomeViewModel vm;

  /// How many lists the strip shows before it stops being a summary.
  static const int _kShown = 4;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final List<WordList> shown = vm.lists.take(_kShown).toList();

    // The heading above supplies the name of this block, so the strip is nothing
    // but the lists themselves.
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // The shell's own breakpoint, so the strip changes shape at the same
        // width the chrome does rather than at a number invented here.
        if (constraints.maxWidth < Layout.mobileBreakpoint) {
          return Card(
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (var i = 0; i < shown.length; i++) ...<Widget>[
                  if (i > 0) Container(height: 1, color: p.line),
                  _ListRow(
                    list: shown[i],
                    words: vm.listWords(shown[i].id),
                    due: vm.listDue(shown[i].id),
                    onTap: () => vm.openList(shown[i].id),
                  ),
                ],
              ],
            ),
          );
        }
        // One shared height so four cards read as one row of cards rather than
        // four boxes that happen to be beside each other. `Intrinsic` is fine
        // here: no descendant of these cards builds a `LayoutBuilder`, which is
        // the one thing it cannot measure.
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (var i = 0; i < shown.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(width: Sp.x3),
                Expanded(
                  child: Card(
                    padding: EdgeInsets.zero,
                    child: _ListRow(
                      list: shown[i],
                      words: vm.listWords(shown[i].id),
                      due: vm.listDue(shown[i].id),
                      onTap: () => vm.openList(shown[i].id),
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// One library: name, how big it is, how much of it is waiting.
class _ListRow extends StatefulWidget {
  const _ListRow({
    required this.list,
    required this.words,
    required this.due,
    required this.onTap,
  });

  final WordList list;
  final int words;
  final int due;
  final VoidCallback onTap;

  @override
  State<_ListRow> createState() => _ListRowState();
}

class _ListRowState extends State<_ListRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        // Opaque so the padding around the text is part of the target: a row
        // whose only live pixels are the glyphs is a row you have to aim at.
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: Motion.dur1,
          curve: Motion.ease,
          // The 44dp floor, held as a *minimum* rather than a fixed height.
          // `TapTarget` is the wrong tool for a full-width row — it pins a
          // 44x44 box and centres the child inside it, which would clip a row
          // that has to grow at a 2.0 text scale. Extending the target, not
          // fixing its shape, is what this row needs.
          constraints: const BoxConstraints(minHeight: Layout.tap),
          padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x3),
          decoration: BoxDecoration(
            color: _hover ? p.surfaceHover : const Color(0x00000000),
            borderRadius: R.borderLg,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      widget.list.name,
                      style: TextStyle(
                        fontSize: Fs.base,
                        height: Lh.snug,
                        fontWeight: FontWeight.w500,
                        color: p.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      context.t('home.listMeta', {
                        'words': widget.words,
                        'due': widget.due,
                      }),
                      style: TextStyle(
                        fontFamily: Fonts.mono,
                        fontSize: Fs.xs,
                        height: Lh.snug,
                        color: widget.due > 0 ? p.accent : p.ink3,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Sp.x2),
              LexIcon(Ic.chevronRight, size: 16, color: p.ink4),
            ],
          ),
        ),
      ),
    );
  }
}

/* ------------------------------------------------------------------ */
/* A tappable hairline row                                             */
/* ------------------------------------------------------------------ */

/// A one-line tappable block on a hairline card.
///
/// Shared by the "continue" suggestion. It is not the `_ListRow` above because
/// that one is a *card* or a *row inside a card* depending on the window, while
/// this is always its own card.
class _TapRow extends StatefulWidget {
  const _TapRow({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  State<_TapRow> createState() => _TapRowState();
}

class _TapRowState extends State<_TapRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: Motion.dur1,
          curve: Motion.ease,
          constraints: const BoxConstraints(minHeight: Layout.tap),
          padding: const EdgeInsets.all(Sp.x4),
          decoration: BoxDecoration(
            color: _hover ? p.surfaceHover : p.surface,
            borderRadius: R.borderLg,
            border: Border.all(color: p.line),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
