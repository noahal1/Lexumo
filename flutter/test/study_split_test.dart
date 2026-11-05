// The practice screens split their body into a study column and a side panel.
//
// Both screens used to decide that split from `MediaQuery.sizeOf(context).width`
// — the *window*, which counts the 232dp sidebar — and to hard-code 1080 as the
// threshold. So a 1081dp window asked for the 296dp panel beside a card that had
// only ~485dp of body left, while resizing to 1080 stacked the panel and handed
// the same card ~800dp. A one-pixel resize rearranged the page and made the
// thing being studied 40% narrower.
//
// `StudySplit` measures the width it is handed instead, so the tests below are
// in two parts: the rule itself at its exact boundary, and one end-to-end case
// shaped like the window/sidebar combination that produced the complaint.

import 'package:flutter/material.dart' hide Card;
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/app/scope.dart';
import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/data/services/tts.dart';
import 'package:lexumo/domain/models/seed.dart';
import 'package:lexumo/ui/core/i18n/i18n.dart';
import 'package:lexumo/ui/core/theme.dart';
import 'package:lexumo/ui/core/tokens.dart';
import 'package:lexumo/ui/core/widgets/controls.dart';
import 'package:lexumo/ui/core/widgets/widgets.dart';
import 'package:lexumo/ui/features/practice/views/practice_page.dart';

import 'support/fake_tts.dart';

/// Pumps a bare [StudySplit] at an exact body width. The children are plain
/// boxes: this test is about where the two columns sit, not what is in them.
Future<void> pumpSplit(WidgetTester tester, double width) async {
  // The test view defaults to 800x600, which would clamp the widths under test.
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Palette.light),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: const StudySplit(
              main: SizedBox(key: Key('main'), height: 200),
              side: SizedBox(key: Key('side'), height: 200),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Pumps the practice screen into a page [body] dp wide inside a [window]-sized
/// window — the arrangement the app shell produces on desktop, where the
/// sidebar takes 232dp of the window before the page sees any of it. The page's
/// own gutters take another 48dp, so [StudySplit] is handed `body - 48`.
Future<void> pumpPractice(
  WidgetTester tester, {
  required double window,
  required double body,
}) async {
  final store = Store(persistence: MemoryStore(), seed: seedData);
  await store.init();
  await store.flush();

  tester.view.physicalSize = Size(window, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: Size(window, 900)),
      child: StoreScope(
        notifier: StoreNotifier(store),
        child: I18nScope(
          i18n: I18n(store.data.settings.uiLang),
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
                      height: 900,
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

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);
  setUp(() => debugSetSpeech(silentSpeech()));
  tearDown(() => debugSetSpeech(null));

  group('StudySplit', () {
    testWidgets('puts the panel beside a card that can keep 560dp', (
      WidgetTester tester,
    ) async {
      for (final double width in <double>[
        StudySplit.splitAt,
        1000,
        1200,
        1360,
      ]) {
        await pumpSplit(tester, width);
        final Rect main = tester.getRect(find.byKey(const Key('main')));
        final Rect side = tester.getRect(find.byKey(const Key('side')));

        expect(
          side.top,
          main.top,
          reason: 'at ${width}dp the panel belongs beside the card',
        );
        expect(
          side.width,
          StudySplit.sideWidth,
          reason: 'the panel has one width, not a flex share',
        );
        expect(
          main.width,
          greaterThanOrEqualTo(StudySplit.mainMin),
          reason: 'at ${width}dp the card must keep at least 560dp',
        );
      }
    });

    testWidgets('stacks the panel below a card that cannot', (
      WidgetTester tester,
    ) async {
      // 875 is one pixel under the threshold: the case that used to fit the
      // panel into a 579dp card.
      for (final double width in <double>[StudySplit.splitAt - 1, 820, 753]) {
        await pumpSplit(tester, width);
        final Rect main = tester.getRect(find.byKey(const Key('main')));
        final Rect side = tester.getRect(find.byKey(const Key('side')));

        expect(
          side.top,
          greaterThanOrEqualTo(main.bottom),
          reason: 'at ${width}dp the panel must sit below the card',
        );
        expect(
          side.width,
          lessThanOrEqualTo(560),
          reason: 'stacked, the panel keeps a readable measure',
        );
      }
    });

    testWidgets('drops the panel on a phone', (WidgetTester tester) async {
      await pumpSplit(tester, 411);
      expect(find.byKey(const Key('side')), findsNothing);
      expect(find.byKey(const Key('main')), findsOneWidget);
    });
  });

  group('the practice screen splits on its body width', () {
    // The split used to be asserted on the practice page's *picker*, which sat
    // in the same scroll view as the side panel. The picker became the page, so
    // the split now only exists inside a round: start one, then compare where
    // the card and the panel ended up.
    const String kReviewsToday = '今日复习';

    Future<void> startRound(WidgetTester tester) async {
      await tester.tap(find.widgetWithText(LexButton, '开始复习'));
      await tester.pumpAndSettle();
    }

    testWidgets('a 1081dp window with a 232dp sidebar stacks the panel', (
      WidgetTester tester,
    ) async {
      // 1081 was the first window width that used to put the panel beside the
      // card. The shell leaves 849 for the page and the gutters leave 801.
      await pumpPractice(tester, window: 1081, body: 849);
      await startRound(tester);

      final Rect card = tester.getRect(
        find.byKey(const ValueKey('flip-card')),
      );
      final Rect panel = tester.getRect(
        find.widgetWithText(StatTile, kReviewsToday),
      );

      expect(
        panel.top,
        greaterThan(card.bottom),
        reason: 'the card has 801dp of body; the panel must not squeeze it',
      );
    });

    testWidgets('a 1440dp window has room for both columns', (
      WidgetTester tester,
    ) async {
      // 1440 minus the 232dp sidebar is 1208; the page caps its content column
      // at 1180 and the gutters leave 1132 for the split.
      await pumpPractice(tester, window: 1440, body: 1208);
      await startRound(tester);

      final Rect card = tester.getRect(
        find.byKey(const ValueKey('flip-card')),
      );
      final Rect panel = tester.getRect(
        find.widgetWithText(StatTile, kReviewsToday),
      );

      expect(
        panel.top,
        lessThan(card.bottom),
        reason: '1160dp of body is enough for a card and the panel in a row',
      );
    });
  });
}
