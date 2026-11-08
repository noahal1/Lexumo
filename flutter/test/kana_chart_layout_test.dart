// The kana deck is the one wordbook that must NOT look like a list of rows.
//
// A gojuon is a spatial shape: five vowel columns by (ten consonant rows and
// a lone ん). Rendering 46 stacked rows throws away exactly the thing that
// makes the deck different from a vocabulary book. This file pins both halves
// of the change — the pure domain function that recognises a kana book and
// lays out its grid, and the widget that draws it instead of the table.
//
// Recognition is by contents, not by a `kind` field on WordList: adding one
// would mean touching the wire whitelist and every sync merge, and would leave
// decks created before this change (and decks restored from a backup) looking
// like an ordinary list forever.

import 'package:flutter/material.dart' hide Card;
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/app/scope.dart';
import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/data/services/tts.dart';
import 'package:lexumo/domain/models/kana.dart';
import 'package:lexumo/domain/models/seed.dart';
import 'package:lexumo/domain/models/types.dart';
import 'package:lexumo/domain/use_cases/kana_chart.dart';
import 'package:lexumo/ui/core/i18n/i18n.dart';
import 'package:lexumo/ui/core/theme.dart';
import 'package:lexumo/ui/core/tokens.dart';
import 'package:lexumo/ui/core/widgets/widgets.dart' show HairlineList;
import 'package:lexumo/ui/features/words/views/words_page.dart';

import 'support/fake_tts.dart';

const int NOW = 1770000000000;
const String kKanaListId = 'list_kana';

WordList _kanaList({String sourceLang = 'ja'}) => WordList(
      id: kKanaListId,
      name: '五十音 · 平假名',
      sourceLang: sourceLang,
      targetLang: 'zh-CN',
      createdAt: NOW,
      updatedAt: NOW,
    );

/// One Word per chart glyph, with the same shape the deck templates write.
List<Word> _words(Iterable<Kana> chart) => <Word>[
      for (final Kana k in chart)
        Word(
          id: 'w-${k.kana}',
          term: k.kana,
          phonetic: k.romaji,
          pos: k.row,
          definition: k.romaji,
          definition2: '',
          example: k.word,
          exampleZh: k.wordZh,
          note: '',
          status: WordStatus.new_,
          favorite: false,
          listId: kKanaListId,
          sourceLang: 'ja',
          targetLang: 'zh-CN',
          listenCount: 0,
          srs: null,
          createdAt: NOW,
          updatedAt: NOW,
        ),
    ];

/// A store whose only list is a full hiragana deck. `_reconcileList` adopts
/// `lists.first`, so a second sample list would quietly win the page.
AppData kanaSeed(int now) => AppData(
      lists: <WordList>[_kanaList()],
      words: _words(hiraganaKana),
      settings: const Settings(),
    );

/// Same deck with one glyph deleted: the chart must still be a chart, with a
/// dimmed ghost where the missing sound belongs.
AppData kanaSeedWithoutN(int now) => AppData(
      lists: <WordList>[_kanaList()],
      words: _words(hiraganaKana.where((Kana k) => k.kana != 'ん')),
      settings: const Settings(),
    );

