/// The flashcard review screen's state and behaviour, with no widgets in it.
///
/// Everything the old `State` mutated lives here: the deck source, the session
/// in progress, the snapshot the page renders of it, the flip flag, the turn
/// token, the store-side undo stack, the auto-play dedupe token and the two
/// turn timers — together with the derivations the page used to recompute
/// inside `build` (the deck counts, the card in hand, the grade preview and the
/// remaining count).
///
/// It is not a widget because none of that needs one. The page's only
/// widget-layer concerns are the focus node, the keyboard bindings and the
/// layout; a session is a small state machine over [Session], and keeping it
/// here means it can be driven and asserted without pumping a tree.
///
/// The two decisions the page's header states are this class's contract now:
///
///   * the deck is *derived* on every read ([summary], [preview]) rather than
///     kept in state, so a grade written to the store immediately changes what
///     "due today" means without a second source of truth;
///   * the store-side undo lives here, not in `domain/models/session.dart`: the
///     session owns the counters, this class snapshots the schedule it is about
///     to overwrite so "undo" can put the card back exactly as it was.
///
/// Audio follows the web build's two rules: a card that is *listening mode*
/// speaks as soon as it appears, and an ordinary card speaks when it is
/// revealed if `autoPlayAudio` is on. Both go through [maybeAutoPlay], which
/// dedupes on `word:index:face` so a repaint — of which there are many, since
/// every store write repaints this screen — cannot repeat a clip. Only an
/// explicit 发音 press bumps the listen count.
///
/// It never imports `material` or `widgets`: dialogs, toasts and navigation
/// arrive through [Feedback], and the four things speech needs — is there an
/// engine at all, say the term, say it without counting the listen, stop the
/// clip — arrive as ports the view supplies. That split is not cosmetic: the
/// real `speakWord`/`speakTerm` read the settings off a `BuildContext`, which
/// this class must never see, while the 发音 button's visibility is the view's
/// decision, so the two halves stay in one place each.
library;

// The constructor's parameter names (`store:`, `feedback:`) read better than
// the private field names, and `_clock`/`_speechAvailable` need defaults — the
// same trade-off `data/repositories/store.dart` and the sibling view models
// make.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../data/repositories/store.dart' show GradeResult, Store;
import '../../../../domain/models/session.dart';
import '../../../../domain/models/srs.dart';
import '../../../../domain/models/types.dart';
import '../../../../domain/use_cases/deck_plan.dart';
import '../../../core/view_model.dart';

/* The deck rules moved to the domain layer when the practice screen started
   asking the same questions *before* a session exists (its front page prints a
   deck size, and 开始复习 has to know whether the round is empty). They are
   re-exported here so every existing import site — including the tests that
   drive this view model directly — keeps resolving, and so there is still one
   obvious place to look for "where does a deck come from". */
export '../../../../domain/use_cases/deck_plan.dart' show DeckSource, DeckSummary;


/// What the page renders of the session. The session itself is a mutable
/// object, so we take a snapshot after every step to give the view a new value
/// to rebuild from.
class _View {
  const _View({
    required this.progress,
    required this.current,
    required this.canUndo,
  });

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

/// Owns the flashcard screen: the deck, the session in flight and the audio.
class FlashcardsViewModel extends ViewModel {
  FlashcardsViewModel({
    required Store store,
    required Feedback feedback,
    DeckSource deck = DeckSource.due,
    int? limit,
    Future<void> Function(Word word, {VoidCallback? onEnd})? speakWord,
    Future<void> Function(Word word, {VoidCallback? onEnd})? speakTerm,
    VoidCallback? stopSpeech,
    VoidCallback? onExit,
    bool Function()? speechAvailable,
    int Function()? clock,
  })  : _store = store,
        _feedback = feedback,
        _deck = deck,
        _limit = limit,
        _speakWord = speakWord,
        _speakTerm = speakTerm,
        _stopSpeech = stopSpeech,
        _onExit = onExit,
        _speechAvailable = speechAvailable ?? _noSpeech,
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _detachStore = _store.addListener(_onStore);
  }

  final Store _store;
  final Feedback _feedback;

  /// The 发音 button: says the word *and* counts the listen — `speakWord` in
  /// production, which needs a `BuildContext` for the settings.
  final Future<void> Function(Word word, {VoidCallback? onEnd})? _speakWord;

  /// Auto-play: says the word without touching the listen count — `speakTerm`
  /// in production.
  final Future<void> Function(Word word, {VoidCallback? onEnd})? _speakTerm;

  /// Cuts whatever is speaking, so the next card does not queue behind it.
  final VoidCallback? _stopSpeech;

  /// Whether an engine exists at all — `speechAvailable` in production.
  final bool Function() _speechAvailable;

  /// What to do when the session ends and this page is a sub-page of the
  /// practice screen: hand control back to the front page.
  ///
  /// Null when the page is mounted on its own (a test, or the old single-page
  /// arrangement), in which case 退出 leaves the picker showing instead.
  final VoidCallback? _onExit;

  /// Reads "now" in ms. Injected so a test can freeze "due today".
  final int Function() _clock;

