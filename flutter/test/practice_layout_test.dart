// The practice screen's front page: the one screen that decides a sitting
// before it starts.
//
// What is pinned here is the shape of the decision, not a screenshot of it:
//
//   * the page names itself — every other screen lets the sidebar or the tab
//     bar do that, and this one cannot, because the first thing it shows is a
//     choice;
//   * the big figure is the round's real size, clamped to the pool. A number
//     that promises 20 and delivers 7 is the one thing this screen must never
//     do;
//   * every option on the page changes the round it describes — and the quiz
//     does not show the card-only ones, because a switch that does nothing is
//     worse than a switch that is absent;
//   * 开始复习 is the only way in, and it is disabled rather than misleading
//     when there is nothing to review.
//
// The old assertions here (`组卡方式` in a ruled strip, `待复习 N · 新卡 N · 共 N
// 张` as one sentence, a 620dp decision column) described the previous
// arrangement, where the deck picker was a header above a sub-page. The picker
// moved into this page and became the page, so they are gone rather than
// rewritten in place.

import 'package:flutter/material.dart' hide Card;
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/app/scope.dart';
import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/data/services/tts.dart';
import 'package:lexumo/domain/models/seed.dart';
import 'package:lexumo/domain/models/quiz.dart' show QuizDirection;
import 'package:lexumo/domain/models/srs.dart' show DAY_MS;
import 'package:lexumo/domain/models/types.dart';
import 'package:lexumo/domain/use_cases/deck_plan.dart';
import 'package:lexumo/ui/core/i18n/i18n.dart';
import 'package:lexumo/ui/core/theme.dart';
import 'package:lexumo/ui/core/tokens.dart';
import 'package:lexumo/ui/core/widgets/controls.dart';
import 'package:lexumo/ui/core/widgets/lex_icon.dart';
import 'package:lexumo/ui/core/widgets/widgets.dart';
import 'package:lexumo/ui/features/practice/view_models/practice_view_model.dart';
import 'package:lexumo/ui/features/practice/views/practice_page.dart';

import 'support/fake_tts.dart';

const I18n _i18n = I18n(UiLang.zhCN);

/// One word with no schedule — a card the planner counts as 新卡.
Word _newWord(String id) => Word(
      id: id,
      term: 'term-$id',
      definition: '释义 $id',
      definition2: '',
      example: '',
      note: '',
      status: WordStatus.new_,
      favorite: false,
      listId: DEFAULT_LIST_ID,
      sourceLang: 'en',
      targetLang: 'zh-CN',
      listenCount: 0,
      srs: null,
      createdAt: 0,
      updatedAt: 0,
    );

/// A snapshot holding exactly [count] brand-new words, so a test can state what
/// the pool is instead of reading it back out of the seed.
///
/// The daily new-card allowance is lifted well above the pool on purpose: the
/// figures under test are about the *round*, and the default allowance of 15
/// would cap a 30-word pool at 15 and make the expected number ambiguous.
AppData _poolOf(int count) => AppData(
      lists: <WordList>[
        const WordList(
          id: DEFAULT_LIST_ID,
          name: 'test',
          sourceLang: 'en',
          targetLang: 'zh-CN',
          createdAt: 0,
          updatedAt: 0,
        ),
      ],
      words: <Word>[for (int i = 0; i < count; i++) _newWord('$i')],
      logs: const <ReviewLog>[],
      settings: const Settings(newCardsPerDay: 200),
    );

/// A snapshot whose [count] words are all scheduled a month out — nothing is
/// due, so the 待复习 pool is empty without the deck being empty.
AppData _nothingDue(int count, int now) {
  final AppData base = _poolOf(count);
  return base.copyWith(
    words: <Word>[
      for (final Word word in base.words)
        word.copyWith(
          status: WordStatus.reviewing,
          srs: SrsState(
            ease: 2.5,
            intervalDays: 30,
            dueAt: now + 30 * DAY_MS,
            reviewCount: 3,
            correctCount: 3,
            lastReviewedAt: now - DAY_MS,
          ),
        ),
    ],
  );
}

