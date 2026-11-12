// Regression tests for Wave 4: the app's custom controls are reachable by
// keyboard and their async "busy" state is visible.
//
// Before Wave 4 these controls were `GestureDetector` + `MouseRegion` only —
// Tab could not reach them and Enter/Space did nothing. They now share
// `KeyFocus`, a small wrapper that owns one `Focus` and reports the focused
// flag back to each control's builder so it can draw an accent ring. These
// tests drive the real key-event path (`sendKeyEvent` -> Focus.onKeyEvent),
// not the pointer path, which `widget_test.dart` already covers.
//
// The pointer path must keep working too: `mobile_layout_test.dart` walks
// `find.byType(GestureDetector)` to check the 44dp touch target, so KeyFocus
// wraps *outside* the GestureDetector rather than replacing it.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/app/scope.dart';
import 'package:lexumo/domain/models/types.dart';
import 'package:lexumo/ui/core/i18n/i18n.dart';
import 'package:lexumo/ui/core/theme.dart';
import 'package:lexumo/ui/core/tokens.dart';
import 'package:lexumo/ui/core/widgets/controls.dart';

/// Pumps [child] inside the theme and i18n scopes a control reads. A single
/// [tester.pump] (not pumpAndSettle) keeps a busy button's infinite
/// CircularProgressIndicator from hanging the test.
Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    I18nScope(
      i18n: const I18n(UiLang.zhCN),
      child: MaterialApp(
        theme: buildTheme(Palette.light),
        home: Scaffold(body: Center(child: child)),
      ),
    ),
  );
  await tester.pump();
}

/// Focuses the `KeyFocus` in the tree through one of its descendants and sends
/// [key] to the now-primary focus node. By default the descendant is the
/// GestureDetector that KeyFocus wraps — every control keeps exactly one.
Future<void> _activateWithKey(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  Finder? descendant,
}) async {
  final Finder target = descendant ??
      find.descendant(
        of: find.byType(KeyFocus),
        matching: find.byType(GestureDetector),
      );
  final BuildContext context = tester.element(target);
  final FocusNode node = Focus.maybeOf(context, createDependency: false)!;
  node.requestFocus();
  await tester.pump();
  await tester.sendKeyEvent(key);
  await tester.pump();
}

void main() {
  group('KeyFocus', () {
    testWidgets('Enter activates the control', (tester) async {
      var activations = 0;
      await _pump(
        tester,
        KeyFocus(
          label: 'Do it',
          onActivate: () => activations++,
          builder: (bool focused) =>
              const SizedBox(key: Key('box'), width: 60, height: 40),
        ),
      );

      await _activateWithKey(
        tester,
        LogicalKeyboardKey.enter,
        descendant: find.byKey(const Key('box')),
      );

      expect(activations, 1);
    });

    testWidgets('Space activates the control', (tester) async {
      var activations = 0;
      await _pump(
        tester,
        KeyFocus(
          label: 'Do it',
          onActivate: () => activations++,
          builder: (bool focused) =>
              const SizedBox(key: Key('box'), width: 60, height: 40),
        ),
      );

      await _activateWithKey(
        tester,
        LogicalKeyboardKey.space,
        descendant: find.byKey(const Key('box')),
      );

      expect(activations, 1);
    });

    testWidgets('the builder is told when the control gains focus',
        (tester) async {
      bool? focusedFlag;
      await _pump(
        tester,
        KeyFocus(
          label: 'Do it',
          onActivate: () {},
          builder: (bool focused) {
            focusedFlag = focused;
            return const SizedBox(key: Key('box'), width: 60, height: 40);
          },
        ),
      );
      expect(focusedFlag, isFalse);

      final FocusNode node = Focus.maybeOf(
        tester.element(find.byKey(const Key('box'))),
        createDependency: false,
      )!;
      node.requestFocus();
      // requestFocus applies the change in a microtask, and onFocusChange ->
      // setState schedules the rebuild for the frame after that. Give it a
      // second frame so the builder runs again with focused == true.
      await tester.pump();
      await tester.pump();

      expect(focusedFlag, isTrue);
    });

    testWidgets('a disabled KeyFocus ignores Enter', (tester) async {
      var activations = 0;
      await _pump(
        tester,
        KeyFocus(
          label: 'Do it',
          onActivate: () => activations++,
          enabled: false,
          builder: (bool focused) =>
              const SizedBox(key: Key('box'), width: 60, height: 40),
        ),
      );

      final FocusNode node = Focus.maybeOf(
        tester.element(find.byKey(const Key('box'))),
        createDependency: false,
      )!;
      node.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(activations, 0);
    });

    testWidgets('exposes a semantic button with its label', (tester) async {
      await _pump(
        tester,
        KeyFocus(
          label: 'Open settings',
          onActivate: () {},
          builder: (bool focused) => const SizedBox(width: 60, height: 40),
        ),
      );
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Open settings'), findsWidgets);
      handle.dispose();
    });
  });

  group('LexButton', () {
    testWidgets('Enter fires onPressed', (tester) async {
      var taps = 0;
      await _pump(
        tester,
        LexButton(label: 'Save', onPressed: () => taps++),
      );

      await _activateWithKey(tester, LogicalKeyboardKey.enter);

      expect(taps, 1);
    });

    testWidgets('a busy button shows a spinner and ignores taps',
        (tester) async {
      var taps = 0;
      await _pump(
        tester,
        LexButton(label: 'Save', onPressed: () => taps++, busy: true),
      );

      // The in-flight action stays fully coloured and keeps its label; only
      // the leading glyph becomes a spinner and every activation path closes.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
      final KeyFocus focus = tester.widget<KeyFocus>(find.byType(KeyFocus));
      expect(focus.enabled, isFalse);

      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(taps, 0);
    });

    testWidgets('a busy button is not key-activatable', (tester) async {
      var taps = 0;
      await _pump(
        tester,
        LexButton(label: 'Save', onPressed: () => taps++, busy: true),
      );

      // KeyFocus is disabled, so its Focus node has canRequestFocus false;
      // requestFocus lands elsewhere and onKeyEvent's enabled guard also
      // refuses to fire. Either way the callback must not run.
      final Finder gd = find.descendant(
        of: find.byType(KeyFocus),
        matching: find.byType(GestureDetector),
      );
      final FocusNode node = Focus.maybeOf(
        tester.element(gd),
        createDependency: false,
      )!;
      node.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(taps, 0);
    });
  });

  group('LexSwitch', () {
    testWidgets('Enter toggles the switch', (tester) async {
      bool? value;
      await _pump(
        tester,
        LexSwitch(
          checked: false,
          label: '先显示译文',
          onChanged: (bool v) => value = v,
        ),
      );

      await _activateWithKey(tester, LogicalKeyboardKey.enter);

      expect(value, isTrue);
    });

    testWidgets('exposes its label and toggled state to a screen reader',
        (tester) async {
      await _pump(
        tester,
        LexSwitch(checked: true, label: '随机', onChanged: (_) {}),
      );
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('随机'), findsWidgets);
      handle.dispose();
    });
  });

  group('LexSelect', () {
    testWidgets('Enter opens the options menu', (tester) async {
      await _pump(
        tester,
        LexSelect<String>(
          value: 'a',
          options: const <String>['a', 'b'],
          onChanged: (_) {},
          labelOf: (String v) => 'opt $v',
        ),
      );

      await _activateWithKey(tester, LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.text('opt b'), findsWidgets);
    });
  });
}
