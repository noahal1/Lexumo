/// The practice screen: a front page that decides a sitting, then the sitting.
///
/// Two states, one destination:
///
///   * **the front page** — cards or quiz, which pool, how many, and the four
///     options that shape a round. This is where 开始复习 is pressed.
///   * **the session** — the card (or the question) itself, which is one of the
///     two sub-pages this file mounts. It owns the keyboard, the focus node and
///     the session; nothing about it is duplicated here.
///
/// The split is what the reference design does, and it is the right one: the
/// choices that shape a round are decisions about a *sitting*, so they belong
/// somewhere you can see them all at once and change before you commit — not in
/// a strip above a card you are already looking at, where changing the pool
/// mid-round would have to throw the round away.
///
/// The front page is a form, so its state is [PracticeViewModel]: which mode,
/// which scope, and the settings the round reads. The session's state is the
/// sub-page's own view model. Only one of the two is mounted at a time.
library;

import 'package:flutter/material.dart';

import '../../../../app/scope.dart';
import '../../../../domain/models/quiz.dart' show QuizDirection;
import '../../../../domain/models/types.dart' show Settings;
import '../../../core/context_feedback.dart';
import '../../../core/tokens.dart';
import '../../../core/widgets/controls.dart';
import '../../../core/widgets/keyboard_hints.dart';
import '../../../core/widgets/lex_icon.dart';
import '../../../core/widgets/widgets.dart';
import '../../flashcards/views/flashcards_page.dart';
import '../../quiz/views/quiz_page.dart';
import '../view_models/practice_view_model.dart';

class PracticePage extends StatefulWidget {
  const PracticePage({super.key, this.controller});

  /// Owned by the shell, so the page scroll position survives a page switch.
  final ScrollController? controller;

  @override
  State<PracticePage> createState() => _PracticePageState();
}

class _PracticePageState extends State<PracticePage> {
  /// Built here rather than in the field initialiser: it needs the store, which
  /// is only reachable once the page is mounted under a [StoreScope].
  late final PracticeViewModel _vm;

  /// The round on screen, or null while the front page is showing.
  ///
  /// The plan is captured when 开始复习 is pressed rather than read from the
  /// view model on every frame: once a round is running, the front page's
  /// controls are gone, so nothing can change the number under the session's
  /// feet — and a session that re-read the round size mid-round would grow or
  /// shrink under the card in hand.
  PracticePlan? _running;

  @override
  void initState() {
    super.initState();
    _vm = PracticeViewModel(
      store: context.store,
      feedback: ContextFeedback(context),
    );
  }

  @override
  void dispose() {
    _vm.dispose();
    super.dispose();
  }

  void _start() {
    if (!_vm.canStart) return;
    setState(() => _running = _vm.plan);
  }

  /// Called by the sub-page when the session is over — by 退出, or by the
  /// done screen's 返回.
  void _leaveSession() {
    if (!mounted) return;
    setState(() => _running = null);
  }

  @override
  Widget build(BuildContext context) {
    final PracticePlan? running = _running;
    if (running != null) {
      // Only the active sub-page is built, never both: each carries its own
      // scroll target (the shell's one controller per destination) and its own
      // focus node, and keeping both alive would fight over both.
      return running.mode == PracticeMode.cards
          ? FlashcardsPage(
              controller: widget.controller,
              plan: running,
              onExit: _leaveSession,
            )
          : QuizPage(
              controller: widget.controller,
              plan: running,
              onExit: _leaveSession,
            );
    }
    // The front page rebuilds on every store write, because every number on it
    // (the pool size, the round size, the four options) is read from the
    // settings or the snapshot.
    return ListenableBuilder(
      listenable: _vm,
      builder: (BuildContext context, Widget? _) => _frontPage(context),
    );
  }

  /* ------------------------------------------------------------------ */
  /* The front page                                                      */
  /* ------------------------------------------------------------------ */

