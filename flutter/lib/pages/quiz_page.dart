/// The multiple-choice quiz screen.
///
/// Ports `src/pages/study/QuizPage.tsx`. A round is a list of [QuizQuestion]s
/// built once by `domain/quiz.dart`; the page only walks them with a [Session]
/// so the score, the progress bar and "did this round finish" all come from the
/// same counters the flashcard page uses.
///
/// Two rules the TS encoded in comments and are kept here:
///
///   * while the feedback for an answer is on screen the session has already
///     moved past that question, so the card shown steps back one
///     ([_QuizPageState._currentIndex]);
///   * a correct answer glides on after 900 ms, but a miss stays put until the
///     correction has actually been read.
///
/// The prompt carries a 发音 button on a term→definition round only: hearing
/// the term is the point, whereas reading a Chinese gloss aloud in an English
/// voice would be worse than silence.
library;

import 'dart:async';

// `Card` is ours (ui/widgets.dart), not Material's.
import 'package:flutter/material.dart' hide Card;
import 'package:flutter/services.dart';

import '../app/scope.dart';
import '../design/tokens.dart';
import '../domain/quiz.dart';
import '../domain/session.dart';
import '../domain/types.dart';
import '../platform/speak_word.dart';
import '../platform/tts.dart' show appSpeech;
import '../ui/controls.dart';
import '../ui/keyboard_hints.dart';
import '../ui/lex_icon.dart';
import '../ui/widgets.dart';
import 'session_result.dart';

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

/// Which of the three screens the page is on.
enum _Phase { idle, active, done }

/// A question the reader got wrong, kept for the results card.
class _Mistake {
  const _Mistake({required this.question, required this.answer, required this.key});

  final QuizQuestion question;

  /// Which option was picked, or null when it was never answered.
  final int? answer;
  final String key;
}

class QuizPage extends StatefulWidget {
  const QuizPage({super.key, this.controller});

  /// Owned by the shell, so the page scroll position survives a page switch.
  final ScrollController? controller;

  @override
  State<QuizPage> createState() => _QuizPageState();
}

class _QuizPageState extends State<QuizPage> {
  QuizDirection _direction = QuizDirection.termToDef;
  _Phase _phase = _Phase.idle;
  List<QuizQuestion> _questions = <QuizQuestion>[];
  List<int?> _answers = <int?>[];
  int? _selected;
  int _elapsed = 0;
  Session? _session;
  SessionProgress? _progress;

  int _startedAt = 0;
  Timer? _advance;

