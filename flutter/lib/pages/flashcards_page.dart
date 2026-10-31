/// The flashcard review screen.
///
/// Ports `src/pages/study/FlashcardsPage.tsx`. Three states live in one page —
/// deck picker, the card in hand, and the finished-session card — because they
/// are three faces of one session, and splitting them into routes would mean
/// passing the session object through the shell.
///
/// Two things are deliberate:
///
///   * the deck is *derived* on every build (`_buildSession`) rather than kept
///     in state, so a grade written to the store immediately changes what "due
///     today" means without a second source of truth;
///   * the store-side undo lives here, not in `domain/session.dart`: the session
///     owns the counters, this page snapshots the schedule it is about to
///     overwrite so "undo" can put the card back exactly as it was.
///
/// Audio follows the web build's two rules: a card that is *listening mode*
/// speaks as soon as it appears, and an ordinary card speaks when it is
/// revealed if `autoPlayAudio` is on. Both go through [_maybeAutoPlay], which
/// dedupes on `word:index:face` so a rebuild — of which there are many, since
/// every store write rebuilds this page — cannot repeat a clip. Only an
/// explicit 发音 press bumps the listen count.
library;

import 'dart:async';

// `Card` is ours (ui/widgets.dart), not Material's.
// `Step` is also a Material widget (the stepper's); ours is the session step.
import 'package:flutter/material.dart' hide Card, Step;
import 'package:flutter/services.dart';

import '../app/scope.dart';
import '../data/store.dart' show GradeResult, dueWords;
import '../design/tokens.dart';
import '../domain/day_stats.dart';
import '../domain/session.dart';
import '../domain/srs.dart';
import '../domain/types.dart';
import '../domain/utils.dart';
import '../platform/speak_word.dart';
import '../platform/tts.dart' show appSpeech;
import '../ui/controls.dart';
import '../ui/keyboard_hints.dart';
import '../ui/lex_icon.dart';
import '../ui/widgets.dart';
import 'session_result.dart';

/// The three grade buttons, in the order the keyboard maps them to 1/2/3.
const List<Grade> _kGrades = <Grade>[Grade.hard, Grade.good, Grade.easy];

const Map<Grade, String> _kGradeLabelKey = <Grade, String>{
  Grade.hard: 'flashcards.gradeHard',
  Grade.good: 'flashcards.gradeGood',
  Grade.easy: 'flashcards.gradeEasy',
};

/// Sorting sentinel for a card with no schedule — `Number.MAX_SAFE_INTEGER` in
/// the TS, kept identical so an unscheduled card sorts last.
const int _kNoDueAt = 9007199254740991;

/// Where the cards in a session come from. `new` is a reserved word in Dart, so
/// the enum member is [fresh] while the wire value and the i18n key stay `new`.
enum _DeckSource { due, fresh, all, favorites }

const Map<_DeckSource, String> _kDeckLabelKey = <_DeckSource, String>{
  _DeckSource.due: 'flashcards.deckDue',
  _DeckSource.fresh: 'flashcards.deckNew',
  _DeckSource.all: 'flashcards.deckAll',
  _DeckSource.favorites: 'flashcards.deckFavorites',
};

/// How many brand-new cards the daily allowance still has room for.
int _newCardsLeft(AppData data, int now) {
  final int start = startOfDay(now);
  /* A card counts as "introduced today" when its earliest review log is from
     today. Deriving this from logs (rather than reviewCount == 1) keeps the
     count stable even if a fresh card is graded twice in one day, and undoing a
     first grade restores the allowance naturally. */
  final Map<String, int> firstReviewAt = <String, int>{};
  for (final ReviewLog log in data.logs) {
    final int? prev = firstReviewAt[log.wordId];
    if (prev == null || log.at < prev) firstReviewAt[log.wordId] = log.at;
  }
  final int introduced = data.words.where((Word word) {
    final int? at = firstReviewAt[word.id];
    return at != null && at >= start;
  }).length;
  final int left = data.settings.newCardsPerDay - introduced;
  return left < 0 ? 0 : left;
}

