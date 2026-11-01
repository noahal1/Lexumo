/// The flashcard review screen.
///
/// Ports `src/pages/study/FlashcardsPage.tsx`. Three states live in one page —
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
import 'session_result.dart';

/// The three grade buttons, in the order the keyboard maps them to 1/2/3.
const List<Grade> _kGrades = <Grade>[Grade.hard, Grade.good, Grade.easy];

const Map<Grade, String> _kGradeLabelKey = <Grade, String>{
  Grade.hard: 'flashcards.gradeHard',
  Grade.good: 'flashcards.gradeGood',
  Grade.easy: 'flashcards.gradeEasy',
};

const Map<DeckSource, String> _kDeckLabelKey = <DeckSource, String>{
  DeckSource.due: 'flashcards.deckDue',
  DeckSource.fresh: 'flashcards.deckNew',
  DeckSource.all: 'flashcards.deckAll',
  DeckSource.favorites: 'flashcards.deckFavorites',
};

class FlashcardsPage extends StatefulWidget {
  const FlashcardsPage({super.key, this.controller});

  /// Owned by the shell, so the page scroll position survives a page switch.
  final ScrollController? controller;

  @override
  State<FlashcardsPage> createState() => _FlashcardsPageState();
}

class _FlashcardsPageState extends State<FlashcardsPage> {
  /// Built here rather than in the field initialiser: it needs the store, which
  /// is only reachable once the page is mounted under a [StoreScope].
  late final FlashcardsViewModel _vm;

  final FocusNode _focus = FocusNode(debugLabel: 'flashcards-page');

