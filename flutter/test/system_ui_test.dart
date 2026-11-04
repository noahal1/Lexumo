// Edge-to-edge window chrome: the overlay style, and the shell that publishes it.
//
// The bug this pins: the app never called the system UI at all, so Android drew
// an opaque default status bar above a letterboxed Flutter view, and the shell's
// `SafeArea` reserved that band a second time. Nothing threw. Nothing failed a
// layout test. The screen just had a dead strip at the top in a colour that
// matched neither material in the design system.
//
// Two halves have to agree, and they are tested separately here because they
// fail differently:
//
//   · `enableEdgeToEdge` is a platform-channel call. A widget test cannot prove
//     the OS obeyed it, but it CAN prove the app asked — and asking is the half
//     that was missing. `SystemChrome.setEnabledSystemUIMode` lands in
//     `SystemChannels.platform` as a `SystemChrome.setEnabledSystemUIMode`
//     method call, which the test binding records.
//   · The glyph colour is an `AnnotatedRegion` resolved from the layer tree, so
//     it is fully testable: pump the shell at a phone width and at a tablet
//     width and read back the value the shell published.
//
// The interesting assertion is the second one's *asymmetry*. The status bar is
// stone in every layout and stone is dark in both themes, so its glyphs are
// always light. The navigation bar is stone only when the phone tab bar is
// there; a tablet has paper to the bottom edge, and paper follows the theme. A
// single `isDark`-driven style would be invisible on one of the two layouts.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/app/scope.dart';
import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/data/services/tts.dart';
import 'package:lexumo/domain/models/seed.dart';
import 'package:lexumo/domain/models/types.dart' show Settings, ThemeMode_;
import 'package:lexumo/ui/core/i18n/i18n.dart';
import 'package:lexumo/ui/core/system_ui.dart';
import 'package:lexumo/ui/core/theme.dart';
import 'package:lexumo/ui/core/tokens.dart';
import 'package:lexumo/ui/features/shell/views/app_shell.dart';

import 'support/fake_tts.dart';

