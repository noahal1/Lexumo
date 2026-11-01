// Tests for the editor's two lookup buttons.
//
// The dictionary itself is tested in `translate_test.dart` against fake HTTP.
// What is not covered there is the wiring: which field a lookup writes into,
// whether the buttons are reachable when they cannot work, and — the case that
// is easy to get wrong and invisible when it is — whether a slow answer for a
// word the user has since retyped can still land.
//
// `defaultLookup` is the process-wide singleton and would open a real socket,
// so every test here installs `FakeLookup` through `debugSetLookup`.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/app/scope.dart';
import 'package:lexumo/data/snapshot_store.dart';
import 'package:lexumo/data/store.dart';
import 'package:lexumo/design/theme.dart';
import 'package:lexumo/design/tokens.dart';
import 'package:lexumo/domain/seed.dart';
import 'package:lexumo/domain/types.dart';
import 'package:lexumo/i18n/i18n.dart';
import 'package:lexumo/pages/word_editor.dart';
import 'package:lexumo/platform/translate.dart';
import 'package:lexumo/platform/tts.dart';
import 'package:lexumo/ui/controls.dart';

import 'support/fake_lookup.dart';
import 'support/fake_tts.dart';

Future<Store> freshStore() async {
  final store = Store(persistence: MemoryStore(), seed: seedData);
  await store.init();
  return store;
}

