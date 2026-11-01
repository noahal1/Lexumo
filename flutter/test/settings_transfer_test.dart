// Export and import from the settings page.
//
// The interesting questions here are not "does the button exist" but the two
// places where this feature can quietly damage a library:
//
//   1. **A cancelled dialog must not report success.** Every platform's picker
//      returns a null/false on cancel, and a toast saying "exported" over a
//      file that was never written is a lie the user only discovers when they
//      need the backup.
//   2. **Import must not duplicate.** The parser is deliberately forgiving, so
//      a file that overlaps the existing library is the normal case, not the
//      edge case. Words already present are skipped and counted.
//
// `fileDialogs` is swapped for a fake because the real implementation opens an
// OS dialog. What that leaves untested is the platform plumbing itself — the
// Android `ACTION_CREATE_DOCUMENT` channel and `getSaveLocation` — which needs a
// device; the parsers are covered by `transfer_test.dart`.
//
// The words used here (`quixotic`, `zeal`) are deliberately NOT in
// `domain/seed.dart`: the store starts with fourteen seeded words, and
// importing a seeded term would exercise the duplicate path instead of the
// add path.

import 'package:flutter/material.dart' hide Card;
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/app/scope.dart';
import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/ui/core/theme.dart';
import 'package:lexumo/ui/core/tokens.dart';
import 'package:lexumo/domain/models/seed.dart';
import 'package:lexumo/ui/core/i18n/i18n.dart';
import 'package:lexumo/ui/features/settings/views/settings_page.dart';
import 'package:lexumo/data/services/file_dialogs.dart';
import 'package:lexumo/data/services/tts.dart';
import 'package:lexumo/ui/core/widgets/controls.dart';

import 'support/fake_tts.dart';

/// One toast the page raised, captured instead of rendered.
typedef ToastRecord = ({String text, ToastKind kind});