  final FocusNode _focus = FocusNode(debugLabel: 'quiz-page');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _advance?.cancel();
    _focus.dispose();
    // A clip started from the prompt or a review row would otherwise keep
    // talking after the user has left for another page.
    appSpeech.stop();
    super.dispose();
  }

  /* ------------------------------------------------------------------ */
  /* Derived state                                                       */
  /* ------------------------------------------------------------------ */

  /// While the feedback is up the session has already advanced, so step back
  /// one to keep showing the question the answer belonged to.
  int get _currentIndex {
    final SessionProgress? progress = _progress;
    if (progress == null) return -1;
    return progress.index - (_selected != null ? 1 : 0);
  }

  QuizQuestion? get _current {
    final int i = _currentIndex;
    if (_phase != _Phase.active || i < 0 || i >= _questions.length) return null;
    return _questions[i];
  }

  /// The 发音 button on the prompt and on the review rows.
  ///
  /// Counts the listen, unlike the flashcard auto-play: both of these are an
  /// explicit press.
  void _playWord(Word word) => speakWord(context, word);

  /// The word a question asks about, or `null` when it was deleted mid-round.
  ///
  /// Quiz rows store a `wordId`, not the word, so the prompt's 发音 button has
  /// to look it up. The web build built the same map (`wordById`); here the
  /// lookup is linear because the deck is small and this runs once per build
  /// rather than once per row.
  Word? _wordFor(QuizQuestion question, AppData data) {
    for (final Word word in data.words) {
      if (word.id == question.wordId) return word;
    }
    return null;
  }

  List<_Mistake> get _mistakes {
    final List<_Mistake> out = <_Mistake>[];
    for (int i = 0; i < _questions.length; i++) {
      final QuizQuestion question = _questions[i];
      final int? answer = i < _answers.length ? _answers[i] : null;
      if (answer != question.answerIndex) {
        out.add(_Mistake(
          question: question,
          answer: answer,
          key: '${question.wordId}-$i',
        ));
      }
    }
    return out;
  }

  /* ------------------------------------------------------------------ */
  /* Actions                                                             */
  /* ------------------------------------------------------------------ */

  void _finish() {
    _advance?.cancel();
    _advance = null;
    setState(() {
      _elapsed = DateTime.now().millisecondsSinceEpoch - _startedAt;
      _phase = _Phase.done;
    });
  }

  Future<void> _requestFinish() async {
    final SessionProgress? progress = _session?.progress();
    if (progress != null && progress.reviewed > 0 && !progress.done) {
      final bool ok = await confirmLex(
        context,
        title: context.t('quiz.exitTitle'),
        subtitle: context.t('quiz.exitConfirm'),
        confirmLabel: context.t('quiz.exit'),
        cancelLabel: context.t('common.cancel'),
      );
      if (!ok || !mounted) return;
      _finish();
      return;
    }
    _finish();
  }

  void _goNext() {
    _advance?.cancel();
    _advance = null;
    // Ask the session rather than the rendered state: the feedback timer fires
    // after the last answer has already advanced it.
    final Session? session = _session;
    if (session == null || session.progress().done) {
      _finish();
      return;
    }
    setState(() => _selected = null);
  }

  void _start(QuizDirection direction) {
    final List<QuizQuestion> built =
        buildQuiz(context.data.words, direction, count: QUIZ_ROUND);
    if (built.isEmpty) {
      context.toast(context.t('quiz.noWords'), ToastKind.info);
      return;
    }
    final Session session = createSession(
      ids: built.map((QuizQuestion q) => q.wordId).toList(),
    );
    _advance?.cancel();
    _advance = null;
    setState(() {
      _session = session;
      _questions = built;
      _answers = List<int?>.filled(built.length, null);
      _selected = null;
      _elapsed = 0;
      _progress = session.progress();
      _startedAt = DateTime.now().millisecondsSinceEpoch;
      _phase = _Phase.active;
    });
  }

  void _choose(int option) {
    final Session? session = _session;
    if (_selected != null || session == null) return;
    final int position = session.progress().index;
    if (position < 0 || position >= _questions.length) return;
    final QuizQuestion question = _questions[position];
    final bool isCorrect = option == question.answerIndex;
    setState(() {
      _selected = option;
      final List<int?> next = List<int?>.of(_answers);
      if (position < next.length) next[position] = option;
      _answers = next;
    });
    session.record(correct: isCorrect);
    setState(() => _progress = session.progress());
    // A correct answer may glide on; a miss must stay put until the correction
    // has actually been read.
    if (isCorrect) {
      _advance = Timer(const Duration(milliseconds: 900), () {
        _advance = null;
        if (mounted) _goNext();
      });
    }
  }

  void _exitToIdle() {
    _advance?.cancel();
    _advance = null;
    setState(() {
      _session = null;
      _phase = _Phase.idle;
      _questions = <QuizQuestion>[];
      _answers = <int?>[];
      _selected = null;
      _progress = null;
    });
  }

  /* ------------------------------------------------------------------ */
  /* Keyboard                                                            */
  /* ------------------------------------------------------------------ */

  Map<ShortcutActivator, VoidCallback> _bindings() {
    if (_phase != _Phase.active) {
      return const <ShortcutActivator, VoidCallback>{};
    }
    return <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.enter): () {
        if (_selected != null) _goNext();
      },
      const SingleActivator(LogicalKeyboardKey.numpadEnter): () {
        if (_selected != null) _goNext();
      },
      for (final MapEntry<String, int> e in _kKeyToIndex.entries)
        SingleActivator(_keyFor(e.key)): () => _choose(e.value),
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
    final AppData data = context.data;
    final String Function(String, [Map<String, Object>?]) t = context.t;
    final List<Word> eligible = quizEligibleWords(data.words);
    final int eligibleCount = eligible.length;
    final bool enough = eligibleCount >= QUIZ_CHOICES;

    final SessionProgress? progress = _progress;
    final int total = progress?.total ?? 0;
    final int score = progress?.correct ?? 0;
    final int answeredCount = progress?.reviewed ?? 0;
    final double accuracy = answeredCount > 0 ? score / answeredCount : 0;
    final bool perfect = answeredCount > 0 &&
        answeredCount == _questions.length &&
        score == answeredCount;
    final bool endedEarly = answeredCount > 0 && answeredCount < _questions.length;
    final bool answered = _selected != null;
    final int questionNumber =
        progress == null || progress.total == 0 || _phase == _Phase.done
            ? 0
            : (progress.index + (answered ? 0 : 1)).clamp(0, progress.total);
    final String questionLabel = questionNumber == 0
        ? ''
        : t('quiz.question', <String, Object>{'i': questionNumber, 'n': total});

    final String directionLabel = _direction == QuizDirection.termToDef
        ? t('quiz.termToDef')
        : t('quiz.defToTerm');

    final Widget side = _sidePanel(
      t,
      eligibleCount: eligibleCount,
      questionLabel: questionLabel,
      score: score,
      answeredCount: answeredCount,
    );

    final QuizQuestion? current = _current;

    final List<Widget> body;
    if (_phase == _Phase.idle) {
      body = <Widget>[_idleState(t, directionLabel, eligibleCount, enough, side)];
    } else if (_phase == _Phase.active && current != null && progress != null) {
      body = <Widget>[
        _studySplit(
          main: _activeColumn(
            t,
            progress: progress,
            current: current,
            word: _wordFor(current, data),
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
            accuracy: accuracy,
            score: score,
            answeredCount: answeredCount,
            ringMax: answeredCount > 1 ? answeredCount : 1,
            perfect: perfect,
            endedEarly: endedEarly,
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
          actions: _phase == _Phase.active
              ? LexButton(
                  label: t('quiz.finish'),
                  kind: BtnKind.quiet,
                  onPressed: _requestFinish,
                )
              : Segmented<QuizDirection>(
                  value: _direction,
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
                      setState(() => _direction = value),
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
          Wrap(
            spacing: Sp.x2,
            runSpacing: Sp.x2,
            children: <Widget>[
              StatusChip(label: directionLabel, tone: 'meta'),
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
                onPressed: () => _start(_direction),
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
    final bool answered = _selected != null;
    final bool isCorrect = _selected == current.answerIndex;

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
                    _direction == QuizDirection.termToDef
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
                  if (speechAvailable && word != null && _direction == QuizDirection.termToDef)
                    Tooltip(
                      message: t('flashcards.autoPlay'),
                      child: LexButton(
                        label: '',
                        icon: Ic.volume,
                        kind: BtnKind.quiet,
                        size: BtnSize.sm,
                        onPressed: () => _playWord(word),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: Sp.x3),
              Text(
                current.prompt,
                style: TextStyle(
                  fontFamily: Fonts.display,
                  fontSize: _direction == QuizDirection.termToDef
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
                onPressed: _goNext,
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
    final bool answered = _selected != null;
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
                      : i == _selected
                          ? _OptionState.wrong
                          : _OptionState.dim,
              onPressed: answered ? null : () => _choose(i),
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
    final List<_Mistake> mistakes = _mistakes;
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
        sub: answeredCount < _questions.length
            ? t('quiz.answeredCount', <String, Object>{
                'n': answeredCount,
                'total': _questions.length,
              })
            : null,
      ),
      rightStat: StatTile(
        label: t('quiz.timeSpent'),
        value: _formatDuration(_elapsed),
      ),
      actions: <Widget>[
        LexButton(
          label: t('quiz.again'),
          kind: BtnKind.primary,
          size: BtnSize.lg,
          onPressed: () => _start(_direction),
          trailing: LexIcon(Ic.refresh, size: 16, color: p.onAccent),
        ),
        LexButton(
          label: t('quiz.exit'),
          kind: BtnKind.quiet,
          onPressed: _exitToIdle,
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
  final List<_Mistake> mistakes;

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
  final _Mistake mistake;

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
