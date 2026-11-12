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
import 'package:lexumo/ui/core/widgets/lex_icon.dart';
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

/// Opens the list manager and then its blank create card.
///
/// The manager hangs off the tab strip's trailing + button; the manual entry
/// point inside it is the dashed 新建词库 row under the last list.
Future<void> openCreateCardFor(WidgetTester tester) async {
  const String kNewList = '新建词库';
  final Finder addTab = find.byTooltip(kNewList);
  await tester.ensureVisible(addTab);
  await tester.pumpAndSettle();
  await tester.tap(addTab);
  await tester.pumpAndSettle();
  final Finder row = find.text(kNewList);
  expect(row, findsOneWidget);
  await tester.ensureVisible(row);
  await tester.pumpAndSettle();
  await tester.tap(row);
  await tester.pumpAndSettle();
}

void main() {
  // `WordsPage`'s row renders a 发音 button, whose visibility comes from
  // `speechAvailable` → `appSpeech`, the process-wide singleton. Without a
  // fake, pumping the page constructs a real `FlutterTts`. See
  // `test/support/fake_tts.dart`.
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);
  setUp(() => debugSetSpeech(silentSpeech()));
  tearDown(() => debugSetSpeech(null));

  group('word row layout', () {
    testWidgets('a wide library puts the gloss beside the term', (WidgetTester tester) async {
      await pumpWordsAt(tester, 1100);

      final term = rectOf(tester, kLongTerm);
      final def = rectOf(tester, kLongGloss);

      // At >=960dp the dead horizontal space is spent on a real grid: the
      // headword gets its own 320dp lane and the gloss sits to its RIGHT on
      // the same line, instead of always being stacked underneath. Stacking
      // is kept for narrower widths (see the 420dp test below).
      expect(
        def.left,
        greaterThanOrEqualTo(term.right),
        reason: 'the definition should start to the right of the headword',
      );
      expect(def.top, lessThan(term.bottom), reason: 'the gloss shares the term\'s row');
    });

    testWidgets('two columns survive the real desktop window, not just a 1x test', (
      WidgetTester tester,
    ) async {
      // A 1600px *physical* Windows window runs at 1.5x devicePixelRatio, so
      // it is only ~1067 logical px wide. After the 232dp sidebar and the
      // paper's padding, the word table is laid out with roughly 787dp of
      // content width. The first cut of the two-column grid used a 960dp
      // threshold: every widget test (pumped at devicePixelRatio 1) passed,
      // yet the actual 1600px window still showed the stacked layout. Pump at
      // that real content width and insist the gloss is beside the term.
      await pumpWordsAt(tester, 787);

      final term = rectOf(tester, kLongTerm);
      final def = rectOf(tester, kLongGloss);
      expect(
        def.left,
        greaterThanOrEqualTo(term.right),
        reason: 'a 1600px@1.5x window must still spend its width on two columns',
      );
      expect(tester.takeException(), isNull, reason: 'the gloss must not overflow');
    });

    testWidgets('the wide header shares the rows\' grid', (WidgetTester tester) async {
      await pumpWordsAt(tester, 1100);

      final term = rectOf(tester, kLongTerm);
      final def = rectOf(tester, kLongGloss);
      final page = tester.getRect(find.byType(WordsPage));

      // The header used to stack 「词语 / 释义」 as two captions while the row
      // stacked a 24dp display line over a 13dp body line, so their left edges
      // drifted ~8dp apart. Both now derive from the same grid constants: the
      // 「词语」 caption lands on the headword's left edge to the pixel.
      final termHeader = tester.getRect(find.text('词语').first);
      final defHeader = tester.getRect(find.text('释义').first);
      expect(termHeader.left, closeTo(term.left, 1), reason: 'header aligns with the term column');
      expect(termHeader.top, lessThan(term.top), reason: 'the header sits above the first row');
      // 「释义」 marks the gloss lane; the visible gloss text starts a pos
      // chip later inside that lane, so it can only be to the right of it.
      expect(defHeader.left, lessThanOrEqualTo(def.left));
      // Spending a lane on the headword must not squeeze the gloss: the whole
      // point was to use the empty middle of a wide window.
      expect(def.width, greaterThan(page.width * 0.4));
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
    const String kNameLabel = '词库名称';
    const String kRequired = '请输入词库名称';
    const String kCreate = '创建';
    const String kCancel = '取消';

    Finder nameField() => find.byKey(const Key('create-list-name'));

    Future<void> openCreateCard(WidgetTester tester) => openCreateCardFor(tester);

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
      // `createList` schedules a debounced save; flushing cancels that timer so
      // the test does not end with "pending timers" (same reason as freshStore).
      await store.flush();
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
      await store.flush();
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

  // The ready-made decks used to sit outside the form, so the dialog offered
  // 五十音 to somebody who was naming an English list. A suggestion is only a
  // suggestion when it answers a choice the user just made, so the picker now
  // lives inside the form and is filtered by the chosen source language.
  group('ready-made decks follow the source language', () {
    const String kDecks = '快速开始';
    const String kHiragana = '五十音 · 平假名';
    const String kKatakana = '五十音 · 片假名';

    /// Opens the source-language dropdown and picks [label].
    ///
    /// The closed control only shows the current language, so the option has to
    /// be reached through the menu the tap opens.
    Future<void> pickSourceLanguage(WidgetTester tester, String label) async {
      await tester.tap(find.byType(LexSelect<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    testWidgets('an English list is not offered 五十音', (
      WidgetTester tester,
    ) async {
      await pumpWordsAt(tester, 1100);
      await openCreateCardFor(tester);

      expect(find.text(kDecks), findsNothing);
      expect(find.text(kHiragana), findsNothing);
      expect(find.text(kKatakana), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('choosing 日语 reveals both kana decks', (
      WidgetTester tester,
    ) async {
      await pumpWordsAt(tester, 1100);
      await openCreateCardFor(tester);

      await pickSourceLanguage(tester, '日语');

      expect(find.text(kDecks), findsOneWidget);
      expect(find.text(kHiragana), findsOneWidget);
      expect(find.text(kKatakana), findsOneWidget);
      // The rows must not be above the choice that produced them.
      expect(
        tester.getRect(find.text(kDecks)).top,
        greaterThan(tester.getRect(find.text('学习语言')).top),
        reason: 'the offer sits under the language pair, not over the form',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('switching back to 英语 takes the offer away again', (
      WidgetTester tester,
    ) async {
      await pumpWordsAt(tester, 1100);
      await openCreateCardFor(tester);

      await pickSourceLanguage(tester, '日语');
      expect(find.text(kDecks), findsOneWidget);

      await pickSourceLanguage(tester, '英语');
      expect(find.text(kDecks), findsNothing);
      expect(find.text(kHiragana), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping a deck adds that list and closes the dialog', (
      WidgetTester tester,
    ) async {
      final Store store = await pumpWordsAt(tester, 1100);
      await openCreateCardFor(tester);
      await pickSourceLanguage(tester, '日语');

      final int before = store.data.lists.length;
      await tester.tap(find.text(kHiragana));
      await tester.pumpAndSettle();

      expect(store.data.lists.length, before + 1);
      final WordList created = store.data.lists.last;
      expect(created.sourceLang, 'ja');
      expect(created.targetLang, 'zh-CN');
      expect(created.name, kHiragana);
      expect(
        store.data.words.where((w) => w.listId == created.id).length,
        46,
        reason: 'one _commit carries the whole deck',
      );
      expect(find.text('词库名称'), findsNothing, reason: 'the dialog closed');
    });
  });

  // The wordbook strip used to be a `Wrap`: three lists fit on a phone and five
  // did not, so the surplus wrapped onto a second and then a third line inside
  // the pinned strip. The strip grew downwards and took the room from the words
  // — the control that picks what you read was eating what you read. These lock
  // the fix: exactly one row high no matter how many wordbooks exist, and the
  // surplus reached by scrolling sideways.
  group('the wordbook strip is one row and scrolls sideways', () {
    /// Seeds [count] extra wordbooks, each with one word.
    Future<void> addLists(Store store, int count) async {
      for (int i = 0; i < count; i++) {
        final WordList list = store.createList(
          name: '词库 ${i + 1} 号',
          sourceLang: 'en',
          targetLang: 'zh-CN',
        );
        store.addWord(
          NewWordInput(term: 'term$i', definition: '释义 $i', listId: list.id),
        );
      }
      await store.flush();
    }

    /// The horizontal scrollable the strip owns (the body's is vertical).
    ScrollableState stripScrollable(WidgetTester tester) =>
        tester.stateList<ScrollableState>(find.byType(Scrollable)).firstWhere(
              (ScrollableState s) => s.position.axis == Axis.horizontal,
              orElse: () => fail('the strip has to scroll horizontally'),
            );

    testWidgets('six wordbooks stay on one line', (WidgetTester tester) async {
      final Store store = await pumpWordsAt(tester, 411);
      await addLists(store, 5);
      await tester.pumpAndSettle();

      // Six wordbooks plus the + cannot fit across a phone, so a `Wrap` here
      // would be several rows tall. One row means every tab shares one top edge
      // and the strip's height is a single control height.
      final List<Rect> tabRects = <Rect>[
        for (final String name in <String>[
          '示例词库 · 英语',
          '词库 1 号',
          '词库 2 号',
        ])
          tester.getRect(find.text(name).first),
      ];
      for (final Rect r in tabRects.skip(1)) {
        expect(
          (r.center.dy - tabRects.first.center.dy).abs(),
          lessThan(1),
          reason: 'a wrapped strip would put these on different lines',
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('the + stays put while the tabs scroll under it', (
      WidgetTester tester,
    ) async {
      final Store store = await pumpWordsAt(tester, 411);
      await addLists(store, 8);
      await tester.pumpAndSettle();

      final Finder addButton = find.byTooltip('新建词库');
      final Rect addBefore = tester.getRect(addButton);
      final ScrollableState strip = stripScrollable(tester);
      expect(
        strip.position.maxScrollExtent,
        greaterThan(0),
        reason: 'nine wordbooks have to overflow a phone, or nothing is proved',
      );

      strip.position.jumpTo(strip.position.maxScrollExtent);
      await tester.pumpAndSettle();

      expect(
        tester.getRect(addButton),
        addBefore,
        reason: 'a + that scrolls off the edge is the bug this fixes',
      );
      expect(
        find.byTooltip('新建词库').hitTestable(),
        findsOneWidget,
        reason: 'the only way into the list manager must stay tappable',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the current wordbook leaves the strip and becomes the pill', (
      WidgetTester tester,
    ) async {
      final Store store = await pumpWordsAt(tester, 411);
      await addLists(store, 3);
      await tester.pumpAndSettle();

      // The active book is pinned at the left, so it is not in the scrolling
      // row any more; the two others are. This is what keeps the strip from
      // showing the same name twice — once as "you are here", once as a
      // destination you are already at.
      final Finder pill = find.byKey(const Key('active-list-button'));
      expect(pill, findsOneWidget);
      expect(
        find.descendant(of: pill, matching: find.text('示例词库 · 英语')),
        findsOneWidget,
        reason: 'the pill names the wordbook the table is showing',
      );
      expect(
        find.text('示例词库 · 英语'),
        findsOneWidget,
        reason: 'and it appears exactly once on the page',
      );
      expect(find.text('词库 1 号'), findsOneWidget);
      expect(find.text('词库 2 号'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the dropdown offers same-language siblings only', (
      WidgetTester tester,
    ) async {
      final Store store = await pumpWordsAt(tester, 411);
      await addLists(store, 2);
      // A Japanese book: same page, different learning language.
      final WordList japanese = store.createList(
        name: '日语 N2',
        sourceLang: 'ja',
        targetLang: 'zh-CN',
      );
      store.addWord(
        NewWordInput(term: 'ねこ', definition: '猫', listId: japanese.id),
      );
      await store.flush();
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(const Key('active-list-button')),
          matching: find.byWidgetPredicate(
            (Widget w) => w is LexIcon && w.name == Ic.chevronDown,
          ),
        ),
        findsOneWidget,
        reason: 'a menu you cannot see is a menu nobody opens',
      );

      await tester.tap(find.byKey(const Key('active-list-button')));
      await tester.pumpAndSettle();

      // The menu is the shortcut for "another book in this language", so the
      // English books are there and the Japanese one is not — a menu that
      // listed everything would be the strip again, one click further away.
      expect(find.byKey(ValueKey<String>('switch-list-${store.data.lists[1].id}')),
          findsOneWidget);
      expect(find.byKey(ValueKey<String>('switch-list-${store.data.lists[2].id}')),
          findsOneWidget);
      expect(
        find.byKey(ValueKey<String>('switch-list-${japanese.id}')),
        findsNothing,
        reason: 'a different learning language is not a sibling',
      );
      expect(
        find.byKey(ValueKey<String>('switch-list-${store.data.lists[0].id}')),
        findsNothing,
        reason: 'the book you are already reading is not a destination',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a wordbook alone in its language has no dropdown', (
      WidgetTester tester,
    ) async {
      final Store store = await pumpWordsAt(tester, 411);
      final WordList japanese = store.createList(
        name: '日语 N2',
        sourceLang: 'ja',
        targetLang: 'zh-CN',
      );
      store.addWord(
        NewWordInput(term: 'ねこ', definition: '猫', listId: japanese.id),
      );
      await store.flush();
      await tester.pumpAndSettle();

      // Switch to the Japanese book, which has no sibling at all.
      await tester.tap(find.text('日语 N2'));
      await tester.pumpAndSettle();

      final Finder pill = find.byKey(const Key('active-list-button'));
      // The icons are hand-drawn SVGs, so this has to name `Ic.chevronDown`;
      // `find.byIcon(Icons.expand_more)` would pass against any build at all,
      // including one that shows the chevron over an empty menu.
      expect(
        find.descendant(
          of: pill,
          matching: find.byWidgetPredicate(
            (Widget w) => w is LexIcon && w.name == Ic.chevronDown,
          ),
        ),
        findsNothing,
        reason: 'a chevron over an empty menu teaches that the control lies',
      );
      // Tapping it must do nothing rather than open an empty popup.
      await tester.tap(pill);
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey<String>('switch-list-${japanese.id}')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('picking from the dropdown switches the table', (
      WidgetTester tester,
    ) async {
      final Store store = await pumpWordsAt(tester, 411);
      final WordList other = store.createList(
        name: '雅思核心',
        sourceLang: 'en',
        targetLang: 'zh-CN',
      );
      // Not one of the seeded words: a term the sample wordbook already holds
      // would be on screen before the switch and the assertion would prove
      // nothing.
      store.addWord(
        NewWordInput(term: 'lacuna', definition: '空白', listId: other.id),
      );
      await store.flush();
      await tester.pumpAndSettle();

      expect(find.text('lacuna'), findsNothing, reason: 'wrong book on screen');

      await tester.tap(find.byKey(const Key('active-list-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey<String>('switch-list-${other.id}')));
      await tester.pumpAndSettle();

      expect(find.text('lacuna'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('active-list-button')),
          matching: find.text('雅思核心'),
        ),
        findsOneWidget,
        reason: 'the pill has to name the book the table now shows',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the strip leads with same-language siblings, not other-language books', (
      WidgetTester tester,
    ) async {
      final Store store = await pumpWordsAt(tester, 411);
      // The kana decks are offered when Japanese is chosen, so in a real
      // library they are often created BEFORE the reader later adds more
      // English books. Creation order alone used to put those Japanese books
      // first in the strip. On a phone the strip's viewport is barely one tab
      // wide, so the very books a reader wants to switch to sat off-screen and
      // looked like they had vanished — with the dropdown the only place still
      // showing them. That is the complaint this locks down.
      for (int i = 0; i < 2; i++) {
        final WordList ja = store.createList(
          name: '五十音 ${i + 1}',
          sourceLang: 'ja',
          targetLang: 'zh-CN',
        );
        store.addWord(NewWordInput(
          term: 'あ$i', definition: '假名 $i', listId: ja.id,
        ));
      }
      final List<String> siblings = <String>[];
      for (int i = 0; i < 2; i++) {
        final WordList en = store.createList(
          name: '英语词本 ${i + 1}',
          sourceLang: 'en',
          targetLang: 'zh-CN',
        );
        store.addWord(NewWordInput(
          term: 'word$i', definition: '释义 $i', listId: en.id,
        ));
        siblings.add(en.name);
      }
      await store.flush();
      await tester.pumpAndSettle();

      // The + is the right edge of the strip; anything to its right is off the
      // screen and needs a sideways scroll to be seen at all.
      final Rect addRect = tester.getRect(find.byTooltip('新建词库'));
      final Rect firstSibling = tester.getRect(find.text(siblings.first).first);
      expect(
        firstSibling.left,
        lessThan(addRect.left),
        reason: 'the first same-language sibling must be visible in the strip, '
            'not pushed past the + button',
      );
      expect(
        firstSibling.left,
        lessThan(tester.getRect(find.text('五十音 1').first).left),
        reason: 'siblings come before books in another learning language',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('switching wordbooks rewinds the strip to the new siblings', (
      WidgetTester tester,
    ) async {
      final Store store = await pumpWordsAt(tester, 411);
      for (int i = 0; i < 3; i++) {
        final WordList list = store.createList(
          name: '词库 ${i + 1} 号',
          sourceLang: 'en',
          targetLang: 'zh-CN',
        );
        store.addWord(NewWordInput(
          term: 'term$i', definition: '释义 $i', listId: list.id,
        ));
      }
      await store.flush();
      await tester.pumpAndSettle();

      final ScrollableState strip = tester
          .stateList<ScrollableState>(find.byType(Scrollable))
          .firstWhere((ScrollableState s) => s.position.axis == Axis.horizontal);
      strip.position.jumpTo(strip.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(strip.position.pixels, greaterThan(0),
          reason: 'the strip has to be scrolled away first, or nothing is proved');

      // Switch through the pill's dropdown — the path a reader actually uses.
      await tester.tap(find.byKey(const Key('active-list-button')));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(ValueKey<String>('switch-list-${store.data.lists[3].id}')));
      await tester.pumpAndSettle();

      expect(strip.position.pixels, 0,
          reason: 'a strip left scrolled to the tail would hide the new '
              "book's same-language siblings off its left edge");
      expect(tester.takeException(), isNull);
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
