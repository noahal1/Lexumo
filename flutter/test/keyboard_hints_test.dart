// Keycap visibility on touch platforms.
//
// The request behind this was blunt: "移动端不要显示快捷键" — no shortcut hints on
// mobile. A keycap (`Ctrl`, `Enter`, `空格`, `1`) is an advertisement for a
// hardware keyboard; on a phone it cannot be pressed and it steals horizontal
// space from the very content the screen exists to show.
//
// Two things are asserted, and they are different questions:
//
//   1. The predicate itself, per platform. Desktop keeps hints, touch drops
//      them — and the rule is platform-based, NOT width-based, so a narrow
//      desktop window must still show them.
//   2. That the widgets actually obey it. A predicate nothing calls is worse
//      than no predicate, so each page that used to draw keycaps is pumped on
//      both branches and searched for keycap text.
//
// `debugDefaultTargetPlatformOverride` is required because `flutter test`
// reports `TargetPlatform.android` by default: without it the desktop branch
// would never run and the "keep the hints" half would be untested.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Card;
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/app/scope.dart';
import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/ui/core/theme.dart';
import 'package:lexumo/ui/core/tokens.dart';
import 'package:lexumo/domain/models/seed.dart';
import 'package:lexumo/ui/core/i18n/i18n.dart';
import 'package:lexumo/ui/features/flashcards/views/flashcards_page.dart';
import 'package:lexumo/ui/features/quiz/views/quiz_page.dart';
import 'package:lexumo/domain/models/types.dart';
import 'package:lexumo/ui/features/words/views/word_editor.dart';
import 'package:lexumo/ui/features/words/views/words_page.dart';
import 'package:lexumo/data/services/tts.dart';
import 'package:lexumo/ui/core/widgets/controls.dart';
import 'package:lexumo/ui/core/widgets/keyboard_hints.dart';

import 'support/fake_tts.dart';

/// Runs [body] with [platform] pinned, restoring the host's value afterwards.
Future<void> withPlatform(
  TargetPlatform platform,
  Future<void> Function() body,
) async {
  // The raw nullable value, not `?? defaultTargetPlatform`: restoring the
  // *resolved* default would leave the override set to android, and the test
  // binding's `debugAssertAllFoundationVarsUnset` then fails every test.
  final TargetPlatform? previous = debugDefaultTargetPlatformOverride;
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    // Leaving the override set would leak into the next test in the file.
    debugDefaultTargetPlatformOverride = previous;
  }
}

Future<Store> freshStore() async {
  final store = Store(persistence: MemoryStore(), seed: seedData);
  await store.init();
  await store.flush();
  return store;
}

