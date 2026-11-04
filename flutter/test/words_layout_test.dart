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
import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/ui/core/theme.dart';
import 'package:lexumo/ui/core/tokens.dart';
import 'package:lexumo/ui/core/widgets/controls.dart';
import 'package:lexumo/domain/models/seed.dart';
import 'package:lexumo/domain/models/types.dart';
import 'package:lexumo/ui/core/i18n/i18n.dart';
import 'package:lexumo/ui/features/words/views/words_page.dart';
import 'package:lexumo/data/services/tts.dart';

import 'support/fake_tts.dart';

/// Long enough that it can never fit on one line at any phone width.
const String kLongTerm = 'counterproductive';
const String kLongGloss = '产生相反效果的；事与愿违的；不但没有帮助反而带来损害的；得不偿失的';

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
/// be exercised without a real device. Returns the store so a test can assert
/// what a gesture did to the data, not just to the pixels.
Future<Store> pumpWordsAt(WidgetTester tester, double width) async {
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
  return store;
}

Rect rectOf(WidgetTester tester, String text) => tester.getRect(find.text(text).first);

void main() {
  // `WordsPage`'s row renders a 发音 button, whose visibility comes from
  // `speechAvailable` → `appSpeech`, the process-wide singleton. Without a
  // fake, pumping the page constructs a real `FlutterTts`. See
  // `test/support/fake_tts.dart`.
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);
  setUp(() => debugSetSpeech(silentSpeech()));
  tearDown(() => debugSetSpeech(null));

  group('word row layout', () {
    testWidgets('the gloss sits below the term, not beside it', (WidgetTester tester) async {
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

    testWidgets('the gloss gets the whole column, not a flex share', (WidgetTester tester) async {
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

      final term = rectOf(tester, kLongTerm);
      final def = rectOf(tester, kLongGloss);

      expect(def.top, greaterThanOrEqualTo(term.bottom - 1));
      // Measured against the headword, not against the page. The row now ends
      // in two 44dp action targets (star, speaker) rather than in a status
      // column plus three buttons, and those targets are the only thing the
      // gloss does not get; everything left of them is the text column. Under
      // the old side-by-side split the gloss had ~44% of that column, so a 60%
      // floor still fails on it while surviving the pos chip's width and a font
      // metric drifting a little.
      expect(
        def.width,
        greaterThan(term.width * 0.6),
        reason: 'the gloss got ${def.width}dp of the ${term.width}dp text column',
      );
      // And the layout must not have overflowed while getting there.
      expect(tester.takeException(), isNull);
    });

    testWidgets('the column header is dropped on a phone', (WidgetTester tester) async {
      await pumpWordsAt(tester, 1100);
      // The header names the columns; on a two-line row it is pure noise.
      expect(find.text('词语'), findsWidgets);

      await pumpWordsAt(tester, 420);
      expect(find.text('词语'), findsNothing, reason: 'the compact layout has no column header');
      expect(tester.takeException(), isNull);
    });
  });

  // The list manager's create card. These exist because of a real report: on
  // the phone, tapping 创建 with an empty name did nothing at all — the guard
  // returned silently, so the button read as broken. The fix is a visible
  // reason plus a layout that keeps the actions reachable; both are asserted
  // here rather than being left to a screenshot.
  group('create-list card', () {
    const String kNewList = '新建词库';
    const String kNameLabel = '词库名称';
    const String kRequired = '请输入词库名称';
    const String kCreate = '创建';
    const String kCancel = '取消';

    Finder nameField() => find.byKey(const Key('create-list-name'));

    Future<void> openCreateCard(WidgetTester tester) async {
      // The list manager hangs off the tab strip's trailing + button…
      final Finder addTab = find.byTooltip(kNewList);
      await tester.ensureVisible(addTab);
      await tester.pumpAndSettle();
      await tester.tap(addTab);
      await tester.pumpAndSettle();
      // …and the manual entry point is the dashed row under the last list.
      final Finder row = find.text(kNewList);
      expect(row, findsOneWidget);
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
    }

    testWidgets('a blank 创建 says why and creates nothing', (WidgetTester tester) async {
      final Store store = await pumpWordsAt(tester, 1100);
      await openCreateCard(tester);
      expect(find.text(kNameLabel), findsOneWidget);

      final int before = store.data.lists.length;
      await tester.tap(find.text(kCreate));
      await tester.pumpAndSettle();

      expect(
        find.text(kRequired),
        findsOneWidget,
        reason: 'a tap that silently returns is what read as a broken button',
      );
      expect(store.data.lists.length, before);
      // Still open, so the user can type a name and press again.
      expect(find.text(kNameLabel), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a name is enough to create the list', (WidgetTester tester) async {
      final Store store = await pumpWordsAt(tester, 1100);
      await openCreateCard(tester);

      await tester.enterText(nameField(), '我的SAT词库');
      await tester.pumpAndSettle();
      await tester.tap(find.text(kCreate));
      await tester.pumpAndSettle();

      expect(store.data.lists.length, 2);
      final WordList created = store.data.lists.last;
      expect(created.name, '我的SAT词库');
      expect(created.sourceLang, 'en');
      expect(created.targetLang, 'zh-CN');
      expect(find.text(kNameLabel), findsNothing, reason: 'the card closed');
    });

    testWidgets('the keyboard action key creates the list too', (WidgetTester tester) async {
      final Store store = await pumpWordsAt(tester, 1100);
      await openCreateCard(tester);

      // The name field autofocuses, so on a phone this is the one gesture that
      // does not require finding the button under the keyboard.
      await tester.enterText(nameField(), '日语 N2');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(store.data.lists.last.name, '日语 N2');
      expect(find.text(kNameLabel), findsNothing);
    });

    testWidgets('a phone stacks the language pair and stretches the actions', (
      WidgetTester tester,
    ) async {
      await pumpWordsAt(tester, 420);
      await openCreateCard(tester);

      final Rect source = rectOf(tester, '学习语言');
      final Rect target = rectOf(tester, '释义语言');
      expect(
        target.top,
        greaterThan(source.bottom),
        reason: 'side by side the labels ellipsise to "中文（简…" at 340dp',
      );

      final Size create = tester.getSize(find.widgetWithText(LexButton, kCreate));
      final Size cancel = tester.getSize(find.widgetWithText(LexButton, kCancel));
      expect(
        (create.width - cancel.width).abs(),
        lessThan(1),
        reason: 'block buttons share the row equally',
      );
      expect(create.width, greaterThan(120), reason: 'a thumb-sized target');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a keyboard does not bury 创建', (WidgetTester tester) async {
      // The other reading of "tapping 创建 does nothing": the tap never landed,
      // because the keypad the name field summons had pushed the actions out of
      // the modal body. The card opens with the insets already applied here —
      // that is the state the phone is in one frame after the tap — and the
      // action row must still be hit-testable, not merely present in the tree.
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      addTearDown(tester.view.resetViewInsets);

      await pumpWordsAt(tester, 420);
      await openCreateCard(tester);

      expect(
        find.text(kCreate).hitTestable(),
        findsOneWidget,
        reason: '创建 has to stay reachable above the keyboard',
      );
      expect(find.text(kCancel).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a dialog keeps the pair on one row', (WidgetTester tester) async {
      await pumpWordsAt(tester, 1100);
      await openCreateCard(tester);

      final Rect source = rectOf(tester, '学习语言');
      final Rect target = rectOf(tester, '释义语言');
      expect((source.top - target.top).abs(), lessThan(0.5));
      expect(target.left, greaterThan(source.right));
    });
  });

  group('pinned header', () {
    const String kNewList = '新建词库';

    // The two controls that decide what the list shows used to scroll away
    // with the rows: after one flick the page was showing a filtered list with
    // no visible filter and no visible wordbook name. They are pinned now, so
    // the assertion is that a long scroll moves the body and not them.
    testWidgets('the wordbook tabs and the query bar do not scroll', (
      WidgetTester tester,
    ) async {
      final Store store = await pumpWordsAt(tester, 411);

      // A list that fits on one screen cannot prove anything stayed put, so the
      // seed is padded until the body overflows a phone.
      for (int i = 0; i < 40; i++) {
        store.addWord(
          NewWordInput(
            term: 'word$i',
            definition: '释义 $i',
            listId: DEFAULT_LIST_ID,
          ),
        );
      }
      await store.flush();
      await tester.pumpAndSettle();

      final Finder tabs = find.byTooltip(kNewList);
      final Finder search = find.byType(TextField).first;
      final Rect tabsBefore = tester.getRect(tabs);
      final Rect searchBefore = tester.getRect(search);

      final ScrollableState body = tester
          .stateList<ScrollableState>(find.byType(Scrollable))
          .firstWhere(
            (ScrollableState s) =>
                s.position.axis == Axis.vertical &&
                s.position.maxScrollExtent > 0,
            orElse: () => fail('the body has to be scrollable'),
          );

      // Start below the pinned strip (it ends around y=120 on a phone) and stay
      // clear of the FAB in the bottom-right corner.
      await tester.dragFrom(const Offset(200, 600), const Offset(0, -400));
      await tester.pumpAndSettle();

      expect(
        body.position.pixels,
        greaterThan(0),
        reason: 'the drag has to actually scroll, or nothing is being proved',
      );
      expect(tester.getRect(tabs), tabsBefore, reason: 'the tabs are pinned');
      expect(
        tester.getRect(search),
        searchBefore,
        reason: 'the query bar is pinned',
      );
    });
  });
}