  @override
  void initState() {
    super.initState();
    _vm = FlashcardsViewModel(
      store: context.store,
      feedback: ContextFeedback(context),
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
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    // The view model cancels the turn timers, stops any clip in flight — which
    // would otherwise talk over whatever comes next — and detaches from the
    // store.
    _vm.dispose();
    _focus.dispose();
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
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
        if (_vm.inProgress) _vm.skip();
      },
      const SingleActivator(LogicalKeyboardKey.arrowRight): () {
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
      body = <Widget>[
        _deckPickerState(t, data, settings, summary, deckSize, side),
      ];
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
          title: t('flashcards.title'),
          subtitle: t('flashcards.subtitle'),
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
      return Card(
        child: EmptyState(
          icon: Ic.cards,
          title: t('words.noWords'),
          text: t('words.noWordsHint'),
          action: _addFirstWordButton(t),
        ),
      );
    }

    final Widget intro = Card(
      padding: const EdgeInsets.all(Sp.x7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          LexIcon(Ic.cards, size: 26, color: Palette.of(context).ink4),
          const SizedBox(height: Sp.x4),
          Text(
            t('flashcards.start'),
            style: TextStyle(
              fontFamily: Fonts.display,
              fontSize: Fs.x2xl,
              height: Lh.title,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.02,
              color: Palette.of(context).ink,
            ),
          ),
          const SizedBox(height: Sp.x2),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: Fs.base * 24),
            child: Text(
              t('flashcards.subtitle'),
              style: TextStyle(
                fontSize: Fs.base,
                height: Lh.loose,
                color: Palette.of(context).ink2,
              ),
            ),
          ),
          const SizedBox(height: Sp.x4),
          Text(
            t('flashcards.buildDeck'),
            style: TextStyle(
              fontSize: Fs.sm,
              fontWeight: FontWeight.w500,
              color: Palette.of(context).ink2,
            ),
          ),
          const SizedBox(height: Sp.x2),
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
          Wrap(
            spacing: Sp.x2,
            runSpacing: Sp.x2,
            children: <Widget>[
              StatusChip(
                label: t('flashcards.dueCount',
                    <String, Object>{'n': summary.dueReview}),
                tone: 'learning',
              ),
              StatusChip(
                label: t('flashcards.newCount',
                    <String, Object>{'n': summary.counts[DeckSource.fresh] ?? 0}),
                tone: 'new',
              ),
              StatusChip(
                label: t('flashcards.deckSize', <String, Object>{'n': deckSize}),
                tone: 'meta',
              ),
            ],
          ),
          if (summary.capReached && !summary.caughtUp) ...<Widget>[
            const SizedBox(height: Sp.x4),
            _Notice(
              text: t('flashcards.newCapReached', <String, Object>{
                'n': settings.newCardsPerDay,
              }),
            ),
          ],
          const SizedBox(height: Sp.x4),
          if (deckSize == 0)
            _emptyDeck(t, summary.caughtUp)
          else
            Row(
              children: <Widget>[
                LexButton(
                  label: t('flashcards.start'),
                  size: BtnSize.lg,
                  kind: BtnKind.primary,
                  onPressed: _vm.startSession,
                  trailing: LexIcon(
                    Ic.arrowRight,
                    size: 17,
                    color: Palette.of(context).onAccent,
                  ),
                ),
              ],
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
                color: Palette.of(context).ink3,
              ),
            ),
          ],
        ],
      ),
    );

    return _studySplit(
      main: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[intro],
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
          Card(
            child: EmptyState(
              icon: Ic.cards,
              title: t('flashcards.emptyDeck'),
              text: t('flashcards.emptyDeckHint'),
              action: LexButton(
                label: t('flashcards.restart'),
                onPressed: _vm.startSession,
              ),
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
        _flipCard(t, word: word, onReveal: onReveal, onSkip: onSkip),
        const SizedBox(height: Sp.x4),
        if (_vm.flipped)
          _gradeRow(t, preview: preview, newCard: newCard, onGrade: onGrade)
        else
          Row(
            children: <Widget>[
              LexButton(
                label: t('flashcards.showAnswer'),
                kind: BtnKind.primary,
                size: BtnSize.lg,
                onPressed: onReveal,
                trailing:
                    context.showsKeyHints ? Kbd(t('flashcards.spaceKey')) : null,
              ),
            ],
          ),
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
        Row(
          children: <Widget>[
            Text(
              t('flashcards.cardOf', <String, Object>{
                'i': progress.index + 1,
                'n': progress.total,
              }),
              style: TextStyle(
                fontFamily: Fonts.mono,
                fontSize: Fs.xs,
                height: Lh.tight,
                color: p.ink3,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
            if (word != null) ...<Widget>[
              const SizedBox(width: Sp.x2),
              StatusChip(
                label: t('status.${word.status.wire}'),
                tone: word.status.wire,
              ),
            ],
            const Spacer(),
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
            const SizedBox(width: Sp.x2),
            LexButton(
              label: t('flashcards.exit'),
              icon: Ic.x,
              kind: BtnKind.quiet,
              size: BtnSize.sm,
              onPressed: onExit,
            ),
          ],
        ),
        const SizedBox(height: Sp.x2),
        ProgressBar(
          value: progress.index.toDouble(),
          max: progress.total.toDouble(),
          thick: true,
        ),
        const SizedBox(height: Sp.x2),
        Wrap(
          spacing: Sp.x3,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            Text(
              '${t('flashcards.reviewedCount')} ${progress.reviewed}',
              style: _metaStyle(p),
            ),
            if (progress.reviewed > 0)
              Text('· ${formatAccuracy(progress.accuracy)}', style: _metaStyle(p)),
            if (progress.skipped > 0)
              Text(
                '· ${t('flashcards.skippedCount', <String, Object>{'n': progress.skipped})}',
                style: _metaStyle(p),
              ),
          ],
        ),
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
    required VoidCallback onReveal,
    required VoidCallback onSkip,
  }) {
    final Palette p = Palette.of(context);
    final Size size = MediaQuery.sizeOf(context);
    final double minHeight = (size.height * 0.46).clamp(330.0, 520.0);
    // On a phone the card may grow past the fold rather than trap a long
    // definition in a nested scroll area.
    final bool compact = size.width <= Layout.mobileBreakpoint;
    final double faceMax = compact ? double.infinity : size.height * 0.48;

    // The face is swapped while the card is edge-on, so the answer can never be
    // seen mirrored; `_vm.turn` only drives the rotation.
    final Widget face = _vm.flipped
        ? _answerFace(t, word: word)
        : (_vm.data.settings.audioFirst
            ? _listenFace(t, word: word)
            : _termFace(t, word: word));

    return _FlipCard(
      turn: _vm.turn,
      tappable: !_vm.flipped,
      onTap: onReveal,
      minHeight: compact ? 0 : minHeight,
      head: Row(
        children: <Widget>[
          Text(
            _vm.flipped ? t('flashcards.back') : t('flashcards.front'),
            style: TextStyle(fontSize: Fs.xs, height: Lh.tight, color: p.ink3),
          ),
          const Spacer(),
          Tooltip(
            message: t('quiz.skip'),
            child: LexButton(
              label: '',
              icon: Ic.arrowRight,
              kind: BtnKind.quiet,
              size: BtnSize.sm,
              onPressed: onSkip,
            ),
          ),
          if (speechAvailable) ...<Widget>[
            const SizedBox(width: Sp.x1),
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
        ],
      ),
      face: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: faceMax),
          child: SingleChildScrollView(child: face),
        ),
      ),
    );
  }

  Widget _termFace(
    String Function(String, [Map<String, Object>?]) t, {
    required Word word,
  }) {
    final Palette p = Palette.of(context);
    final double termSize =
        (MediaQuery.sizeOf(context).width * 0.04).clamp(30.0, 46.0);
    final String? phonetic = word.phonetic;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
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
        if (phonetic != null && phonetic.isNotEmpty) ...<Widget>[
          const SizedBox(height: Sp.x1),
          Text(
            '/$phonetic/',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: Fonts.mono,
              fontSize: Fs.md,
              height: Lh.tight,
              color: p.ink3,
            ),
          ),
        ],
        if (context.showsKeyHints) ...<Widget>[
          const SizedBox(height: Sp.x4),
          _hintRow(t, t('flashcards.spaceKey'), t('flashcards.revealHint')),
        ],
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
        if (context.showsKeyHints) ...<Widget>[
          const SizedBox(height: Sp.x4),
          _hintRow(t, t('flashcards.spaceKey'), t('flashcards.revealHint')),
        ],
      ],
    );
  }

  Widget _hintRow(
    String Function(String, [Map<String, Object>?]) t,
    String key,
    String label,
  ) {
    final Palette p = Palette.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Kbd(key),
        const SizedBox(width: Sp.x2),
        Text(
          label,
          style: TextStyle(fontSize: Fs.xs, height: Lh.tight, color: p.ink3),
        ),
      ],
    );
  }

  Widget _answerFace(
    String Function(String, [Map<String, Object>?]) t, {
    required Word word,
  }) {
    final Palette p = Palette.of(context);
    final String? pos = word.pos;
    final String? exampleZh = word.exampleZh;
    final String definition =
        word.definition.trim().isEmpty ? t('words.noDefinition') : word.definition;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          word.term,
          style: TextStyle(
            fontFamily: Fonts.display,
            fontSize: Fs.lg,
            height: Lh.tight,
            letterSpacing: -0.01,
            color: p.ink2,
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
      crossAxisAlignment: CrossAxisAlignment.stretch,
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
        if (context.showsKeyHints)
          Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  t('settings.shortcuts'),
                  style: TextStyle(
                    fontSize: Fs.md,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.005,
                    color: Palette.of(context).ink,
                  ),
                ),
                const SizedBox(height: Sp.x2),
                ShortcutRow(keys: const <String>['空格'], label: t('settings.shortcutFlip')),
                ShortcutRow(keys: const <String>['1'], label: t('flashcards.gradeHard')),
                ShortcutRow(keys: const <String>['2'], label: t('flashcards.gradeGood')),
                ShortcutRow(keys: const <String>['3'], label: t('flashcards.gradeEasy')),
                ShortcutRow(keys: const <String>['←', '→'], label: t('quiz.skip')),
                ShortcutRow(keys: const <String>['Ctrl', 'Z'], label: t('flashcards.undo')),
              ],
            ),
          ),
      ],
    );
  }

  /* ------------------------------------------------------------------ */
  /* Layout                                                              */
  /* ------------------------------------------------------------------ */

  /// The web build's `.study-split`: main column plus a 296px side panel, which
  /// drops below the main column at 1080 and disappears at 720.
  Widget _studySplit({required Widget main, required Widget side}) {
    final double width = MediaQuery.sizeOf(context).width;
    final bool showSide = width > Layout.mobileBreakpoint;
    if (width <= 1080) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          main,
          if (showSide) ...<Widget>[const SizedBox(height: Sp.x4), side],
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(child: main),
        if (showSide) ...<Widget>[
          const SizedBox(width: Sp.x5),
          SizedBox(width: 296, child: side),
        ],
      ],
    );
  }
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
class _FlipCard extends StatefulWidget {
  const _FlipCard({
    required this.turn,
    required this.tappable,
    required this.onTap,
    required this.minHeight,
    required this.head,
    required this.face,
  });

  final String? turn;
  final bool tappable;
  final VoidCallback onTap;
  final double minHeight;
  final Widget head;
  final Widget face;

  @override
  State<_FlipCard> createState() => _FlipCardState();
}

class _FlipCardState extends State<_FlipCard> with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(
    vsync: this,
    duration: Motion.dur1,
  );
  bool _hover = false;

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
    return MouseRegion(
      cursor: widget.tappable ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.tappable ? widget.onTap : null,
        child: AnimatedBuilder(
          animation: _turn,
          builder: (BuildContext context, Widget? child) {
            return Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.0012)
                ..rotateY(_radians()),
              child: child,
            );
          },
          child: AnimatedContainer(
            duration: Motion.dur2,
            curve: Motion.ease,
            constraints: BoxConstraints(minHeight: widget.minHeight),
            padding: const EdgeInsets.fromLTRB(Sp.x7, Sp.x6, Sp.x7, Sp.x5),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: R.borderLg,
              border: Border.all(color: _hover ? p.lineStrong : p.line),
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