Future<Store> _pump(
  WidgetTester tester,
  AppData Function(int now) seed,
) async {
  final Store store = Store(
    persistence: MemoryStore(),
    seed: seed,
    saveDelayMs: 0,
  );
  await store.init();
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
              theme: buildTheme(Palette.light),
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

int _countKeys(WidgetTester tester, String prefix) => find
    .byWidgetPredicate((Widget w) {
      final Key? key = w.key;
      return key is ValueKey<String> && key.value.startsWith(prefix);
    })
    .evaluate()
    .length;

Color _stripe(WidgetTester tester, String glyph) =>
    tester.widget<Container>(find.byKey(ValueKey<String>('kana-stripe-$glyph'))).color!;

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);
  setUp(() => debugSetSpeech(silentSpeech()));
  tearDown(() => debugSetSpeech(null));

  /* ---------------------------------------------------------------- */
  /* Domain: recognising a kana book and laying out its grid            */
  /* ---------------------------------------------------------------- */

  group('chartScriptOf', () {
    test('recognises a full hiragana deck', () {
      expect(
        chartScriptOf(_kanaList(), _words(hiraganaKana)),
        KanaScript.hiragana,
      );
    });

    test('recognises a full katakana deck', () {
      expect(
        chartScriptOf(_kanaList(), _words(katakanaKana)),
        KanaScript.katakana,
      );
    });

    test('rejects a non-Japanese book', () {
      expect(
        chartScriptOf(_kanaList(sourceLang: 'en'), _words(hiraganaKana)),
        isNull,
        reason: 'an English book with kana-looking words must stay a table',
      );
    });

    test('rejects a book with one ordinary word mixed in', () {
      final List<Word> words = _words(hiraganaKana);
      words[10] = words[10].copyWith(term: 'cat');
      expect(chartScriptOf(_kanaList(), words), isNull,
          reason: 'a chart cannot show a word that is not one of its 46 cells');
    });

    test('rejects fewer than 40 words', () {
      expect(
        chartScriptOf(_kanaList(), _words(hiraganaKana.take(39))),
        isNull,
        reason: 'a normal vocabulary book with a few stray kana is not a chart',
      );
    });

    test('rejects a duplicated glyph', () {
      final List<Word> words = _words(hiraganaKana);
      words[5] = words[5].copyWith(term: 'あ');
      expect(chartScriptOf(_kanaList(), words), isNull,
          reason: 'two cells cannot claim the same square');
    });

    test('rejects a book mixing the two scripts', () {
      final List<Word> words = <Word>[
        ..._words(hiraganaKana.take(40)),
        ..._words(katakanaKana.take(6)),
      ];
      expect(chartScriptOf(_kanaList(), words), isNull,
          reason: 'the chart is one script at a time');
    });

    test('tolerates a few deletions', () {
      expect(
        chartScriptOf(
          _kanaList(),
          _words(hiraganaKana.where((Kana k) => k.kana != 'ん' && k.kana != 'を')),
        ),
        KanaScript.hiragana,
        reason: 'deleting a card must not collapse the layout back to a list',
      );
    });
  });

  group('buildKanaChart', () {
    test('is 5 columns by 11 rows, 46 filled and 9 gaps', () {
      for (final KanaScript script in KanaScript.values) {
        final List<KanaChartRow> rows = buildKanaChart(script);
        expect(rows.length, 11, reason: '${script.wire} row count');
        for (final KanaChartRow row in rows) {
          expect(row.cells.length, kanaChartColumns);
        }
        final int filled =
            rows.expand((KanaChartRow r) => r.cells).whereType<Kana>().length;
        expect(filled, 46, reason: '${script.wire} filled cells');
        expect(11 * kanaChartColumns - filled, 9,
            reason: '${script.wire} gaps');
      }
    });

    test('や行 leaves i and e empty, わ行 leaves i/u/e empty', () {
      final List<KanaChartRow> rows = buildKanaChart(KanaScript.hiragana);
      final KanaChartRow ya = rows.firstWhere((KanaChartRow r) => r.label == 'や行');
      expect(ya.cells[0]!.kana, 'や');
      expect(ya.cells[1], isNull);
      expect(ya.cells[2]!.kana, 'ゆ');
      expect(ya.cells[3], isNull);
      expect(ya.cells[4]!.kana, 'よ');

      final KanaChartRow wa = rows.firstWhere((KanaChartRow r) => r.label == 'わ行');
      expect(wa.cells[0]!.kana, 'わ');
      expect(wa.cells[1], isNull);
      expect(wa.cells[2], isNull);
      expect(wa.cells[3], isNull);
      expect(wa.cells[4]!.kana, 'を');
    });

    test('ん has no vowel and sits alone in the first column of its own row', () {
      final KanaChartRow last = buildKanaChart(KanaScript.hiragana).last;
      expect(last.label, 'ん');
      expect(last.cells[0]!.kana, 'ん');
      expect(last.cells.sublist(1).every((Kana? c) => c == null), isTrue);
    });

    test('the exceptions land in their vowel column', () {
      final List<KanaChartRow> rows = buildKanaChart(KanaScript.hiragana);
      final KanaChartRow sa = rows.firstWhere((KanaChartRow r) => r.label == 'さ行');
      final KanaChartRow ta = rows.firstWhere((KanaChartRow r) => r.label == 'た行');
      final KanaChartRow ha = rows.firstWhere((KanaChartRow r) => r.label == 'は行');
      expect(sa.cells[1]!.kana, 'し', reason: 'shi → i');
      expect(ta.cells[1]!.kana, 'ち', reason: 'chi → i');
      expect(ta.cells[2]!.kana, 'つ', reason: 'tsu → u');
      expect(ha.cells[2]!.kana, 'ふ', reason: 'fu → u');
    });
  });

  /* ---------------------------------------------------------------- */
  /* Widget: the page draws the chart and nothing else                  */
  /* ---------------------------------------------------------------- */

  group('the word library with a kana deck', () {
    testWidgets('draws the gojuon instead of the row table', (tester) async {
      await _pump(tester, kanaSeed);

      expect(find.byKey(const ValueKey('kana-chart')), findsOneWidget);
      expect(find.byType(HairlineList), findsNothing,
          reason: 'the chart replaces the table, not sits on top of it');
      expect(_countKeys(tester, 'kana-cell-'), 46);
      expect(_countKeys(tester, 'kana-blank-'), 9);
      expect(_countKeys(tester, 'kana-stripe-'), 46);
    });

    testWidgets('is a real 5-column grid, not a wrap of cells', (tester) async {
      await _pump(tester, kanaSeed);

      final Rect a = tester.getRect(find.text('あ'));
      final Rect i = tester.getRect(find.text('い'));
      final Rect ka = tester.getRect(find.text('か'));

      expect(ka.left, equals(a.left),
          reason: 'あ and か are both the first (a) column');
      expect(ka.top, greaterThan(a.bottom),
          reason: 'か行 is the row below あ行');
      expect(i.left, greaterThan(a.right),
          reason: 'い is the second (i) column of the same row');
      expect(i.top, equals(a.top), reason: 'あ and い share a row');
    });

    testWidgets('a deleted kana keeps a dimmed place on the grid', (tester) async {
      await _pump(tester, kanaSeedWithoutN);

      expect(find.byKey(const ValueKey('kana-chart')), findsOneWidget);
      expect(find.byKey(const ValueKey('kana-ghost-ん')), findsOneWidget);
      expect(find.byKey(const ValueKey('kana-cell-ん')), findsNothing);
      expect(_countKeys(tester, 'kana-cell-'), 45);
      expect(_countKeys(tester, 'kana-blank-'), 9,
          reason: 'the missing sound is a ghost, not a gap in the chart');
    });

    testWidgets('each cell carries the shared status colour', (tester) async {
      final Store store = await _pump(tester, kanaSeed);
      store
        ..setWordStatus('w-あ', WordStatus.reviewing)
        ..setWordStatus('w-い', WordStatus.learning)
        ..setWordStatus('w-う', WordStatus.mastered);
      await store.flush();
      await tester.pumpAndSettle();

      // Literal palette colours, deliberately NOT routed through statusColor:
      // if the mapping is flattened to one colour, these asserts must fail.
      expect(_stripe(tester, 'え'), Palette.light.ink4,
          reason: 'new → grey');
      expect(_stripe(tester, 'あ'), Palette.light.info,
          reason: 'reviewing → blue');
      expect(_stripe(tester, 'い'), Palette.light.warn,
          reason: 'learning → amber');
      expect(_stripe(tester, 'う'), Palette.light.ok,
          reason: 'mastered → green');

      final Set<Color> four = <Color>{
        Palette.light.ink4,
        Palette.light.info,
        Palette.light.warn,
        Palette.light.ok,
      };
      expect(four.length, 4, reason: 'the four hues must be distinct');
    });

    testWidgets('a search falls back to the table so matches are readable',
        (tester) async {
      await _pump(tester, kanaSeed);
      expect(find.byKey(const ValueKey('kana-chart')), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'a');
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('kana-chart')), findsNothing,
          reason: 'a half-empty chart would hide what the reader searched for');
      expect(find.byType(HairlineList), findsOneWidget);
    });

    testWidgets('an ordinary wordbook is still the row table', (tester) async {
      await _pump(tester, seedData);

      expect(find.byKey(const ValueKey('kana-chart')), findsNothing);
      expect(find.byType(HairlineList), findsOneWidget);
    });
  });
}
