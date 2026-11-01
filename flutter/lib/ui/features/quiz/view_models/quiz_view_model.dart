/// The quiz screen's state and behaviour, with no widgets in it.
///
/// Everything the old `State` mutated lives here: the phase, the direction, the
/// questions, the answers picked so far, the selection, the session counters,
/// the start/elapsed clock and the 900 ms advance timer — together with the
/// derivations the page used to recompute inside `build` (the question on
/// screen, the score, the accuracy, the misses, the eligible-word count).
///
/// It is not a widget because none of that needs one. The page's only
/// widget-layer concerns are the focus node, the keyboard bindings and the
/// layout; the round itself is a small state machine over a [Session], and
/// keeping it here means it can be driven and asserted without pumping a tree.
///
/// The two rules the TS encoded in comments — and that the page's header
/// restates — are this class's contract now:
///
///   * while the feedback for an answer is on screen the session has already
///     moved past that question, so the card shown steps back one
///     ([currentIndex]);
///   * a correct answer glides on after 900 ms, but a miss stays put until the
///     correction has actually been read.
///
/// It never imports `material` or `widgets`: dialogs, toasts and navigation
/// arrive through [Feedback], and speech through the injected [speak] port,
/// which is what makes this class testable without a widget tree.
library;

// The constructor's parameter names (`store:`, `feedback:`) read better than
// the private field names, and `_clock` needs a default — the same trade-off
// `data/repositories/store.dart` makes.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import '../../../../data/repositories/store.dart';
import '../../../../domain/models/quiz.dart';
import '../../../../domain/models/session.dart';
import '../../../../domain/models/types.dart';
import '../../../core/view_model.dart';

/// Which of the three screens the page is on.
enum QuizPhase { idle, active, done }

/// A question the reader got wrong, kept for the results card.
class QuizMistake {
  const QuizMistake({
    required this.question,
    required this.answer,
    required this.key,
  });

  final QuizQuestion question;

  /// Which option was picked, or null when it was never answered.
  final int? answer;
  final String key;
}

