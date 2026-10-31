// The phone layout, asserted rather than photographed.
//
// A screenshot can show that a page *looks* cramped but it cannot say what the
// budget was spent on, and a phone is the only place this design system's
// desktop measurements stop being true. Three kinds of claim are made here, and
// each one failed at least once while the mobile pass was being written:
//
//   · **nothing overflows at phone width.** `RenderFlex overflowed by 40
//     pixels` is how the settings page announced that a 260dp desktop select
//     had been mistaken for a minimum.
//   · **every tappable thing is 44dp.** The audit found 54 targets under 44 on
//     the word library alone, most of them 32dp icon buttons.
//   · **the first screen is content, not chrome.** The word library used to
//     spend 164dp of a 401dp-wide phone on three rows of query bar, putting the
//     first word at y=358 of an 805dp body.
//
// The numbers below are budgets, not measurements of one machine: they are the
// largest values the design tolerates, so they hold when a font metric shifts a
// fraction of a pixel.

import 'package:flutter/material.dart' hide Card;
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/app/scope.dart';
import 'package:lexumo/app/shell.dart';
import 'package:lexumo/data/snapshot_store.dart';
import 'package:lexumo/data/store.dart';
import 'package:lexumo/design/theme.dart';
import 'package:lexumo/design/tokens.dart';
import 'package:lexumo/domain/seed.dart';
import 'package:lexumo/i18n/i18n.dart';
import 'package:lexumo/pages/flashcards_page.dart';
import 'package:lexumo/pages/quiz_page.dart';
import 'package:lexumo/pages/settings_page.dart';
import 'package:lexumo/pages/stats_page.dart';
import 'package:lexumo/pages/words_page.dart';
import 'package:lexumo/platform/tts.dart';
import 'package:lexumo/ui/controls.dart';
import 'package:lexumo/ui/widgets.dart';

import 'support/fake_tts.dart';

/// The emulator's logical viewport: 1080x2400 at 2.625, minus the system bars
/// Android reserves. This is what the app is actually given.
const Size kPhone = Size(411, 866);

