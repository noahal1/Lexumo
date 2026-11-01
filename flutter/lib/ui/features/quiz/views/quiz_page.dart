/// The multiple-choice quiz screen.
///
/// Ports `src/pages/study/QuizPage.tsx`. A round is a list of [QuizQuestion]s
/// built once by `domain/quiz.dart`; the page only walks them with a [Session]
/// so the score, the progress bar and "did this round finish" all come from the
/// same counters the flashcard page uses.
///
/// The round itself — its phase, its questions, the answer in flight and the
/// results — lives in [QuizViewModel]. This file is the layout for it: it owns
/// the focus node, the keyboard bindings and the three screen shapes, and reads
/// every value off the view model inside one [ListenableBuilder].
///
/// Two rules the TS encoded in comments and are kept here:
///
///   * while the feedback for an answer is on screen the session has already
///     moved past that question, so the card shown steps back one
///     ([QuizViewModel.currentIndex]);
///   * a correct answer glides on after 900 ms, but a miss stays put until the
///     correction has actually been read.
///
/// The prompt carries a 发音 button on a term→definition round only: hearing
/// the term is the point, whereas reading a Chinese gloss aloud in an English
/// voice would be worse than silence.
library;

// `Card` is ours (ui/widgets.dart), not Material's.
import 'package:flutter/material.dart' hide Card;
import 'package:flutter/services.dart';

import '../../../../app/scope.dart';
import '../../../core/context_feedback.dart';
import '../../../core/tokens.dart';
import '../../../../domain/models/quiz.dart';
import '../../../../domain/models/session.dart';
import '../../../../domain/models/types.dart';
import '../../../../data/services/speech.dart';
import '../../../../data/services/tts.dart' show appSpeech;
import '../../../core/widgets/controls.dart';
import '../../../core/widgets/density.dart';
import '../../../core/widgets/keyboard_hints.dart';
import '../../../core/widgets/lex_icon.dart';
import '../../../core/widgets/widgets.dart';
import '../../flashcards/views/session_result.dart';
import '../view_models/quiz_view_model.dart';

/// The keycap letters on the four options, in order.
const List<String> _kLetters = <String>['A', 'B', 'C', 'D'];

/// `A`–`D` and `1`–`4` both pick an option, as on the web.
const Map<String, int> _kKeyToIndex = <String, int>{
  'a': 0,
  'b': 1,
  'c': 2,
  'd': 3,
  '1': 0,
  '2': 1,
  '3': 2,
  '4': 3,
};