/// Owns the quiz screen: the round, the answer in flight and the results.
class QuizViewModel extends ViewModel {
  QuizViewModel({
    required Store store,
    required Feedback feedback,
    Future<void> Function(Word word)? speak,
    int Function()? clock,
  })  : _store = store,
        _feedback = feedback,
        _speak = speak,
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _detachStore = _store.addListener(_onStoreWrite);
  }

  final Store _store;
  final Feedback _feedback;

  /// Speaks a term and records the listen — `speakWord` in production.
  ///
  /// A port rather than a direct call because the real `speakWord` reads the
  /// settings off a `BuildContext`, and this class must never see one. The view
  /// supplies `(word) => speakWord(context, word)`.
  final Future<void> Function(Word word)? _speak;

  /// Reads "now" in ms. Injected so a test can freeze the elapsed time.
  final int Function() _clock;

  /// Unsubscribes from the store in [dispose].
  late final void Function() _detachStore;

  QuizDirection _direction = QuizDirection.termToDef;
  QuizPhase _phase = QuizPhase.idle;
  List<QuizQuestion> _questions = <QuizQuestion>[];
  List<int?> _answers = <int?>[];
  int? _selected;
  int _elapsed = 0;
  Session? _session;
  SessionProgress? _progress;

  int _startedAt = 0;

  /// The "glide on after a correct answer" timer; null when none is pending.
  Timer? _advance;

  /* ------------------------------------------------------------------ */
  /* Lifecycle                                                           */
  /* ------------------------------------------------------------------ */

  /// The store is the only thing this screen does not own, so it is also the
  /// only thing it listens to.
  void _onStoreWrite() => refresh();

  @override
  void dispose() {
    _cancelAdvance();
    _detachStore();
    super.dispose();
  }

  /* ------------------------------------------------------------------ */
  /* State                                                               */
  /* ------------------------------------------------------------------ */

  QuizDirection get direction => _direction;
  QuizPhase get phase => _phase;

  /// The counters the progress bar, the score chip and the result card read.
  SessionProgress? get progress => _progress;

  int get total => _progress?.total ?? 0;
  int get score => _progress?.correct ?? 0;
  int get answeredCount => _progress?.reviewed ?? 0;

  double get accuracy => answeredCount > 0 ? score / answeredCount : 0;

  /// How many questions this round has, answered or not.
  int get questionCount => _questions.length;

  /// Every question answered, all of them right.
  bool get perfect =>
      answeredCount > 0 &&
      answeredCount == _questions.length &&
      score == answeredCount;

  /// The round was left before the last question.
  bool get endedEarly =>
      answeredCount > 0 && answeredCount < _questions.length;

  /// The option picked for the question on screen, or null while it is open.
  int? get selected => _selected;

  bool get answered => _selected != null;

  /// The logical elapsed time in ms, frozen when the round finished.
  int get elapsed => _elapsed;

  /// `1`-based number of the question on screen, or `0` when there is none.
  int get questionNumber {
    final SessionProgress? progress = _progress;
    if (progress == null || progress.total == 0 || _phase == QuizPhase.done) {
      return 0;
    }
    return (progress.index + (answered ? 0 : 1)).clamp(0, progress.total);
  }

  /* ------------------------------------------------------------------ */
  /* Derived state                                                       */
  /* ------------------------------------------------------------------ */

  /// While the feedback is up the session has already advanced, so step back
  /// one to keep showing the question the answer belonged to.
  int get currentIndex {
    final SessionProgress? progress = _progress;
    if (progress == null) return -1;
    return progress.index - (_selected != null ? 1 : 0);
  }

  QuizQuestion? get current {
    final int i = currentIndex;
    if (_phase != QuizPhase.active || i < 0 || i >= _questions.length) {
      return null;
    }
    return _questions[i];
  }

  /// The words a round can be built from, cached per snapshot.
  ///
  /// Three reads per frame (the idle card, the side panel and the "enough
  /// words" check) would otherwise filter the whole deck three times; the cache
  /// is keyed on the snapshot identity, so a store write rebuilds it exactly
  /// once.
  AppData? _eligibleData;
  List<Word>? _eligibleCache;

  List<Word> get eligibleWords {
    final AppData data = _store.data;
    final List<Word>? cached = _eligibleCache;
    if (cached != null && identical(_eligibleData, data)) return cached;
    final List<Word> built = quizEligibleWords(data.words);
    _eligibleData = data;
    _eligibleCache = built;
    return built;
  }

  int get eligibleCount => eligibleWords.length;

  /// False when the deck cannot fill a single question, so the page shows the
  /// empty state instead of a start button that would do nothing.
  bool get enough => eligibleCount >= QUIZ_CHOICES;

  /// The word a question asks about, or `null` when it was deleted mid-round.
  ///
  /// Quiz rows store a `wordId`, not the word, so the prompt's 发音 button has
  /// to look it up. The web build built the same map (`wordById`); here the
  /// lookup is linear because the deck is small and this runs once per build
  /// rather than once per row.
  Word? wordFor(QuizQuestion question) {
    for (final Word word in _store.data.words) {
      if (word.id == question.wordId) return word;
    }
    return null;
  }

  List<QuizMistake> get mistakes {
    final List<QuizMistake> out = <QuizMistake>[];
    for (int i = 0; i < _questions.length; i++) {
      final QuizQuestion question = _questions[i];
      final int? answer = i < _answers.length ? _answers[i] : null;
      if (answer != question.answerIndex) {
        out.add(QuizMistake(
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

  void setDirection(QuizDirection direction) {
    update(() => _direction = direction);
  }

  /// The 发音 button on the prompt and on the review rows.
  ///
  /// Counts the listen, unlike the flashcard auto-play: both of these are an
  /// explicit press.
  void playWord(Word word) {
    final Future<void> Function(Word word)? speak = _speak;
    if (speak == null) return;
    unawaited(speak(word));
  }

  void _finish() {
    _cancelAdvance();
    update(() {
      _elapsed = _clock() - _startedAt;
      _phase = QuizPhase.done;
    });
  }

  Future<void> requestFinish() async {
    final SessionProgress? progress = _session?.progress();
    if (progress != null && progress.reviewed > 0 && !progress.done) {
      final bool ok = await _feedback.confirm(
        title: _feedback.t('quiz.exitTitle'),
        subtitle: _feedback.t('quiz.exitConfirm'),
        confirmLabel: _feedback.t('quiz.exit'),
      );
      if (!ok || isDisposed) return;
      _finish();
      return;
    }
    _finish();
  }

  void goNext() {
    _cancelAdvance();
    // Ask the session rather than the rendered state: the feedback timer fires
    // after the last answer has already advanced it.
    final Session? session = _session;
    if (session == null || session.progress().done) {
      _finish();
      return;
    }
    update(() => _selected = null);
  }

  void start(QuizDirection direction) {
    final List<QuizQuestion> built =
        buildQuiz(_store.data.words, direction, count: QUIZ_ROUND);
    if (built.isEmpty) {
      _feedback.toast(_feedback.t('quiz.noWords'), kind: ToastKind.info);
      return;
    }
    final Session session = createSession(
      ids: built.map((QuizQuestion q) => q.wordId).toList(),
    );
    _cancelAdvance();
    update(() {
      _session = session;
      _questions = built;
      _answers = List<int?>.filled(built.length, null);
      _selected = null;
      _elapsed = 0;
      _progress = session.progress();
      _startedAt = _clock();
      _phase = QuizPhase.active;
    });
  }

  void choose(int option) {
    final Session? session = _session;
    if (_selected != null || session == null) return;
    final int position = session.progress().index;
    if (position < 0 || position >= _questions.length) return;
    final QuizQuestion question = _questions[position];
    final bool isCorrect = option == question.answerIndex;
    update(() {
      _selected = option;
      final List<int?> next = List<int?>.of(_answers);
      if (position < next.length) next[position] = option;
      _answers = next;
    });
    session.record(correct: isCorrect);
    update(() => _progress = session.progress());
    // A correct answer may glide on; a miss must stay put until the correction
    // has actually been read.
    if (isCorrect) {
      _advance = Timer(const Duration(milliseconds: 900), () {
        _advance = null;
        if (!isDisposed) goNext();
      });
    }
  }

  void exitToIdle() {
    _cancelAdvance();
    update(() {
      _session = null;
      _phase = QuizPhase.idle;
      _questions = <QuizQuestion>[];
      _answers = <int?>[];
      _selected = null;
      _progress = null;
    });
  }

  void _cancelAdvance() {
    _advance?.cancel();
    _advance = null;
  }

  /* ------------------------------------------------------------------ */
  /* Navigation                                                          */
  /* ------------------------------------------------------------------ */

  /// True when a shell is above this screen, i.e. when [goTo] would work.
  bool get canNavigate => _feedback.canNavigate;

  void goTo(String pageId) => _feedback.goTo(pageId);
}
