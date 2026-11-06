// The word library's left stripe reports a word's place in the review cycle.
//
// Before this, [HairlineList] painted ONE unbroken accent line down the whole
// column — there was no per-word information on the left edge at all. Now each
// row paints its own short stripe in one of four semantic colours. These tests
// pin that down because a screenshot cannot: they assert that every visible
// row has exactly one stripe, that the four statuses map to four DIFFERENT
// colours (not four shades of one hue), and that the list-wide rule is really
// off (otherwise it would be painted over every stripe).
//
// See the user request: "分别弄几种颜色 代表复习状态 单词左侧的色条就是
// 对应的颜色".

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
import 'package:lexumo/ui/core/widgets/widgets.dart' show HairlineList;
import 'package:lexumo/ui/features/words/views/words_page.dart';

import 'support/fake_tts.dart';

/// Pumps [WordsPage] at a wide logical width so every seeded row is laid out.
/// [palette] lets the dark-theme test prove the colours do not collapse there.
Future<Store> pumpWords(
  WidgetTester tester, {
  Palette palette = Palette.light,
}) async {
  final Store store = Store(persistence: MemoryStore(), seed: seedData);
  await store.init();
  // Cancel any debounced save so the widget test does not fail with
  // "pending timers" at teardown.
  await store.flush();
  tester.view.physicalSize = const Size(1100, 900);
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
              theme: buildTheme(palette),
              home: Scaffold(body: WordsPage()),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

/// All status stripes currently in the tree, keyed by the word's wire status.
/// Each stripe is a [Container] whose key records the status it was painted
/// for, so a test can assert colours without reaching into a private widget.
Map<String, List<Color>> stripeColorsByStatus(WidgetTester tester) {
  final Map<String, List<Color>> out = <String, List<Color>>{};
  for (final Element e in find
      .byWidgetPredicate(
        (Widget w) =>
            w is Container &&
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('status-stripe-'),
      )
      .evaluate()) {
    final Container c = e.widget as Container;
    final String wire = (c.key! as ValueKey<String>)
        .value
        .substring('status-stripe-'.length);
    (out[wire] ??= <Color>[]).add(c.color!);
  }
  return out;
}

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);
  setUp(() => debugSetSpeech(silentSpeech()));
  tearDown(() => debugSetSpeech(null));

  group('word row status stripe', () {
    testWidgets('every row paints its status colour, and the four differ', (
      WidgetTester tester,
    ) async {
      final Store store = await pumpWords(tester);
      final Palette p = Palette.light;

      final Map<String, List<Color>> byStatus = stripeColorsByStatus(tester);
      expect(
        byStatus.keys.toSet(),
        <String>{'new', 'reviewing', 'learning', 'mastered'},
        reason: 'the seed mixes all four statuses; each must appear',
      );
      for (final MapEntry<String, List<Color>> entry in byStatus.entries) {
        expect(entry.value.toSet().length, 1,
            reason: '${entry.key} must have exactly one colour');
      }
      final Set<Color> distinct =
          byStatus.values.map((List<Color> c) => c.first).toSet();
      expect(distinct.length, 4,
          reason: 'four statuses need four different colours, not four shades');

      Color of(String wire) => byStatus[wire]!.first;
      expect(of('new'), p.ink4, reason: 'new = never studied, grey');
      expect(of('reviewing'), p.info, reason: 'reviewing = in the queue, blue');
      expect(of('learning'), p.warn, reason: 'learning = amber');
      expect(of('mastered'), p.ok, reason: 'mastered = green');

      // One stripe per visible word: all seed words live in the default
      // wordbook and no filter is active, so the table shows all of them.
      final int total = byStatus.values
          .fold<int>(0, (int a, List<Color> c) => a + c.length);
      expect(total, store.data.words.length,
          reason: 'every word row must paint exactly one stripe');

      // If the list-wide accent rule were still on it would be painted over
      // every per-row stripe, so the four colours would never be seen.
      expect(find.byType(HairlineList), findsOneWidget);
      expect(
        tester.widget<HairlineList>(find.byType(HairlineList)).rule,
        isFalse,
        reason: 'the list-wide accent rule would cover the status stripes',
      );
    });

    testWidgets('the four colours stay distinct in the dark theme', (
      WidgetTester tester,
    ) async {
      await pumpWords(tester, palette: Palette.dark);
      final Map<String, List<Color>> byStatus = stripeColorsByStatus(tester);
      expect(
        byStatus.keys.toSet(),
        <String>{'new', 'reviewing', 'learning', 'mastered'},
      );
      final Set<Color> distinct =
          byStatus.values.map((List<Color> c) => c.first).toSet();
      expect(distinct.length, 4,
          reason: 'no stripe may vanish into the dark background');
    });

    testWidgets('the filter menu repeats the same four swatches', (
      WidgetTester tester,
    ) async {
      await pumpWords(tester);
      final Palette p = Palette.light;

      final Finder menu =
          find.byWidgetPredicate((Widget w) => w is PopupMenuButton);
      expect(menu, findsOneWidget);
      await tester.tap(menu);
      await tester.pumpAndSettle();

      Color dot(String wire) {
        final Container c = tester.widget<Container>(
          find.byKey(ValueKey<String>('status-dot-$wire')),
        );
        return (c.decoration! as BoxDecoration).color!;
      }

      // The dots use the same mapping as the stripes, so the colour a reader
      // sees on a row can be decoded straight from the filter menu.
      expect(dot('new'), p.ink4);
      expect(dot('reviewing'), p.info);
      expect(dot('learning'), p.warn);
      expect(dot('mastered'), p.ok);
    });
  });
}
