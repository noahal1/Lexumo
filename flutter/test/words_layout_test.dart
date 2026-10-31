// Layout tests for the word library rows.
//
// These exist because of a real complaint: on a phone the list looked like it
// was hiding entries. The cause was structural, not textual — the term and the
// gloss sat in two side-by-side flex columns, so a long English headword and a
// long Chinese gloss both had to ellipsise inside roughly half the row.
//
// A screenshot cannot prove the fix (it cannot say *why* the text fits), so the
// geometry is asserted instead: the gloss must start BELOW the term, and at a
// narrow width the gloss must be able to use the whole row rather than a
// fraction of it. A deliberately long gloss is used for the width check because
// a `Text` sizes to its glyphs when they fit — only an overflowing one reports
// the constraint width, which is exactly the column width we want to measure.

import 'package:flutter/material.dart' hide Card;
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/app/scope.dart';
import 'package:lexumo/data/snapshot_store.dart';
import 'package:lexumo/data/store.dart';
import 'package:lexumo/design/theme.dart';
import 'package:lexumo/design/tokens.dart';
import 'package:lexumo/domain/seed.dart';
import 'package:lexumo/domain/types.dart';
import 'package:lexumo/i18n/i18n.dart';
import 'package:lexumo/pages/words_page.dart';
import 'package:lexumo/platform/tts.dart';

import 'support/fake_tts.dart';

/// Long enough that it can never fit on one line at any phone width.
const String kLongTerm = 'counterproductive';
const String kLongGloss =
    '产生相反效果的；事与愿违的；不但没有帮助反而带来损害的；得不偿失的';

/// A store with the default seed plus one deliberately wide entry.
Future<Store> freshStore() async {
  final store = Store(persistence: MemoryStore(), seed: seedData);
  await store.init();
  store.addWord(
    const NewWordInput(
      term: kLongTerm,
      phonetic: '/ˌkaʊntəprəˈdʌktɪv/',
      pos: 'adj.',
      definition: kLongGloss,
      example: 'It would be counterproductive to raise the tax now.',
      listId: DEFAULT_LIST_ID,
    ),
  );
  // `addWord` schedules a debounced save; flushing cancels that timer so the
  // widget test does not fail with "pending timers" at teardown.
  await store.flush();
  return store;
}

/// Pumps [WordsPage] at an exact logical width so the compact/wide split can
/// be exercised without a real device.
Future<void> pumpWordsAt(WidgetTester tester, double width) async {
  final store = await freshStore();
  tester.view.physicalSize = Size(width, 900);
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
              home: Scaffold(body: WordsPage()),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Rect rectOf(WidgetTester tester, String text) =>
    tester.getRect(find.text(text).first);

void main() {
  // `WordsPage`'s row renders a 发音 button, whose visibility comes from
  // `speechAvailable` → `appSpeech`, the process-wide singleton. Without a
  // fake, pumping the page constructs a real `FlutterTts`. See
  // `test/support/fake_tts.dart`.
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);
  setUp(() => debugSetSpeech(silentSpeech()));
  tearDown(() => debugSetSpeech(null));

  group('word row layout', () {
    testWidgets('the gloss sits below the term, not beside it', (
      WidgetTester tester,
    ) async {
      await pumpWordsAt(tester, 1100);

      final term = rectOf(tester, kLongTerm);
      final def = rectOf(tester, kLongGloss);

      // Stacked means the gloss's top is at or past the term's bottom. A
      // side-by-side layout would put them at (nearly) the same top and give
      // the gloss an x offset instead.
      expect(
        def.top,
        greaterThanOrEqualTo(term.bottom - 1),
        reason: 'the definition should start under the headword',
      );
    });

    testWidgets('the gloss gets the whole column, not a flex share', (
      WidgetTester tester,
    ) async {
      await pumpWordsAt(tester, 1100);

      final page = tester.getRect(find.byType(WordsPage));
      final def = rectOf(tester, kLongGloss);

      // The old flex:3 / flex:4 / flex:2 split handed the gloss column ~44% of
      // the row. Stacked, it spans the content area minus only the fixed
      // status/action columns.
      expect(
        def.width,
        greaterThan(page.width * 0.55),
        reason: 'the gloss must not be confined to a narrow flex column',
      );
    });

    testWidgets('a phone width keeps the gloss readable and unclipped', (
      WidgetTester tester,
    ) async {
      // 420dp is the emulator's logical width in portrait.
      await pumpWordsAt(tester, 420);

      final page = tester.getRect(find.byType(WordsPage));
      final term = rectOf(tester, kLongTerm);
      final def = rectOf(tester, kLongGloss);

      expect(def.top, greaterThanOrEqualTo(term.bottom - 1));
      // Under the old split the gloss would have had ~44% of a ~356dp content
      // area (~157dp). Stacked it must clear the majority of the row.
      expect(
        def.width,
        greaterThan(page.width * 0.6),
        reason: 'the gloss should own the row width on a phone',
      );
      // And the layout must not have overflowed while getting there.
      expect(tester.takeException(), isNull);
    });

    testWidgets('the column header is dropped on a phone', (
      WidgetTester tester,
    ) async {
      await pumpWordsAt(tester, 1100);
      // The header names the columns; on a two-line row it is pure noise.
      expect(find.text('词语'), findsWidgets);

      await pumpWordsAt(tester, 420);
      expect(
        find.text('词语'),
        findsNothing,
        reason: 'the compact layout has no column header',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
