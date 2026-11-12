// Wave 2 — "one figure, one place."
//
// The redesign's second wave removed information that was restated, not added:
// the same number printed three or four times on one screen, a permanent slab
// of chrome repeating figures that belong to a page, a version number that
// named itself twice, and an identity with no way to change its mind. These are
// decisions a screenshot can suggest but not pin down, so the tree is asserted
// directly: the goal's numbers live in the goal card, the due count in the
// headline and the practice badge, and nowhere else.
//
// All strings come from the same I18n the pages use (zh_cn by seed default), so
// a finder can never disagree with the tree about what a label says.

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
import 'package:lexumo/ui/core/tokens.dart' show Palette;
import 'package:lexumo/ui/core/widgets/controls.dart' show LexButton;
import 'package:lexumo/ui/core/widgets/widgets.dart' show StatTile;
import 'package:lexumo/ui/features/home/views/home_page.dart';
import 'package:lexumo/ui/features/profile/views/profile_page.dart';
import 'package:lexumo/ui/features/shell/views/app_shell.dart';
import 'package:lexumo/ui/features/stats/views/stats_page.dart';

import 'support/fake_tts.dart';

const I18n _zh = I18n(UiLang.zhCN);
const Size _wide = Size(1280, 900);

/// A real store and the four scopes every screen is mounted with. The desktop
/// viewport keeps the expanded sidebar (not the bottom bar) on screen.
Future<void> _pump(
  WidgetTester tester,
  Widget screen, {
  Size size = _wide,
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
              home: Scaffold(body: screen),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The private per-screen widgets are library-private, so `byType` cannot name
/// them. Matching the runtime type string is the same trick the words-shortcut
/// test uses to reach `_WordEditorPage`.
Finder _named(String runtimeName) => find.byWidgetPredicate(
      (Widget w) => w.runtimeType.toString() == runtimeName,
    );

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);
  setUp(() => debugSetSpeech(silentSpeech()));
  tearDown(() => debugSetSpeech(null));

  group('2.1 · the daily goal owns its own numbers', () {
    testWidgets('the reviews tile and the two cards stop restating progress',
        (tester) async {
      await _pump(tester, const StatsPage(controller: null));

      final List<StatTile> tiles =
          tester.widgetList<StatTile>(find.byType(StatTile)).toList();
      final StatTile reviews = tiles.singleWhere(
        (StatTile t) => t.label == _zh.t('stats.reviewsToday'),
      );

      // Was `reached ? goalReached : remainingToGoal` — a second copy of the
      // goal's own line, on a screen where the goal card already prints it.
      // Now it is null, or at most the bare "goal reached" flag.
      expect(reviews.sub, anyOf(isNull, equals(_zh.t('home.goalDone'))));

      // `stats.remainingToGoal` ("还差 N 次到目标") is no longer used anywhere
      // on this page — the goal card uses `stats.remainingReviews` instead.
      expect(find.textContaining('次到目标'), findsNothing);

      // `stats.wordsInTotal` ("共 N 个词语") was the distribution card's
      // subtitle; `total` is already the first tile's figure.
      final int total = int.tryParse(
            tiles
                .singleWhere((StatTile t) => t.label == _zh.t('stats.totalWords'))
                .value,
          ) ??
          0;
      expect(
        find.text(_zh.t('stats.wordsInTotal', <String, Object>{'n': total})),
        findsNothing,
      );

      // The old `stats.todayProgress` card subtitle was the single joined
      // string "today / goal". The ring now prints the two as separate Texts,
      // and the chart's date ticks ("10/12") must not be mistaken for it.
      final int today = int.tryParse(reviews.value) ?? 0;
      const int goal = 20; // Settings.dailyGoal's seed default.
      expect(
        find.text(_zh.t('stats.todayProgress', <String, Object>{'n': today, 'goal': goal})),
        findsNothing,
      );
    });
  });

  group('2.2 · the due count has two homes, not four', () {
    testWidgets('the action is a verb; library rows carry only their size',
        (tester) async {
      await _pump(tester, const HomePage());

      expect(find.text(_zh.t('home.startReview')), findsOneWidget);
      // The button used to append " · 7".
      expect(
        find.textContaining('${_zh.t('home.startReview')} ·'),
        findsNothing,
      );
      // `home.listMeta` ("{words} 词 · {due} 待复习") used to restate the due
      // figure on every library row.
      expect(find.textContaining('待复习'), findsNothing);
      expect(find.textContaining('词 ·'), findsNothing);
    });
  });

  group('2.4 · the profile stops saying the version twice', () {
    testWidgets('signed out offers a way in', (tester) async {
      await _pump(tester, const ProfilePage(controller: null));
      expect(find.text(_zh.t('settings.syncStatusSignedOut')), findsOneWidget);
      // The sign-in action is a real primary button in the identity block, not
      // stray text and not a destination buried two taps away in settings.
      expect(
        find.ancestor(
          of: find.text(_zh.t('settings.syncSignIn')),
          matching: find.byType(LexButton),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the version label appears once and the notice is last',
        (tester) async {
      await _pump(tester, const ProfilePage(controller: null));

      // `_AboutRow` used to add a trailing "版本" label beside a subtitle that
      // was itself the version. The sheet that legitimately pairs them is shut.
      expect(find.text(_zh.t('settings.version')), findsNothing);

      // The desktop notice is an aside, not a destination: it now sits after
      // the flat run of rows instead of splitting them.
      final Finder about = _named('_AboutRow');
      final Finder notice = _named('_DesktopCard');
      expect(about, findsOneWidget);
      expect(notice, findsOneWidget);
      expect(
        tester.getTopLeft(notice).dy,
        greaterThan(tester.getTopLeft(about).dy),
      );
    });
  });

  group('2.3 · the sidebar is navigation, not a dashboard', () {
    testWidgets('the streak card is gone and the tagline lives in the wordmark',
        (tester) async {
      await _pump(tester, const AppShell());

      expect(_named('_StreakCard'), findsNothing);
      expect(find.text(_zh.t('common.appTagline')), findsOneWidget);
      expect(_named('_SidebarButton'), findsNWidgets(3));

      // At rest a Tooltip names nothing: the resting control needs its own
      // semantic label so a screen reader can reach the three icon buttons.
      final handle = tester.ensureSemantics();
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(_zh.t('settings.shortcuts')), findsWidgets);
      handle.dispose();
    });
  });
}