/// Pump the real shell at [size] and hand back the overlay style it published.
///
/// Reading the `AnnotatedRegion` back out of the tree is the whole point: the
/// style is a *derived* value that depends on the layout mode, so asserting on
/// the function's return value alone would not catch a shell that published the
/// wrong one.
Future<SystemUiOverlayStyle> _publishedStyle(
  WidgetTester tester, {
  required Size size,
  bool dark = false,
}) async {
  final store = Store(
    persistence: MemoryStore(),
    seed: seedData,
    // The default 220 ms debounce leaves a `Timer` alive past the test body,
    // which trips `testWidgets`'s pending-timer check.
    saveDelayMs: 0,
  );
  await store.init();
  // `ShellViewModel.isDark` reads the *setting*, not the ambient theme — the
  // setting is what `main.dart` feeds to `MaterialApp.themeMode`. Flipping only
  // the MaterialApp would leave the view model saying "light" while the palette
  // painted dark, which is a state the real app cannot reach.
  if (dark) {
    store.updateSettings(
      (Settings s) => s.copyWith(theme: ThemeMode_.dark),
    );
    await store.flush();
  }

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: size),
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
                darkTheme: buildTheme(Palette.dark),
                themeMode:
                    dark ? ThemeMode.dark : ThemeMode.light,
                home: const AppShell(),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  // The shell's own region is the one wrapping the Scaffold. `first` is the
  // shell because it is the outermost of the regions the tree contains.
  final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
    find.byType(AnnotatedRegion<SystemUiOverlayStyle>).first,
  );
  return region.value;
}

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);
  setUp(() => debugSetSpeech(silentSpeech()));
  tearDown(() => debugSetSpeech(null));

  group('shellOverlayStyle', () {
    test('both bars are transparent so the app colour reaches the glass', () {
      for (final bool isDark in <bool>[true, false]) {
        final style = shellOverlayStyle(isDark: isDark, statusOnPaper: false);
        expect(
          style.statusBarColor,
          Colors.transparent,
          reason: 'status bar @ isDark=$isDark',
        );
        expect(
          style.systemNavigationBarColor,
          Colors.transparent,
          reason: 'navigation bar @ isDark=$isDark',
        );
        expect(
          style.systemNavigationBarDividerColor,
          Colors.transparent,
          reason: 'divider @ isDark=$isDark',
        );
      }
    });

    test('the OS scrim is off on both edges', () {
      // Android 10+ defaults `systemNavigationBarContrastEnforced` to true when
      // the bar is transparent, which paints a translucent scrim in a colour no
      // design token owns. Same for the status bar from Android 11.
      for (final bool isDark in <bool>[true, false]) {
        final style = shellOverlayStyle(isDark: isDark, statusOnPaper: false);
        expect(style.systemStatusBarContrastEnforced, isFalse);
        expect(style.systemNavigationBarContrastEnforced, isFalse);
      }
    });

    test('over the stone frame the glyphs are light in both themes', () {
      // The frame does not change colour with the theme — that is the design
      // system's own rule. So this loop deliberately ignores `isDark`: over
      // stone, if the status icons ever followed the theme, one of the two
      // modes would put dark glyphs on dark stone.
      for (final bool isDark in <bool>[true, false]) {
        final style = shellOverlayStyle(isDark: isDark, statusOnPaper: false);
        expect(style.statusBarIconBrightness, Brightness.light);
        // iOS spells the same intent inverted: `dark` means "light content".
        expect(style.statusBarBrightness, Brightness.dark);
      }
    });

    test('over paper the status glyphs follow the theme', () {
      // A phone runs its paper to the top of the glass, so the bar sits on the
      // theme's paper: dark glyphs on light paper, light glyphs on dark.
      final light = shellOverlayStyle(isDark: false, statusOnPaper: true);
      expect(light.statusBarIconBrightness, Brightness.dark);
      // iOS inverted again: a light backing is what asks for dark glyphs.
      expect(light.statusBarBrightness, Brightness.light);

      final dark = shellOverlayStyle(isDark: true, statusOnPaper: true);
      expect(dark.statusBarIconBrightness, Brightness.light);
      expect(dark.statusBarBrightness, Brightness.dark);
    });

    test('nav glyphs follow the theme, because the bottom edge is always paper',
        () {
      // Every layout ends in paper now: the phone's bar is a paper dock with a
      // paper capsule on it, and the wider layouts have no bar at all. There is
      // no layout mode left in which the bottom edge is stone, which is why this
      // function stopped taking one. It used to be told the layout and got the
      // phone case wrong — it painted light glyphs over a paper bar.
      expect(
        shellOverlayStyle(isDark: false, statusOnPaper: false).systemNavigationBarIconBrightness,
        Brightness.dark,
      );
      expect(
        shellOverlayStyle(isDark: true, statusOnPaper: false).systemNavigationBarIconBrightness,
        Brightness.light,
      );
    });
  });

  group('enableEdgeToEdge', () {
    // One test, not two, and deliberately so: `SystemChrome` keeps the last
    // style it applied in a *static* field, and `setSystemUIOverlayStyle` skips
    // the platform call entirely when handed a style equal to that field. Split
    // across two tests, whichever ran second would see no call and fail for a
    // reason that has nothing to do with the code under test.
    test('asks for edge-to-edge and primes the overlay style', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await enableEdgeToEdge();
      // The overlay style is applied from a microtask, not synchronously, so it
      // has not reached the channel when the future completes.
      await pumpEventQueue();

      final modes = calls
          .where((c) => c.method == 'SystemChrome.setEnabledSystemUIMode')
          .toList();
      expect(
        modes,
        isNotEmpty,
        reason: 'the app must actually ask for edge-to-edge; '
            'this is the call that was missing entirely',
      );
      expect(
        modes.last.arguments,
        // `edgeToEdge` is the mode that keeps both bars visible as transparent
        // overlays. `leanBack`/`immersive` hide them, which a user cannot
        // recover their clock from without a gesture.
        SystemUiMode.edgeToEdge.toString(),
      );

      expect(
        calls.any((c) => c.method == 'SystemChrome.setSystemUIOverlayStyle'),
        isTrue,
        reason: 'the first frame is drawn before the shell builds, so it needs '
            'a style of its own or it flashes the platform default',
      );
    });
  });

  group('the shell publishes the style for its own layout mode', () {
    testWidgets('a phone ends in paper too, so nav glyphs are dark',
        (WidgetTester tester) async {
      final style = await _publishedStyle(
        tester,
        size: const Size(411, 866),
      );
      // The phone used to be the one layout with a stone strip under the page,
      // so this asserted light glyphs. The bar is a paper dock now — light
      // glyphs on paper is exactly the failure this line pins.
      expect(style.systemNavigationBarIconBrightness, Brightness.dark);
      // The paper runs to the top of the glass on a phone, so in the light
      // theme the status glyphs are dark — they used to be light over stone.
      expect(style.statusBarIconBrightness, Brightness.dark);
      expect(style.statusBarColor, Colors.transparent);
    });

    testWidgets('a phone in the dark theme flips the nav glyphs back',
        (WidgetTester tester) async {
      final style = await _publishedStyle(
        tester,
        size: const Size(411, 866),
        dark: true,
      );
      expect(style.systemNavigationBarIconBrightness, Brightness.light);
      // Dark paper under the top edge takes light status glyphs back.
      expect(style.statusBarIconBrightness, Brightness.light);
    });

    testWidgets('a tablet has no tab bar, so the bottom edge is paper',
        (WidgetTester tester) async {
      final style = await _publishedStyle(
        tester,
        size: const Size(800, 1280),
      );
      // Light theme paper under the bottom edge: dark glyphs.
      expect(style.systemNavigationBarIconBrightness, Brightness.dark);
      // The top edge is still stone in every layout.
      expect(style.statusBarIconBrightness, Brightness.light);
    });

    testWidgets('a tablet in the dark theme goes back to light glyphs',
        (WidgetTester tester) async {
      final style = await _publishedStyle(
        tester,
        size: const Size(800, 1280),
        dark: true,
      );
      expect(style.systemNavigationBarIconBrightness, Brightness.light);
    });

    testWidgets('a desktop window is wide but has no tab bar either',
        (WidgetTester tester) async {
      final style = await _publishedStyle(
        tester,
        size: const Size(1280, 800),
      );
      expect(style.systemNavigationBarIconBrightness, Brightness.dark);
      expect(style.statusBarColor, Colors.transparent);
      expect(style.systemNavigationBarColor, Colors.transparent);
    });
  });
}