  /// Unsubscribes from the store in [dispose].
  late final void Function() _detachStore;

  /* ------------------------------------------------------------------ */
  /* State                                                               */
  /* ------------------------------------------------------------------ */

  DeckSource _deck;

  /// Cap on one round, or null for "the whole pool".
  ///
  /// The practice screen owns the round size now (it is the number under the
  /// big "20 / 本轮" readout), so it hands the number down rather than letting
  /// the session re-derive it. Null keeps the old behaviour for a page that
  /// mounts this view on its own.
  final int? _limit;

  Session? _session;
  _View? _view;
  bool _flipped = false;

  /// `'out'` while the front turns away, `'in'` while the answer turns in,
  /// `null` at rest — the TS's `'idle' | 'out' | 'in'`.
  String? _turn;
  List<_StoreStep> _storeSteps = <_StoreStep>[];

  Timer? _turnOut;
  Timer? _turnIn;

  /// The `word:index:face` token of the last clip auto-play started, so a
  /// repaint cannot repeat it. The web build used a ref for the same reason.
  ///
  /// Written without [update] on purpose: it is a dedupe latch, not screen
  /// state, and the page it came from assigned it outside `setState` for the
  /// same reason — notifying would repaint a screen whose pixels did not move.
  String? _spoken;

  /* ------------------------------------------------------------------ */
  /* Lifecycle                                                           */
  /* ------------------------------------------------------------------ */

  /// The store is the only thing this screen does not own, so it is also the
  /// only thing it listens to: a grade written here, or a sync round landing
  /// elsewhere, changes what "due today" means.
  void _onStore() => refresh();

  @override
  void dispose() {
    _clearTurn();
    // Leaving the page mid-sentence would talk over whatever comes next.
    _stopSpeech?.call();
    _detachStore();
    super.dispose();
  }

  static bool _noSpeech() => false;

  /* ------------------------------------------------------------------ */
  /* State the view reads                                                */
  /* ------------------------------------------------------------------ */

  AppData get data => _store.data;

  DeckSource get deck => _deck;

  bool get flipped => _flipped;

  /// The face-turn token the flip animation reads.
  String? get turn => _turn;

  SessionProgress? get progress => _view?.progress;

  bool get canUndo => _view?.canUndo ?? false;

  /// True while a session is on screen and not finished.
  bool get inProgress => _view != null && !_view!.progress.done;

  /// The word behind the card in hand, or null once the session is done.
  Word? get word {
    final String? id = _view?.current;
    if (id == null) return null;
    for (final Word word in _store.data.words) {
      if (word.id == id) return word;
    }
    return null;
  }

  /// True when the card in hand has never been reviewed.
  bool get newCard {
    final Word? word = this.word;
    return word != null && isNew(word.srs);
  }

  /// What each grade would do to the card in hand, for the buttons' preview.
  Map<Grade, ({int intervalDays, WordStatus status})>? get preview {
    final Word? word = this.word;
    if (word == null) return null;
    return previewGrades(
      CardState(srs: word.srs, status: word.status),
      _clock(),
    );
  }

  /// Cards left in the session, for the side panel.
  int get remaining {
    final SessionProgress? progress = _view?.progress;
    return progress == null
        ? 0
        : (progress.total - progress.index).clamp(0, progress.total);
  }

  /// The deck picker's counts for the selected deck.
  int get deckSize => summary.counts[_deck] ?? 0;

  /// Everything the deck picker shows about the snapshot as it stands now.
  DeckSummary get summary => summarizeDeck(_store.data, _clock());

  /* ------------------------------------------------------------------ */
  /* Session plumbing                                                    */
  /* ------------------------------------------------------------------ */