/// Card ids for a session, ordered by the user's review-order setting.
List<String> _buildSession(AppData data, int now, _DeckSource source) {
  switch (source) {
    case _DeckSource.all:
      return shuffle(data.words).map((Word w) => w.id).toList();
    case _DeckSource.favorites:
      return shuffle(data.words.where((Word w) => w.favorite).toList())
          .map((Word w) => w.id)
          .toList();
    case _DeckSource.fresh:
      final int left = _newCardsLeft(data, now);
      return data.words
          .where((Word w) => isNew(w.srs))
          .take(left)
          .map((Word w) => w.id)
          .toList();
    case _DeckSource.due:
      final List<Word> due = dueWords(data, now);
      final List<Word> review = due.where((Word w) => !isNew(w.srs)).toList();
      final List<Word> fresh = due
          .where((Word w) => isNew(w.srs))
          .take(_newCardsLeft(data, now))
          .toList();
      if (data.settings.reviewOrder == 'random') {
        return shuffle(<Word>[...review, ...fresh]).map((Word w) => w.id).toList();
      }
      final List<Word> ordered = review.toList()
        ..sort((Word a, Word b) {
          final int x = a.srs?.dueAt ?? _kNoDueAt;
          final y = b.srs?.dueAt ?? _kNoDueAt;
          return x.compareTo(y);
        });
      return <Word>[...ordered, ...fresh].map((Word w) => w.id).toList();
  }
}

/// What the page renders of the session. The session itself is a mutable
/// object, so we take a snapshot after every step to give `setState` a new
/// value to rebuild from.
class _View {
  const _View({required this.progress, required this.current, required this.canUndo});

  final SessionProgress progress;
  final String? current;
  final bool canUndo;
}

/// Store-side half of an undo: the schedule and status the last grade
/// overwrote.
class _StoreStep {
  const _StoreStep({
    required this.id,
    required this.prevSrs,
    required this.prevStatus,
    required this.logId,
  });

  final String id;
  final SrsState? prevSrs;
  final WordStatus prevStatus;
  final String logId;
}

class FlashcardsPage extends StatefulWidget {
  const FlashcardsPage({super.key, this.controller});

  /// Owned by the shell, so the page scroll position survives a page switch.
  final ScrollController? controller;

  @override
  State<FlashcardsPage> createState() => _FlashcardsPageState();
}

class _FlashcardsPageState extends State<FlashcardsPage> {
  _DeckSource _deck = _DeckSource.due;
  Session? _session;
  _View? _view;
  bool _flipped = false;

  /// `'out'` while the front turns away, `'in'` while the answer turns in,
  /// `null` at rest — the TS's `'idle' | 'out' | 'in'`.
  String? _turn;
  List<_StoreStep> _storeSteps = <_StoreStep>[];

  Timer? _turnOut;
  Timer? _turnIn;

  final FocusNode _focus = FocusNode(debugLabel: 'flashcards-page');

  /// The `word:index:face` token of the last clip auto-play started, so a
  /// rebuild cannot repeat it. The web build used a ref for the same reason.
  String? _spoken;

  @override
  void initState() {
    super.initState();
    // The page owns the keyboard while it is open; a focusable node is the only
    // way Flutter delivers key events to `CallbackShortcuts` below.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _turnOut?.cancel();
    _turnIn?.cancel();
    _focus.dispose();
    // Leaving the page mid-sentence would talk over whatever comes next.
    appSpeech.stop();
    super.dispose();
  }

  /* ------------------------------------------------------------------ */
  /* Session plumbing                                                    */
  /* ------------------------------------------------------------------ */

  void _sync() {
    final Session? session = _session;
    setState(() {
      _view = session == null
          ? null
          : _View(
              progress: session.progress(),
              current: session.current(),
              canUndo: session.canUndo(),
            );
    });
  }

  void _clearTurn() {
    _turnOut?.cancel();
    _turnIn?.cancel();
    _turnOut = null;
    _turnIn = null;
  }

  void _resetFlip() {
    _clearTurn();
    setState(() {
      _turn = null;
      _flipped = false;
    });
  }

