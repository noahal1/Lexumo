// The 我的 page, asserted rather than photographed.
//
// This screen was built from a reference design, and the claims below are the
// ones that design makes that a screenshot could not prove and a later
// refactor could silently break:
//
//   · **the three figures are centred in equal columns and nothing rules them
//     off.** The reference separates them with whitespace alone; adding a
//     divider "to help" would change what the card means.
//   · **the figures are the page's headline.** Their numerals are printed in
//     the display face at a size no other text on the page uses.
//   · **the action rows are flat.** No box drawn around them, and their glyphs
//     are bare — the reference puts no filled square behind an icon.
//   · **every row is a 44dp target**, which is the phone floor this design
//     system already holds every other screen to.
//   · **settings is reachable from here**, because it is no longer a
//     destination of its own.
//
// The numbers are budgets, not measurements of one machine: they are the
// largest values the design tolerates, so they hold when a font metric shifts a
// fraction of a pixel.

import 'package:flutter/material.dart' hide Card;
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/app/scope.dart';
import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/domain/models/seed.dart';
import 'package:lexumo/domain/models/types.dart';
import 'package:lexumo/ui/core/i18n/i18n.dart';
import 'package:lexumo/ui/core/theme.dart';
import 'package:lexumo/ui/core/tokens.dart';
import 'package:lexumo/ui/core/widgets/lex_icon.dart';
import 'package:lexumo/data/services/file_dialogs.dart';
import 'package:lexumo/ui/features/profile/views/profile_page.dart';
import 'package:lexumo/ui/features/settings/views/settings_page.dart';
import 'package:lexumo/ui/features/shell/views/app_shell.dart';

/// The emulator's logical viewport, the same one the other layout tests use.
const Size kPhone = Size(411, 866);

/// The page's labels, resolved once so a finder can never disagree with the
/// tree about which string it is looking for.
const I18n _zh = I18n(UiLang.zhCN);

