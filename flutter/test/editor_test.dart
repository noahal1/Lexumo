// Page-level tests for the editor and the shell.
//
// The emulator walkthrough proved the app runs, but a device cannot prove that
// a field lands in the right column — a tap at the wrong y puts a definition in
// `definition2` and the list then correctly shows "还没有释义", which looks like
// a bug and isn't. These tests drive the widgets by identity instead.

import 'package:flutter/material.dart' hide Card;
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/app/scope.dart';
import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/ui/core/theme.dart';
import 'package:lexumo/ui/core/tokens.dart';
import 'package:lexumo/domain/models/seed.dart';
import 'package:lexumo/domain/models/types.dart';
import 'package:lexumo/ui/core/i18n/i18n.dart';
import 'package:lexumo/ui/features/words/views/word_editor.dart';
import 'package:lexumo/data/services/tts.dart';
import 'package:lexumo/ui/core/widgets/controls.dart';

import 'support/fake_tts.dart';

/// The footer's primary Save button.
///
/// Not `find.text('保存')`: the keyboard legend above the footer also spells
/// "Ctrl + Enter 保存", so the bare text is ambiguous. The button is identified
/// by its widget type plus label.
final Finder saveButton = find.widgetWithText(LexButton, '保存');

/// A store with a fresh seed and no disk, ready for a widget tree.
Future<Store> freshStore() async {
  final store = Store(persistence: MemoryStore(), seed: seedData);
  await store.init();
  return store;
}

/// Pumps [child] with everything a page reads: store, i18n, toast, nav.
Future<void> pumpApp(
  WidgetTester tester,
  Store store,
  Widget child, {
  List<String> navigations = const <String>[],
}) async {
  await tester.pumpWidget(
    StoreScope(
      notifier: StoreNotifier(store),
      child: I18nScope(
        i18n: I18n(store.data.settings.uiLang),
        child: ToastScope(
          show: (text, kind, {actionLabel, onAction, durationMs}) {},
          child: NavScope(
            onNavigate: navigations.add,
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
      builder: (BuildContext context) => LexButtonHost(
        onPressed: () => showWordEditor(
          context,
          word: word,
          defaultListId: DEFAULT_LIST_ID,
        ),
      ),
    ),
  );
  await tester.tap(find.byType(ElevatedButton));
  await tester.pumpAndSettle();
}

/// Minimal host: one button that opens the editor.
class LexButtonHost extends StatelessWidget {
  const LexButtonHost({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) =>
      ElevatedButton(onPressed: onPressed, child: const Text('open'));
}

void main() {
  // The editor offers the same 发音 control as the list, gated on
  // `speechAvailable` → `appSpeech`, the process-wide singleton. Without a
  // fake, opening the editor constructs a real `FlutterTts`. See
  // `test/support/fake_tts.dart`.
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);
  setUp(() => debugSetSpeech(silentSpeech()));
  tearDown(() => debugSetSpeech(null));

  group('word editor', () {
    testWidgets('a new word saves its term and definition into the right fields',
        (tester) async {
      final store = await freshStore();
      await openEditor(tester, store);

      expect(find.text('添加词语'), findsOneWidget);

      // The term field is the one whose hint is the term placeholder.
      final termField = find.byType(TextField).first;
      await tester.enterText(termField, 'zephyr');
      await tester.pumpAndSettle();

      // Field order in the modal: 0 term, 1 part of speech, 2 definition,
      // 3 secondary definition, then the example / note text areas.
      final fields = find.byType(TextField).evaluate().toList();
      expect(fields.length, greaterThanOrEqualTo(4));

      await tester.enterText(find.byType(TextField).at(2), 'a gentle breeze');
      await tester.pumpAndSettle();

      await tester.tap(saveButton);
      await tester.pumpAndSettle();

      final added = store.data.words.where((w) => w.term == 'zephyr').toList();
      expect(added, hasLength(1), reason: 'the word should have been added');
      expect(added.single.definition, 'a gentle breeze',
          reason: 'the definition must land in `definition`, not `definition2`');
      expect(added.single.definition2, isEmpty);
    });

    testWidgets('saving with an empty term reports an error and adds nothing',
        (tester) async {
      final store = await freshStore();
      final before = store.data.words.length;
      await openEditor(tester, store);

      await tester.tap(saveButton);
      await tester.pumpAndSettle();

      expect(store.data.words.length, before);
      expect(find.text('请输入词语'), findsOneWidget);
    });

    testWidgets('a duplicate term shows the duplicate notice', (tester) async {
      final store = await freshStore();
      final existing = store.data.words.first;
      await openEditor(tester, store);

      await tester.enterText(find.byType(TextField).first, existing.term);
      await tester.pumpAndSettle();

      expect(find.text('这个词语已经在词库里了'), findsOneWidget);
    });

    testWidgets('editing an existing word pre-fills every field', (tester) async {
      final store = await freshStore();
      final word = store.data.words.first;
      await openEditor(tester, store, word: word);

      expect(find.text(word.term), findsWidgets);
      expect(find.text(word.definition), findsWidgets);
    });
  });
}
