// Layout holds at every viewport the app can be handed, not just the phone.
//
// `mobile_layout_test.dart` pins 411x866 portrait, which is where this design
// system's desktop measurements first broke. But the shell has three layout
// modes (mobile / rail / full sidebar) and only one of them is reachable from
// that viewport, so a whole class of overflow was invisible to it:
//
//   · the rail is what a *wide* window gets (<= 1000dp), so the phone never
//     draws it. Its footer row of three 44dp touch targets did not fit the
//     47dp the 64dp rail leaves after padding and border — 85dp of overflow,
//     on the primary desktop mode, in the same build that passed every phone
//     test.
//   · a tablet is wide but still a fingertip, so `isTouch` is true while the
//     query bar takes its wide branch: the status chips grew to the 44dp floor
//     inside a slot sized for the mouse. 13dp over.
//   · an accessibility text scale is neither a width nor a platform. At 2x the
//     two quiz direction labels measure ~388dp in a 305dp column. 83dp over.
//
// All three throw `RenderFlex overflowed`, which is the one layout failure that
// is impossible to mistake for a design choice — so they are asserted rather
// than photographed. The sweeps below are the ones that actually found them;
// they are cheap because a thrown overflow needs no pixel reasoning.

import 'package:flutter/material.dart' hide Card;
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/app/scope.dart';
import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/data/services/tts.dart';
import 'package:lexumo/domain/models/seed.dart';
import 'package:lexumo/domain/models/types.dart' show DEFAULT_LIST_ID;
import 'package:lexumo/ui/core/i18n/i18n.dart';
import 'package:lexumo/ui/core/theme.dart';
import 'package:lexumo/ui/core/tokens.dart';
import 'package:lexumo/ui/features/flashcards/views/flashcards_page.dart';
import 'package:lexumo/ui/features/home/views/home_page.dart';
import 'package:lexumo/ui/features/quiz/views/quiz_page.dart';
import 'package:lexumo/ui/features/settings/views/settings_page.dart';
import 'package:lexumo/ui/features/shell/views/app_shell.dart';
import 'package:lexumo/ui/features/stats/views/stats_page.dart';
import 'package:lexumo/ui/features/words/views/word_editor.dart';
import 'package:lexumo/ui/features/words/views/words_page.dart';

import 'support/fake_tts.dart';

/// The seven screens, in the order the tab bar lists them plus the shell itself.
final List<(String, Widget)> _screens = <(String, Widget)>[
  ('home', const HomePage()),
  ('words', const WordsPage()),
  ('flashcards', const FlashcardsPage(controller: null)),
  ('quiz', const QuizPage(controller: null)),
  ('stats', const StatsPage(controller: null)),
  ('settings', const SettingsPage(controller: null)),
  ('shell', const AppShell()),
];

/// Viewports that exercise a layout mode the phone cannot reach.
///
/// Chosen from the real breakpoints rather than a ladder of round numbers:
/// [Layout.mobileBreakpoint] is 720 and [Layout.railBreakpoint] is 1000, so a
/// 320-wide phone is `mobile`, a 800-wide tablet is `rail`, and 1280 is the
/// width the design tokens were measured at. Landscape 866x411 is the case
/// where the shell draws a rail in only 411dp of height — the shortest thing
/// the sidebar has to survive.
final List<(String, Size)> _viewports = <(String, Size)>[
  ('narrow phone 320x568', const Size(320, 568)),
  ('small phone 360x640', const Size(360, 640)),
  ('landscape phone 866x411', const Size(866, 411)),
  ('tablet 800x1280', const Size(800, 1280)),
  ('desktop 1280x800', const Size(1280, 800)),
];

/// Text scales from "slightly larger" to the accessibility maximum.
///
/// 2.0 is not a contrived case: it is the setting a low-vision user turns on,
/// and it is where both `Segmented` strips ran out of room.
const List<(String, double)> _textScales = <(String, double)>[
  ('1.3x', 1.3),
  ('2.0x', 2.0),
];