  Widget _frontPage(BuildContext context) {
    final String Function(String, [Map<String, Object>?]) t = context.t;
    final Palette p = Palette.of(context);
    final Settings settings = _vm.settings;
    final bool cards = _vm.mode == PracticeMode.cards;
    final int size = _vm.roundSize;

    final List<Widget> options = <Widget>[
      _OptionRow(
        label: cards ? t('practice.roundSizeCards') : t('practice.roundSizeQuiz'),
        control: LexStepper(
          value: settings.roundSize,
          min: kMinRoundSize,
          max: kMaxRoundSize,
          onChanged: _vm.setRoundSize,
          decrementLabel: t('practice.fewer'),
          incrementLabel: t('practice.more'),
        ),
      ),
      if (cards)
        _OptionRow(
          label: t('practice.autoPlay'),
          control: SizedBox(
            // A fixed measure so the four labels do not each size the select
            // differently and shuffle the column when the choice changes.
            width: 132,
            child: LexSelect<AutoPlayWhen>(
              value: _vm.autoPlay,
              options: AutoPlayWhen.values,
              onChanged: _vm.setAutoPlay,
              labelOf: (AutoPlayWhen when) => t(_kAutoPlayLabelKey[when]!),
            ),
          ),
        ),
      // 随机 is the same setting the settings page calls 复习顺序. It is offered
      // here because it changes the round you are about to start, and reaching
      // into another page to change it is the reason it went unnoticed.
      _OptionRow(
        label: t('practice.random'),
        control: LexSwitch(
          checked: _vm.isRandom,
          label: t('practice.random'),
          onChanged: _vm.setRandom,
        ),
      ),
      if (cards)
        _OptionRow(
          label: t('practice.translationFirst'),
          control: LexSwitch(
            checked: settings.translationFirst,
            label: t('practice.translationFirst'),
            onChanged: _vm.setTranslationFirst,
          ),
        ),
      if (!cards)
        _OptionRow(
          label: t('practice.direction'),
          control: Segmented<QuizDirection>(
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
            onChanged: _vm.setDirection,
          ),
        ),
    ];

    final Widget column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // The page names itself. Every other screen in the app lets the sidebar
        // or the tab bar name it, and this one did too until the round controls
        // moved in: a screen that asks you to decide something before you can
        // leave it needs a title, or the first thing you see is a segmented
        // control with no context.
        Text(
          t('practice.title'),
          style: TextStyle(
            fontFamily: Fonts.display,
            fontSize: Fs.xl,
            height: Lh.title,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.01,
            color: p.ink,
          ),
        ),
        const SizedBox(height: Sp.x7),
        Center(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Segmented<PracticeMode>(
              value: _vm.mode,
              scale: SegScale.page,
              options: <SegOption<PracticeMode>>[
                SegOption<PracticeMode>(
                  value: PracticeMode.cards,
                  label: t('practice.cards'),
                ),
                SegOption<PracticeMode>(
                  value: PracticeMode.quiz,
                  label: t('practice.quiz'),
                ),
              ],
              onChanged: _vm.setMode,
            ),
          ),
        ),
        const SizedBox(height: Sp.x6),
        _RoundFigure(size: size, label: t('practice.thisRound')),
        const SizedBox(height: Sp.x5),
        // The scope only exists for cards: a quiz is drawn from every word that
        // can be asked, so a 待复习/自定义 switch above a quiz round would be a
        // control that does nothing.
        if (cards)
          Center(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Segmented<PracticeScope>(
                value: _vm.scope,
                scale: SegScale.page,
                options: <SegOption<PracticeScope>>[
                  SegOption<PracticeScope>(
                    value: PracticeScope.due,
                    label: t('practice.scopeDue'),
                  ),
                  SegOption<PracticeScope>(
                    value: PracticeScope.custom,
                    label: t('practice.scopeCustom'),
                  ),
                ],
                onChanged: _vm.setScope,
              ),
            ),
          ),
        const SizedBox(height: Sp.x7),
        SectionTitle(label: t('practice.options'), padded: false),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: options,
        ),
        // No rule here: the last option row already closes the list with its own
        // bottom border. A second hairline 28dp below it reads as an empty row
        // — a setting with nothing in it — rather than as a section break.
        const SizedBox(height: Sp.x7),
        LexButton(
          label: cards ? t('flashcards.start') : t('quiz.start'),
          kind: BtnKind.primary,
          size: BtnSize.lg,
          block: true,
          icon: Ic.play,
          onPressed: _vm.canStart ? _start : null,
        ),
        if (!_vm.canStart) ...<Widget>[
          const SizedBox(height: Sp.x3),
          Text(
            cards ? t('practice.emptyPool') : t('practice.needWords'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: Fs.xs, height: Lh.body, color: p.ink3),
          ),
        ],
        if (context.showsKeyHints) ...<Widget>[
          const SizedBox(height: Sp.x3),
          Text(
            cards ? t('flashcards.keyboardHint') : t('quiz.keyboardHint'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: Fs.xs, height: Lh.body, color: p.ink3),
          ),
        ],
      ],
    );

    return PageShell(
      controller: widget.controller,
      children: <Widget>[
        Align(
          alignment: AlignmentDirectional.topCenter,
          // Capped and centred: the form is one column of decisions, and past
          // ~560dp a label and its control drift so far apart that the row
          // stops reading as one row.
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: column,
          ),
        ),
      ],
    );
  }
}