/// `m:ss`, with the seconds zero-padded — the TS's `formatDuration`.
String _formatDuration(int ms) {
  final int total = ((ms / 1000) + 0.5).floor();
  final int safe = total < 0 ? 0 : total;
  final int minutes = safe ~/ 60;
  final int seconds = safe % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

class QuizPage extends StatefulWidget {
  const QuizPage({super.key, this.controller});

  /// Owned by the shell, so the page scroll position survives a page switch.
  final ScrollController? controller;

  @override
  State<QuizPage> createState() => _QuizPageState();
}

class _QuizPageState extends State<QuizPage> {
  /// Built here rather than in the field initialiser: it needs the store, which
  /// is only reachable once the page is mounted under a [StoreScope].
  late final QuizViewModel _vm;

  final FocusNode _focus = FocusNode(debugLabel: 'quiz-page');

  @override
  void initState() {
    super.initState();
    _vm = QuizViewModel(
      store: context.store,
      feedback: ContextFeedback(context),
      // The one thing the view model cannot do itself: the real `speakWord`
      // needs a `BuildContext` for the settings and the listen counter.
      speak: (Word word) => speakWord(context, word),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _vm.dispose();
    _focus.dispose();
    // A clip started from the prompt or a review row would otherwise keep
    // talking after the user has left for another page.
    appSpeech.stop();
    super.dispose();
  }

  /* ------------------------------------------------------------------ */
  /* Keyboard                                                            */
  /* ------------------------------------------------------------------ */

  Map<ShortcutActivator, VoidCallback> _bindings() {
    if (_vm.phase != QuizPhase.active) {
      return const <ShortcutActivator, VoidCallback>{};
    }
    return <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.enter): () {
        if (_vm.selected != null) _vm.goNext();
      },
      const SingleActivator(LogicalKeyboardKey.numpadEnter): () {
        if (_vm.selected != null) _vm.goNext();
      },
      for (final MapEntry<String, int> e in _kKeyToIndex.entries)
        SingleActivator(_keyFor(e.key)): () => _vm.choose(e.value),
    };
  }

  static LogicalKeyboardKey _keyFor(String key) => switch (key) {
        'a' => LogicalKeyboardKey.keyA,
        'b' => LogicalKeyboardKey.keyB,
        'c' => LogicalKeyboardKey.keyC,
        'd' => LogicalKeyboardKey.keyD,
        '1' => LogicalKeyboardKey.digit1,
        '2' => LogicalKeyboardKey.digit2,
        '3' => LogicalKeyboardKey.digit3,
        _ => LogicalKeyboardKey.digit4,
      };

  /* ------------------------------------------------------------------ */
  /* Build                                                               */
  /* ------------------------------------------------------------------ */

  @override
  Widget build(BuildContext context) {
    // One listenable for the whole screen: the view model notifies on every
    // round mutation and on every store write it subscribed to, so this single
    // builder is the only place the page reads state from.
    return ListenableBuilder(
      listenable: _vm,
      builder: (BuildContext context, Widget? _) => _build(context),
    );
  }

  /// Layout only: every value below is a getter on [_vm].
  Widget _build(BuildContext context) {
    final String Function(String, [Map<String, Object>?]) t = context.t;

    final SessionProgress? progress = _vm.progress;
    final int total = _vm.total;
    final int score = _vm.score;
    final int answeredCount = _vm.answeredCount;
    final int questionNumber = _vm.questionNumber;
    final String questionLabel = questionNumber == 0
        ? ''
        : t('quiz.question', <String, Object>{'i': questionNumber, 'n': total});

    final String directionLabel = _vm.direction == QuizDirection.termToDef
        ? t('quiz.termToDef')
        : t('quiz.defToTerm');

    final Widget side = _sidePanel(
      t,
      eligibleCount: _vm.eligibleCount,
      questionLabel: questionLabel,
      score: score,
      answeredCount: answeredCount,
    );

    final QuizQuestion? current = _vm.current;

    final List<Widget> body;
    if (_vm.phase == QuizPhase.idle) {
      body = <Widget>[
        _idleState(t, directionLabel, _vm.eligibleCount, _vm.enough, side),
      ];
    } else if (_vm.phase == QuizPhase.active && current != null && progress != null) {
      body = <Widget>[
        _studySplit(
          main: _activeColumn(
            t,
            progress: progress,
            current: current,
            word: _vm.wordFor(current),
            questionLabel: questionLabel,
            directionLabel: directionLabel,
            score: score,
            side: side,
          ),
          side: side,
        ),
      ];
    } else {
      body = <Widget>[
        _studySplit(
          main: _doneColumn(
            t,
            accuracy: _vm.accuracy,
            score: score,
            answeredCount: answeredCount,
            ringMax: answeredCount > 1 ? answeredCount : 1,
            perfect: _vm.perfect,
            endedEarly: _vm.endedEarly,
            side: side,
          ),
          side: side,
        ),
      ];
    }

    return CallbackShortcuts(
      bindings: _bindings(),
      child: Focus(
        focusNode: _focus,
        child: PageShell(
          title: t('quiz.title'),
          subtitle: t('quiz.subtitle'),
          controller: widget.controller,
          // The direction picker is 237dp wide. Standing in the bar it left
          // 109dp for a 146dp subtitle, so "用主动回忆检验掌握程度" broke after
          // "用主动回忆检验" on every phone. On touch it moves into the card
          // below, which is where the choice actually belongs — it configures
          // the round the card is about to start, and the card already names
          // the direction in its own subtitle.
          actions: _vm.phase == QuizPhase.active
              ? LexButton(
                  label: t('quiz.finish'),
                  kind: BtnKind.quiet,
                  onPressed: _vm.requestFinish,
                )
              : context.isTouch
                  ? null
                  : Segmented<QuizDirection>(
                      value: _vm.direction,
                      options: <SegOption<QuizDirection>>[
                        SegOption<QuizDirection>(
                          value: QuizDirection.termToDef,
                          label: t('quiz.termToDef'),
                        ),
                        SegOption<QuizDirection>(
                          value: QuizDirection.defToTerm,
                          label: t('quiz.defToTerm'),
                        ),
                      ],
                      onChanged: (QuizDirection value) =>
                          _vm.setDirection(value),
                    ),
          children: body,
        ),
      ),
    );
  }

  /* ------------------------------------------------------------------ */
  /* State 1 — idle                                                      */
  /* ------------------------------------------------------------------ */

  Widget _idleState(
    String Function(String, [Map<String, Object>?]) t,
    String directionLabel,
    int eligibleCount,
    bool enough,
    Widget side,
  ) {
    if (!enough) {
      return _studySplit(
        main: Card(
          child: EmptyState(
            icon: Ic.quiz,
            title: t('quiz.noWords'),
            text: t('quiz.noWordsHint'),
            action: LexButton(
              label: t('words.addWord'),
              kind: BtnKind.primary,
              icon: Ic.plus,
              onPressed: context.canNavigate ? () => context.goTo('words') : null,
            ),
          ),
        ),
        side: side,
      );
    }

    final Palette p = Palette.of(context);
    final int count = QUIZ_ROUND < eligibleCount ? QUIZ_ROUND : eligibleCount;
    final Widget intro = Card(
      padding: const EdgeInsets.all(Sp.x7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          LexIcon(Ic.quiz, size: 26, color: p.ink4),
          const SizedBox(height: Sp.x4),
          Text(
            t('quiz.start'),
            style: TextStyle(
              fontFamily: Fonts.display,
              fontSize: Fs.x2xl,
              height: Lh.title,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.02,
              color: p.ink,
            ),
          ),
          const SizedBox(height: Sp.x2),
          Text(
            '$directionLabel · ${t('quiz.chooseCount')} $count',
            style: TextStyle(fontSize: Fs.base, height: Lh.loose, color: p.ink2),
          ),
          const SizedBox(height: Sp.x4),
          // On a phone the picker lives here rather than in the page bar; see
          // the `actions` comment above. It replaces the direction chip, which
          // said the same thing in less useful form — a chip reports, a picker
          // changes.
          if (context.isTouch) ...<Widget>[
            // Scrollable, not stretched: at a 2x accessibility text scale the
            // two labels measure ~388dp against the 305dp this column has, and
            // a RenderFlex overflowed by 83. The strip keeps its natural width
            // and scrolls instead of truncating a label it was built to show.
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Segmented<QuizDirection>(
                value: _vm.direction,
                options: <SegOption<QuizDirection>>[
                  SegOption<QuizDirection>(
                    value: QuizDirection.termToDef,
                    label: t('quiz.termToDef'),
                  ),
                  SegOption<QuizDirection>(
                    value: QuizDirection.defToTerm,
                    label: t('quiz.defToTerm'),
                  ),
                ],
                onChanged: (QuizDirection value) => _vm.setDirection(value),
              ),
            ),
            const SizedBox(height: Sp.x4),
          ],
          Wrap(
            spacing: Sp.x2,
            runSpacing: Sp.x2,
            children: <Widget>[
              if (!context.isTouch) StatusChip(label: directionLabel, tone: 'meta'),
              StatusChip(
                label: t('quiz.eligible', <String, Object>{'n': eligibleCount}),
                tone: 'new',
              ),
            ],
          ),
          const SizedBox(height: Sp.x4),
          Row(
            children: <Widget>[
              LexButton(
                label: t('quiz.start'),
                kind: BtnKind.primary,
                size: BtnSize.lg,
                onPressed: () => _vm.start(_vm.direction),
                trailing: LexIcon(Ic.arrowRight, size: 17, color: p.onAccent),
              ),
            ],
          ),
          if (context.showsKeyHints) ...<Widget>[
            const SizedBox(height: Sp.x3),
            Text(
              t('quiz.keyboardHint'),
              style: TextStyle(fontSize: Fs.xs, height: Lh.body, color: p.ink3),
            ),
          ],
        ],
      ),
    );

    return _studySplit(
      main: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[intro]),
      side: side,
    );
  }

  /* ------------------------------------------------------------------ */
  /* State 2 — in a round                                                */
  /* ------------------------------------------------------------------ */

  Widget _activeColumn(
    String Function(String, [Map<String, Object>?]) t, {
    required SessionProgress progress,
    required QuizQuestion current,
    required Word? word,
    required String questionLabel,
    required String directionLabel,
    required int score,
    required Widget side,
  }) {
    final Palette p = Palette.of(context);
    final bool answered = _vm.answered;
    final bool isCorrect = _vm.selected == current.answerIndex;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              questionLabel,
              style: TextStyle(
                fontFamily: Fonts.mono,
                fontSize: Fs.xs,
                height: Lh.tight,
                color: p.ink3,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: Sp.x2),
            StatusChip(label: directionLabel, tone: 'meta'),
            const Spacer(),
            StatusChip(label: '${t('quiz.score')} $score', tone: 'reviewed'),
          ],
        ),
        const SizedBox(height: Sp.x2),
        ProgressBar(
          value: progress.index.toDouble(),
          max: progress.total.toDouble(),
          thick: true,
        ),
        const SizedBox(height: Sp.x4),
        // The prompt is the question-asking surface, not a card with a body.
        Card(
          padding: const EdgeInsets.all(Sp.x6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text(
                    _vm.direction == QuizDirection.termToDef
                        ? t('flashcards.front')
                        : t('flashcards.back'),
                    style: TextStyle(fontSize: Fs.xs, height: Lh.tight, color: p.ink3),
                  ),
                  const Spacer(),
                  // Only the term is worth hearing: on a definition→term round
                  // the prompt is a gloss, and reading Chinese aloud in an
                  // English voice would be worse than silence. The web build
                  // offered the button in both directions and let the engine
                  // sort it out; skipping it here is the narrower lie.
                  if (speechAvailable && word != null && _vm.direction == QuizDirection.termToDef)
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
              const SizedBox(height: Sp.x3),
              Text(
                current.prompt,
                style: TextStyle(
                  fontFamily: Fonts.display,
                  fontSize: _vm.direction == QuizDirection.termToDef
                      ? (MediaQuery.sizeOf(context).width * 0.036).clamp(26.0, 38.0)
                      : (MediaQuery.sizeOf(context).width * 0.024).clamp(19.0, 24.0),
                  height: Lh.snug,
                  letterSpacing: -0.015,
                  color: p.ink,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Sp.x4),
        _options(current),
        const SizedBox(height: Sp.x4),
        if (answered)
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Expanded(
                child: _QuizNotice(
                  ok: isCorrect,
                  text: isCorrect
                      ? t('quiz.correct')
                      : '${t('quiz.wrong')} · ${t('quiz.correctAnswer')}：'
                          '${current.options[current.answerIndex]}',
                ),
              ),
              const SizedBox(width: Sp.x3),
              LexButton(
                label: progress.done ? t('quiz.finish') : t('quiz.next'),
                kind: BtnKind.primary,
                onPressed: _vm.goNext,
                trailing: context.showsKeyHints ? const Kbd('Enter') : null,
              ),
            ],
          )
        else
          _choiceHint(t, p),
      ],
    );
  }

  Widget _options(QuizQuestion current) {
    final bool answered = _vm.answered;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // `repeat(auto-fit, minmax(240px, 1fr))` from the stylesheet: as many
        // 240px columns as fit, at least one.
        final double usable = constraints.maxWidth;
        int columns = ((usable + Sp.x3) / (240 + Sp.x3)).floor();
        if (columns < 1) columns = 1;
        if (columns > current.options.length) columns = current.options.length;

        final List<Widget> cells = <Widget>[
          for (int i = 0; i < current.options.length; i++)
            _OptionButton(
              letter: i < _kLetters.length ? _kLetters[i] : '${i + 1}',
              text: current.options[i],
              state: !answered
                  ? _OptionState.idle
                  : i == current.answerIndex
                      ? _OptionState.correct
                      : i == _vm.selected
                          ? _OptionState.wrong
                          : _OptionState.dim,
              onPressed: answered ? null : () => _vm.choose(i),
            ),
        ];

        final List<Widget> rows = <Widget>[];
        for (int start = 0; start < cells.length; start += columns) {
          final List<Widget> row = <Widget>[];
          for (int i = start; i < start + columns && i < cells.length; i++) {
            if (i > start) row.add(const SizedBox(width: Sp.x3));
            row.add(Expanded(child: cells[i]));
          }
          // Keep the last, short row's cells the same width as the ones above.
          for (int i = start + columns; i < (start ~/ columns + 1) * columns; i++) {
            row.add(const SizedBox(width: Sp.x3));
            row.add(const Expanded(child: SizedBox.shrink()));
          }
          if (rows.isNotEmpty) rows.add(const SizedBox(height: Sp.x3));
          // `stretch` equalises the height of the answers in a row, which is
          // what makes a grid of wrapped definitions look deliberate. It needs
          // a bounded height to do that, and this column lives inside the
          // page's scroll view where the height is unbounded — hence the
          // IntrinsicHeight, which measures the tallest cell first.
          rows.add(IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: row,
            ),
          ));
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
      },
    );
  }

  Widget _choiceHint(
    String Function(String, [Map<String, Object>?]) t,
    Palette p,
  ) {
    // "A B C D / 1 2 3 4 to choose" is nothing but a keyboard legend; with no
    // hardware keyboard the row is dead weight above the answers.
    if (!context.showsKeyHints) return const SizedBox.shrink();
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: Sp.x1,
      runSpacing: Sp.x1,
      children: <Widget>[
        for (final String letter in _kLetters) Kbd(letter),
        Text(' / ', style: TextStyle(fontSize: Fs.xs, color: p.ink3)),
        for (int i = 1; i <= 4; i++) Kbd('$i'),
        const SizedBox(width: Sp.x2),
        Text(
          t('quiz.chooseHintSuffix'),
          style: TextStyle(fontSize: Fs.xs, height: Lh.tight, color: p.ink3),
        ),
      ],
    );
  }

  /* ------------------------------------------------------------------ */
  /* State 3 — results                                                   */
  /* ------------------------------------------------------------------ */

  Widget _doneColumn(
    String Function(String, [Map<String, Object>?]) t, {
    required double accuracy,
    required int score,
    required int answeredCount,
    required int ringMax,
    required bool perfect,
    required bool endedEarly,
    required Widget side,
  }) {
    final Palette p = Palette.of(context);
    final List<QuizMistake> mistakes = _vm.mistakes;
    final String title = perfect
        ? t('quiz.perfect')
        : endedEarly
            ? t('quiz.endedEarly')
            : t('quiz.keepGoing');

    final Widget summary = SessionResult(
      accuracy: accuracy,
      ringValue: score.toDouble(),
      ringMax: ringMax.toDouble(),
      ringSize: 140,
      accuracyLabel: t('quiz.accuracy'),
      title: title,
      text: t('quiz.result'),
      leftStat: StatTile(
        label: t('quiz.score'),
        value: '$score / $answeredCount',
        sub: answeredCount < _vm.questionCount
            ? t('quiz.answeredCount', <String, Object>{
                'n': answeredCount,
                'total': _vm.questionCount,
              })
            : null,
      ),
      rightStat: StatTile(
        label: t('quiz.timeSpent'),
        value: _formatDuration(_vm.elapsed),
      ),
      actions: <Widget>[
        LexButton(
          label: t('quiz.again'),
          kind: BtnKind.primary,
          size: BtnSize.lg,
          onPressed: () => _vm.start(_vm.direction),
          trailing: LexIcon(Ic.refresh, size: 16, color: p.onAccent),
        ),
        LexButton(
          label: t('quiz.exit'),
          kind: BtnKind.quiet,
          onPressed: _vm.exitToIdle,
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        summary,
        if (mistakes.isNotEmpty) ...<Widget>[
          const SizedBox(height: Sp.x4),
          _MistakeCard(t: t, mistakes: mistakes),
        ],
      ],
    );
  }

  /* ------------------------------------------------------------------ */
  /* Side panel                                                          */
  /* ------------------------------------------------------------------ */

  Widget _sidePanel(
    String Function(String, [Map<String, Object>?]) t, {
    required int eligibleCount,
    required String questionLabel,
    required int score,
    required int answeredCount,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        StatTile(
          label: t('quiz.score'),
          value: '$score / $answeredCount',
          sub: questionLabel.isEmpty
              ? t('quiz.eligible', <String, Object>{'n': eligibleCount})
              : questionLabel,
          icon: Ic.target,
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
                ShortcutRow(keys: const <String>['A', 'B', 'C', 'D'], label: t('quiz.chooseAnswer')),
                ShortcutRow(keys: const <String>['1', '2', '3', '4'], label: t('quiz.chooseAnswerNum')),
                ShortcutRow(keys: const <String>['Enter'], label: t('quiz.next')),
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

enum _OptionState { idle, correct, wrong, dim }

/// One of the four answers. The keycap says which key picks it; the trailing
/// mark says which one was right once the round has moved on.
class _OptionButton extends StatefulWidget {
  const _OptionButton({
    required this.letter,
    required this.text,
    required this.state,
    required this.onPressed,
  });

  final String letter;
  final String text;
  final _OptionState state;
  final VoidCallback? onPressed;

  @override
  State<_OptionButton> createState() => _OptionButtonState();
}

class _OptionButtonState extends State<_OptionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);
    final bool enabled = widget.onPressed != null;

    final (Color bg, Color line, Color fg, Color keyBg, Color keyFg) =
        switch (widget.state) {
      _OptionState.correct => (p.accentSoft, p.accent, p.accentInk, p.accent, p.onAccent),
      _OptionState.wrong => (p.dangerSoft, p.danger, p.danger, p.danger, p.onDanger),
      _OptionState.dim => (p.surface2, p.line, p.ink3, p.surface2, p.ink3),
      _OptionState.idle => (
          _hover && enabled ? p.surfaceHover : p.surface,
          _hover && enabled ? p.accent : p.lineStrong,
          p.ink,
          p.surface2,
          p.ink3,
        ),
    };

    final Widget body = Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: R.borderSm,
        border: Border.all(color: line),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: keyBg,
              borderRadius: R.borderXs,
              border: Border.all(
                color: widget.state == _OptionState.idle && !_hover
                    ? p.lineStrong
                    : keyBg,
              ),
            ),
            child: Center(
              child: Text(
                widget.letter,
                style: TextStyle(
                  fontFamily: Fonts.mono,
                  fontSize: Fs.xs,
                  height: Lh.tight,
                  color: keyFg,
                ),
              ),
            ),
          ),
          const SizedBox(width: Sp.x3),
          Expanded(
            child: Text(
              widget.text,
              style: TextStyle(fontSize: Fs.md, height: Lh.body, color: fg),
            ),
          ),
          if (widget.state == _OptionState.correct) ...<Widget>[
            const SizedBox(width: Sp.x2),
            LexIcon(Ic.check, size: 16, color: p.accentInk),
          ],
          if (widget.state == _OptionState.wrong) ...<Widget>[
            const SizedBox(width: Sp.x2),
            LexIcon(Ic.x, size: 16, color: p.danger),
          ],
        ],
      ),
    );

    return Opacity(
      // `is-dim`: the options the reader did not pick fade back.
      opacity: widget.state == _OptionState.dim ? 0.55 : 1,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(onTap: widget.onPressed, child: body),
      ),
    );
  }
}