/// Pumps [child] inside the scopes a page needs, at a fixed logical width.
Future<Store> pumpPage(
  WidgetTester tester,
  Widget child, {
  double width = 1100,
}) async {
  final store = await freshStore();
  tester.view.physicalSize = Size(width, 1200);
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
              home: Scaffold(body: child),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

void main() {
  // QuizPage and FlashcardsPage evaluate `speechAvailable` while building
  // (they hide the 发音 button when the engine failed), and that getter reads
  // `appSpeech` — the process-wide singleton. Without a fake, pumping those
  // pages constructs a real `FlutterTts` and sets up its method channel, so
  // these layout tests would be exercising a plugin too. See
  // `test/support/fake_tts.dart`.
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);
  setUp(() => debugSetSpeech(silentSpeech()));
  tearDown(() => debugSetSpeech(null));

  group('showKeyboardHints', () {
    test('desktop platforms keep the keycaps', () {
      for (final TargetPlatform p in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      ]) {
        expect(showKeyboardHints(platform: p), isTrue, reason: '$p has a keyboard');
      }
    });

    test('touch platforms drop them', () {
      for (final TargetPlatform p in <TargetPlatform>[
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.fuchsia,
      ]) {
        expect(showKeyboardHints(platform: p), isFalse, reason: '$p has no keyboard');
      }
    });

    test('the rule is the platform, not the window width', () {
      // A 900dp-wide desktop window is still keyboard-driven, and a tablet in
      // landscape is wide but still has no keyboard. Width would answer both
      // wrongly, which is why it is not consulted.
      expect(showKeyboardHints(platform: TargetPlatform.windows), isTrue);
      expect(showKeyboardHints(platform: TargetPlatform.android), isFalse);
    });
  });

  group('words page footer', () {
    testWidgets('desktop shows the / and n keycaps', (WidgetTester tester) async {
      await withPlatform(TargetPlatform.windows, () async {
        await pumpPage(tester, const WordsPage());
        expect(find.text('/'), findsWidgets);
        expect(find.text('n'), findsWidgets);
      });
    });

    testWidgets('android shows neither', (WidgetTester tester) async {
      await withPlatform(TargetPlatform.android, () async {
        await pumpPage(tester, const WordsPage());
        expect(find.text('/'), findsNothing);
        expect(find.text('n'), findsNothing);
      });
    });
  });

  group('quiz page', () {
    // The page opens on its idle screen, where the answer legend is not built
    // at all — asserting "no A/B" there would pass for the wrong reason. The
    // round has to be started first so the legend is genuinely on screen.
    //
    // The button, not the heading: the intro card repeats the words "开始测验"
    // as its title, and tapping the title does nothing.
    Future<void> startRound(WidgetTester tester) async {
      await tester.tap(find.widgetWithText(LexButton, '开始测验').first);
      await tester.pumpAndSettle();
    }

    testWidgets('desktop shows the answer-letter legend', (WidgetTester tester) async {
      await withPlatform(TargetPlatform.windows, () async {
        await pumpPage(tester, const QuizPage());
        await startRound(tester);
        // The round really started: the four answer buttons carry A–D badges,
        // and the idle intro is gone.
        expect(find.text('开始测验'), findsNothing);
        // The legend is the row of A B C D / 1 2 3 4 keycaps above the answers.
        expect(find.text('A'), findsWidgets);
        expect(find.text('B'), findsWidgets);
      });
    });

    testWidgets('android shows no letter legend', (WidgetTester tester) async {
      await withPlatform(TargetPlatform.android, () async {
        await pumpPage(tester, const QuizPage());
        await startRound(tester);
        expect(find.text('开始测验'), findsNothing);
        // The A–D badges on the answer buttons are part of the answer itself,
        // not a shortcut, and they must survive: they label the options.
        expect(find.text('A'), findsWidgets);
        expect(find.text('B'), findsWidgets);
        // What must be gone is the keycap legend — the "A B C D / 1 2 3 4"
        // row and the idle screen's keyboard sentence.
        expect(find.text('按 A–D 或 1–4 选择，Enter 下一题。'), findsNothing);
        expect(find.text(' / '), findsNothing);
      });
    });
  });

  group('word editor', () {
    // The editor is a modal, not a page: it is opened from a host button the
    // way the library page opens it, so the legend is measured where it really
    // lives rather than in a synthetic body.
    Future<void> openEditor(WidgetTester tester) async {
      await pumpPage(
        tester,
        Builder(
          builder: (BuildContext context) => ElevatedButton(
            onPressed: () => showWordEditor(
              context,
              word: null,
              defaultListId: DEFAULT_LIST_ID,
            ),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('desktop shows the keyboard legend under the fields', (
      WidgetTester tester,
    ) async {
      await withPlatform(TargetPlatform.windows, () async {
        await openEditor(tester);
        expect(find.text('Ctrl'), findsWidgets);
        expect(find.text('Esc'), findsWidgets);
      });
    });

    testWidgets('android shows no keyboard legend', (WidgetTester tester) async {
      await withPlatform(TargetPlatform.android, () async {
        await openEditor(tester);
        expect(find.text('Ctrl'), findsNothing);
        expect(find.text('Esc'), findsNothing);
      });
    });
  });

  group('flashcards intro', () {
    // The intro screen ends with a plain sentence spelling out the whole
    // keyboard map ("空格翻面，1 困难，2 记得，3 简单，Ctrl+Z 撤销"). It is prose,
    // not a keycap, so it slipped past the earlier sweep — a device dump caught
    // it on the phone. It must follow the same platform rule as the keycaps.
    const String hint = '空格翻面，1 困难，2 记得，3 简单，Ctrl+Z 撤销';

    testWidgets('desktop spells out the keyboard map', (WidgetTester tester) async {
      await withPlatform(TargetPlatform.windows, () async {
        await pumpPage(tester, const FlashcardsPage());
        expect(find.text(hint), findsOneWidget);
      });
    });

    testWidgets('android drops the sentence entirely', (WidgetTester tester) async {
      await withPlatform(TargetPlatform.android, () async {
        await pumpPage(tester, const FlashcardsPage());
        expect(find.text(hint), findsNothing);
        // No stray "Ctrl" from any other part of the intro either.
        expect(find.textContaining('Ctrl'), findsNothing);
      });
    });
  });
}