/// The four 自动朗读 states, by i18n key.
const Map<AutoPlayWhen, String> _kAutoPlayLabelKey = <AutoPlayWhen, String>{
  AutoPlayWhen.off: 'practice.autoPlayOff',
  AutoPlayWhen.front: 'practice.autoPlayFront',
  AutoPlayWhen.back: 'practice.autoPlayBack',
  AutoPlayWhen.both: 'practice.autoPlayBoth',
};

/// The round's size, as the one figure the screen is built around.
///
/// It is a count of things, not a score, so it is printed as a number with a
/// caption under it rather than inside a card: the reference design's single
/// large numeral is the whole point of the screen — the answer to "how much am
/// I about to do". The size is deliberately above the type scale's top step
/// ([Fs.x3xl]); like the card's term it is a hero figure, and a hero figure
/// that respects the caption scale is not a hero figure.
class _RoundFigure extends StatelessWidget {
  const _RoundFigure({required this.size, required this.label});

  final int size;
  final String label;

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);
    final double figure =
        (MediaQuery.sizeOf(context).width * 0.13).clamp(52.0, 84.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          '$size',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: Fonts.display,
            fontSize: figure,
            height: Lh.none,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.03,
            color: size > 0 ? p.accent : p.ink4,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: Sp.x2),
        Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: Fs.sm, height: Lh.snug, color: p.ink3),
        ),
      ],
    );
  }
}

/// One line of the 选项 block: a label, and the control that sets it.
///
/// Not [HairlineRow]: that one is a list row with a 76dp floor and a hover tint,
/// built for rows you click to go somewhere. These are settings you operate in
/// place, so they get a hairline between them and no hover — the hover belongs
/// to the control, not to the row.
///
/// The row is one line at every width. It used to drop the control under its
/// label below 420dp, on the theory that a 132dp control and a long label could
/// not share a phone's measure; what that produced was a form whose three row
/// shapes each stood a different height, so the option list read as three
/// unrelated blocks rather than one list of four settings. A phone in fact has
/// the 215dp a label wants beside a 132dp control, and where it does not — a
/// 320dp screen at double text size — the label wraps inside its own column
/// while the control keeps its edge. That is a taller row, not a different row.
class _OptionRow extends StatelessWidget {
  const _OptionRow({required this.label, required this.control});

  final String label;
  final Widget control;

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: Layout.tap),
      padding: const EdgeInsets.symmetric(vertical: Sp.x3),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.line)),
      ),
      child: Row(
        // Centred rather than stretched: the controls are 44dp tall whatever the
        // label does, and centring keeps a control level with a label that has
        // wrapped onto a second line instead of pinning it to the first.
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(child: Text(label, style: _labelStyle(p))),
          const SizedBox(width: Sp.x4),
          control,
        ],
      ),
    );
  }

  TextStyle _labelStyle(Palette p) =>
      TextStyle(fontSize: Fs.base, height: Lh.snug, color: p.ink);
}
