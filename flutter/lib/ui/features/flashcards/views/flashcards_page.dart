/// The flashcard review screen.
///
/// Ports the web build's `FlashcardsPage.tsx`. Three states live in one page —
/// deck picker, the card in hand, and the finished-session card — because they
/// are three faces of one session, and splitting them into routes would mean
/// passing the session object through the shell.
///
/// The session itself — the deck, the session in flight, the flip, the turn
/// timers, the store-side undo stack and the auto-play latch — lives in
/// [FlashcardsViewModel]. This file is the layout for it: it owns the focus
/// node, the keyboard bindings, the reduced-motion reading and the three
/// screen shapes, and reads every value off the view model inside one
/// [ListenableBuilder].
///
/// Two things are deliberate, and they are the view model's contract now:
///
///   * the deck is *derived* on every read ([FlashcardsViewModel.summary])
///     rather than kept in state, so a grade written to the store immediately
///     changes what "due today" means without a second source of truth;
///   * the store-side undo lives in the view model, not in
///     `domain/models/session.dart`: the session owns the counters, the view
///     model snapshots the schedule it is about to overwrite so "undo" can put
///     the card back exactly as it was.
///
/// Audio follows the web build's two rules: a card that is *listening mode*
/// speaks as soon as it appears, and an ordinary card speaks when it is
/// revealed if `autoPlayAudio` is on. Both go through
/// [FlashcardsViewModel.maybeAutoPlay], which dedupes on `word:index:face` so a
/// rebuild — of which there are many, since every store write rebuilds this
/// page — cannot repeat a clip. Only an explicit 发音 press bumps the listen
/// count.
///
/// The speech *calls* stay here and arrive at the view model as ports, because
/// the real `speakWord`/`speakTerm` read the settings off a `BuildContext`;
/// whether the 发音 button exists at all is also decided here, from
/// `speechAvailable`. That is the one seam the MVVM split leaves open, and it
/// is documented where it is wired in [initState].
library;

// `Card` is ours (ui/widgets.dart), not Material's.
// `Step` is also a Material widget (the stepper's); ours is the session step.
import 'package:flutter/material.dart' hide Card, Step;
import 'package:flutter/services.dart';

import '../../../../app/scope.dart';
import '../../../core/context_feedback.dart';
import '../../../core/tokens.dart';
import '../../../../domain/use_cases/day_stats.dart';
import '../../../../domain/models/session.dart';
import '../../../../domain/models/srs.dart';
import '../../../../domain/models/types.dart';
import '../../../../data/services/speech.dart';
import '../../../../data/services/tts.dart' show appSpeech;
import '../../../core/widgets/controls.dart';
import '../../../core/widgets/keyboard_hints.dart';
import '../../../core/widgets/lex_icon.dart';
import '../../../core/widgets/widgets.dart';
import '../view_models/flashcards_view_model.dart';
import '../../practice/view_models/practice_view_model.dart'
    show PracticePlan, PracticeScope;
import 'session_result.dart';

/// The three grade buttons, in the order the keyboard maps them to 1/2/3.
const List<Grade> _kGrades = <Grade>[Grade.hard, Grade.good, Grade.easy];

const Map<Grade, String> _kGradeLabelKey = <Grade, String>{
  Grade.hard: 'flashcards.gradeHard',
  Grade.good: 'flashcards.gradeGood',
  Grade.easy: 'flashcards.gradeEasy',
};

/// The decision a live drag is pointing at.
///
/// One per grade, plus the skip: left is 困难, right is 记得, up is 简单, and
/// down is 跳过. Four gestures, four meanings — the pill under the card names
/// whichever one the hand is currently holding.
enum _IntentKind { hard, good, easy, skip }

/// The pill under the card while the hand is on it: what the release would do,
/// and how far the pull still has to go.
///
/// It is the reference design's single pill —「一般 · 2 天后」— with one
/// difference that matters: that pill is a *button* in the reference, while
/// here the same shape is a *readout*. Tapping a grade you have not decided on
/// is a mis-tap away from silently rescheduling a word; dragging toward one and
/// letting go is a decision made with the hand, and the pill is what tells the
/// hand which decision the drag currently means.
class _DragPreview {
  const _DragPreview({required this.kind, required this.armed, required this.travel});

  final _IntentKind kind;

  /// Whether the release would commit at this distance. Before it, the pill is
  /// a hint; after it, the pill is a promise — and it says so in colour.
  final bool armed;

  /// How far the pull has gone, 0..1 of the commit distance, for the fill.
  final double travel;
}

const Map<DeckSource, String> _kDeckLabelKey = <DeckSource, String>{
  DeckSource.due: 'flashcards.deckDue',
  DeckSource.fresh: 'flashcards.deckNew',
  DeckSource.all: 'flashcards.deckAll',
  DeckSource.favorites: 'flashcards.deckFavorites',
};

class FlashcardsPage extends StatefulWidget {
  const FlashcardsPage({
    super.key,
    this.controller,
    this.plan,
    this.onExit,
  });

  /// Owned by the shell, so the page scroll position survives a page switch.
  final ScrollController? controller;

  /// The round the practice screen decided on, or null when this page is
  /// mounted on its own.
  ///
  /// A plan means two things: the session starts as soon as the page appears
  /// (the 开始复习 press already happened on the front page), and there is no
  /// deck picker to go back to — 退出 returns to that front page instead.
  final PracticePlan? plan;

  /// Called when the session ends and the caller owns what comes next.
  final VoidCallback? onExit;

  @override
  State<FlashcardsPage> createState() => _FlashcardsPageState();
}

class _FlashcardsPageState extends State<FlashcardsPage> {
  /// Built here rather than in the field initialiser: it needs the store, which
  /// is only reachable once the page is mounted under a [StoreScope].
  late final FlashcardsViewModel _vm;

  final FocusNode _focus = FocusNode(debugLabel: 'flashcards-page');

  /// What the hand is about to do, published by the card while a drag is live
  /// and read by the pill under it.
  ///
  /// It is a notifier rather than a callback into `setState` for a reason: a
  /// drag repaints every frame, and rebuilding the page — card, deck edges,
  /// action row, grade row — to move a 36 dp label would put the whole session
  /// on the wrong side of the frame budget. Only the pill listens.
  final ValueNotifier<_DragPreview?> _dragPreview =
      ValueNotifier<_DragPreview?>(null);