/// Mounts the profile page with a real store and no sync session.
///
/// Signed out on purpose: that is the branch that has to invent no person, and
/// it is the one a fresh install actually takes.
Future<void> pumpProfile(
  WidgetTester tester, {
  Size size = kPhone,
}) async {
  final store = Store(persistence: MemoryStore(), seed: seedData);
  await store.init();
  await store.flush();

  tester.view.physicalSize = size;
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
              home: Scaffold(body: const ProfilePage(controller: null)),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Every `Container` on the page, as widgets, for decoration assertions.
Iterable<Container> containers(WidgetTester tester) =>
    tester.widgetList<Container>(find.byType(Container));

/// Whether [d] draws a box the design forbids around a flat row.
bool _hasBoxEdge(BoxDecoration? d) {
  final Border? border = d?.border is Border ? d!.border! as Border : null;
  if (border == null) return false;
  return border.top.width + border.bottom.width + border.left.width + border.right.width > 0;
}

/// The three numerals of the figures card, in reading order.
///
/// Found by their style rather than by their text: the figures are the only
/// text on the page printed in the display face at `Fs.x2xl`, which is exactly
/// the claim being made about them.
List<RenderParagraph> figures(WidgetTester tester) {
  return tester
      .renderObjectList<RenderParagraph>(find.byType(RichText))
      .where((RenderParagraph p) {
    final TextStyle? s = p.text.style;
    return s?.fontFamily == Fonts.display && s?.fontSize == Fs.x2xl;
  }).toList();
}

void main() {
  group('identity block', () {
    testWidgets('signed out, it names the app instead of inventing a person',
        (WidgetTester tester) async {
      await pumpProfile(tester);

      // The initial letter is only drawn when there is an address to take it
      // from, so a signed-out build shows a glyph instead.
      expect(find.text('L'), findsNothing);
      expect(find.text('Lexumo'), findsOneWidget);
      expect(find.byIcon(Icons.person), findsNothing,
          reason: 'the person glyph is drawn from the project icon set, not Material');
    });

    testWidgets('the avatar is a circle', (WidgetTester tester) async {
      await pumpProfile(tester);

      final Iterable<Container> circles = containers(tester).where(
        (Container c) => c.decoration is BoxDecoration &&
            (c.decoration! as BoxDecoration).shape == BoxShape.circle,
      );
      // Two: the avatar, and the circle inside the desktop card.
      expect(circles.length, greaterThanOrEqualTo(2));
      expect(find.byType(LexIcon), findsWidgets);
    });
  });

  group('the three figures', () {
    testWidgets('reviewed, streak and total are all printed',
        (WidgetTester tester) async {
      await pumpProfile(tester);

      expect(find.text(_zh.t('stats.reviewsToday')), findsOneWidget);
      expect(find.text(_zh.t('stats.streak')), findsOneWidget);
      expect(find.text(_zh.t('stats.totalWords')), findsOneWidget);
    });

    testWidgets('the numerals are the display face at the display size',
        (WidgetTester tester) async {
      await pumpProfile(tester);

      final List<RenderParagraph> nums = figures(tester);
      expect(nums.length, 3, reason: 'three figures, no more and no fewer');
      for (final RenderParagraph p in nums) {
        expect(p.text.style?.fontFamily, Fonts.display);
        expect(p.text.style?.fontSize, Fs.x2xl);
      }
    });

    testWidgets('they sit in three equal columns', (WidgetTester tester) async {
      await pumpProfile(tester);

      final List<RenderBox> columns = tester
          .renderObjectList<RenderBox>(
            find
                .ancestor(
                  of: find.text(_zh.t('stats.reviewsToday')),
                  matching: find.byType(Column),
                )
                .first,
          )
          .toList();
      expect(columns, isNotEmpty);

      // The three labels are each inside their own equal share of the row.
      final RenderBox firstLabel = tester.renderObject<RenderBox>(
        find.ancestor(of: find.text(_zh.t('stats.reviewsToday')), matching: find.byType(Column)).first,
      );
      final RenderBox lastLabel = tester.renderObject<RenderBox>(
        find.ancestor(of: find.text(_zh.t('stats.totalWords')), matching: find.byType(Column)).first,
      );
      expect(firstLabel.size.width, closeTo(lastLabel.size.width, 0.5));
    });

    testWidgets('no rule stands between them', (WidgetTester tester) async {
      await pumpProfile(tester);

      // The reference separates the figures with whitespace alone.
      final Iterable<Container> ruled = containers(tester).where((Container c) {
        final BoxDecoration? d =
            c.decoration is BoxDecoration ? c.decoration! as BoxDecoration : null;
        final Border? border = d?.border is Border ? d!.border! as Border : null;
        if (border == null) return false;
        // A card edge is all four sides; a divider is one side only.
        final bool sides = border.top.width > 0 &&
            border.bottom.width > 0 &&
            border.left.width > 0 &&
            border.right.width > 0;
        return !sides &&
            (border.left.width > 0 || border.right.width > 0);
      });
      expect(ruled, isEmpty);
    });
  });

  group('the action rows', () {
    testWidgets('import and settings are both offered',
        (WidgetTester tester) async {
      await pumpProfile(tester);

      expect(find.text(_zh.t('profile.importTitle')), findsOneWidget);
      expect(find.text(_zh.t('nav.settings')), findsOneWidget);
    });

    testWidgets('a row is a 44dp target', (WidgetTester tester) async {
      await pumpProfile(tester);

      // The tappable box around the import row: its ancestor GestureDetector is
      // opaque and sized by the row's own minHeight.
      final Iterable<Element> hits = find
          .ancestor(
            of: find.text(_zh.t('profile.importTitle')),
            matching: find.byType(GestureDetector),
          )
          .evaluate();
      expect(hits, isNotEmpty);
      final double tallest = hits
          .map((Element e) => (e.renderObject! as RenderBox).size.height)
          .reduce((double a, double b) => a > b ? a : b);
      expect(tallest, greaterThanOrEqualTo(Layout.tap));
    });

    testWidgets('the rows are flat — nothing is boxed around them',
        (WidgetTester tester) async {
      await pumpProfile(tester);

      final Iterable<Element> wrappers = find
          .ancestor(
            of: find.text(_zh.t('profile.importTitle')),
            matching: find.byType(Container),
          )
          .evaluate();
      expect(wrappers, isNotEmpty);
      for (final Element e in wrappers) {
        final Container c = e.widget as Container;
        final BoxDecoration? d =
            c.decoration is BoxDecoration ? c.decoration! as BoxDecoration : null;
        expect(_hasBoxEdge(d), isFalse,
            reason: 'the reference draws no box around an action row');
      }
    });
  });

  group('navigation', () {
    testWidgets('the fifth destination is 我的 and settings retired into it',
        (WidgetTester tester) async {
      expect(PageId.values.length, 5, reason: 'the tab bar keeps five slots');
      expect(PageId.values.last.id, 'profile');
      expect(PageId.values.last.labelKey, 'nav.profile');
      // A stale call site asking for the retired id lands on the tab that
      // replaced it rather than being dropped.
      expect(PageId.fromId('settings'), PageId.profile);
      expect(PageId.fromId('profile'), PageId.profile);
      expect(PageId.fromId('nope'), isNull);
    });

    testWidgets('the shell renders the profile page for that destination',
        (WidgetTester tester) async {
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
            i18n: I18n(UiLang.zhCN),
            child: ToastScope(
              show: (text, kind, {actionLabel, onAction, durationMs}) {},
              child: MaterialApp(
                theme: buildTheme(Palette.light),
                home: const AppShell(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ProfilePage), findsNothing,
          reason: 'the shell opens on the first destination');
      await tester.tap(find.text(_zh.t('nav.profile')).last);
      await tester.pumpAndSettle();

      expect(find.byType(ProfilePage), findsOneWidget);
    });
  });

  group('the way into settings', () {
    testWidgets('the settings row pushes the page and a bar brings it back',
        (WidgetTester tester) async {
      fileDialogs = FakeFileDialogs();
      addTearDown(() => fileDialogs = const PlatformFileDialogs());
      await pumpProfile(tester);

      // Settings is no longer a destination, so this row is now the only way
      // to reach it from the tab bar.
      expect(find.byType(SettingsPage), findsNothing);
      await tester.tap(find.text(_zh.t('nav.settings')));
      await tester.pumpAndSettle();

      expect(find.byType(SettingsPage), findsOneWidget);
      expect(tester.takeException(), isNull);

      // The pushed page has no chrome of its own; the route supplies a bar with
      // a way back, and that is what is exercised here.
      await tester.tap(find.byKey(const ValueKey<String>('profile-push-back')));
      await tester.pumpAndSettle();

      expect(find.byType(SettingsPage), findsNothing);
      expect(find.byType(ProfilePage), findsOneWidget);
    });
  });

  group('layout budget', () {
    testWidgets('nothing overflows at phone width', (WidgetTester tester) async {
      await pumpProfile(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('nothing is drawn past the right edge at 320dp',
        (WidgetTester tester) async {
      await pumpProfile(tester, size: const Size(320, 568));

      const double limit = 320.0;
      for (final Element e in find.byType(RichText).evaluate()) {
        final RenderBox box = e.renderObject! as RenderBox;
        final Offset topLeft = box.localToGlobal(Offset.zero);
        expect(
          topLeft.dx + box.size.width,
          lessThanOrEqualTo(limit + 0.5),
          reason: 'text "${(e.widget as RichText).text.toPlainText()}" is cut off',
        );
      }
      expect(tester.takeException(), isNull);
    });
  });
}
