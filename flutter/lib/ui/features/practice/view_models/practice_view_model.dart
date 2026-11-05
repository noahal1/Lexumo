/// The practice screen's front page: what the round will be made of.
///
/// This is the screen that decides a sitting before it starts — cards or quiz,
/// which pool, how many, and the four options that shape it. It owns no session
/// of its own: pressing 开始复习 hands a [PracticePlan] to the sub-page, which
/// builds the session and owns it. That split is why this class has no timers,
/// no `Session` and no speech: it is a form, and a form's state is the settings
/// plus which pool was picked.
///
/// It never imports `material` or `widgets`: the sub-pages, the toasts and the
/// navigation all arrive through [Feedback] or the caller.
library;

// The constructor's parameter names read better than the private field names —
// the same trade-off the sibling view models make.
// ignore_for_file: prefer_initializing_formals

import '../../../../data/repositories/store.dart';
import '../../../../domain/models/quiz.dart';
import '../../../../domain/models/types.dart';
import '../../../../domain/models/utils.dart' show clamp;
import '../../../../domain/use_cases/deck_plan.dart';
import '../../../core/view_model.dart';

/// The two faces of a practice session, in the order the segmented control
/// presents them.
enum PracticeMode { cards, quiz }

/// Which pool a card round draws from.
///
/// Two, not the flashcard page's four: 收藏 is a filter the word library already
/// has, and a front page that offers four pools has to explain the difference
/// between three of them. 待复习 is "what you owe", 自定义 is "everything I have".
enum PracticeScope { due, custom }

/// Everything the sub-page needs to start a round.
///
/// Passed as one value rather than four constructor arguments so the page and
/// the sub-page cannot disagree about which pool the number under 本轮 was
/// counted from.
class PracticePlan {
  const PracticePlan({
    required this.mode,
    required this.size,
    this.scope = PracticeScope.due,
    this.direction = QuizDirection.termToDef,
  });

  final PracticeMode mode;

  /// The round's card count, already clamped to what the pool can supply.
  final int size;

  /// Cards only.
  final PracticeScope scope;

  /// Quiz only.
  final QuizDirection direction;
}

/// The 自动朗读 picker's four states, as a value the view can render and the
/// view model can store.
///
/// Derived from the two booleans rather than stored: the settings record is
/// shared with the settings page (which shows them as two separate switches),
/// and a third stored field would have to be kept in step with them by hand.
enum AutoPlayWhen {
  off,
  front,
  back,
  both;

  /// Read the pair back out of the settings.
  static AutoPlayWhen of(Settings s) {
    if (s.autoPlayFront) return s.autoPlayAudio ? both : front;
    return s.autoPlayAudio ? back : off;
  }

  /// The patch that turns this state into the two booleans.
  ({bool front, bool back}) get flags => switch (this) {
        AutoPlayWhen.off => (front: false, back: false),
        AutoPlayWhen.front => (front: true, back: false),
        AutoPlayWhen.back => (front: false, back: true),
        AutoPlayWhen.both => (front: true, back: true),
      };
}

/// The practice front page's state and behaviour.
class PracticeViewModel extends ViewModel {
  PracticeViewModel({
    required Store store,
    required Feedback feedback,
    PracticeMode mode = PracticeMode.cards,
    int Function()? clock,
  })  : _store = store,
        _feedback = feedback,
        _mode = mode,
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _detachStore = _store.addListener(_onStore);
  }

  final Store _store;
  final Feedback _feedback;

  /// Reads "now" in ms. Injected so a test can freeze "due today".
  final int Function() _clock;

  late final void Function() _detachStore;

  PracticeMode _mode;
  PracticeScope _scope = PracticeScope.due;
  QuizDirection _direction = QuizDirection.termToDef;

  /* ------------------------------------------------------------------ */
  /* Lifecycle                                                           */
  /* ------------------------------------------------------------------ */

  void _onStore() => refresh();

  @override
  void dispose() {
    _detachStore();
    super.dispose();
  }

  /* ------------------------------------------------------------------ */
  /* Reads                                                               */
  /* ------------------------------------------------------------------ */

  AppData get data => _store.data;
  Settings get settings => _store.data.settings;
  PracticeMode get mode => _mode;
  PracticeScope get scope => _scope;
  QuizDirection get direction => _direction;
  AutoPlayWhen get autoPlay => AutoPlayWhen.of(_store.data.settings);

  /// How many cards the chosen pool holds right now.
  int get poolSize => _mode == PracticeMode.cards
      ? summarizeDeck(_store.data, _clock()).counts[_deck] ?? 0
      : quizEligibleWords(_store.data.words).length;

  /// The number under 本轮: the round size, clamped to the pool.
  ///
  /// Clamped rather than promised, because a round of 20 drawn from a pool of 7
  /// is a round of 7 and the big number is the one thing on this screen that
  /// must not be aspirational.
  int get roundSize => _mode == PracticeMode.cards
      ? deckRoundSize(settings, poolSize)
      : quizRoundSize(settings, poolSize);

  /// True when there is enough material to start.
  ///
  /// A quiz needs [QUIZ_CHOICES] words before it can offer four options at all,
  /// so it cannot start on the same condition a card round can.
  bool get canStart =>
      _mode == PracticeMode.cards ? roundSize > 0 : poolSize >= QUIZ_CHOICES;

  /// The deck source the card round will draw from.
  DeckSource get _deck =>
      _scope == PracticeScope.due ? DeckSource.due : DeckSource.all;

  /// Everything a caller needs to mount the right sub-page.
  PracticePlan get plan => PracticePlan(
        mode: _mode,
        size: roundSize,
        scope: _scope,
        direction: _direction,
      );

  /* ------------------------------------------------------------------ */
  /* Intents                                                             */
  /* ------------------------------------------------------------------ */

  void setMode(PracticeMode value) => update(() => _mode = value);

  void setScope(PracticeScope value) => update(() => _scope = value);

  void setDirection(QuizDirection value) => update(() => _direction = value);

  /// The 每轮卡片数 stepper. Clamped by the caller's `min`/`max` too, so a
  /// test that drives it directly cannot park the setting outside the range the
  /// stepper offers.
  void setRoundSize(int value) {
    final int clamped = clamp(value, kMinRoundSize, kMaxRoundSize).toInt();
    if (clamped == settings.roundSize) return;
    _store.updateSettings((Settings s) => s.copyWith(roundSize: clamped));
  }

  void setAutoPlay(AutoPlayWhen value) {
    final ({bool front, bool back}) flags = value.flags;
    _store.updateSettings(
      (Settings s) => s.copyWith(
        autoPlayFront: flags.front,
        autoPlayAudio: flags.back,
      ),
    );
  }

  /// 随机: the order cards come up in.
  void setRandom(bool value) {
    _store.updateSettings(
      (Settings s) => s.copyWith(reviewOrder: value ? 'random' : 'due'),
    );
  }

  bool get isRandom => settings.reviewOrder == 'random';

  void setTranslationFirst(bool value) {
    _store.updateSettings(
      (Settings s) => s.copyWith(translationFirst: value),
    );
  }

  /* ------------------------------------------------------------------ */
  /* Navigation                                                          */
  /* ------------------------------------------------------------------ */

  bool get canNavigate => _feedback.canNavigate;

  void goTo(String pageId) => _feedback.goTo(pageId);
}

/// Bounds the 每轮卡片数 stepper offers.
///
/// A round of 1 is a legitimate way to use the app for a minute; a round of 200
/// is the same as "everything" without saying so, which is what 自定义 is for.
const int kMinRoundSize = 5;
const int kMaxRoundSize = 100;