/// Pumps the settings page inside the scopes it needs, collecting toasts.
///
/// 1100 logical pixels keeps it on the wide layout, where the Data section's
/// rows are side-by-side; the page stacks them below 520 and the buttons would
/// scroll out of the finder's reach.
Future<(Store, List<ToastRecord>)> pumpSettings(WidgetTester tester) async {
  final store = Store(persistence: MemoryStore(), seed: seedData);
  await store.init();
  await store.flush();
  final toasts = <ToastRecord>[];

  tester.view.physicalSize = const Size(1100, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    StoreScope(
      notifier: StoreNotifier(store),
      child: I18nScope(
        i18n: I18n(store.data.settings.uiLang),
        child: ToastScope(
          show: (text, kind, {actionLabel, onAction, durationMs}) {
            toasts.add((text: text, kind: kind));
          },
          child: NavScope(
            onNavigate: (_) {},
            child: MaterialApp(
              theme: buildTheme(Palette.light),
              home: Scaffold(body: SettingsPage()),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (store, toasts);
}

/// Scrolls [finder] into view, then taps it.
///
/// `ensureVisible` rather than a fixed drag: the page is long and the section's
/// position depends on the language (Chinese labels wrap differently), so a
/// hardcoded offset would break the moment a string changed.
Future<void> tapInView(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Taps the LexButton carrying [label].
Future<void> tapButton(WidgetTester tester, String label) =>
    tapInView(tester, find.widgetWithText(LexButton, label).first);

/// The N-th LexButton carrying [label] (0-based).
Finder buttonAt(String label, int index) =>
    find.widgetWithText(LexButton, label).at(index);

/// A minimal CSV the parser recognises by its header.
///
/// Neither term is in the seed library.
const String _csv = 'term,definition\n'
    'quixotic,不切实际的；堂吉诃德式的\n'
    'zeal,热情；热忱\n';

void main() {
  // Every test replaces the dialogs and must put the real ones back, or the
  // next test in the file would hit the fake's defaults.
  late FileDialogs original;

  // `SettingsPage.initState` calls `appSpeech.warmUp()`, and `appSpeech` is the
  // process-wide singleton — so without this, every test here reaches the real
  // `flutter_tts` plugin and its platform channel. Those calls are wrapped in
  // try/catch upstream, so they do not fail the test; they just make it silent
  // about what it exercised. Installing a silent engine keeps the assertions on
  // the page. See `test/support/fake_tts.dart`.
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);
  setUp(() => debugSetSpeech(silentSpeech()));
  tearDown(() => debugSetSpeech(null));

  setUp(() {
    original = fileDialogs;
  });

  tearDown(() {
    fileDialogs = original;
  });

  group('export', () {
    testWidgets('a completed save writes JSON and says so', (WidgetTester tester) async {
      final fake = FakeFileDialogs();
      fileDialogs = fake;
      final (store, toasts) = await pumpSettings(tester);

      await tapButton(tester, '导出'); // Export, first row (JSON)

      expect(fake.saved, hasLength(1));
      final saved = fake.saved.single;
      expect(saved.name, startsWith('lexumo-backup-'));
      expect(saved.name, endsWith('.json'));
      expect(saved.mimeType, 'application/json');
      // The snapshot must carry the seeded words — an empty file that reports
      // success is the failure mode this asserts against.
      expect(saved.content, contains('"words"'));
      expect(store.data.words, isNotEmpty);
      expect(saved.content, contains(store.data.words.first.term));

      expect(toasts, hasLength(1));
      expect(toasts.single.kind, ToastKind.ok);
      expect(toasts.single.text, '已导出 JSON 备份');
    });

    testWidgets('a cancelled dialog reports failure, not success', (WidgetTester tester) async {
      // `onSave` returning false is exactly what the real layer does when the
      // user closes the save dialog.
      final fake = FakeFileDialogs(onSave: (_, _) async => false);
      fileDialogs = fake;
      final (_, toasts) = await pumpSettings(tester);

      await tapButton(tester, '导出');

      expect(fake.saved, hasLength(1), reason: 'the write was attempted');
      expect(toasts, hasLength(1));
      expect(toasts.single.kind, ToastKind.err);
      expect(toasts.single.text, '导出未完成');
    });

    testWidgets('the CSV export is a separate row with its own file name',
        (WidgetTester tester) async {
      final fake = FakeFileDialogs();
      fileDialogs = fake;
      final (store, _) = await pumpSettings(tester);

      // The second 导出 button belongs to the CSV row.
      expect(find.widgetWithText(LexButton, '导出'), findsNWidgets(2),
          reason: 'JSON and CSV each have one');
      await tapInView(tester, buttonAt('导出', 1));

      expect(fake.saved, hasLength(1));
      final saved = fake.saved.single;
      expect(saved.name, startsWith('lexumo-words-'));
      expect(saved.name, endsWith('.csv'));
      expect(saved.mimeType, 'text/csv');
      // Excel needs the BOM to read CJK without mojibake; `transfer_test.dart`
      // asserts it on the encoder, this asserts it survives to the write.
      expect(saved.content.startsWith('\uFEFF'), isTrue);
      expect(saved.content, contains(store.data.words.first.term));
    });
  });

  group('import', () {
    testWidgets('a picked file shows a preview and adds nothing yet',
        (WidgetTester tester) async {
      fileDialogs = FakeFileDialogs(
        onPick: () async => const PickedFile(name: 'two.csv', text: _csv),
      );
      final (store, _) = await pumpSettings(tester);
      final before = store.data.words.length;

      await tapButton(tester, '导入');

      // Preview, not commit: the dialog is open and the library is untouched.
      expect(find.text('导入预览'), findsOneWidget);
      expect(find.textContaining('two.csv'), findsOneWidget);
      expect(find.text('quixotic'), findsOneWidget, reason: 'preview lists it');
      expect(store.data.words.length, before, reason: 'nothing added before confirm');
    });

    testWidgets('confirming adds the words', (WidgetTester tester) async {
      fileDialogs = FakeFileDialogs(
        onPick: () async => const PickedFile(name: 'two.csv', text: _csv),
      );
      final (store, toasts) = await pumpSettings(tester);
      final before = store.data.words.length;

      await tapButton(tester, '导入');
      await tester.tap(find.widgetWithText(LexButton, '导入 · 2'));
      await tester.pumpAndSettle();

      expect(store.data.words.length, before + 2);
      final terms = store.data.words.map((w) => w.term).toSet();
      expect(terms, containsAll(<String>['quixotic', 'zeal']));
      expect(toasts.single.kind, ToastKind.ok);
      expect(toasts.single.text, '成功导入 2 个词语');
    });

    testWidgets('cancelling the preview adds nothing', (WidgetTester tester) async {
      fileDialogs = FakeFileDialogs(
        onPick: () async => const PickedFile(name: 'two.csv', text: _csv),
      );
      final (store, toasts) = await pumpSettings(tester);
      final before = store.data.words.length;

      await tapButton(tester, '导入');
      await tester.tap(find.widgetWithText(LexButton, '取消'));
      await tester.pumpAndSettle();

      expect(store.data.words.length, before);
      expect(toasts, isEmpty, reason: 'a cancelled preview is not an outcome');
    });

    testWidgets('a word already in the library is skipped, not duplicated',
        (WidgetTester tester) async {
      final (store, toasts) = await pumpSettings(tester);

      // Import one word twice: the second pass must be a no-op.
      const once = 'term,definition\nquixotic,不切实际的\n';
      fileDialogs = FakeFileDialogs(
        onPick: () async => const PickedFile(name: 'one.csv', text: once),
      );
      await tapButton(tester, '导入');
      await tester.tap(find.widgetWithText(LexButton, '导入 · 1'));
      await tester.pumpAndSettle();
      final afterFirst = store.data.words.length;
      expect(afterFirst, greaterThan(0));
      toasts.clear();

      await tapButton(tester, '导入');
      await tester.tap(find.widgetWithText(LexButton, '导入 · 1'));
      await tester.pumpAndSettle();

      expect(store.data.words.length, afterFirst, reason: 'no duplicate row');
      expect(store.data.words.where((w) => w.term == 'quixotic').length, 1);
      // The duplicate is reported as info, not as a failure: the file was
      // fine, the word was simply already there.
      expect(toasts.single.kind, ToastKind.info);
      expect(toasts.single.text, '已跳过 1 个重复词语');
    });

    testWidgets('an unrecognised file is refused without opening the preview',
        (WidgetTester tester) async {
      fileDialogs = FakeFileDialogs(
        onPick: () async => const PickedFile(name: 'notes.md', text: '# hello'),
      );
      final (store, toasts) = await pumpSettings(tester);
      final before = store.data.words.length;

      await tapButton(tester, '导入');

      expect(find.text('导入预览'), findsNothing);
      expect(store.data.words.length, before);
      expect(toasts.single.kind, ToastKind.err);
      expect(toasts.single.text, contains('无法识别'));
    });

    testWidgets('cancelling the picker does nothing at all',
        (WidgetTester tester) async {
      // `onPick` null is the fake's default, matching a closed dialog.
      fileDialogs = FakeFileDialogs();
      final (store, toasts) = await pumpSettings(tester);
      final before = store.data.words.length;

      await tapButton(tester, '导入');

      expect(find.text('导入预览'), findsNothing);
      expect(store.data.words.length, before);
      // No toast either: a dialog the user closed is not an error.
      expect(toasts, isEmpty);
    });
  });
}
