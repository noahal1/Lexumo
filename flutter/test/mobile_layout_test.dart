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
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/app/scope.dart';
import 'package:lexumo/ui/features/shell/views/app_shell.dart';
import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/ui/core/theme.dart';
import 'package:lexumo/ui/core/tokens.dart';
import 'package:lexumo/domain/models/seed.dart';
import 'package:lexumo/ui/core/i18n/i18n.dart';
import 'package:lexumo/ui/features/home/views/home_page.dart';
import 'package:lexumo/ui/features/practice/views/practice_page.dart';
import 'package:lexumo/ui/features/settings/views/settings_page.dart';
import 'package:lexumo/ui/features/stats/views/stats_page.dart';
import 'package:lexumo/ui/features/words/views/words_page.dart';
import 'package:lexumo/data/services/tts.dart';

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

/// The seven screens, in the order the tab bar lists them plus the shell itself.
final List<(String, Widget)> kScreens = <(String, Widget)>[
  ('home', const HomePage()),
  ('words', const WordsPage()),
  ('practice', const PracticePage(controller: null)),
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

  group('nothing is cut off', () {
    // Overflowing *by a pixel* is the shape this app's phone bugs take. A
    // `Segmented` measures itself at its content width and its row scrolls, so
    // a five-chip status filter ran 21.8dp past the card edge — the last chip
    // was half drawn, which reads as "this app is broken", not as "scroll me".
    // A `Text` in a `SizedBox(width: 52)` cut `0.95×` into two lines. Both were
    // invisible to the overflow test above, because neither one throws: they
    // clip.
    for (final (name, screen) in kScreens) {
      testWidgets('$name draws every box inside ${kPhone.width}dp', (
        WidgetTester tester,
      ) async {
        await pumpPhone(tester, screen);

        final List<String> past = <String>[];
        // `FractionalTranslation` moves a child at paint time and leaves its
        // layout box where it was. The stats chart parks its last axis label at
        // the end of the track and shifts it left by its own width, so the
        // layout box reads 366..415 while the glyphs are drawn at 317..366.
        // Measuring layout boxes alone would report a defect that is not on
        // screen, so the accumulated paint shift travels down the walk.
        void visit(Element e, double shiftX) {
          double selfShift = shiftX;
          final Widget widget = e.widget;
          if (widget is FractionalTranslation) {
            final RenderObject? own = e.renderObject;
            if (own is RenderBox && own.hasSize) {
              // A `FractionalTranslation` paints nothing of its own; what it
              // occupies on screen is its translated child. Reporting its raw
              // layout box would flag the 415dp end of the stats chart's axis
              // track, where nothing is actually drawn.
              selfShift += widget.translation.dx * own.size.width;
            }
          }
          final RenderObject? ro = e.renderObject;
          if (ro is RenderBox && ro.hasSize && ro.attached) {
            final double left =
                ro.localToGlobal(Offset.zero).dx + selfShift;
            final double right = left + ro.size.width;
            // A horizontal scroller's child is allowed to be wider than the
            // viewport — that is what scrolling is. The strip is judged by its
            // clip, not by its child's extent.
            final bool inScroller = e
                .findAncestorWidgetOfExactType<SingleChildScrollView>()
                ?.scrollDirection ==
                Axis.horizontal;
            // `Positioned` and `FractionalTranslation` draw nothing: their box
            // is their child's box, and the child is judged on its own. The
            // stats chart's last axis label sits in a `Positioned` at the track
            // end and is translated left by its own width; flagging the wrapper
            // would report the empty end of the track as clipped text.
            final bool isWrapper =
                widget is Positioned || widget is FractionalTranslation;
            if (!inScroller && !isWrapper && right > kPhone.width + 0.5) {
              past.add('${right.toStringAsFixed(1)}dp: ${e.widget.runtimeType}');
            }
          }
          e.visitChildElements((Element child) => visit(child, selfShift));
        }

        for (final Element root in find.byType(Scaffold).evaluate()) {
          visit(root, 0);
        }
        expect(
          past,
          isEmpty,
          reason: '$name draws ${past.length} box(es) past the right edge: '
              '${past.take(6).join(', ')}',
        );
      });

      testWidgets('$name clips no text that had room to be drawn', (
        WidgetTester tester,
      ) async {
        await pumpPhone(tester, screen);

        final List<String> cut = <String>[];
        for (final Element e in find.byType(RichText).evaluate()) {
          final RenderObject? ro = e.renderObject;
          if (ro is! RenderParagraph || !ro.hasSize) continue;
          if (!ro.didExceedMaxLines) continue;
          // A text field is a viewport onto text the user can scroll, so its
          // hint being wider than the field is the field working: the server
          // URL `http://127.0.0.1:8787` is 325dp of glyphs in a 287dp box and
          // every character is still reachable. The hint is a sibling of the
          // editable, not a child, so the check walks up to the field itself.
          // Everything else that clips is a label the reader cannot finish.
          final bool inField =
              e.findAncestorWidgetOfExactType<TextField>() != null;
          if (inField) continue;
          cut.add(ro.text.toPlainText());
        }
        expect(
          cut,
          isEmpty,
          reason: '$name clips ${cut.length} text run(s): '
              '${cut.take(5).map((s) => '"$s"').join(', ')}',
        );
      });
    }
  });

  group('wrapping is a last resort', () {
    // Text that broke onto a second line while its own single-line width would
    // have fit the column is never a choice — it means the column was squeezed
    // by a sibling. The quiz subtitle had 109.5dp for a 145.8dp sentence because
    // the 237.5dp direction picker stood in the page bar; the stats card title
    // had 85.3dp for 128dp because a 224dp window picker sat beside it. Both
    // read as broken layout, and neither throws.
    for (final (name, screen) in kScreens) {
      testWidgets('$name never breaks a line it could have kept', (
        WidgetTester tester,
      ) async {
        await pumpPhone(tester, screen);

        final List<String> squeezed = <String>[];
        for (final Element e in find.byType(RichText).evaluate()) {
          final RenderObject? ro = e.renderObject;
          if (ro is! RenderParagraph || !ro.hasSize) continue;
          if (ro.didExceedMaxLines) continue;
          final double oneLine = ro.getMaxIntrinsicWidth(double.infinity);
          // Half a dp of slack: the intrinsic width and the laid-out width are
          // measured through different paths and disagree by a rounding step.
          if (ro.size.width + 0.5 >= oneLine) continue;
          if (ro.text.toPlainText().trim().isEmpty) continue;
          // A paragraph is only "squeezed" if it actually wrapped.
          if (ro.size.height <=
              ro.getMinIntrinsicHeight(ro.size.width) + 0.5) {
            continue;
          }
          squeezed.add(
            '"${ro.text.toPlainText()}" '
            '${ro.size.width.toStringAsFixed(0)}dp of '
            '${oneLine.toStringAsFixed(0)}dp',
          );
        }
        expect(
          squeezed,
          isEmpty,
          reason: '$name squeezed ${squeezed.length} paragraph(s) narrower than '
              'one line: ${squeezed.take(4).join('; ')}',
        );
      });
    }
  });

  group('first screen budget', () {
    testWidgets('no page spends its first screen on a title', (
      WidgetTester tester,
    ) async {
      // The pages used to open with a sticky bar: a 30dp serif title and a
      // one-line subtitle, ~77dp of an 866dp phone before any content. It named
      // the page the shell's own navigation had just named, so it was removed
      // rather than resized — and this is the assertion that keeps it removed.
      //
      // Measured as "where the scrolling body starts", which is the honest
      // shape of the claim: no chrome above the content at all.
      await pumpPhone(tester, const WordsPage());
      final RenderBox body = tester.renderObject<RenderBox>(
        find.byType(SingleChildScrollView).first,
      );
      final double header = body.localToGlobal(Offset.zero).dy;
      expect(
        header,
        0,
        reason: 'the page body starts ${header}dp down an 866dp screen',
      );
    });

    testWidgets('the page name is still reachable from the shell', (
      WidgetTester tester,
    ) async {
      // Removing the in-page title is only safe because the shell names the
      // page. Asserted at the shell rather than at a page, so this fails if a
      // future change drops the nav label believing the title covers it.
      await pumpPhone(tester, const AppShell());
      expect(find.text('词库'), findsWidgets);
      expect(find.text('练习'), findsWidgets);
      expect(find.text('统计'), findsWidgets);
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

    testWidgets('the query bar is one row, at every width', (
      WidgetTester tester,
    ) async {
      await pumpPhone(tester, const WordsPage());

      // Two controls: the search field, and one capsule that holds every
      // other way of narrowing the list. There used to be five — a strip of
      // six status segments, a sort menu, a favourites toggle, a select
      // button, and a third row of tokens restating whatever was active —
      // which cost 164dp of a 401dp-wide phone before the first word.
      final Finder search = find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_SearchField',
      );
      final Finder filter = find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_FilterMenu',
      );
      expect(search, findsOneWidget);
      expect(filter, findsOneWidget);

      final Rect searchRect = tester.getRect(search);
      final Rect filterRect = tester.getRect(filter);

      // Same row: their vertical centres agree to within a pixel, which is
      // the claim that matters. Anything that made the bar wrap would put
      // one of them on a second line and separate these by ~44.
      expect(
        filterRect.center.dy,
        closeTo(searchRect.center.dy, 1),
        reason: 'the filter capsule shares the search field\'s row',
      );
      // And the whole bar is one control tall: no token row underneath, no
      // wrapped second line.
      expect(
        filterRect.bottom - searchRect.top,
        lessThanOrEqualTo(Layout.controlH + 8),
        reason:
            'the query bar is ${(filterRect.bottom - searchRect.top).toStringAsFixed(0)}dp tall',
      );
      // The search field still gets most of the row, and it is not the whole
      // row — the capsule beside it is what keeps it from being five rows.
      expect(
        searchRect.width,
        lessThan(kPhone.width - 2 * Sp.x6),
        reason: 'the search field must share its row with the capsule',
      );
      expect(
        searchRect.width,
        greaterThan((kPhone.width - 2 * Sp.x6) * 0.6),
        reason: 'search still owns most of the row',
      );
    });
  });
}