  @override
  void initState() {
    super.initState();
    final PracticePlan? plan = widget.plan;
    _vm = FlashcardsViewModel(
      store: context.store,
      feedback: ContextFeedback(context),
      // The round the practice screen decided on. Both are null when this page
      // is mounted on its own, which leaves the deck picker in charge.
      deck: plan?.scope == PracticeScope.custom
          ? DeckSource.all
          : DeckSource.due,
      limit: plan?.size,
      // Hand control back to the practice screen instead of falling back to the
      // picker, which this page never showed in the first place.
      onExit: widget.onExit,
      // The four things the view model cannot do itself, because all of them
      // need a `BuildContext`: the two speech calls (they read the TTS settings
      // off the scope and, for `speakWord`, bump the listen counter), stopping
      // a clip, and asking whether an engine exists at all.
      speakWord: (Word word, {VoidCallback? onEnd}) =>
          speakWord(context, word, onEnd: onEnd),
      speakTerm: (Word word, {VoidCallback? onEnd}) =>
          speakTerm(context, word, onEnd: onEnd),
      stopSpeech: () => appSpeech.stop(),
      speechAvailable: () => speechAvailable,
    );
    // The page owns the keyboard while it is open; a focusable node is the only
    // way Flutter delivers key events to `CallbackShortcuts` below.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      // A plan means 开始复习 was already pressed: there is nothing to pick, so
      // the round begins with the first frame. Post-frame rather than in
      // `initState` because starting a session notifies listeners, and this
      // widget has not been built yet.
      if (plan != null) _vm.startSession();
    });
  }

  @override
  void dispose() {
    // The view model cancels the turn timers, stops any clip in flight — which
    // would otherwise talk over whatever comes next — and detaches from the
    // store.
    _vm.dispose();
    _focus.dispose();
    _dragPreview.dispose();
    super.dispose();
  }

  /* ------------------------------------------------------------------ */
  /* Keyboard                                                            */
  /* ------------------------------------------------------------------ */

  Map<ShortcutActivator, VoidCallback> _bindings() {
    return <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _vm.undo,
      const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): _vm.undo,
      // A focused button owns Space on the web; here the card is the only thing
      // Space can mean, so it always flips.
      const SingleActivator(LogicalKeyboardKey.space): () {
        if (!_vm.inProgress) return;
        if (_vm.flipped) {
          _vm.resetFlip();
        } else {
          _reveal();
        }
      },
      // The keyboard twins of the four swipe directions, in the same order the
      // card uses: left 困难, right 记得, up 简单, down 跳过. They grade on both
      // faces, exactly like the gesture — gating them on the answer being
      // revealed would teach a second, contradictory rule.
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
        if (_vm.inProgress) _vm.grade(Grade.hard);
      },
      const SingleActivator(LogicalKeyboardKey.arrowRight): () {
        if (_vm.inProgress) _vm.grade(Grade.good);
      },
      const SingleActivator(LogicalKeyboardKey.arrowUp): () {
        if (_vm.inProgress) _vm.grade(Grade.easy);
      },
      const SingleActivator(LogicalKeyboardKey.arrowDown): () {
        if (_vm.inProgress) _vm.skip();
      },
      const SingleActivator(LogicalKeyboardKey.digit1): () {
        if (_vm.inProgress && _vm.flipped) _vm.grade(Grade.hard);
      },
      const SingleActivator(LogicalKeyboardKey.digit2): () {
        if (_vm.inProgress && _vm.flipped) _vm.grade(Grade.good);
      },
      const SingleActivator(LogicalKeyboardKey.digit3): () {
        if (_vm.inProgress && _vm.flipped) _vm.grade(Grade.easy);
      },
    };
  }

  /// Turn the card over, honouring the platform's reduced-motion preference.
  ///
  /// The reading happens here rather than in the view model because it needs a
  /// `MediaQuery`; everything the turn then does — the 125 ms edge-on half, the
  /// 190 ms answer-in half, the timers — is the view model's.
  void _reveal() => _vm.reveal(
        reduceMotion: MediaQuery.maybeOf(context)?.disableAnimations ?? false,
      );

  /* ------------------------------------------------------------------ */
  /* Build                                                               */
  /* ------------------------------------------------------------------ */

  @override
  Widget build(BuildContext context) {
    // One listenable for the whole screen: the view model notifies on every
    // session mutation and on every store write it subscribed to, so this single
    // builder is the only place the page reads state from.
    return ListenableBuilder(
      listenable: _vm,
      builder: (BuildContext context, Widget? _) => _build(context),
    );
  }

  /// Layout only: every value below is a getter on [_vm].
  Widget _build(BuildContext context) {
    final String Function(String, [Map<String, Object>?]) t = context.t;
    final AppData data = _vm.data;
    final Settings settings = data.settings;

    final DeckSummary summary = _vm.summary;
    final int deckSize = _vm.deckSize;

    final SessionProgress? progress = _vm.progress;
    final bool inProgress = _vm.inProgress;
    final Word? word = _vm.word;
    final bool newCard = _vm.newCard;
    final Map<Grade, ({int intervalDays, WordStatus status})>? preview =
        _vm.preview;

    final Widget side = _sidePanel(
      t,
      data,
      settings,
      inProgress: inProgress,
      remaining: _vm.remaining,
      total: progress?.total ?? 0,
    );

    // Auto-play is decided after the frame, so it runs once the face actually
    // on screen matches the card in hand — starting it here would speak the
    // *previous* card during a flip.
    if (inProgress) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _vm.maybeAutoPlay();
      });
    }

    final List<Widget> body;
    if (progress == null) {
      // A plan means the round is about to start in the post-frame callback, so
      // the picker never belonged to this mount: drawing it for the one frame
      // before the session lands would flash a screen the reader never chose.
      body = widget.plan == null
          ? <Widget>[_deckPickerState(t, data, settings, summary, deckSize, side)]
          : const <Widget>[];
    } else if (inProgress) {
      body = <Widget>[
        _studySplit(
          main: _sessionColumn(
            t,
            progress: progress,
            word: word,
            newCard: newCard,
            preview: preview,
            onGrade: _vm.grade,
            onReveal: _reveal,
            onSkip: _vm.skip,
            onUndo: _vm.undo,
            onExit: _vm.requestExit,
          ),
          side: side,
        ),
      ];
    } else {
      body = <Widget>[
        _studySplit(
          main: _doneColumn(t, data, settings, progress, deckSize, side),
          side: side,
        ),
      ];
    }

    return CallbackShortcuts(
      bindings: _bindings(),
      child: Focus(
        focusNode: _focus,
        child: PageShell(
          controller: widget.controller,
          children: body,
        ),
      ),
    );
  }

  /* ------------------------------------------------------------------ */
  /* State 1 — deck picker                                               */
  /* ------------------------------------------------------------------ */

  Widget _deckPickerState(
    String Function(String, [Map<String, Object>?]) t,
    AppData data,
    Settings settings,
    DeckSummary summary,
    int deckSize,
    Widget side,
  ) {
    if (data.words.isEmpty) {
      return EmptyState(
        icon: Ic.cards,
        title: t('words.noWords'),
        text: t('words.noWordsHint'),
        action: _addFirstWordButton(t),
      );
    }

    final Palette p = Palette.of(context);
    final Widget intro = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // This block used to open with a 开始复习 heading, which was fine while
        // a page header sat above it naming the screen. That header is gone
        // (the sidebar and the tab bar name the page), so the heading became
        // the top line of the screen — and it printed the exact words of the
        // button three lines below it. One of the two had to go, and the
        // button is the one that does something. The block now starts with the
        // label of the control it holds.
        Text(
          t('flashcards.buildDeck'),
          style: TextStyle(
            fontSize: Fs.sm,
            height: Lh.tight,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.04,
            color: p.ink3,
          ),
        ),
        const SizedBox(height: Sp.x3),
        // The segmented control is one row; on a phone the four deck names do
        // not fit, so it scrolls sideways instead of overflowing.
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Segmented<DeckSource>(
            value: _vm.deck,
            options: <SegOption<DeckSource>>[
              for (final DeckSource s in DeckSource.values)
                SegOption<DeckSource>(
                  value: s,
                  label: t(_kDeckLabelKey[s]!),
                  count: summary.counts[s],
                ),
            ],
            onChanged: _vm.setDeck,
          ),
        ),
        const SizedBox(height: Sp.x4),
        // Three figures stood here, each a number over its own label, and the
        // first of them counted cards the side panel already counts on the
        // same screen. A deck's size is one sentence, not a statistic board:
        // what is due, what is new, how big — on one quiet line, so the button
        // below is still the only thing asking for a decision.
        Text(
          t('flashcards.pickerMeta', <String, Object>{
            'due': summary.dueReview,
            'fresh': summary.counts[DeckSource.fresh] ?? 0,
            'total': deckSize,
          }),
          style: TextStyle(
            fontSize: Fs.xs,
            height: Lh.body,
            color: p.ink3,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
        if (summary.capReached && !summary.caughtUp) ...<Widget>[
          const SizedBox(height: Sp.x4),
          _Notice(
            text: t('flashcards.newCapReached', <String, Object>{
              'n': settings.newCardsPerDay,
            }),
          ),
        ],
        const SizedBox(height: Sp.x5),
        if (deckSize == 0)
          _emptyDeck(t, summary.caughtUp)
        else
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: LexButton(
              label: t('flashcards.start'),
              size: BtnSize.lg,
              kind: BtnKind.primary,
              onPressed: _vm.startSession,
              trailing: LexIcon(
                Ic.arrowRight,
                size: 17,
                color: p.onAccent,
              ),
            ),
          ),
        // Key legends are meaningless without a keyboard, so the whole block
        // (spacing included) is dropped on touch devices.
        if (context.showsKeyHints) ...<Widget>[
          const SizedBox(height: Sp.x3),
          Text(
            t('flashcards.keyboardHint'),
            style: TextStyle(
              fontSize: Fs.xs,
              height: Lh.body,
              color: p.ink3,
            ),
          ),
        ],
      ],
    );

    return _studySplit(
      main: Align(
        // Centred, not pinned left. The measure is capped at 620dp, so on a
        // wide pane a left-aligned block spent the whole difference as a gap
        // under one edge: the column read as half-finished rather than as a
        // measure. Centred, the same cap reads as margins.
        alignment: AlignmentDirectional.center,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: intro,
        ),
      ),
      side: side,
    );
  }

  Widget _emptyDeck(
    String Function(String, [Map<String, Object>?]) t,
    bool caughtUp,
  ) {
    final DeckSource deck = _vm.deck;
    final bool nothingDue =
        caughtUp && (deck == DeckSource.due || deck == DeckSource.fresh);
    if (!nothingDue) {
      return _Notice(
        text: '${t('flashcards.emptyDeck')} ${t('flashcards.emptyDeckHint')}',
      );
    }
    final bool canNav = _vm.canNavigate;
    return EmptyState(
      icon: Ic.sparkles,
      title: t('flashcards.noCards'),
      text: t('flashcards.noCardsHint'),
      action: Wrap(
        spacing: Sp.x2,
        runSpacing: Sp.x2,
        children: <Widget>[
          if (canNav)
            LexButton(
              label: t('flashcards.goQuiz'),
              kind: BtnKind.primary,
              icon: Ic.quiz,
              onPressed: () => _vm.goTo('quiz'),
            ),
          if (canNav)
            LexButton(
              label: t('words.addWord'),
              kind: BtnKind.quiet,
              icon: Ic.plus,
              onPressed: () => _vm.goTo('words'),
            ),
        ],
      ),
    );
  }

  Widget _addFirstWordButton(String Function(String, [Map<String, Object>?]) t) {
    return LexButton(
      label: t('words.addFirst'),
      kind: BtnKind.primary,
      icon: Ic.plus,
      onPressed: _vm.canNavigate ? () => _vm.goTo('words') : null,
    );
  }

  /* ------------------------------------------------------------------ */
  /* State 2 — the card in hand                                          */
  /* ------------------------------------------------------------------ */

  Widget _sessionColumn(
    String Function(String, [Map<String, Object>?]) t, {
    required SessionProgress progress,
    required Word? word,
    required bool newCard,
    required Map<Grade, ({int intervalDays, WordStatus status})>? preview,
    required void Function(Grade) onGrade,
    required VoidCallback onReveal,
    required VoidCallback onSkip,
    required VoidCallback onUndo,
    required VoidCallback onExit,
  }) {
    if (word == null || preview == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _progressBar(t, progress,
              word: null,
              canUndo: _vm.canUndo,
              onUndo: onUndo,
              onExit: onExit),
          const SizedBox(height: Sp.x4),
          EmptyState(
            icon: Ic.cards,
            title: t('flashcards.emptyDeck'),
            text: t('flashcards.emptyDeckHint'),
            action: LexButton(
              label: t('flashcards.restart'),
              onPressed: _vm.startSession,
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _progressBar(t, progress,
            word: word,
            canUndo: _vm.canUndo,
            onUndo: onUndo,
            onExit: onExit),
        const SizedBox(height: Sp.x4),
        _flipCard(t,
            word: word,
            preview: preview,
            onGrade: onGrade,
            onReveal: onReveal,
            onSkip: onSkip,
            onPreview: (p) => _dragPreview.value = p),
        // The pill's lane. Reserved whether or not a drag is live — a slot
        // that appeared mid-gesture would push the card, the thing the hand is
        // holding, away from the finger.
        //
        // 52 dp with the pill on the lane's floor: the two deck edges hang 15
        // dp past the card's bottom edge (they are Positioned with negative
        // bottoms and the Stack does not reserve for them), so a pill centred
        // in a shorter lane sits on top of the paper and reads as if it were
        // part of the stack.
        SizedBox(
          height: 52,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: _DragPill(
              preview: _dragPreview,
              labelOf: (kind) => switch (kind) {
                _IntentKind.hard => t('flashcards.gradeHard'),
                _IntentKind.good => t('flashcards.gradeGood'),
                _IntentKind.easy => t('flashcards.gradeEasy'),
                _IntentKind.skip => t('quiz.skip'),
              },
              intervalOf: (kind) => switch (kind) {
                _IntentKind.skip => '',
                _IntentKind.hard => newCard
                    ? t('flashcards.firstTime')
                    : formatInterval(preview[Grade.hard]!.intervalDays),
                _IntentKind.good => newCard
                    ? t('flashcards.firstTime')
                    : formatInterval(preview[Grade.good]!.intervalDays),
                _IntentKind.easy => newCard
                    ? t('flashcards.firstTime')
                    : formatInterval(preview[Grade.easy]!.intervalDays),
              },
            ),
          ),
        ),
        const SizedBox(height: Sp.x3),
        if (_vm.flipped)
          _gradeRow(t, preview: preview, newCard: newCard, onGrade: onGrade)
        else ...<Widget>[
          // The round action row from the reference design: favorite, play,
          // skip — the three things you can do to a card you have not turned.
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              _circleAction(
                icon: word.favorite ? Ic.starFilled : Ic.star,
                tooltip: t('common.favorite'),
                active: word.favorite,
                onTap: () => context.store.toggleFavorite(word.id),
              ),
              if (speechAvailable) ...<Widget>[
                const SizedBox(width: Sp.x4),
                _circleAction(
                  icon: Ic.volume,
                  tooltip: t('flashcards.autoPlay'),
                  onTap: () => _vm.playWord(word),
                ),
              ],
              const SizedBox(width: Sp.x4),
              _circleAction(
                icon: Ic.arrowRight,
                tooltip: t('quiz.skip'),
                onTap: onSkip,
              ),
            ],
          ),
          const SizedBox(height: Sp.x4),
          Row(
            children: <Widget>[
              Expanded(
                child: LexButton(
                  label: t('flashcards.showAnswer'),
                  kind: BtnKind.primary,
                  size: BtnSize.lg,
                  block: true,
                  onPressed: onReveal,
                  trailing: context.showsKeyHints
                      ? Kbd(t('flashcards.spaceKey'))
                      : null,
                ),
              ),
            ],
          ),
        ],
        if (_vm.flipped && newCard) ...<Widget>[
          const SizedBox(height: Sp.x3),
          Text(
            t('flashcards.firstGradeHint'),
            style: TextStyle(
              fontSize: Fs.xs,
              height: Lh.body,
              color: Palette.of(context).ink3,
            ),
          ),
        ],
      ],
    );
  }

  /// The round's progress, in the reference design's order: the pill bar first,
  /// then the count, then the card.
  ///
  /// The count reads "20 中的 0" — how far into the round you are, total first,
  /// because the total is the number you chose a moment ago and the position is
  /// the one that moves. Undo and exit keep their corners: the design has
  /// neither, but a card screen with no way out is a trap, and undo is the only
  /// defence against a mis-tap on a grade button.
  Widget _progressBar(
    String Function(String, [Map<String, Object>?]) t,
    SessionProgress progress, {
    required Word? word,
    required bool canUndo,
    required VoidCallback onUndo,
    required VoidCallback onExit,
  }) {
    final Palette p = Palette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // Filled pills, one per card: the round is a countable thing, so its
        // progress is drawn as the count rather than as a fraction of a bar.
        // Past 40 cards the bar switches to a proportional fill — 100 pills on
        // a phone would be a grey smear, not a count.
        SegmentedBar(value: progress.index, max: progress.total),
        const SizedBox(height: Sp.x3),
        Row(
          children: <Widget>[
            Tooltip(
              message: t('flashcards.undo'),
              child: LexButton(
                label: '',
                icon: Ic.undo,
                kind: BtnKind.quiet,
                size: BtnSize.sm,
                onPressed: canUndo ? onUndo : null,
              ),
            ),
            Expanded(
              child: Center(
                child: Text(
                  t('flashcards.progressOf', <String, Object>{
                    'i': progress.index,
                    'n': progress.total,
                  }),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: Fonts.mono,
                    fontSize: Fs.sm,
                    height: Lh.tight,
                    color: p.ink3,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ),
            ),
            if (word != null) ...<Widget>[
              StatusChip(
                label: t('status.${word.status.wire}'),
                tone: word.status.wire,
              ),
              const SizedBox(width: Sp.x2),
            ],
            LexButton(
              label: '',
              icon: Ic.x,
              kind: BtnKind.quiet,
              size: BtnSize.sm,
              onPressed: onExit,
            ),
          ],
        ),
        // Nothing reviewed and nothing skipped yet: the two counters would both
        // read zero, and "Cards 0" above a card the reader has not touched
        // reads as "this round is empty" rather than as a tally. The progress
        // line above already says where the round stands.
        if (progress.reviewed > 0 || progress.skipped > 0) ...<Widget>[
          const SizedBox(height: Sp.x2),
          Wrap(
            spacing: Sp.x3,
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Text(
                '${t('flashcards.reviewedCount')} ${progress.reviewed}',
                style: _metaStyle(p),
              ),
              if (progress.reviewed > 0)
                Text('· ${formatAccuracy(progress.accuracy)}',
                    style: _metaStyle(p)),
              if (progress.skipped > 0)
                Text(
                  '· ${t('flashcards.skippedCount', <String, Object>{'n': progress.skipped})}',
                  style: _metaStyle(p),
                ),
            ],
          ),
        ],
      ],
    );
  }

  TextStyle _metaStyle(Palette p) => TextStyle(
        fontSize: Fs.xs,
        height: Lh.tight,
        color: p.ink3,
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      );

  Widget _flipCard(
    String Function(String, [Map<String, Object>?]) t, {
    required Word word,
    required Map<Grade, ({int intervalDays, WordStatus status})> preview,
    required void Function(Grade) onGrade,
    required VoidCallback onReveal,
    required VoidCallback onSkip,
    required ValueChanged<_DragPreview?> onPreview,
  }) {
    final Palette p = Palette.of(context);
    final Size size = MediaQuery.sizeOf(context);
    final double minHeight = (size.height * 0.46).clamp(330.0, 520.0);
    // Every window gets the same height floor. Without it a phone's front face
    // shrinks to its content (~175dp) while the revealed answer is ~322dp, so
    // flipping the card grows it by ~147dp and shoves every control below it
    // down by the same amount. Holding the card to one height keeps the round
    // action row and the answer button in the same place on both faces — the
    // tap target never moves out from under the reader's hand.
    // On a phone the card may still grow past the fold rather than trap a long
    // definition in a nested scroll area: the floor is a minimum, not a cap.
    final bool compact = size.width <= Layout.mobileBreakpoint;
    final double faceMax = compact ? double.infinity : size.height * 0.48;

    // The face is swapped while the card is edge-on, so the answer can never be
    // seen mirrored; `_vm.turn` only drives the rotation.
    //
    // 先显示译文 turns the card around: the meaning is the question and the term
    // is the answer. It is a recognition drill rather than a recall drill —
    // which is what a beginner with a long definition list actually needs — so
    // the two faces swap places, and the answer face promotes the term to the
    // hero line (see `_answerFace`).
    final Settings settings = _vm.data.settings;
    final bool translationFirst = settings.translationFirst;
    final Widget face;
    if (_vm.flipped) {
      face = translationFirst
          ? _answerFace(t, word: word, termEmphasis: true)
          : _answerFace(t, word: word);
    } else if (settings.audioFirst) {
      face = _listenFace(t, word: word);
    } else {
      face = translationFirst
          ? _meaningFace(t, word: word)
          : _termFace(t, word: word);
    }

    // Two paper edges peek out under the card: the deck the current card
    // was drawn from. They are Positioned inside a Stack that sizes to the
    // card, so they never move the layout — and Clip.none lets them hang
    // below the card's bottom edge.
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: <Widget>[
        Positioned(left: 18, right: 18, top: 14, bottom: -8, child: _deckEdge(p, far: false)),
        Positioned(left: 34, right: 34, top: 26, bottom: -15, child: _deckEdge(p, far: true)),
        _FlipCard(
          key: const ValueKey('flip-card'),
          turn: _vm.turn,
          tappable: !_vm.flipped,
          onTap: onReveal,
          // Swiping grades on both faces, one direction per grade: left 困难,
          // right 记得, up 简单, down 跳过. The gate used to be "only after the
          // answer is showing", on the grounds that grading blind is a mistake
          // — but that left the front with a single meaning for every
          // direction, which read as "everything skips". The reference design
          // puts its grade pill on the unrevealed card too: you look, you
          // decide, you throw.
          onSwipe: onGrade,
          // A down-dominant throw skips. Sideways on the front means nothing —
          // there is no grade to give an unrevealed card — so it springs back
          // rather than discarding the card on a gesture that taught nothing.
          onSwipeDown: onSkip,
          onPreview: onPreview,
          minHeight: minHeight,
          // Where each sideways grade would send this word. The dragged border
          // wears the destination's status colour so the pull previews the same
          // four hues the word library paints down its left margin.
          statusOf: preview.map(
            (Grade g, ({int intervalDays, WordStatus status}) v) =>
                MapEntry<Grade, WordStatus>(g, v.status),
          ),
          currentStatus: word.status,
          head: Row(
            children: <Widget>[
              Text(
                _vm.flipped ? t('flashcards.back') : t('flashcards.front'),
                style:
                    TextStyle(fontSize: Fs.xs, height: Lh.tight, color: p.ink3),
              ),
              const Spacer(),
              // The speaker stays on the back only: on the front the round
              // action row under the card owns play, favorite and skip.
              if (_vm.flipped && speechAvailable)
                Tooltip(
                  message: t('flashcards.autoPlay'),
                  child: LexButton(
                    label: '',
                    icon: Ic.volume,
                    kind: BtnKind.quiet,
                    size: BtnSize.sm,
                    onPressed: () => _vm.playWord(word),
                  ),
                ),
            ],
          ),
          face: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: faceMax),
              // Only the revealed answer on a wide window can overflow its cap,
              // so only that one combination keeps a scroll view. Everywhere
              // else the scroll view would be dead weight that still wins the
              // arena for vertical drags — and the card is meant to follow the
              // hand in both axes now, not to fight an invisible scroller for
              // them.
              child: (_vm.flipped && !compact)
                  ? SingleChildScrollView(child: face)
                  : face,
            ),
          ),
        ),
      ],
    );
  }

  /// One paper edge of the deck behind the card. `far` is the deeper sheet:
  /// it sits on the page color so the two read as a receding stack.
  Widget _deckEdge(Palette p, {required bool far}) => DecoratedBox(
        decoration: BoxDecoration(
          color: far ? p.bg : p.surface,
          borderRadius: R.borderXl,
          border: Border.all(color: p.line),
        ),
      );

  /// A round icon button under the card — the reference design's star, play
  /// and skip.
  ///
  /// One size smaller and one shade lighter than the buttons around it: these
  /// are secondary actions on a card whose real verbs are the drag and the big
  /// reveal button below. At 56 px with a full-strength border they read as a
  /// toolbar competing with the card; at 44 px on `surface2` with a hairline
  /// they read as a quiet row under it. 44 px is also the tap-target floor, so
  /// nothing below is a smaller target than the platform allows.
  Widget _circleAction({
    required String icon,
    required String tooltip,
    required VoidCallback onTap,
    bool active = false,
  }) {
    final Palette p = Palette.of(context);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: active ? p.warnSoft : p.surface2,
        shape: CircleBorder(
          side: BorderSide(color: active ? p.warn : p.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Center(
              child: LexIcon(icon, size: 18, color: active ? p.warn : p.ink3),
            ),
          ),
        ),
      ),
    );
  }

  /// The front of the card: the word, and nothing else. A flashcard asks one
  /// question, so the phonetic and the "think first, then flip" hint moved off
  /// the front — they crowded the term the eye is meant to land on, and the
  /// hint repeats what the reveal button below the card already says.
  Widget _termFace(
    String Function(String, [Map<String, Object>?]) t, {
    required Word word,
  }) {
    final Palette p = Palette.of(context);
    final double termSize =
        (MediaQuery.sizeOf(context).width * 0.04).clamp(30.0, 46.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        // The reference design's overline: what the term is, in one quiet
        // caps line — the part of speech when the entry has one, the
        // language label when it does not.
        Text(
          ((word.pos?.isNotEmpty ?? false) ? word.pos! : t('flashcards.termLang'))
              .toUpperCase(),
          style: TextStyle(
            fontFamily: Fonts.mono,
            fontSize: Fs.xs,
            height: Lh.tight,
            letterSpacing: 1.6,
            color: p.ink4,
          ),
        ),
        const SizedBox(height: Sp.x3),
        Text(
          word.term,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: Fonts.display,
            fontSize: termSize,
            height: Lh.title,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.02,
            color: p.ink,
          ),
        ),
        const SizedBox(height: Sp.x6),
        Text(
          t('flashcards.tapToReveal'),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: Fs.sm,
            height: Lh.snug,
            color: p.ink4,
          ),
        ),
      ],
    );
  }

  /// The front of the card when 先显示译文 is on: the meaning is the question.
  ///
  /// Same shape as [_termFace] with the roles swapped — a quiet overline, the
  /// hero line, and the tap hint. The overline says 释义 rather than the part
  /// of speech: a Chinese definition has no part of speech to name, and the
  /// point of the line here is to say what kind of text you are reading.
  Widget _meaningFace(
    String Function(String, [Map<String, Object>?]) t, {
    required Word word,
  }) {
    final Palette p = Palette.of(context);
    final String definition =
        word.definition.trim().isEmpty ? t('words.noDefinition') : word.definition;
    final double size =
        (MediaQuery.sizeOf(context).width * 0.034).clamp(24.0, 36.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Text(
          t('flashcards.meaningOverline').toUpperCase(),
          style: TextStyle(
            fontFamily: Fonts.mono,
            fontSize: Fs.xs,
            height: Lh.tight,
            letterSpacing: 1.6,
            color: p.ink4,
          ),
        ),
        const SizedBox(height: Sp.x3),
        Text(
          definition,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: Fonts.display,
            fontSize: size,
            height: Lh.title,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.01,
            color: p.ink,
          ),
        ),
        const SizedBox(height: Sp.x6),
        Text(
          t('flashcards.tapToReveal'),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: Fs.sm, height: Lh.snug, color: p.ink4),
        ),
      ],
    );
  }

  Widget _listenFace(
    String Function(String, [Map<String, Object>?]) t, {
    required Word word,
  }) {
    final Palette p = Palette.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        LexIcon(Ic.volume, size: 34, color: p.ink4),
        const SizedBox(height: Sp.x3),
        Text(
          t('flashcards.listenPrompt'),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: Fs.base,
            height: Lh.body,
            color: p.ink2,
          ),
        ),
        if (speechAvailable) ...<Widget>[
          const SizedBox(height: Sp.x3),
          LexButton(
            label: t('flashcards.listenAgain'),
            icon: Ic.volume,
            kind: BtnKind.quiet,
            size: BtnSize.sm,
            onPressed: () => _vm.playWord(word),
          ),
        ],
      ],
    );
  }

  Widget _answerFace(
    String Function(String, [Map<String, Object>?]) t, {
    required Word word,
    bool termEmphasis = false,
  }) {
    final Palette p = Palette.of(context);
    final String? pos = word.pos;
    final String? exampleZh = word.exampleZh;
    final String definition =
        word.definition.trim().isEmpty ? t('words.noDefinition') : word.definition;
    // 先显示译文 asks the meaning first, so the term is the answer and has to
    // read as one: hero size, not the quiet overline it is on the normal back.
    final double termSize =
        (MediaQuery.sizeOf(context).width * 0.04).clamp(28.0, 44.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          word.term,
          style: TextStyle(
            fontFamily: Fonts.display,
            fontSize: termEmphasis ? termSize : Fs.lg,
            height: termEmphasis ? Lh.title : Lh.tight,
            fontWeight: termEmphasis ? FontWeight.w600 : null,
            letterSpacing: termEmphasis ? -0.02 : -0.01,
            color: termEmphasis ? p.ink : p.ink2,
          ),
        ),
        const SizedBox(height: Sp.x3),
        Container(height: 1, color: p.line),
        const SizedBox(height: Sp.x3),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (pos != null && pos.isNotEmpty) ...<Widget>[
              Text(
                pos,
                style: TextStyle(
                  fontFamily: Fonts.mono,
                  fontSize: Fs.sm,
                  height: Lh.snug,
                  color: p.ink3,
                ),
              ),
              const SizedBox(width: Sp.x2),
            ],
            Expanded(
              child: Text(
                definition,
                style: TextStyle(
                  fontFamily: Fonts.display,
                  fontSize: Fs.lg,
                  height: Lh.snug,
                  letterSpacing: -0.01,
                  color: p.ink,
                ),
              ),
            ),
          ],
        ),
        if (word.definition2.trim().isNotEmpty) ...<Widget>[
          const SizedBox(height: Sp.x3),
          Text(
            word.definition2,
            style: TextStyle(fontSize: Fs.base, height: Lh.body, color: p.ink2),
          ),
        ],
        if (word.example.trim().isNotEmpty) ...<Widget>[
          const SizedBox(height: Sp.x3),
          Container(
            padding: const EdgeInsets.only(left: Sp.x3),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: p.lineStrong, width: 2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  word.example,
                  style: TextStyle(
                    fontSize: Fs.base,
                    height: Lh.body,
                    fontStyle: FontStyle.italic,
                    color: p.ink2,
                  ),
                ),
                if (exampleZh != null && exampleZh.isNotEmpty) ...<Widget>[
                  const SizedBox(height: Sp.x1),
                  Text(
                    exampleZh,
                    style: TextStyle(fontSize: Fs.sm, height: Lh.body, color: p.ink3),
                  ),
                ],
              ],
            ),
          ),
        ],
        if (word.note.trim().isNotEmpty) ...<Widget>[
          const SizedBox(height: Sp.x3),
          Container(
            padding: const EdgeInsets.all(Sp.x3),
            decoration: BoxDecoration(
              color: p.surface2,
              borderRadius: R.borderSm,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: LexIcon(Ic.info, size: 14, color: p.ink3),
                ),
                const SizedBox(width: Sp.x2),
                Expanded(
                  child: Text(
                    word.note,
                    style: TextStyle(fontSize: Fs.sm, height: Lh.body, color: p.ink2),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _gradeRow(
    String Function(String, [Map<String, Object>?]) t, {
    required Map<Grade, ({int intervalDays, WordStatus status})> preview,
    required bool newCard,
    required void Function(Grade) onGrade,
  }) {
    final bool oneColumn = MediaQuery.sizeOf(context).width <= 620;
    final List<Widget> buttons = <Widget>[
      for (int i = 0; i < _kGrades.length; i++)
        _GradeButton(
          grade: _kGrades[i],
          index: i + 1,
          label: t(_kGradeLabelKey[_kGrades[i]]!),
          interval: newCard
              ? t('flashcards.firstTime')
              : formatInterval(preview[_kGrades[i]]!.intervalDays),
          onPressed: () => onGrade(_kGrades[i]),
        ),
    ];
    if (oneColumn) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int i = 0; i < buttons.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: Sp.x3),
            buttons[i],
          ],
        ],
      );
    }
    return Row(
      // Not `stretch`: this row sits inside the page's scroll viewport, whose
      // cross axis is unbounded, and stretch would force an infinite height on
      // the buttons. Each button carries its own 60dp floor, so centering
      // costs nothing — the three heights match anyway.
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        for (int i = 0; i < buttons.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: Sp.x3),
          Expanded(child: buttons[i]),
        ],
      ],
    );
  }

  /* ------------------------------------------------------------------ */
  /* State 3 — finished                                                  */
  /* ------------------------------------------------------------------ */

  Widget _doneColumn(
    String Function(String, [Map<String, Object>?]) t,
    AppData data,
    Settings settings,
    SessionProgress progress,
    int deckSize,
    Widget side,
  ) {
    final Palette p = Palette.of(context);
    final bool canNav = _vm.canNavigate;
    final int ringMax = progress.reviewed > 1 ? progress.reviewed : 1;
    return SessionResult(
      accuracy: progress.accuracy,
      ringValue: progress.correct.toDouble(),
      ringMax: ringMax.toDouble(),
      accuracyLabel: t('flashcards.accuracy'),
      accuracySub: '${progress.correct} / $ringMax',
      title: t('flashcards.sessionDone'),
      text: t('flashcards.sessionDoneText', <String, Object>{'n': progress.reviewed}),
      leftStat: StatTile(
        label: t('flashcards.reviewedCount'),
        value: '${progress.reviewed}',
        sub: progress.skipped > 0
            ? t('flashcards.skippedCount', <String, Object>{'n': progress.skipped})
            : null,
      ),
      rightStat: StatTile(
        label: t('stats.reviewsToday'),
        value: '${reviewsToday(data)}',
      ),
      actions: <Widget>[
        if (deckSize > 0)
          LexButton(
            label: t('flashcards.nextSession'),
            kind: BtnKind.primary,
            size: BtnSize.lg,
            onPressed: _vm.startSession,
            trailing: LexIcon(Ic.refresh, size: 16, color: p.onAccent),
          )
        else if (canNav)
          LexButton(
            label: t('flashcards.goQuiz'),
            kind: BtnKind.primary,
            size: BtnSize.lg,
            icon: Ic.quiz,
            onPressed: () => _vm.goTo('quiz'),
          ),
        if (_vm.canUndo)
          LexButton(
            label: t('flashcards.undo'),
            kind: BtnKind.quiet,
            icon: Ic.undo,
            onPressed: _vm.undo,
          ),
        LexButton(
          label: t('common.back'),
          kind: BtnKind.quiet,
          onPressed: _vm.exitSession,
        ),
      ],
      footer: deckSize == 0
          ? Text(
              t('flashcards.noCardsHint'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: Fs.xs, height: Lh.body, color: p.ink3),
            )
          : null,
    );
  }

  /* ------------------------------------------------------------------ */
  /* Side panel                                                          */
  /* ------------------------------------------------------------------ */

  Widget _sidePanel(
    String Function(String, [Map<String, Object>?]) t,
    AppData data,
    Settings settings, {
    required bool inProgress,
    required int remaining,
    required int total,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (inProgress) ...<Widget>[
          StatTile(
            label: t('flashcards.remaining'),
            value: '$remaining',
            sub: t('flashcards.deckSize', <String, Object>{'n': total}),
            icon: Ic.layers,
          ),
          const SizedBox(height: Sp.x4),
        ],
        StatTile(
          label: t('stats.reviewsToday'),
          value: '${reviewsToday(data)}',
          sub: '${t('stats.dailyGoal')} ${settings.dailyGoal}',
          icon: Ic.flame,
        ),
        const SizedBox(height: Sp.x4),
        if (context.showsKeyHints) ...[
          Text(
            t('settings.shortcuts'),
            style: TextStyle(
              fontSize: Fs.sm,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.04,
              color: Palette.of(context).ink3,
            ),
          ),
          const SizedBox(height: Sp.x2),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ShortcutRow(keys: const <String>['空格'], label: t('settings.shortcutFlip')),
              ShortcutRow(keys: const <String>['←'], label: t('flashcards.gradeHard')),
              ShortcutRow(keys: const <String>['→'], label: t('flashcards.gradeGood')),
              ShortcutRow(keys: const <String>['↑'], label: t('flashcards.gradeEasy')),
              ShortcutRow(keys: const <String>['↓'], label: t('quiz.skip')),
              ShortcutRow(keys: const <String>['Ctrl', 'Z'], label: t('flashcards.undo')),
            ],
          ),
        ],
      ],
    );
  }

  /* ------------------------------------------------------------------ */
  /* Layout                                                              */
  /* ------------------------------------------------------------------ */

  /// The review screen's two columns. The measured rule lives in [StudySplit],
  /// shared with the quiz screen, so both split at the same *body* width rather
  /// than each guessing from the window size (which counts the sidebar).
  Widget _studySplit({required Widget main, required Widget side}) =>
      StudySplit(main: main, side: side);
}