Future<void> _pump(
  WidgetTester tester,
  Widget screen, {
  required Size size,
  double textScale = 1.0,
}) async {
  final store = Store(persistence: MemoryStore(), seed: seedData);
  await store.init();
  await store.flush();

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MediaQuery(
      // The app reads the text scale through the ambient MediaQuery, so
      // overriding it here is what a system font-size change actually does.
      data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
      child: StoreScope(
        notifier: StoreNotifier(store),
        child: I18nScope(
          i18n: I18n(store.data.settings.uiLang),
          child: ToastScope(
            show: (text, kind, {actionLabel, onAction, durationMs}) {},
            child: NavScope(
              onNavigate: (_) {},
              child: MaterialApp(
                theme: buildTheme(Palette.light),
                home: Scaffold(body: screen),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);
  setUp(() => debugSetSpeech(silentSpeech()));
  tearDown(() => debugSetSpeech(null));

  group('every viewport lays out without an overflow', () {
    // `RenderFlex overflowed` is unambiguous: content exists that cannot be
    // seen. Nothing in this design tolerates it, so the assertion is that the
    // exception is null rather than that it is small.
    for (final (vpName, size) in _viewports) {
      for (final (name, screen) in _screens) {
        testWidgets('$name @ $vpName', (WidgetTester tester) async {
          await _pump(tester, screen, size: size);
          expect(
            tester.takeException(),
            isNull,
            reason: '$name must lay out at $vpName without a layout exception',
          );
        });
      }
    }
  });

  group('every text scale lays out without an overflow', () {
    for (final (scaleName, scale) in _textScales) {
      for (final (name, screen) in _screens) {
        testWidgets('$name @ $scaleName', (WidgetTester tester) async {
          await _pump(
            tester,
            screen,
            size: const Size(411, 866),
            textScale: scale,
          );
          expect(
            tester.takeException(),
            isNull,
            reason: '$name must lay out at $scaleName without a layout exception',
          );
        });
      }
    }
  });

  group('the sidebar rail keeps its footer inside the rail', () {
    // The specific defect, asserted at its own surface so a future change to
    // the rail width or the button size fails here rather than only in the
    // sweep above. `Layout.sidebarRailW` is 64; the sidebar pads 8 a side and
    // draws a 1dp border on the right, leaving 47 for its contents.
    testWidgets('three footer buttons do not share the rail\'s row', (
      WidgetTester tester,
    ) async {
      await _pump(tester, const AppShell(), size: const Size(866, 411));
      expect(tester.takeException(), isNull);

      // On a wide-but-short window the rail is drawn, and it must be exactly
      // the rail width — the footer growing the sidebar would be the other way
      // to "fix" the overflow and would break the page beside it. Addressed by
      // key, not by "the first AnimatedContainer", which would silently start
      // measuring a different widget the moment the tree above it changes.
      final Finder rail = find.byKey(kSidebarKey);
      expect(rail, findsOneWidget);
      final RenderBox box = tester.renderObject<RenderBox>(rail);
      expect(box.size.width, Layout.sidebarRailW);
    });
  });

  group('the status chips survive a wide touch viewport', () {
    // A tablet is `isTouch` (so chips grow to 44dp) *and* wide (so the query
    // bar takes its single-row branch). That combination is what overflowed by
    // 13dp; the fix makes the chip strip scroll, so the row can stay one line.
    testWidgets('the words query bar lays out on a tablet', (
      WidgetTester tester,
    ) async {
      await _pump(tester, const WordsPage(), size: const Size(800, 1280));
      expect(tester.takeException(), isNull);
    });
  });

  group('the word editor dialog survives a phone width', () {
    // The reported defect: "释义" printed as two stacked characters. The dialog
    // is capped at 560dp wide, so on a phone the two definition fields got
    // 159.5dp each — less than the language pair (134.8dp) plus the 翻译
    // button (~64dp) already in that field's header row. The label sat in an
    // `Expanded`, so it was handed a **0dp** box, and a zero-width Text still
    // wraps: the label rendered as two lines instead of vanishing.
    //
    // The web build collapses `.field-row` to one column below 820px. The port
    // had kept two columns unconditionally, so this is the phone shape of a
    // rule that already existed.
    for (final (vpName, size) in _viewports) {
      testWidgets('word editor @ $vpName', (WidgetTester tester) async {
        await _openEditor(tester, size: size);
        expect(
          tester.takeException(),
          isNull,
          reason: 'the word editor must lay out at $vpName',
        );
      });
    }

    // The band that made this defect invisible to every existing test. With the
    // old two-column layout the label sat in an `Expanded`, so it absorbed
    // whatever the pair label and the 翻译 button left over: at 520dp it got a
    // 0dp box (and threw), but from ~540 to ~580 it got 5-25dp and wrapped
    // *without throwing anything*. Nothing but a line count can see that.
    for (final double width in <double>[411, 540, 560, 580, 620, 900]) {
      testWidgets('the 释义 label stays on one line at ${width.toInt()}dp', (
        WidgetTester tester,
      ) async {
        await _openEditor(tester, size: Size(width, 900));
        expect(tester.takeException(), isNull);

        final Finder label = find.descendant(
          of: find.byType(Dialog),
          matching: find.text('释义'),
        );
        expect(label, findsOneWidget);
        final RenderParagraph para =
            tester.renderObject<RenderParagraph>(label);

        // Intrinsic width: a squeezed label is narrower than the text it holds.
        final double intrinsic = para.getMaxIntrinsicWidth(double.infinity);
        expect(
          para.size.width,
          greaterThanOrEqualTo(intrinsic - 0.5),
          reason: '释义 must get its intrinsic width ($intrinsic), not the '
              '${para.size.width} it is being squeezed into',
        );

        // The reported symptom, asserted directly: two stacked characters.
        // Counting distinct glyph-box tops is the line count.
        final List<TextBox> boxes = para.getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 2),
        );
        expect(
          boxes.map((TextBox b) => b.top).toSet().length,
          1,
          reason: '释义 is two characters on one line, not two lines of one '
              '(glyph tops: ${boxes.map((TextBox b) => b.top).toList()})',
        );
      });
    }
  });
}

/// Pumps a host screen and opens the add-word dialog on top of it.
///
/// The editor is a dialog, so it has to be opened through a real tap rather
/// than by pumping it as `home:` — `showLexModal` measures itself against the
/// enclosing `Dialog`, which is what the defect was about.
Future<void> _openEditor(WidgetTester tester, {required Size size}) async {
  await _pump(
    tester,
    Builder(
      builder: (BuildContext ctx) => Center(
        child: ElevatedButton(
          onPressed: () => showWordEditor(
            ctx,
            word: null,
            defaultListId: DEFAULT_LIST_ID,
          ),
          child: const Text('open editor'),
        ),
      ),
    ),
    size: size,
  );
  await tester.tap(find.text('open editor'));
  await tester.pumpAndSettle();
}
