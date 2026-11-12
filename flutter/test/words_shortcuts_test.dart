// The word library's single-key shortcuts, and the one place they must not fire.
//
// `n` (add a word) and `/` (jump to the search field) are bound on a
// `CallbackShortcuts` that wraps the whole page — which makes the search field
// a *descendant* of the binding. Letter keys are not protected the way Space
// and Enter are: `DefaultTextEditingShortcuts` installs
// `DoNothingAndStopPropagationTextIntent` for those two only, so an ordinary
// letter reaches the page's binding first and is swallowed there.
//
// The symptom was that typing `n` while searching opened the editor instead of
// inserting the letter. Nothing in the existing suite could see it: every other
// test types with `tester.enterText`, which writes straight into the controller
// and never sends a key event.
//
// The three tests below are deliberately a pair plus a control: the fix must
// silence the shortcut *inside* a field without silencing it outside one, and
// `/` must keep working as the way in.

import 'package:flutter/material.dart' hide Card;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/app/scope.dart';
import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/ui/core/theme.dart';
import 'package:lexumo/ui/core/tokens.dart';
import 'package:lexumo/ui/core/i18n/i18n.dart';
import 'package:lexumo/domain/models/seed.dart';
import 'package:lexumo/ui/features/words/views/words_page.dart';
import 'package:lexumo/data/services/tts.dart';

import 'support/fake_tts.dart';

Future<Store> freshStore() async {
  final Store store = Store(persistence: MemoryStore(), seed: seedData);
  await store.init();
  // A save is scheduled on the first write; flushing cancels the debounce timer
  // so teardown does not fail with "A Timer is still pending".
  await store.flush();
  return store;
}

/// Pumps [WordsPage] inside the four scopes it reads, at a desktop width.
///
/// The width matters only in that it keeps the page out of its phone layout;
/// the shortcut bug reproduced at every width.
Future<Store> pumpWords(WidgetTester tester) async {
  final Store store = await freshStore();
  tester.view.physicalSize = const Size(1280, 900);
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
            onNavigate: (String _) {},
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

/// The word editor route, matched by type name.
///
/// `_WordEditorPage` is library-private to `word_editor.dart`, so `byType`
/// cannot name it from a test. Matching on `runtimeType.toString()` is the
/// narrowest thing that still works: no other widget in the tree is called
/// `_WordEditorPage`, so a match can only mean the editor route was pushed.
/// That is exactly the claim these tests need to make — not "the screen looks
/// different", but "a route exists that should not".
Finder editorRoute() => find.byWidgetPredicate(
      (Widget w) => w.runtimeType.toString() == '_WordEditorPage',
    );

/// The page's search field — the only `TextField` on the library screen until
/// the list manager opens.
Finder searchField() => find.byType(TextField).first;

/// Whether the keyboard is currently going into a text field, by the same
/// ancestor walk the page's guard uses. Asserted directly so a failure says
/// "the field was not focused after all" instead of blaming the shortcut.
bool focusIsInTextField() {
  final BuildContext? ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  bool inField = false;
  ctx.visitAncestorElements((Element element) {
    if (element.widget is EditableText) {
      inField = true;
      return false;
    }
    return true;
  });
  return inField;
}

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);
  // The editor renders a 发音 button and reads `appSpeech`; installing the fake
  // keeps the flutter_tts platform channel out of the test.
  setUp(() => debugSetSpeech(silentSpeech()));
  tearDown(() => debugSetSpeech(null));

  testWidgets('typing n in the search field does not open the editor',
      (tester) async {
    await pumpWords(tester);

    await tester.showKeyboard(searchField());
    await tester.pumpAndSettle();
    expect(
      focusIsInTextField(),
      isTrue,
      reason: 'the search field must hold focus for this test to mean anything',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.pumpAndSettle();

    // The regression: without the guard this route is pushed and the page the
    // user was typing into disappears behind an editor.
    expect(editorRoute(), findsNothing);
    expect(find.byType(WordsPage), findsOneWidget);
    // The letter belonged to the field, so the field must still own the focus.
    expect(focusIsInTextField(), isTrue);
  });

  testWidgets('n outside a text field still opens the editor', (tester) async {
    // The positive control. A guard that returned true whenever *any* focus
    // existed would pass the test above and quietly kill the shortcut; this is
    // what catches that.
    await pumpWords(tester);

    expect(
      focusIsInTextField(),
      isFalse,
      reason: 'nothing is focused in a field on first paint',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.pumpAndSettle();

    expect(editorRoute(), findsOneWidget);
  });

  testWidgets('slash with the search field already focused is a no-op',
      (tester) async {
    // `/` re-focusing the field it is already in must not push anything, clear
    // the query, or leave select mode — the field's own text handling owns the
    // key while it has focus.
    await pumpWords(tester);

    await tester.showKeyboard(searchField());
    await tester.pumpAndSettle();
    expect(focusIsInTextField(), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pumpAndSettle();

    expect(editorRoute(), findsNothing);
    expect(focusIsInTextField(), isTrue);
    expect(find.byType(WordsPage), findsOneWidget);
  });

  testWidgets('slash outside a text field still focuses the search field',
      (tester) async {
    await pumpWords(tester);

    expect(focusIsInTextField(), isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pumpAndSettle();

    expect(focusIsInTextField(), isTrue);
  });
}