/// `.notice` for answer feedback: accent for a hit, danger for a miss.
class _QuizNotice extends StatelessWidget {
  const _QuizNotice({required this.ok, required this.text});

  final bool ok;
  final String text;

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x3),
      decoration: BoxDecoration(
        color: ok ? p.accentSoft : p.dangerSoft,
        borderRadius: R.borderSm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: LexIcon(ok ? Ic.check : Ic.x, size: 15, color: ok ? p.accentInk : p.danger),
          ),
          const SizedBox(width: Sp.x3),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: Fs.sm,
                height: Lh.body,
                color: ok ? p.accentInk : p.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The missed-words card: a flush card with a head row and one row per miss.
class _MistakeCard extends StatelessWidget {
  const _MistakeCard({required this.t, required this.mistakes});

  final String Function(String, [Map<String, Object>?]) t;
  final List<QuizMistake> mistakes;

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);
    return Card(
      padding: EdgeInsets.zero,
      tight: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Sp.x5, vertical: Sp.x4),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    t('quiz.missed'),
                    style: TextStyle(
                      fontSize: Fs.md,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.005,
                      color: p.ink,
                    ),
                  ),
                ),
                Text(
                  '${mistakes.length}',
                  style: TextStyle(fontSize: Fs.sm, height: Lh.tight, color: p.ink3),
                ),
              ],
            ),
          ),
          Container(height: 1, color: p.line),
          for (int i = 0; i < mistakes.length; i++) ...<Widget>[
            if (i > 0) Container(height: 1, color: p.line),
            _MistakeRow(t: t, mistake: mistakes[i]),
          ],
        ],
      ),
    );
  }
}