  void _sync() {
    final Session? session = _session;
    update(() {
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

  /// Back to the front of the card, with no turn in flight.
  void resetFlip() {
    _clearTurn();
    update(() {
      _turn = null;
      _flipped = false;
    });
  }

  /// Turn the card over.
  ///
  /// [reduceMotion] is the view's reading of the platform's "disable
  /// animations" preference; it is a parameter because this class has no
  /// `MediaQuery` to ask.
  void reveal({required bool reduceMotion}) {
    if (_flipped || _turn != null) return;
    if (reduceMotion) {
      update(() => _flipped = true);
      return;
    }
    update(() => _turn = 'out');
    _turnOut = Timer(const Duration(milliseconds: 125), () {
      if (isDisposed) return;
      update(() {
        _flipped = true;
        _turn = 'in';
      });
      _turnIn = Timer(const Duration(milliseconds: 190), () {
        if (isDisposed) return;
        update(() => _turn = null);
      });
    });
  }

  /// Build the deck for the selected source and start walking it.
  void startSession() {
    final List<String> ids = buildDeck(
      _store.data,
      _clock(),
      _deck,
      limit: _limit,
    );
    _clearTurn();
    _storeSteps = <_StoreStep>[];
    _spoken = null;
    update(() {
      _flipped = false;
      _turn = null;
      _session = ids.isEmpty ? null : createSession(ids: ids);
    });
    _sync();
  }

  /// Drop the session and go back to the deck picker — or, when this page is
  /// the practice screen's session, back to that screen's front page.
  void exitSession() {
    _clearTurn();
    _stopSpeech?.call();
    _spoken = null;
    update(() {
      _session = null;
      _view = null;
      _flipped = false;
      _turn = null;
      _storeSteps = <_StoreStep>[];
    });
    _onExit?.call();
  }

  /// Pick which deck the next session draws from.
  void setDeck(DeckSource value) => update(() => _deck = value);

  void grade(Grade value) {
    final Word? word = this.word;
    final Session? session = _session;
    if (word == null || session == null) return;
    final SrsState? prevSrs = word.srs;
    final WordStatus prevStatus = word.status;
    final GradeResult? result = _store.gradeWord(word.id, value);
    if (result == null) return;
    _storeSteps.add(_StoreStep(
      id: word.id,
      prevSrs: prevSrs,
      prevStatus: prevStatus,
      logId: result.logId,
    ));
    session.record(correct: gradeCountsAsCorrect(value));
    _sync();
    resetFlip();
  }

  void skip() {
    final Session? session = _session;
    if (session == null) return;
    session.skip();
    _sync();
    resetFlip();
  }

  void undo() {
    final Session? session = _session;
    if (session == null) return;
    final Step? step = session.undo();
    if (step == null) return;
    if (step is RecordStep) {
      final _StoreStep? storeStep =
          _storeSteps.isEmpty ? null : _storeSteps.removeLast();
      if (storeStep != null) {
        _store.undoReview(
          storeStep.id,
          storeStep.prevSrs,
          storeStep.prevStatus,
          storeStep.logId,
        );
      }
      _clearTurn();
      update(() {
        _turn = null;
        _flipped = true;
      });
    } else {
      update(() => _flipped = false);
    }
    _sync();
  }

  /// The 退出 button: asks first when the session is half done.
  Future<void> requestExit() async {
    final String exitLabel = _feedback.t('flashcards.exit');
    final SessionProgress? progress = _view?.progress;
    if (progress != null && progress.reviewed > 0 && !progress.done) {
      final int remaining = progress.total - progress.index;
      final bool ok = await _feedback.confirm(
        title: exitLabel,
        subtitle: _feedback.t('flashcards.exitConfirm', <String, Object>{
          'n': remaining < 0 ? 0 : remaining,
        }),
        confirmLabel: exitLabel,
      );
      if (!ok || isDisposed) return;
      _confirmExitNow();
      return;
    }
    exitSession();
  }

  void _confirmExitNow() {
    final int reviewed = _session?.progress().reviewed ?? 0;
    exitSession();
    if (reviewed > 0) {
      _feedback.toast(
        _feedback.t('flashcards.exitSaved', <String, Object>{'n': reviewed}),
        kind: ToastKind.ok,
      );
    }
  }

  /// The 发音 button: says the word and counts the listen.
  void playWord(Word word) {
    final Future<void> Function(Word word, {VoidCallback? onEnd})? speak =
        _speakWord;
    if (speak == null) return;
    unawaited(speak(word));
  }

  /// Starts the automatic clip for the card now on screen, if this face is
  /// meant to be heard.
  ///
  /// Called from the view's post-frame callback rather than from [reveal] /
  /// [_sync]: the settings it depends on live in the store, and a screen that
  /// started speech from a state change would talk over the flip animation. The
  /// token makes it idempotent, so calling it on every frame is free.
  void maybeAutoPlay() {
    final Word? word = this.word;
    final SessionProgress? progress = _view?.progress;
    if (word == null || progress == null || progress.done) return;
    if (!_speechAvailable()) return;
    final Settings settings = _store.data.settings;
    final bool listening = settings.audioFirst;
    // 听力模式 speaks on the front by definition — the sound *is* the prompt.
    // Otherwise the two booleans decide, one per face. 正面 under 先显示译文 is
    // silent: the front is the meaning there, so speaking the term would answer
    // the question the card is asking.
    final bool frontSpeaking =
        settings.autoPlayFront && !settings.translationFirst;
    final bool shouldSpeak = listening
        ? !_flipped
        : (_flipped ? settings.autoPlayAudio : frontSpeaking);
    if (!shouldSpeak) return;
    final String token =
        '${word.id}:${progress.index}:${_flipped ? 'back' : 'front'}';
    if (_spoken == token) return;
    _spoken = token;
    // Cut the previous card's clip rather than queueing behind it: a review
    // that grades fast would otherwise hear a backlog of old terms.
    _stopSpeech?.call();
    final Future<void> Function(Word word, {VoidCallback? onEnd})? speak =
        _speakTerm;
    if (speak == null) return;
    unawaited(speak(word));
  }

  /* ------------------------------------------------------------------ */
  /* Navigation                                                          */
  /* ------------------------------------------------------------------ */

  /// True when a shell is above this screen, i.e. when [goTo] would work.
  bool get canNavigate => _feedback.canNavigate;

  void goTo(String pageId) => _feedback.goTo(pageId);
}