/* -------------------------------------------------------------------------- */
/* Pieces                                                                     */
/* -------------------------------------------------------------------------- */

/// `.notice`: an icon column and a tinted body.
class _Notice extends StatelessWidget {
  const _Notice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);
    final Color bg = p.accentSoft;
    final Color fg = p.accentInk;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x3),
      decoration: BoxDecoration(color: bg, borderRadius: R.borderSm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: LexIcon(Ic.info, size: 15, color: fg),
          ),
          const SizedBox(width: Sp.x3),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: Fs.sm, height: Lh.body, color: fg),
            ),
          ),
        ],
      ),
    );
  }
}

/// The card itself: a hairline surface that overturns on its Y axis.
///
/// The turn is two halves — the front rotates edge-on, the face is swapped
/// while it is invisible, then the answer rotates in — so no text is ever seen
/// mirrored. When the platform asks for reduced motion the page skips the turn
/// entirely.
///
/// The card is also a free-drag surface, the way the reference deck apps feel:
/// it follows the hand in both axes with a slight tilt, springs back on a
/// release that decides nothing, and flies out along its pull when the release
/// commits — left for a hard, right for a good, down for a skip.
class _FlipCard extends StatefulWidget {
  const _FlipCard({
    super.key,
    required this.turn,
    required this.tappable,
    required this.onTap,
    required this.minHeight,
    required this.head,
    required this.face,
    required this.statusOf,
    required this.currentStatus,
    this.onSwipe,
    this.onSwipeDown,
    this.onPreview,
  });

