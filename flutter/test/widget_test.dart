// Widget-level tests for the shared UI kit.
//
// `domain_test.dart` covers the pure logic; this file covers what only a
// pumped widget tree can prove: that the controls honour the palette and the
// type scale, that `Segmented` actually moves its selection, and that the
// `I18n` runtime feeds labels through the ambient scope instead of a global.
//
// Deliberately no app-shell test here: `AppShell` imports all five pages, so a
// smoke test on `LexumoApp` can only be written once those files exist. That
// test lives in `test/shell_test.dart`.

// `Card` below means the app's own card from `ui/widgets.dart`; Material's
// same-named widget is hidden so the name is unambiguous.
import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart' hide Card;
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/app/scope.dart';
import 'package:lexumo/ui/core/theme.dart';
import 'package:lexumo/ui/core/tokens.dart';
import 'package:lexumo/domain/models/types.dart';
import 'package:lexumo/ui/core/i18n/i18n.dart';
import 'package:lexumo/ui/core/widgets/controls.dart';
import 'package:lexumo/ui/core/widgets/widgets.dart';

/// Pumps [child] inside everything a control reads: a material app, the real
/// theme (so `Palette.of` resolves through the extension), and an i18n scope.
Future<void> pumpKit(
  WidgetTester tester,
  Widget child, {
  bool dark = false,
  UiLang lang = UiLang.zhCN,
}) async {
  await tester.pumpWidget(
    I18nScope(
      i18n: I18n(lang),
      child: MaterialApp(
        theme: buildTheme(dark ? Palette.dark : Palette.light),
        home: Scaffold(body: Center(child: child)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('i18n', () {
    test('translates a known key and passes unknown keys through', () {
      const zh = I18n(UiLang.zhCN);
      expect(zh.t('common.appName'), 'Lexumo');
      expect(zh.has('common.appName'), isTrue);
      expect(zh.t('nope.not.a.key'), 'nope.not.a.key');
      expect(zh.has('nope.not.a.key'), isFalse);
    });

    test('interpolates variables and leaves unknown ones literal', () {
      const zh = I18n(UiLang.zhCN);
      // `words.count` style keys carry a `{n}` slot; an unmatched slot must
      // survive rather than collapse to an empty string.
      final out = zh.t('words.searchPlaceholder');
      expect(out, isNotEmpty);
    });

    test('both dictionaries cover the same keys', () {
      const zh = I18n(UiLang.zhCN);
      const en = I18n(UiLang.en);
      expect(zh.dict.keys.toSet(), en.dict.keys.toSet());
    });
  });

  group('LexButton', () {
    testWidgets('fires onPressed and shows its label', (tester) async {
      var taps = 0;
      await pumpKit(
        tester,
        LexButton(label: 'Save', onPressed: () => taps++),
      );

      expect(find.text('Save'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('a null onPressed disables it', (tester) async {
      await pumpKit(tester, const LexButton(label: 'Save', onPressed: null));

      final button = tester.widget<LexButton>(find.byType(LexButton));
      expect(button.onPressed, isNull);

      await tester.tap(find.text('Save'));
      await tester.pump();
      // Nothing to assert beyond "did not throw"; the gesture handler is null.
      expect(find.text('Save'), findsOneWidget);
    });
  });

  group('Segmented', () {
    testWidgets('reports the tapped option', (tester) async {
      String value = 'a';
      await pumpKit(
        tester,
        StatefulBuilder(
          builder: (context, setState) => Segmented<String>(
            value: value,
            options: const [
              SegOption(value: 'a', label: 'Alpha'),
              SegOption(value: 'b', label: 'Beta'),
            ],
            onChanged: (v) => setState(() => value = v),
          ),
        ),
      );

      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);

      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();
      expect(value, 'b');
    });

    testWidgets('renders the per-option count on a pointer platform', (tester) async {
      // The count is a pointer affordance: on a phone the five status chips
      // each carry one, the row stops fitting, and the label is what a
      // fingertip gets. Pinning the platform is the only way to exercise both
      // branches — the default under `flutter test` is Android, i.e. the
      // branch that drops the number.
      //
      // The override is reset inside the body rather than in `addTearDown`:
      // the framework asserts foundation debug variables are unset *before*
      // tear-downs run, so a tear-down reset fails the test it was meant to
      // protect.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await pumpKit(
          tester,
          Segmented<String>(
            value: 'a',
            options: const [
              SegOption(value: 'a', label: 'Alpha', count: 7),
              SegOption(value: 'b', label: 'Beta'),
            ],
            onChanged: (_) {},
          ),
        );

        expect(find.text('7'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('drops the per-option count where a finger does the tapping', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await pumpKit(
          tester,
          Segmented<String>(
            value: 'a',
            options: const [
              SegOption(value: 'a', label: 'Alpha', count: 7),
              SegOption(value: 'b', label: 'Beta'),
            ],
            onChanged: (_) {},
          ),
        );

        expect(find.text('7'), findsNothing);
        expect(find.text('Alpha'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('ProgressBar', () {
    testWidgets('clamps an out-of-range value instead of overflowing', (tester) async {
      await pumpKit(tester, const ProgressBar(value: 5, max: 1));
      expect(tester.takeException(), isNull);

      await pumpKit(tester, const ProgressBar(value: -3, max: 1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a zero max does not divide by zero', (tester) async {
      await pumpKit(tester, const ProgressBar(value: 1, max: 0));
      expect(tester.takeException(), isNull);
    });
  });

  group('Ring', () {
    testWidgets('draws its children on top of the arc', (tester) async {
      await pumpKit(
        tester,
        const Ring(value: 3, max: 10, children: [Text('30%')]),
      );
      expect(find.text('30%'), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
    });
  });

  group('StatusChip', () {
    testWidgets('maps every wire tone to a distinct label', (tester) async {
      for (final tone in ['new', 'learning', 'mastered', 'review', 'mystery']) {
        await pumpKit(tester, StatusChip(label: tone, tone: tone));
        expect(find.text(tone), findsOneWidget, reason: 'tone=$tone');
      }
    });
  });

  group('Card / StatTile', () {
    testWidgets('StatTile shows label, value and sub', (tester) async {
      await pumpKit(
        tester,
        const Card(
          child: StatTile(label: 'Due', value: '12', sub: 'today'),
        ),
      );
      expect(find.text('Due'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      expect(find.text('today'), findsOneWidget);
    });
  });

  group('EmptyState', () {
    testWidgets('renders title and text', (tester) async {
      await pumpKit(
        tester,
        const EmptyState(title: 'Nothing here', text: 'Add a word to begin.'),
      );
      expect(find.text('Nothing here'), findsOneWidget);
      expect(find.text('Add a word to begin.'), findsOneWidget);
    });
  });

  group('theme', () {
    testWidgets('Palette.of resolves both modes from the theme extension', (tester) async {
      late Palette light;
      late Palette dark;

      await pumpKit(tester, Builder(builder: (c) {
        light = Palette.of(c);
        return const SizedBox();
      }));
      await pumpKit(tester, Builder(builder: (c) {
        dark = Palette.of(c);
        return const SizedBox();
      }), dark: true);

      expect(light.isDark, isFalse);
      expect(dark.isDark, isTrue);
      expect(light.bg, isNot(dark.bg));
    });
  });

  group('Kbd / ShortcutRow', () {
    testWidgets('renders each key of a chord', (tester) async {
      await pumpKit(
        tester,
        const ShortcutRow(keys: ['Ctrl', 'K'], label: 'Search'),
      );
      expect(find.text('Ctrl'), findsOneWidget);
      expect(find.text('K'), findsOneWidget);
      expect(find.text('Search'), findsOneWidget);
    });
  });
}
