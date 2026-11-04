// The practice screen's chrome: the mode switch as a ruled page header, the
// deck readout as one sentence, and a decision column that is centred in the
// pane it was given.
//
// Three separate complaints are pinned here, because all three are the kind of
// thing a later refactor can quietly undo:
//
//   * the switch used to float on the page background with no edge under it,
//     so it read as a control dropped on top of the screen rather than as the
//     line naming which page you were on;
//   * the deck picker printed its three numbers as three labelled figures, one
//     of them counting cards the side panel already counted on the same screen;
//   * the intro column was capped at 620dp and pinned to the left edge, which
//     on a wide pane spent the whole difference as a gap under one edge.
//
// The geometry below is computed from the same public constants the layout
// uses (`Layout.contentMax`, `Sp.x6`, `StudySplit.sideWidth`), so it states the
// rule rather than a screenshot of one window size.

import 'package:flutter/material.dart' hide Card;
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/app/scope.dart';
import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/data/services/tts.dart';
import 'package:lexumo/domain/models/seed.dart';
import 'package:lexumo/domain/models/types.dart';
import 'package:lexumo/ui/core/i18n/i18n.dart';
import 'package:lexumo/ui/core/theme.dart';
import 'package:lexumo/ui/core/tokens.dart';
import 'package:lexumo/ui/core/widgets/widgets.dart';
import 'package:lexumo/ui/features/practice/views/practice_page.dart';

import 'support/fake_tts.dart';

/// The practice screen inside a [window]-sized window whose page body is
/// [body] dp wide — the arrangement the shell produces on desktop, where the
/// sidebar eats 232dp of the window before the page sees any of it.
Future<void> pumpPractice(
  WidgetTester tester, {
  required double window,
  required double body,
  double height = 900,
}) async {
  final store = Store(persistence: MemoryStore(), seed: seedData);
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
          i18n: I18n(UiLang.zhCN),
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
}

/// The one vertical scroll view on the screen: `PageShell`'s body. The two
/// horizontal strips in the intro are deliberately excluded.
Finder get _verticalScrollable => find.byWidgetPredicate(
      (Widget w) =>
          w is Scrollable && w.axisDirection == AxisDirection.down,
    );

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);
  setUp(() => debugSetSpeech(silentSpeech()));
  tearDown(() => debugSetSpeech(null));

  group('the mode switch is the page header', () {
    testWidgets('it sits in a ruled strip above the body', (
      WidgetTester tester,
    ) async {
      await pumpPractice(tester, window: 1440, body: 1208);

      expect(find.byType(PinnedStrip), findsOneWidget);
      final Rect strip = tester.getRect(find.byType(PinnedStrip));
      final Rect switcher = tester.getRect(
        find.byType(Segmented<PracticeMode>),
      );
      final Rect intro = tester.getRect(find.text('组卡方式'));

      expect(
        strip.contains(switcher.center),
        isTrue,
        reason: 'the switch is inside the strip, not loose on the body',
      );
      expect(
        strip.bottom,
        lessThanOrEqualTo(intro.top),
        reason: 'the strip owns the space above the sub-page',
      );
    });

    testWidgets('the strip lives outside the body scroll view', (
      WidgetTester tester,
    ) async {
      await pumpPractice(tester, window: 1440, body: 1208);

      // The invariant, independent of how tall the picker happens to be: the
      // header is not inside the scroller, so no amount of scrolling can move
      // it — and the sub-page body is, so it scrolls under the strip.
      expect(
        find.ancestor(
          of: find.byType(PinnedStrip),
          matching: _verticalScrollable,
        ),
        findsNothing,
        reason: 'a header inside the scroller would scroll away',
      );
      expect(
        find.ancestor(of: find.text('组卡方式'), matching: _verticalScrollable),
        findsOneWidget,
        reason: 'the body scrolls; the header does not',
      );
    });
  });

  group('the deck readout is one sentence', () {
    testWidgets('due, new and total print once, on one line', (
      WidgetTester tester,
    ) async {
      await pumpPractice(tester, window: 1440, body: 1208);

      final Finder readout = find.textContaining(
        RegExp(r'^待复习 \d+ · 新卡 \d+ · 共 \d+ 张$'),
      );
      expect(readout, findsOneWidget);
      // The three separate figure labels are gone with their widgets.
      expect(find.text('张到期'), findsNothing);
      expect(find.text('张新卡'), findsNothing);
      expect(find.text('本组卡片'), findsNothing);
    });
  });

  group('the decision column is centred', () {
    testWidgets('it splits the difference either side of the 620dp measure', (
      WidgetTester tester,
    ) async {
      const double body = 1208;
      await pumpPractice(tester, window: 1440, body: body);

      final double content = body < Layout.contentMax ? body : Layout.contentMax;
      final double pageLeft = (body - content) / 2;
      final double inner = content - Sp.x6 * 2;
      final double main = inner >= StudySplit.splitAt
          ? inner - StudySplit.sideWidth - Sp.x5
          : inner;
      final double expected = pageLeft + Sp.x6 + (main - 620) / 2;

      expect(
        tester.getRect(find.text('组卡方式')).left,
        moreOrLessEquals(expected, epsilon: 1),
        reason: 'a 620dp column in a ${main}dp pane has equal margins',
      );
    });
  });

  group('the quiz intro states its size once', () {
    testWidgets('the direction is named by the picker only', (
      WidgetTester tester,
    ) async {
      final I18n i18n = I18n(UiLang.zhCN);
      await pumpPractice(tester, window: 1440, body: 1208);

      await tester.tap(find.text(i18n.t('practice.quiz')));
      await tester.pumpAndSettle();

      expect(
        find.textContaining(RegExp(r'^每轮 \d+ 题$')),
        findsOneWidget,
        reason: 'the round length is the fact the picker cannot state',
      );
      expect(
        find.text(i18n.t('quiz.termToDef')),
        findsOneWidget,
        reason: 'the direction appears in the picker, and nowhere else',
      );
      // The switch moved with it: same strip, same page chrome.
      expect(
        find.ancestor(
          of: find.byType(Segmented<PracticeMode>),
          matching: find.byType(PinnedStrip),
        ),
        findsOneWidget,
      );
    });
  });

  group('a phone keeps the header and the readout', () {
    testWidgets('nothing overflows at 411dp', (WidgetTester tester) async {
      await pumpPractice(tester, window: 411, body: 411, height: 860);

      expect(tester.takeException(), isNull);
      expect(find.byType(Segmented<PracticeMode>), findsOneWidget);
      expect(
        find.textContaining(RegExp(r'^待复习 \d+ · 新卡 \d+ · 共 \d+ 张$')),
        findsOneWidget,
      );
    });
  });
}