  void _reveal() {
    if (_flipped || _turn != null) return;
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      setState(() => _flipped = true);
      return;
    }
    setState(() => _turn = 'out');
    _turnOut = Timer(const Duration(milliseconds: 125), () {
      if (!mounted) return;
      setState(() {
        _flipped = true;
        _turn = 'in';
      });
      _turnIn = Timer(const Duration(milliseconds: 190), () {
        if (!mounted) return;
        setState(() => _turn = null);
      });
    });
  }

  void _startSession() {
    final List<String> ids =
        _buildSession(context.data, DateTime.now().millisecondsSinceEpoch, _deck);
    _clearTurn();
    _storeSteps = <_StoreStep>[];
    _spoken = null;
    setState(() {
      _flipped = false;
      _turn = null;
      _session = ids.isEmpty ? null : createSession(ids: ids);
    });
    _sync();
  }

  void _exitSession() {
    _clearTurn();
    appSpeech.stop();
    _spoken = null;
    setState(() {
      _session = null;
      _view = null;
      _flipped = false;
      _turn = null;
      _storeSteps = <_StoreStep>[];
    });
  }

  void _grade(Grade value) {
    final Word? word = _currentWord(context.data);
    final Session? session = _session;
    if (word == null || session == null) return;
    final SrsState? prevSrs = word.srs;
    final WordStatus prevStatus = word.status;
    final GradeResult? result = context.store.gradeWord(word.id, value);
    if (result == null) return;
    _storeSteps.add(_StoreStep(
      id: word.id,
      prevSrs: prevSrs,
      prevStatus: prevStatus,
      logId: result.logId,
    ));
    session.record(correct: gradeCountsAsCorrect(value));
    _sync();
    _resetFlip();
  }

  void _skip() {
    final Session? session = _session;
    if (session == null) return;
    session.skip();
    _sync();
    _resetFlip();
  }

  void _undo() {
    final Session? session = _session;
    if (session == null) return;
    final Step? step = session.undo();
    if (step == null) return;
    if (step is RecordStep) {
      final _StoreStep? storeStep =
          _storeSteps.isEmpty ? null : _storeSteps.removeLast();
      if (storeStep != null) {
        context.store.undoReview(
          storeStep.id,
          storeStep.prevSrs,
          storeStep.prevStatus,
          storeStep.logId,
        );
      }
      _clearTurn();
      setState(() {
        _turn = null;
        _flipped = true;
      });
    } else {
      setState(() => _flipped = false);
    }
    _sync();
  }

  Future<void> _requestExit() async {
    final String exitLabel = context.t('flashcards.exit');
    final SessionProgress? progress = _view?.progress;
    if (progress != null && progress.reviewed > 0 && !progress.done) {
      final int remaining = progress.total - progress.index;
      final bool ok = await confirmLex(
        context,
        title: exitLabel,
        subtitle: context.t('flashcards.exitConfirm', <String, Object>{
          'n': remaining < 0 ? 0 : remaining,
        }),
        confirmLabel: exitLabel,
        cancelLabel: context.t('common.cancel'),
      );
      if (!ok || !mounted) return;
      _confirmExitNow();
      return;
    }
    _exitSession();
  }

  void _confirmExitNow() {
    final int reviewed = _session?.progress().reviewed ?? 0;
    _exitSession();
    if (reviewed > 0) {
      context.toast(
        context.t('flashcards.exitSaved', <String, Object>{'n': reviewed}),
        ToastKind.ok,
      );
    }
  }

  Word? _currentWord(AppData data) {
    final String? id = _view?.current;
    if (id == null) return null;
    for (final Word word in data.words) {
      if (word.id == id) return word;
    }
    return null;
  }

  /// The 发音 button: says the word and counts the listen.
  void _playWord(Word word) {
    speakWord(context, word);
  }

  /// Starts the automatic clip for the card now on screen, if this face is
  /// meant to be heard.
  ///
  /// Called from `build` through a post-frame callback rather than from
  /// `_reveal` / `_sync`: the settings it depends on live in the store, and a
  /// page that started speech from a setState would talk over the flip
  /// animation. The token makes it idempotent, so calling it on every frame is
  /// free.
  void _maybeAutoPlay(Word? word, SessionProgress? progress) {
    if (word == null || progress == null || progress.done) return;
    if (!speechAvailable) return;
    final Settings settings = context.data.settings;
    final bool listening = settings.audioFirst;
    final bool shouldSpeak =
        listening ? !_flipped : (_flipped && settings.autoPlayAudio);
    if (!shouldSpeak) return;
    final String token =
        '${word.id}:${progress.index}:${_flipped ? 'back' : 'front'}';
    if (_spoken == token) return;
    _spoken = token;
    // Cut the previous card's clip rather than queueing behind it: a review
    // that grades fast would otherwise hear a backlog of old terms.
    appSpeech.stop();
    speakTerm(context, word);
  }

  /* ------------------------------------------------------------------ */
  /* Keyboard                                                            */
  /* ------------------------------------------------------------------ */

  Map<ShortcutActivator, VoidCallback> _bindings() {
    return <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _undo,
      const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): _undo,
      // A focused button owns Space on the web; here the card is the only thing
      // Space can mean, so it always flips.
      const SingleActivator(LogicalKeyboardKey.space): () {
        if (!_inProgress) return;
        if (_flipped) {
          _resetFlip();
        } else {
          _reveal();
        }
      },
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
        if (_inProgress) _skip();
      },
      const SingleActivator(LogicalKeyboardKey.arrowRight): () {
        if (_inProgress) _skip();
      },
      const SingleActivator(LogicalKeyboardKey.digit1): () {
        if (_inProgress && _flipped) _grade(Grade.hard);
      },
      const SingleActivator(LogicalKeyboardKey.digit2): () {
        if (_inProgress && _flipped) _grade(Grade.good);
      },
      const SingleActivator(LogicalKeyboardKey.digit3): () {
        if (_inProgress && _flipped) _grade(Grade.easy);
      },
    };
  }

  bool get _inProgress => _view != null && !_view!.progress.done;

  /* ------------------------------------------------------------------ */
  /* Build                                                               */
  /* ------------------------------------------------------------------ */

  @override
  Widget build(BuildContext context) {
    final AppData data = context.data;
    final Settings settings = data.settings;
    final String Function(String, [Map<String, Object>?]) t = context.t;
    final int now = DateTime.now().millisecondsSinceEpoch;

    final List<Word> due = dueWords(data, now);
    final int dueReviewCount = due.where((Word w) => !isNew(w.srs)).length;
    final int dueFreshCount = due.where((Word w) => isNew(w.srs)).length;
    final int freshLeft = _newCardsLeft(data, now);
    final bool caughtUp = due.isEmpty;
    final bool hasNewWords = data.words.any((Word w) => isNew(w.srs));
    final bool capReached =
        settings.newCardsPerDay > 0 && freshLeft == 0 && hasNewWords;

    final int newWordCount = data.words.where((Word w) => isNew(w.srs)).length;
    final Map<_DeckSource, int> counts = <_DeckSource, int>{
      _DeckSource.due: dueReviewCount + (dueFreshCount < freshLeft ? dueFreshCount : freshLeft),
      _DeckSource.fresh: newWordCount < freshLeft ? newWordCount : freshLeft,
      _DeckSource.all: data.words.length,
      _DeckSource.favorites: data.words.where((Word w) => w.favorite).length,
    };
    final int deckSize = counts[_deck] ?? 0;

    final SessionProgress? progress = _view?.progress;
    final bool inProgress = progress != null && !progress.done;
    final Word? word = _currentWord(data);
    final bool newCard = word != null && isNew(word.srs);
    final Map<Grade, ({int intervalDays, WordStatus status})>? preview = word == null
        ? null
        : previewGrades(CardState(srs: word.srs, status: word.status), now);
    final int remaining =
        progress == null ? 0 : (progress.total - progress.index).clamp(0, progress.total);

    final Widget side = _sidePanel(t, data, settings, inProgress: inProgress, remaining: remaining, total: progress?.total ?? 0);

    // Auto-play is decided after the frame, so it runs once the face actually
    // on screen matches the card in hand — starting it here would speak the
    // *previous* card during a flip.
    if (inProgress) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeAutoPlay(word, progress);
      });
    }

    final List<Widget> body;
    if (progress == null) {
      body = <Widget>[_deckPickerState(t, data, settings, counts, deckSize, dueReviewCount, caughtUp, hasNewWords, capReached, side)];
    } else if (inProgress) {
      body = <Widget>[
        _studySplit(
          main: _sessionColumn(
            t,
            progress: progress,
            word: word,
            newCard: newCard,
            preview: preview,
            canUndo: _view?.canUndo ?? false,
            onGrade: _grade,
            onReveal: _reveal,
            onSkip: _skip,
            onUndo: _undo,
            onExit: _requestExit,
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
    Map<_DeckSource, int> counts,
    int deckSize,
    int dueReviewCount,
    bool caughtUp,
    bool hasNewWords,
    bool capReached,
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
            child: Segmented<_DeckSource>(
              value: _deck,
              options: <SegOption<_DeckSource>>[
                for (final _DeckSource s in _DeckSource.values)
                  SegOption<_DeckSource>(
                    value: s,
                    label: t(_kDeckLabelKey[s]!),
                    count: counts[s],
                  ),
              ],
              onChanged: (_DeckSource value) => setState(() => _deck = value),
            ),
          ),
          const SizedBox(height: Sp.x4),
          Wrap(
            spacing: Sp.x2,
            runSpacing: Sp.x2,
            children: <Widget>[
              StatusChip(
                label: t('flashcards.dueCount', <String, Object>{'n': dueReviewCount}),
                tone: 'learning',
              ),
              StatusChip(
                label: t('flashcards.newCount', <String, Object>{'n': counts[_DeckSource.fresh] ?? 0}),
                tone: 'new',
              ),
              StatusChip(
                label: t('flashcards.deckSize', <String, Object>{'n': deckSize}),
                tone: 'meta',
              ),
            ],
          ),
          if (capReached && !caughtUp) ...<Widget>[
            const SizedBox(height: Sp.x4),
            _Notice(
              text: t('flashcards.newCapReached', <String, Object>{
                'n': settings.newCardsPerDay,
              }),
            ),
          ],
          const SizedBox(height: Sp.x4),
          if (deckSize == 0)
            _emptyDeck(t, caughtUp)
          else
            Row(
              children: <Widget>[
                LexButton(
                  label: t('flashcards.start'),
                  size: BtnSize.lg,
                  kind: BtnKind.primary,
                  onPressed: _startSession,
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
              style: TextStyle(fontSize: Fs.xs, height: Lh.body, color: Palette.of(context).ink3),
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

  Widget _emptyDeck(String Function(String, [Map<String, Object>?]) t, bool caughtUp) {
    final bool nothingDue = caughtUp && (_deck == _DeckSource.due || _deck == _DeckSource.fresh);
    if (!nothingDue) {
      return _Notice(text: '${t('flashcards.emptyDeck')} ${t('flashcards.emptyDeckHint')}');
    }
    final bool canNav = context.canNavigate;
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
              onPressed: () => context.goTo('quiz'),
            ),
          if (canNav)
            LexButton(
              label: t('words.addWord'),
              kind: BtnKind.quiet,
              icon: Ic.plus,
              onPressed: () => context.goTo('words'),
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
      onPressed: context.canNavigate ? () => context.goTo('words') : null,
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
    required bool canUndo,
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
          _progressBar(t, progress, word: null, canUndo: canUndo, onUndo: onUndo, onExit: onExit),
          const SizedBox(height: Sp.x4),
          Card(
            child: EmptyState(
              icon: Ic.cards,
              title: t('flashcards.emptyDeck'),
              text: t('flashcards.emptyDeckHint'),
              action: LexButton(
                label: t('flashcards.restart'),
                onPressed: _startSession,
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _progressBar(t, progress, word: word, canUndo: canUndo, onUndo: onUndo, onExit: onExit),
        const SizedBox(height: Sp.x4),
        _flipCard(t, word: word, onReveal: onReveal, onSkip: onSkip),
        const SizedBox(height: Sp.x4),
        if (_flipped)
          _gradeRow(t, preview: preview, newCard: newCard, onGrade: onGrade)
        else
          Row(
            children: <Widget>[
              LexButton(
                label: t('flashcards.showAnswer'),
                kind: BtnKind.primary,
                size: BtnSize.lg,
                onPressed: onReveal,
                trailing: context.showsKeyHints ? Kbd(t('flashcards.spaceKey')) : null,
              ),
            ],
          ),
        if (_flipped && newCard) ...<Widget>[
          const SizedBox(height: Sp.x3),
          Text(
            t('flashcards.firstGradeHint'),
            style: TextStyle(fontSize: Fs.xs, height: Lh.body, color: Palette.of(context).ink3),
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
    // seen mirrored; `_turn` only drives the rotation.
    final Widget face = _flipped
        ? _answerFace(t, word: word)
        : (context.data.settings.audioFirst
            ? _listenFace(t, word: word)
            : _termFace(t, word: word));

    return _FlipCard(
      turn: _turn,
      tappable: !_flipped,
      onTap: onReveal,
      minHeight: compact ? 0 : minHeight,
      head: Row(
        children: <Widget>[
          Text(
            _flipped ? t('flashcards.back') : t('flashcards.front'),
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
                onPressed: () => _playWord(word),
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

  Widget _termFace(String Function(String, [Map<String, Object>?]) t, {required Word word}) {
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
            onPressed: () => _playWord(word),
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

  Widget _answerFace(String Function(String, [Map<String, Object>?]) t, {required Word word}) {
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
    final bool canNav = context.canNavigate;
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
            onPressed: _startSession,
            trailing: LexIcon(Ic.refresh, size: 16, color: p.onAccent),
          )
        else if (canNav)
          LexButton(
            label: t('flashcards.goQuiz'),
            kind: BtnKind.primary,
            size: BtnSize.lg,
            icon: Ic.quiz,
            onPressed: () => context.goTo('quiz'),
          ),
        if (_view?.canUndo ?? false)
          LexButton(
            label: t('flashcards.undo'),
            kind: BtnKind.quiet,
            icon: Ic.undo,
            onPressed: _undo,
          ),
        LexButton(
          label: t('common.back'),
          kind: BtnKind.quiet,
          onPressed: _exitSession,
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