/// Mounts [child] at [kPhone] and settles.
Future<void> pumpPhone(WidgetTester tester, Widget child) async {
  final store = Store(persistence: MemoryStore(), seed: seedData);
  await store.init();
  await store.flush();

  tester.view.physicalSize = kPhone;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    StoreScope(
      notifier: StoreNotifier(store),
      child: I18nScope(
        i18n: I18n(store.data.settings.uiLang),
        child: ToastScope(
          show: (text, kind, {actionLabel, onAction, durationMs}) {},
          child: NavScope(
            onNavigate: (_) {},
            child: MaterialApp(
              theme: buildTheme(Palette.light),
              home: Scaffold(body: child),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The six screens, in the order the tab bar lists them plus the shell itself.
final List<(String, Widget)> kScreens = <(String, Widget)>[
  ('words', const WordsPage()),
  ('flashcards', const FlashcardsPage(controller: null)),
  ('quiz', const QuizPage(controller: null)),
  ('stats', const StatsPage(controller: null)),
  ('settings', const SettingsPage(controller: null)),
  ('shell', const AppShell()),
];

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);
  setUp(() => debugSetSpeech(silentSpeech()));
  tearDown(() => debugSetSpeech(null));

  group('phone width', () {
    for (final (name, screen) in kScreens) {
      testWidgets('$name does not overflow', (WidgetTester tester) async {
        await pumpPhone(tester, screen);
        expect(
          tester.takeException(),
          isNull,
          reason: '$name must fit 411dp without a layout exception',
        );
      });
    }
  });

  group('touch floor', () {
    // Only the pages. `AppShell` contains every page *and* the chrome, so it is
    // already covered by the five below plus its own test.
    final List<(String, Widget)> pages = kScreens
        .where((s) => s.$1 != 'shell')
        .toList();

    for (final (name, screen) in pages) {
      testWidgets('$name has no target under ${Layout.tap}dp', (
        WidgetTester tester,
      ) async {
        await pumpPhone(tester, screen);

        // `GestureDetector` is the app's own tap primitive — Material's own
        // controls (dialog buttons, the popup menu) are not on screen at rest
        // and are not measured here.
        final List<String> short = <String>[];
        for (final Element e in find.byType(GestureDetector).evaluate()) {
          final RenderObject? ro = e.renderObject;
          if (ro is! RenderBox || !ro.hasSize) continue;
          if (ro.size.width >= Layout.tap && ro.size.height >= Layout.tap) {
            continue;
          }
          short.add(
            '${ro.size.width.toStringAsFixed(1)}x${ro.size.height.toStringAsFixed(1)}',
          );
        }
        expect(
          short,
          isEmpty,
          reason:
              '$name has ${short.length} tap targets below ${Layout.tap}dp: '
              '${short.toSet().join(', ')}',
        );
      });
    }
  });

  group('first screen budget', () {
    testWidgets('the page header stays under 84dp', (WidgetTester tester) async {
      // 87dp of an 866dp screen is 10% spent on a title. The floor is the type:
      // Fs.xl at Lh.title plus the subtitle, so this budget is about air, not
      // about shrinking the heading.
      await pumpPhone(tester, const WordsPage());
      final RenderBox body = tester.renderObject<RenderBox>(
        find.byType(SingleChildScrollView).first,
      );
      final double header = body.localToGlobal(Offset.zero).dy;
      expect(
        header,
        lessThanOrEqualTo(84),
        reason: 'the sticky header is ${header}dp of an 866dp screen',
      );
    });

    testWidgets('the first word is above the fold', (
      WidgetTester tester,
    ) async {
      await pumpPhone(tester, const WordsPage());

      // The first row of the table is the first full-width opaque tap target.
      // Measuring the row itself rather than the list strip that precedes it
      // keeps this budget about "how much of the first screen is content".
      double? firstRowTop;
      for (final Element e in find.byType(GestureDetector).evaluate()) {
        final RenderObject? ro = e.renderObject;
        if (ro is! RenderBox || !ro.hasSize) continue;
        if (ro.size.width < 300 || ro.size.height < 60) continue;
        final double top = ro.localToGlobal(Offset.zero).dy;
        if (firstRowTop == null || top < firstRowTop) firstRowTop = top;
      }
      expect(firstRowTop, isNotNull, reason: 'the seeded store has words');
      // Three rows fit above the tab bar at 306dp; the budget leaves room for a
      // font metric to drift without the assertion becoming a tripwire.
      expect(
        firstRowTop,
        lessThanOrEqualTo(320),
        reason: 'the first word starts at ${firstRowTop}dp',
      );
    });

    testWidgets('the query bar folds into two rows, not three', (
      WidgetTester tester,
    ) async {
      await pumpPhone(tester, const WordsPage());

      final Finder strip = find.byType(Segmented<String>);
      expect(strip, findsOneWidget);
      final Rect statusRect = tester.getRect(strip);
      final Finder search = find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_SearchField',
      );
      expect(search, findsOneWidget);
      final Rect searchRect = tester.getRect(search);
      final Rect selectRect = tester.getRect(
        find.widgetWithText(LexButton, '批量选择'),
      );

      // Row one: the search field shares its row with the sort menu and the
      // favourites toggle, so it is narrower than the bar.
      expect(
        searchRect.width,
        lessThan(kPhone.width - 2 * Sp.x6),
        reason: 'the search field must share its row with the sort menu',
      );
      // Row two: the status strip is wider than what its row leaves it, which is
      // why it lives in a horizontal scroller rather than being squeezed. The
      // point of the assertion is that it shares row two with the select button
      // instead of owning a row of its own.
      expect(
        statusRect.width,
        greaterThan(0),
        reason: 'the status strip must be laid out at its natural width',
      );
      expect(
        selectRect.top,
        closeTo(statusRect.top, 1),
        reason: 'the select button shares the status strip\'s row',
      );
      expect(
        searchRect.top,
        lessThan(statusRect.top),
        reason: 'search is row one, statuses are row two',
      );
      // 24 of padding + 44 + 12 + 44 + 24 = 124 is the whole bar on a phone. The
      // old three-row version was 164.
      expect(
        statusRect.bottom - searchRect.top,
        lessThanOrEqualTo(120),
        reason:
            'the query bar is ${(statusRect.bottom - searchRect.top).toStringAsFixed(0)}dp tall',
      );
    });
  });
}