  final String? turn;
  final bool tappable;
  final VoidCallback onTap;
  final double minHeight;
  final Widget head;
  final Widget face;

  /// The study status each sideways grade would land on, from
  /// [previewGrades]. A sideways drag is a decision about the word's future,
  /// so the border previews that destination in the same status colour the
  /// word library uses.
  final Map<Grade, WordStatus> statusOf;

  /// The word's status before the drag. A skip leaves the status alone, so
  /// its border stays this colour rather than inventing a fifth hue.
  final WordStatus currentStatus;

  /// Called with a grade when the revealed card is dragged sideways past the
  /// swipe threshold — left for a hard, right for a good. Null disables the
  /// commit, which is what the unrevealed card passes: grading a card the
  /// answer has not been seen for is a mistake the undo stack should not have
  /// to clean up. The front still plays with the drag — it just cannot
  /// commit one.
  final void Function(Grade)? onSwipe;

  /// Called when the card is dragged downwards past the skip threshold, down
  /// more than sideways — the gesture layout for the skip button, which
  /// advances the session without a grade. Passed unconditionally: the front
  /// skips the same way the back does, so there is no face where the action
  /// is missing.
  final VoidCallback? onSwipeDown;

  /// Reports what the current pull would do, for the pill under the card.
  ///
  /// Called with null when the hand leaves, so the pill can fade out on the
  /// same release that resolves the drag. It does not use `setState`: the card
  /// repaints every frame of a drag, and the page does not need to.
  final ValueChanged<_DragPreview?>? onPreview;