class _MistakeRow extends StatelessWidget {
  const _MistakeRow({required this.t, required this.mistake});

  final String Function(String, [Map<String, Object>?]) t;
  final QuizMistake mistake;

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);
    final QuizQuestion question = mistake.question;
    final int? answer = mistake.answer;
    final String yourAnswer = answer == null
        ? t('quiz.unanswered')
        : question.options[answer];
    final String correctAnswer = question.options[question.answerIndex];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x5, vertical: Sp.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            question.prompt,
            style: TextStyle(
              fontFamily: Fonts.display,
              fontSize: Fs.md,
              height: Lh.snug,
              fontWeight: FontWeight.w600,
              color: p.ink,
            ),
          ),
          const SizedBox(height: Sp.x1),
          Wrap(
            spacing: Sp.x2,
            runSpacing: Sp.x1,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Text.rich(
                TextSpan(
                  children: <InlineSpan>[
                    TextSpan(text: '${t('quiz.yourAnswer')}：'),
                    TextSpan(
                      text: yourAnswer,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: answer == null ? p.ink3 : p.danger,
                      ),
                    ),
                  ],
                ),
                style: TextStyle(fontSize: Fs.sm, height: Lh.tight, color: p.ink3),
              ),
              Text('·', style: TextStyle(fontSize: Fs.sm, color: p.ink3)),
              Text.rich(
                TextSpan(
                  children: <InlineSpan>[
                    TextSpan(text: '${t('quiz.correctAnswer')}：'),
                    TextSpan(
                      text: correctAnswer,
                      style: TextStyle(fontWeight: FontWeight.w600, color: p.accentInk),
                    ),
                  ],
                ),
                style: TextStyle(fontSize: Fs.sm, height: Lh.tight, color: p.ink3),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