Future<void> pumpApp(WidgetTester tester, Store store, Widget child) async {
  await tester.pumpWidget(
    StoreScope(
      notifier: StoreNotifier(store),
      child: I18nScope(
        i18n: I18n(store.data.settings.uiLang),
        child: ToastScope(
          show: (text, kind, {actionLabel, onAction, durationMs}) {},
          child: NavScope(
            onNavigate: (String _) {},
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

/// Opens the editor from a host button and leaves it on screen.
Future<void> openEditor(WidgetTester tester, Store store, {Word? word}) async {
  await pumpApp(
    tester,
    store,
    Builder(
      builder: (BuildContext context) => ElevatedButton(
        onPressed: () => showWordEditor(
          context,
          word: word,
          defaultListId: DEFAULT_LIST_ID,
        ),
        child: const Text('open'),
      ),
    ),
  );
  await tester.tap(find.byType(ElevatedButton));
  await tester.pumpAndSettle();
}

/// The 翻译 button inside the definition row.
///
/// By label rather than by type: the dialog has several quiet buttons and
/// `find.widgetWithText` is what distinguishes them.
Finder translateButton() => find.widgetWithText(LexButton, '翻译');

/// The 由释义查词 button on the term row.
Finder reverseButton() => find.widgetWithText(LexButton, '由释义查词');

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);
  setUp(() => debugSetSpeech(silentSpeech()));
  tearDown(() {
    debugSetSpeech(null);
    debugSetLookup(null);
  });

  group('forward lookup', () {
    testWidgets('fills the meaning fields from the dictionary', (tester) async {
      final FakeLookup lookup = FakeLookup(
        result: lookupResult(
          phonetic: 'ˈkændɪd',
          senses: const <DictSense>[
            DictSense(pos: 'adj.', meaning: '坦率的'),
            DictSense(pos: 'adj.', meaning: '抓拍的'),
          ],
          examples: const <DictExample>[
            DictExample(en: 'a candid answer', zh: '坦率的回答'),
          ],
        ),
      );
      debugSetLookup(lookup);

      final store = await freshStore();
      await openEditor(tester, store);

      await tester.enterText(find.byType(TextField).first, 'candid');
      await tester.pumpAndSettle();
      await tester.tap(translateButton());
      await tester.pumpAndSettle();

      expect(lookup.calls, hasLength(1));
      expect(lookup.calls.single.term, 'candid');
      // `force` is set on every click: a click is also how a stale cache entry
      // gets refreshed.
      expect(lookup.calls.single.options.force, isTrue);

      // The part of speech goes into its own field, never glued to the gloss.
      final fields = find.byType(TextField).evaluate().toList();
      expect((fields[1].widget as TextField).controller!.text, 'adj.');
      expect((fields[2].widget as TextField).controller!.text, '坦率的');
      // The second sense lands in the secondary field, still without its tag.
      expect((fields[3].widget as TextField).controller!.text, '抓拍的');

      // The phonetic line appears above the meaning fields.
      expect(find.textContaining('ˈkændɪd'), findsOneWidget);
      // The example sentence and its translation arrive together.
      expect(find.textContaining('a candid answer'), findsOneWidget);
      expect(find.textContaining('坦率的回答'), findsOneWidget);
    });

    testWidgets('is disabled until there is a term to look up', (tester) async {
      final FakeLookup lookup = FakeLookup();
      debugSetLookup(lookup);

      final store = await freshStore();
      await openEditor(tester, store);

      // Empty term: the button is present but cannot be pressed, so a click
      // never turns into a request for the empty string.
      final LexButton button =
          tester.widget<LexButton>(translateButton());
      expect(button.onPressed, isNull);

      await tester.enterText(find.byType(TextField).first, 'candid');
      await tester.pumpAndSettle();
      expect(tester.widget<LexButton>(translateButton()).onPressed, isNotNull);
    });

    testWidgets('reports a failure under the button and keeps the draft',
        (tester) async {
      debugSetLookup(FakeLookup(failure: LookupFailure.offline));

      final store = await freshStore();
      await openEditor(tester, store);
      await tester.enterText(find.byType(TextField).first, 'candid');
      await tester.pumpAndSettle();
      await tester.tap(translateButton());
      await tester.pumpAndSettle();

      expect(find.text('无法联网查词，可手动填写'), findsOneWidget);
      // The button now offers to try again rather than pretending nothing
      // happened.
      expect(find.widgetWithText(LexButton, '重新翻译'), findsOneWidget);
      // Nothing was written over the user's draft.
      final fields = find.byType(TextField).evaluate().toList();
      expect((fields[2].widget as TextField).controller!.text, isEmpty);
    });

    testWidgets('a rate-limited failure says so specifically', (tester) async {
      debugSetLookup(FakeLookup(failure: LookupFailure.rateLimited));

      final store = await freshStore();
      await openEditor(tester, store);
      await tester.enterText(find.byType(TextField).first, 'candid');
      await tester.pumpAndSettle();
      await tester.tap(translateButton());
      await tester.pumpAndSettle();

      expect(find.text('词典这会儿有点忙，过一会儿再查。'), findsOneWidget);
    });

    testWidgets('a retry click lifts the cooldown the failure installed',
        (tester) async {
      // A 429 benches every provider for 90 seconds. If the retry click did not
      // clear that window the button could only fail for a minute and a half,
      // which is indistinguishable from a broken button.
      final FakeLookup lookup = FakeLookup(failure: LookupFailure.rateLimited);
      debugSetLookup(lookup);

      final store = await freshStore();
      await openEditor(tester, store);
      await tester.enterText(find.byType(TextField).first, 'candid');
      await tester.pumpAndSettle();

      await tester.tap(translateButton());
      await tester.pumpAndSettle();
      expect(lookup.resetCalls, 0, reason: 'the first attempt is not a retry');

      // The button now reads 重新翻译; pressing it is the user overriding the
      // cooldown.
      await tester.tap(find.widgetWithText(LexButton, '重新翻译'));
      await tester.pumpAndSettle();
      expect(lookup.resetCalls, 1);
      expect(lookup.calls, hasLength(2));
    });

    testWidgets('shows a loading label while the request is in flight',
        (tester) async {
      debugSetLookup(
        FakeLookup(
          delay: const Duration(milliseconds: 200),
          result: lookupResult(
            senses: const <DictSense>[DictSense(pos: 'n.', meaning: '风')],
          ),
        ),
      );

      final store = await freshStore();
      await openEditor(tester, store);
      await tester.enterText(find.byType(TextField).first, 'zephyr');
      await tester.pumpAndSettle();
      await tester.tap(translateButton());
      await tester.pump();

      expect(find.widgetWithText(LexButton, '翻译中…'), findsOneWidget);
      // A second click cannot start a parallel request.
      expect(
        tester.widget<LexButton>(find.widgetWithText(LexButton, '翻译中…')).onPressed,
        isNull,
      );

      // `pumpAndSettle` alone would stop as soon as no frame is scheduled,
      // which is before the fake's timer fires — advance past it explicitly.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(LexButton, '翻译'), findsOneWidget);
    });

    testWidgets('a late answer for a retyped term is dropped', (tester) async {
      // The scenario this guards: the user types `cat`, presses 翻译, and types
      // over it with `catalogue` before the slow answer lands. The answer for
      // `cat` must not be written into a draft that is now about `catalogue`.
      final FakeLookup lookup = FakeLookup(
        delay: const Duration(milliseconds: 300),
        result: lookupResult(
          term: 'cat',
          senses: const <DictSense>[DictSense(pos: 'n.', meaning: '猫')],
        ),
      );
      debugSetLookup(lookup);

      final store = await freshStore();
      await openEditor(tester, store);
      await tester.enterText(find.byType(TextField).first, 'cat');
      await tester.pumpAndSettle();
      await tester.tap(translateButton());
      await tester.pump(const Duration(milliseconds: 50));

      // Retype, then close the dialog — closing disposes the model, and the
      // pending answer arrives afterwards.
      await tester.enterText(find.byType(TextField).first, 'catalogue');
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));

      final fields = find.byType(TextField).evaluate().toList();
      expect(
        (fields[2].widget as TextField).controller!.text,
        isEmpty,
        reason: 'the answer for `cat` must not land in a `catalogue` draft',
      );
    });
  });

  group('reverse lookup', () {
    testWidgets('fills the term from a typed meaning', (tester) async {
      final FakeLookup lookup = FakeLookup(
        result: lookupResult(
          term: 'りんご',
          phonetic: '',
          senses: const <DictSense>[DictSense(pos: '', meaning: 'りんご')],
        ),
      );
      debugSetLookup(lookup);

      final store = await freshStore();
      await openEditor(tester, store);

      // The meaning field is index 2.
      await tester.enterText(find.byType(TextField).at(2), '苹果');
      await tester.pumpAndSettle();
      await tester.tap(reverseButton());
      await tester.pumpAndSettle();

      expect(lookup.calls, hasLength(1));
      expect(lookup.calls.single.term, '苹果');
      // The pair is swapped, and Youdao is pushed behind the engines that
      // return a lemma instead of a polite sentence.
      expect(lookup.calls.single.options.from, 'zh-CN');
      expect(lookup.calls.single.options.to, 'en');
      expect(
        lookup.calls.single.options.prefer,
        <ProviderId>[ProviderId.google, ProviderId.myMemory],
      );

      final fields = find.byType(TextField).evaluate().toList();
      expect((fields[0].widget as TextField).controller!.text, 'りんご');
      // The meaning the user typed is left alone.
      expect((fields[2].widget as TextField).controller!.text, '苹果');
    });

    testWidgets('is disabled until a meaning has been typed', (tester) async {
      debugSetLookup(FakeLookup());
      final store = await freshStore();
      await openEditor(tester, store);

      expect(tester.widget<LexButton>(reverseButton()).onPressed, isNull);

      await tester.enterText(find.byType(TextField).at(2), '苹果');
      await tester.pumpAndSettle();
      expect(tester.widget<LexButton>(reverseButton()).onPressed, isNotNull);
    });

    testWidgets('an empty answer leaves the term alone', (tester) async {
      // A provider can answer with senses that are all empty strings; the term
      // must not be blanked out by that.
      debugSetLookup(
        FakeLookup(
          result: lookupResult(senses: const <DictSense>[]),
        ),
      );
      final store = await freshStore();
      await openEditor(tester, store);
      await tester.enterText(find.byType(TextField).first, 'apple');
      await tester.enterText(find.byType(TextField).at(2), '苹果');
      await tester.pumpAndSettle();
      await tester.tap(reverseButton());
      await tester.pumpAndSettle();

      final fields = find.byType(TextField).evaluate().toList();
      expect((fields[0].widget as TextField).controller!.text, 'apple');
    });
  });

  group('lookup and the dirty check', () {
    testWidgets('a lookup that filled nothing leaves the draft clean',
        (tester) async {
      // Opening an existing word and pressing 翻译 with a failing lookup must
      // not make the dialog think it has unsaved changes: closing it should not
      // ask "要丢掉吗".
      debugSetLookup(FakeLookup(failure: LookupFailure.offline));

      final store = await freshStore();
      final Word word = store.data.words.first;
      await openEditor(tester, store, word: word);

      await tester.tap(translateButton());
      await tester.pumpAndSettle();

      // Esc closes without the discard line.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('这个词语还没保存，要丢掉吗？'), findsNothing);
    });

    testWidgets('a lookup that filled a field makes the draft dirty',
        (tester) async {
      debugSetLookup(
        FakeLookup(
          result: lookupResult(
            senses: const <DictSense>[DictSense(pos: 'n.', meaning: '新释义')],
          ),
        ),
      );

      final store = await freshStore();
      final Word word = store.data.words.first;
      await openEditor(tester, store, word: word);
      await tester.tap(translateButton());
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('这个词语还没保存，要丢掉吗？'), findsOneWidget);
    });
  });
}