/// The practice screen inside a [window]-sized window whose page body is
/// [body] dp wide — the arrangement the shell produces on desktop, where the
/// sidebar eats 232dp of the window before the page sees any of it.
///
/// Returns the store so a test can read the snapshot the page is rendering and
/// compare the figure on screen with the one the domain says it should be.
Future<Store> pumpPractice(
  WidgetTester tester, {
  required double window,
  required double body,
  double height = 900,
  AppData Function(int now)? seed,
}) async {
  final Store store = Store(
    persistence: MemoryStore(),
    seed: seed ?? seedData,
    saveDelayMs: 0,
  );
  await store.init();
  await store.flush();

  tester.view.physicalSize = Size(window, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: Size(window, height)),
      child: StoreScope(
        notifier: StoreNotifier(store),
        child: I18nScope(
          i18n: _i18n,
          child: ToastScope(
            show: (text, kind, {actionLabel, onAction, durationMs}) {},
            child: NavScope(
              onNavigate: (_) {},
              child: MaterialApp(
                theme: buildTheme(Palette.light),
                home: Scaffold(
                  body: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: body,
                      height: height,
                      child: const PracticePage(controller: null),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

/// The one vertical scroll view on the screen: `PageShell`'s body.
Finder get _verticalScrollable => find.byWidgetPredicate(
      (Widget w) => w is Scrollable && w.axisDirection == AxisDirection.down,
    );

/// The stepper's + button. Identified by its icon rather than by position: the
/// minus button sits in the same row and is the same size.
Finder get _stepperPlus => find.descendant(
      of: find.byType(LexStepper),
      matching: find.byWidgetPredicate(
        (Widget w) => w is LexIcon && w.name == Ic.plus,
      ),
    );

/// One switch, found by the label it announces. Two of them sit on this page
/// and they differ only in that label, so position would be a guess.
Finder _switch(String label) => find.byWidgetPredicate(
      (Widget w) => w is LexSwitch && w.label == label,
    );

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);
  setUp(() => debugSetSpeech(silentSpeech()));
  tearDown(() => debugSetSpeech(null));

  group('the front page names itself', () {
    testWidgets('the title sits above the first control', (
      WidgetTester tester,
    ) async {
      await pumpPractice(tester, window: 1440, body: 1208);

      final Finder title = find.text(_i18n.t('practice.title'));
      expect(title, findsOneWidget);

      // Above, not beside: the title is the page's name, and a name printed
      // next to the first control reads as that control's label.
      expect(
        tester.getRect(title).bottom,
        lessThanOrEqualTo(
          tester.getRect(find.byType(Segmented<PracticeMode>)).top,
        ),
        reason: 'the page name comes before the choice it introduces',
      );
      expect(
        find.ancestor(of: title, matching: _verticalScrollable),
        findsOneWidget,
        reason: 'the title scrolls with the form; it is not pinned chrome',
      );
    });
  });

  // Wave 3.2: the start button used to sit below four option rows inside a
  // 560dp column, so on a 1600x1000 desktop it took ~600dp of scrolling to
  // reach the one control the screen exists for. It now shares a lane with the
  // round figure, beside (desktop) or just above (phone) the options.
  group('the start action is in the first screen', () {
    testWidgets('a desktop keeps the button above the fold', (
      WidgetTester tester,
    ) async {
      await pumpPractice(tester, window: 1440, body: 1208, height: 900);

      final Finder start = find.widgetWithText(
        LexButton,
        _i18n.t('flashcards.start'),
      );
      expect(start, findsOneWidget);
      expect(
        tester.getRect(start).bottom,
        lessThanOrEqualTo(900),
        reason: 'the round is startable without scrolling a 900dp-tall window',
      );
    });

    testWidgets('a phone keeps the button above the fold', (
      WidgetTester tester,
    ) async {
      await pumpPractice(tester, window: 411, body: 411, height: 860);

      final Finder start = find.widgetWithText(
        LexButton,
        _i18n.t('flashcards.start'),
      );
      expect(start, findsOneWidget);
      expect(
        tester.getRect(start).bottom,
        lessThanOrEqualTo(860),
        reason: 'the round is startable without scrolling an 860dp-tall phone',
      );
    });

    testWidgets('a desktop sets the launch lane beside the options', (
      WidgetTester tester,
    ) async {
      await pumpPractice(tester, window: 1440, body: 1208);

      final Rect figure = tester.getRect(
        find.text(_i18n.t('practice.thisRound')),
      );
      final Rect options = tester.getRect(
        find.text(_i18n.t('practice.options')),
      );
      expect(
        figure.right,
        lessThanOrEqualTo(options.left),
        reason: 'the launch block is a column to the left of the options, '
            'not a full-width row above them',
      );
    });
  });

  group('the round figure states what will happen', () {
    testWidgets('it prints the pool size when the pool is smaller', (
      WidgetTester tester,
    ) async {
      // Seven words, a round size of 20: the figure must say 7, because that is
      // how many cards 开始复习 will actually hand over.
      final Store store = await pumpPractice(
        tester,
        window: 1440,
        body: 1208,
        seed: (_) => _poolOf(7),
      );
      expect(summarizeDeck(store.data, 0).counts[DeckSource.due], 7);
      expect(store.data.settings.roundSize, 20);

      expect(
        find.text('7'),
        findsWidgets,
        reason: 'the figure is the clamped size, not the requested one',
      );
      expect(
        find.text(_i18n.t('practice.thisRound')),
        findsOneWidget,
        reason: 'the caption says which number the figure is',
      );
    });

    testWidgets('the stepper moves the figure and the setting together', (
      WidgetTester tester,
    ) async {
      final Store store = await pumpPractice(
        tester,
        window: 1440,
        body: 1208,
        seed: (_) => _poolOf(30),
      );
      expect(find.text('20'), findsWidgets);

      await tester.tap(_stepperPlus);
      await tester.pumpAndSettle();
      await store.flush();

      expect(store.data.settings.roundSize, 21);
      expect(find.text('21'), findsWidgets);
      expect(find.text('20'), findsNothing);
    });
  });

  group('options change the round they describe', () {
    testWidgets('随机 writes the review order', (WidgetTester tester) async {
      final Store store = await pumpPractice(tester, window: 1440, body: 1208);
      expect(store.data.settings.reviewOrder, 'due');

      // Tap the switch, not the label: the label is a separate Text on the far
      // left of the row, and tapping it would prove nothing.
      await tester.tap(_switch(_i18n.t('practice.random')));
      await tester.pumpAndSettle();
      await store.flush();

      expect(store.data.settings.reviewOrder, 'random');
    });

    testWidgets('先显示译文 writes the card orientation', (
      WidgetTester tester,
    ) async {
      final Store store = await pumpPractice(tester, window: 1440, body: 1208);
      expect(store.data.settings.translationFirst, isFalse);

      await tester.tap(_switch(_i18n.t('practice.translationFirst')));
      await tester.pumpAndSettle();
      await store.flush();

      expect(store.data.settings.translationFirst, isTrue);
    });

    testWidgets('自动朗读 shows the state the two flags encode', (
      WidgetTester tester,
    ) async {
      final Store store = await pumpPractice(tester, window: 1440, body: 1208);
      // The defaults are autoPlayAudio: true, autoPlayFront: false — the select
      // must show 背面, not a placeholder.
      expect(
        find.text(_i18n.t('practice.autoPlayBack')),
        findsOneWidget,
        reason: 'the select reads its value out of the settings',
      );

      await tester.tap(find.text(_i18n.t('practice.autoPlayBack')));
      await tester.pumpAndSettle();
      for (final String key in <String>[
        'practice.autoPlayOff',
        'practice.autoPlayFront',
        'practice.autoPlayBoth',
      ]) {
        expect(find.text(_i18n.t(key)), findsWidgets, reason: 'menu has $key');
      }

      await tester.tap(find.text(_i18n.t('practice.autoPlayOff')).last);
      await tester.pumpAndSettle();
      await store.flush();

      expect(store.data.settings.autoPlayAudio, isFalse);
      expect(store.data.settings.autoPlayFront, isFalse);
    });
  });

  group('the quiz drops the card-only options', () {
    testWidgets('it keeps the direction and loses the card switches', (
      WidgetTester tester,
    ) async {
      await pumpPractice(tester, window: 1440, body: 1208);

      await tester.tap(find.text(_i18n.t('practice.quiz')));
      await tester.pumpAndSettle();

      // Card-only controls are gone: a scope switch above a quiz round, a
      // translation-first switch on a question that already shows the meaning,
      // and an auto-play switch on a screen with no faces.
      expect(find.text(_i18n.t('practice.scopeDue')), findsNothing);
      expect(find.text(_i18n.t('practice.translationFirst')), findsNothing);
      expect(find.text(_i18n.t('practice.autoPlay')), findsNothing);
      // The ones that survive are the ones the quiz reads.
      expect(find.text(_i18n.t('practice.direction')), findsOneWidget);
      expect(find.text(_i18n.t('practice.roundSizeQuiz')), findsOneWidget);
      expect(find.text(_i18n.t('quiz.termToDef')), findsOneWidget);
    });
  });

  group('开始复习 is the only way in', () {
    testWidgets('it mounts the session and drops the picker', (
      WidgetTester tester,
    ) async {
      await pumpPractice(tester, window: 1440, body: 1208);

      await tester.tap(
        find.widgetWithText(LexButton, _i18n.t('flashcards.start')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('flip-card')), findsOneWidget);
      // The front page is gone, including its picker: the round was decided
      // before the card appeared, so there is nothing here to re-decide.
      expect(find.text(_i18n.t('practice.options')), findsNothing);
      expect(find.text(_i18n.t('flashcards.buildDeck')), findsNothing);
      expect(find.text(_i18n.t('practice.title')), findsNothing);
    });

    testWidgets('an empty pool disables it and says why', (
      WidgetTester tester,
    ) async {
      await pumpPractice(
        tester,
        window: 1440,
        body: 1208,
        seed: (int now) => _nothingDue(3, now),
      );

      final LexButton start = tester.widget<LexButton>(
        find.widgetWithText(LexButton, _i18n.t('flashcards.start')),
      );
      expect(start.onPressed, isNull, reason: 'disabled, not a silent no-op');
      expect(find.text(_i18n.t('practice.emptyPool')), findsOneWidget);
    });
  });

  group('a phone keeps the whole form', () {
    testWidgets('nothing overflows at 411dp', (WidgetTester tester) async {
      await pumpPractice(tester, window: 411, body: 411, height: 860);

      expect(tester.takeException(), isNull);
      expect(find.byType(Segmented<PracticeMode>), findsOneWidget);
      expect(find.byType(Segmented<PracticeScope>), findsOneWidget);
      expect(find.byType(LexStepper), findsOneWidget);
      expect(find.byType(LexSwitch), findsNWidgets(2));
    });
  });

  // The two strips at the top of the page are not toolbar filters: they are the
  // question the screen asks, and each holds exactly two labels. Drawn at the
  // inline scale they measured 88dp across in total, with 4dp of padding a
  // side, so 卡片 and 测验 stood shoulder to shoulder inside a lozenge barely
  // wider than the two characters. A page-scale chip is at least 88dp wide.
  group('the two strips are page decisions, not filters', () {
    testWidgets('each chip is wide enough to hold its label', (
      WidgetTester tester,
    ) async {
      await pumpPractice(tester, window: 411, body: 411, height: 860);

      for (final Finder strip in <Finder>[
        find.byType(Segmented<PracticeMode>),
        find.byType(Segmented<PracticeScope>),
      ]) {
        final Finder chips = find.descendant(
          of: strip,
          matching: find.byType(GestureDetector),
        );
        expect(chips, findsNWidgets(2));
        for (final Element chip in chips.evaluate()) {
          expect(
            tester.getSize(find.byWidget(chip.widget)).width,
            greaterThanOrEqualTo(88),
            reason: 'a page chip holds its own label with air around it',
          );
        }
      }
    });

    testWidgets('a toolbar strip stays inline', (WidgetTester tester) async {
      // The direction picker on the quiz side lives inside an option row and
      // must keep the tight geometry: 词语 → 释义 is far longer than 卡片.
      await pumpPractice(tester, window: 411, body: 411, height: 860);
      await tester.tap(find.text(_i18n.t('practice.quiz')));
      await tester.pumpAndSettle();

      final Finder strip = find.byType(Segmented<QuizDirection>);
      expect(strip, findsOneWidget);
      expect(
        tester.widget<Segmented<QuizDirection>>(strip).scale,
        SegScale.inline,
      );
    });
  });

  // One shape per row, at every width. The row used to drop its control under
  // its label below 420dp, which on a 411dp phone folded all four rows into two
  // lines and stood them 98dp apart: the list read as three unrelated blocks
  // instead of one list of four settings.
  group('an option row is one line at every width', () {
    for (final double width in <double>[320, 360, 411, 1208]) {
      testWidgets('label and control share a line at ${width.toInt()}dp', (
        WidgetTester tester,
      ) async {
        await pumpPractice(tester, window: width, body: width, height: 900);

        final Map<String, Finder> rows = <String, Finder>{
          'practice.roundSizeCards': find.byType(LexStepper),
          'practice.autoPlay': find.byType(LexSelect<AutoPlayWhen>),
        };
        rows.forEach((String key, Finder control) {
          expect(control, findsOneWidget, reason: 'no $key control to measure');
          final Rect label = tester.getRect(find.text(_i18n.t(key)));
          final Rect c = tester.getRect(control);
          // Sharing a line means sharing a vertical band. Comparing vertical
          // centres rather than rect overlap: label and control are side by
          // side, so their rectangles never intersect even on one line.
          expect(
            (label.center.dy - c.center.dy).abs(),
            lessThan(c.height / 2),
            reason: '${_i18n.t(key)} and its control sat on different lines',
          );
          expect(
            label.right,
            lessThanOrEqualTo(c.left),
            reason: 'the label ran into its control instead of ending before it',
          );
        });
      });
    }
  });
}