  @override
  State<_FlipCard> createState() => _FlipCardState();
}

class _FlipCardState extends State<_FlipCard> with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(
    vsync: this,
    duration: Motion.dur1,
  );
  bool _hover = false;

  // The free drag. `_dragOffset` is where the hand holds the card while a
  // pan is live; `_target` is where the card is heading — the same value as
  // the hold while dragging (the follow is instantaneous), zero after a
  // release that decided nothing (spring home), or off-table along the pull
  // when the release commits (fly out). One TweenAnimationBuilder drives all
  // three: zero duration tracks the hand frame by frame, the motion durations
  // animate the release.
  Offset _dragOffset = Offset.zero;
  Offset _target = Offset.zero;
  bool _dragging = false;
  bool _flying = false;
  VoidCallback? _pending;

  // Up is a grade too, and it needs more travel than sideways to fire: the
  // easy interval is the longest a release can hand out, so it gets the
  // longest pull. Down stays a skip and is measured on its own axis. The
  // dominance factors decide a diagonal: a pull has to be more down than
  // sideways to skip, more up than sideways to take Easy.
  static const double _swipeThreshold = 72;
  static const double _easyThreshold = 96;
  static const double _skipThreshold = 96;
  static const double _skipDominance = 1.2;
  static const double _easyDominance = 1.2;
  static const double _dragClamp = 280;

  Grade? _swipeGrade() {
    if (_dragOffset.dx < -_swipeThreshold) return Grade.hard;
    if (_dragOffset.dx > _swipeThreshold) return Grade.good;
    return null;
  }

  bool get _skipReady =>
      widget.onSwipeDown != null &&
      _dragOffset.dy > _skipThreshold &&
      _dragOffset.dy > _dragOffset.dx.abs() * _skipDominance;

  /// An upward pull past [_easyThreshold], more up than sideways.
  ///
  /// 简单 is the grade with the longest interval — the one a release commits
  /// furthest ahead — so it asks for the longest pull. It is also the only
  /// grade left once the three other directions are taken, and up reads as
  /// "this one is going away for a while" in the same vocabulary as the rest.
  bool get _easyReady =>
      widget.onSwipe != null &&
      _dragOffset.dy < -_easyThreshold &&
      -_dragOffset.dy > _dragOffset.dx.abs() * _easyDominance;

  /// The throw that skips: down, and decisively down.
  ///
  /// It used to fire on the front for a pull in *any* direction, on the
  /// reasoning that nothing else was on offer there. That read badly in the
  /// hand: a card that vanishes however you pull it makes the whole screen feel
  /// like a skip button, and the gesture stops teaching anything. Down is the
  /// skip on both faces, and the other three directions are the three grades.
  bool get _throwReady => _skipReady;

  void _panStart(DragStartDetails d) {
    if (_flying) return;
    setState(() {
      _dragging = true;
      _dragOffset = Offset.zero;
      _target = Offset.zero;
    });
    _publishPreview();
  }

  void _panUpdate(DragUpdateDetails d) {
    if (_flying) return;
    setState(() {
      _dragOffset = Offset(
        (_dragOffset.dx + d.delta.dx).clamp(-_dragClamp, _dragClamp),
        (_dragOffset.dy + d.delta.dy).clamp(-_dragClamp, _dragClamp),
      );
      _target = _dragOffset;
    });
    _publishPreview();
  }

  /// Tells the pill what the hand is currently pointing at.
  ///
  /// The card already knows: [_swipeGrade] answers which sideways grade a pull
  /// means, [_easyReady] and [_skipReady] whether it has become a vertical one.
  /// What the pill adds is the *distance still owed*, so the answer is one
  /// number — `travel` — that reaches 1 exactly where the release would commit.
  ///
  /// The precedence here is the release's, case for case, so the pill never
  /// names a decision the release would not take.
  void _publishPreview() {
    final ValueChanged<_DragPreview?>? report = widget.onPreview;
    if (report == null) return;
    final double dx = _dragOffset.dx;
    final double dy = _dragOffset.dy;
    // Below a couple of pixels this is a tap that wobbled, not a decision.
    if (dx.abs() < 2 && dy.abs() < 2) {
      report(null);
      return;
    }
    // Same precedence as the release, so the pill never names a decision the
    // release would not take.
    if (_skipReady) {
      report(_DragPreview(
        kind: _IntentKind.skip,
        armed: true,
        travel: dy / _skipThreshold,
      ));
      return;
    }
    if (_easyReady) {
      report(_DragPreview(
        kind: _IntentKind.easy,
        armed: true,
        travel: -dy / _easyThreshold,
      ));
      return;
    }
    if (dx.abs() < dy.abs()) {
      // Vertical but not yet dominant in either direction: no decision is
      // committed, so the pill stays away rather than flickering between two
      // answers.
      report(null);
      return;
    }
    report(_DragPreview(
      kind: dx < 0 ? _IntentKind.hard : _IntentKind.good,
      armed: dx.abs() > _swipeThreshold,
      travel: dx.abs() / _swipeThreshold,
    ));
  }

  void _panCancel() {
    if (_flying) return;
    _springBack();
  }

  void _panEnd(DragEndDetails d) {
    if (_flying) return;
    // The pill retires on the release, not on the landing: the flight below
    // takes 180 ms and the answer to "what am I about to do" is settled the
    // moment the hand leaves.
    widget.onPreview?.call(null);
    // The release reads the hold, not the fling: a throw past the cage still
    // commits by where the hand stopped, which keeps the decision reviewable —
    // the tint previewed during the drag is the grade that lands.
    //
    // Order matters. A down-dominant pull is a skip even if it also cleared a
    // sideways threshold; an up-dominant pull is 简单; only then do the
    // sideways grades get a look.
    if (_skipReady) {
      _flyAway(widget.onSwipeDown!);
      return;
    }
    if (_easyReady) {
      _flyAway(() => widget.onSwipe!(Grade.easy));
      return;
    }
    final Grade? grade = _swipeGrade();
    if (widget.onSwipe != null && grade != null) {
      _flyAway(() => widget.onSwipe!(grade));
      return;
    }
    _springBack();
  }

  void _springBack() {
    widget.onPreview?.call(null);
    setState(() {
      _dragging = false;
      _dragOffset = Offset.zero;
      _target = Offset.zero;
    });
  }

  void _flyAway(VoidCallback action) {
    final Size? box = context.size;
    final double w = box?.width ?? 420;
    final double h = box?.height ?? 420;
    _pending = action;
    _flying = true;
    // The hand has left: the flight is an animation, not a follow. Keeping
    // _dragging here would hold the tween at zero duration and complete the
    // flight during build, where the landing setState is not allowed.
    _dragging = false;
    // A downward pull leaves along its fall; a sideways throw leaves along
    // its side, keeping a little of the vertical so the exit reads as the
    // same gesture. Deciding by where the hand went — not by which action
    // lands — keeps the front's sideways skip and the back's grading exits
    // honest to the same map.
    _target = _dragOffset.dy > _dragOffset.dx.abs()
        ? Offset(_dragOffset.dx * 0.3, h * 0.75 + 60)
        : Offset(_dragOffset.dx.sign * (w * 0.75 + 60), _dragOffset.dy * 0.5);
    setState(() {});
  }

  void _flightDone() {
    if (!_flying) return;
    _flying = false;
    _dragOffset = Offset.zero;
    _target = Offset.zero;
    setState(() {});
    _pending?.call();
    _pending = null;
  }

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void didUpdateWidget(covariant _FlipCard old) {
    super.didUpdateWidget(old);
    if (old.turn != widget.turn) _run();
  }

  void _run() {
    _turn.stop();
    switch (widget.turn) {
      case 'out':
        _turn.duration = Motion.dur1;
        _turn.forward(from: 0);
      case 'in':
        _turn.duration = Motion.dur2;
        _turn.forward(from: 0);
      default:
        _turn.value = 0;
    }
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  double _radians() {
    const double edge = 88 * 3.1415926535897932 / 180;
    final double v = _turn.value;
    switch (widget.turn) {
      case 'out':
        return -edge * Motion.easeIn.transform(v);
      case 'in':
        return edge * (1 - Motion.easeTurn.transform(v));
      default:
        return 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);
    // The pull previews a decision, so it wears the same four status colours
    // the word library paints on its left stripe. A sideways drag on the back
    // shows where that grade would send the word; a skip leaves the status
    // alone, so it keeps the word's current colour. No fifth "danger" or
    // "warn" accent: that would teach a legend the library does not have.
    final Grade? grade = _swipeGrade();
    final bool grades = !widget.tappable && grade != null && !_skipReady;
    final Color border;
    if (grades) {
      border = p.statusColor(widget.statusOf[grade]!);
    } else if (_throwReady) {
      border = p.statusColor(widget.currentStatus);
    } else {
      border = _hover ? p.lineStrong : p.line;
    }
    return MouseRegion(
      cursor: widget.tappable
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.tappable ? widget.onTap : null,
        onPanStart: _panStart,
        onPanUpdate: _panUpdate,
        onPanCancel: _panCancel,
        onPanEnd: _panEnd,
        // The turn and the drag share one Transform: the flip's rotateY and the
        // hand's translate + tilt compose in a single matrix, so a card can be
        // dragged while it is edge-on without the two fighting for the child.
        child: AnimatedBuilder(
          animation: _turn,
          builder: (BuildContext context, Widget? child) {
            return TweenAnimationBuilder<Offset>(
              tween: Tween<Offset>(end: _target),
              duration: _dragging ? Duration.zero : Motion.dur2,
              curve: _flying ? Motion.easeIn : Motion.easeTurn,
              onEnd: _flightDone,
              builder: (BuildContext context, Offset drag, Widget? inner) {
                return Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()
                    ..setEntry(3, 2, 0.0012)
                    ..rotateY(_radians())
                    ..translateByDouble(drag.dx, drag.dy, 0.0, 1.0)
                    ..rotateZ((drag.dx / 480).clamp(-1.0, 1.0) * 0.14),
                  child: inner,
                );
              },
              child: child,
            );
          },
          child: AnimatedContainer(
            duration: _dragging ? Duration.zero : Motion.dur2,
            curve: Motion.ease,
            constraints: BoxConstraints(minHeight: widget.minHeight),
            padding: const EdgeInsets.fromLTRB(Sp.x7, Sp.x6, Sp.x7, Sp.x5),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: R.borderXl,
              border: Border.all(color: border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                widget.head,
                const SizedBox(height: Sp.x3),
                widget.face,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The pill that appears under the card while a hand is dragging it.
///
/// It reads the preview off a [ValueNotifier], so the page itself never
/// rebuilds during a drag; only this ~190×30 strip does.
///
/// The fill is the honest part. A pill that only appeared once the threshold
/// was crossed would answer the wrong question — the hand needs to know how
/// much further to pull *while* it pulls, not after it is too late to matter.
/// The colour wells up from the left as the pull approaches the commit point,
/// and once the release would commit the whole pill goes solid.
class _DragPill extends StatelessWidget {
  const _DragPill({
    required this.preview,
    required this.labelOf,
    required this.intervalOf,
  });

  final ValueNotifier<_DragPreview?> preview;
  final String Function(_IntentKind) labelOf;
  final String Function(_IntentKind) intervalOf;

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);
    return ValueListenableBuilder<_DragPreview?>(
      valueListenable: preview,
      builder: (BuildContext context, _DragPreview? live, Widget? _) {
        final bool shown = live != null;
        final _DragPreview current = live ??
            const _DragPreview(
              kind: _IntentKind.good,
              armed: false,
              travel: 0,
            );
        final Color tint = switch (current.kind) {
          _IntentKind.hard => p.ink,
          _IntentKind.good => p.accent,
          _IntentKind.easy => p.ok,
          _IntentKind.skip => p.ink3,
        };
        final String interval = intervalOf(current.kind);
        final double fill = current.travel.clamp(0.0, 1.0);
        return IgnorePointer(
          child: AnimatedOpacity(
            opacity: shown ? 1 : 0,
            duration: Motion.dur1,
            curve: Motion.ease,
            child: ClipRRect(
              key: const ValueKey('drag-pill'),
              borderRadius: R.borderPill,
              child: Stack(
                children: <Widget>[
                  // The well: the pill's unfilled body, always the page's
                  // raised surface so it reads as a chip rather than as a
                  // floating word.
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: current.armed ? tint : p.surface,
                        borderRadius: R.borderPill,
                        border: Border.all(
                          color: current.armed ? tint : p.lineStrong,
                        ),
                      ),
                    ),
                  ),
                  // The fill: the same hue at a strength that grows with the
                  // pull, so "keep pulling" is legible without a number.
                  if (!current.armed && fill > 0)
                    Positioned.fill(
                      child: FractionallySizedBox(
                        alignment: AlignmentDirectional.centerStart,
                        widthFactor: fill,
                        child: ColoredBox(color: tint.withValues(alpha: 0.18)),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Sp.x4,
                      vertical: Sp.x2,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          labelOf(current.kind),
                          style: TextStyle(
                            fontSize: Fs.sm,
                            height: Lh.tight,
                            fontWeight: FontWeight.w500,
                            color: current.armed ? p.surface : tint,
                          ),
                        ),
                        if (interval.isNotEmpty) ...<Widget>[
                          Text(
                            ' · ',
                            style: TextStyle(
                              fontSize: Fs.sm,
                              height: Lh.tight,
                              color: current.armed ? p.surface : p.ink3,
                            ),
                          ),
                          Text(
                            interval,
                            style: TextStyle(
                              fontSize: Fs.sm,
                              height: Lh.tight,
                              color: current.armed ? p.surface : p.ink3,
                              fontFeatures: const <FontFeature>[
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One of the three grade buttons: the key that grades it, its name, and what
/// it would do to the schedule.
class _GradeButton extends StatefulWidget {
  const _GradeButton({
    required this.grade,
    required this.index,
    required this.label,
    required this.interval,
    required this.onPressed,
  });

  final Grade grade;
  final int index;
  final String label;
  final String interval;
  final VoidCallback onPressed;

  @override
  State<_GradeButton> createState() => _GradeButtonState();
}

class _GradeButtonState extends State<_GradeButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: Motion.dur1,
          curve: Motion.ease,
          constraints: const BoxConstraints(minHeight: 60),
          padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: Sp.x2),
          decoration: BoxDecoration(
            color: _hover ? p.surfaceHover : p.surface,
            borderRadius: R.borderSm,
            border: Border.all(color: p.lineStrong),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (context.showsKeyHints) ...<Widget>[
                    Kbd('${widget.index}'),
                    const SizedBox(width: Sp.x1),
                  ],
                  Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: Fs.md,
                      height: Lh.tight,
                      fontWeight: FontWeight.w500,
                      color: p.ink,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Sp.x1),
              Text(
                widget.interval,
                style: TextStyle(
                  fontSize: Fs.xs,
                  height: Lh.tight,
                  color: p.ink3,
                  fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
