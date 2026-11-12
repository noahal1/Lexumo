// Wave 1.2 — the phone tab bar used to cover the last row on a narrowed
// desktop window.
//
// The layout mode (sidebar / rail / phone tab bar) is chosen from window
// *width*, but PageShell's bottom padding used to be chosen from the
// *platform* (`context.isTouch`). On Windows those two disagree: a 620dp
// window draws a phone tab bar (width says "phone") while
// `isTouchPlatform()` says "mouse" and reserves nothing. The last row sat
// under the bar. The fix publishes the shell's decision through
// [ShellChrome], an InheritedWidget, and PageShell reads that instead.
//
// These tests pin three things:
//   · the inset is driven by the InheritedWidget, not by the platform;
//   · the FAB clears the same inset;
//   · a page pumped on its own (no ShellChrome) keeps the old platform rule,
//     so the existing bare-page widget tests are unaffected.

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart' hide Card;
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/ui/core/theme.dart';
import 'package:lexumo/ui/core/tokens.dart';
import 'package:lexumo/ui/core/widgets/widgets.dart';

const Key _bodyKey = Key('page-body');
const Key _fabKey = Key('page-fab');

/// Pumps a bare [PageShell] with [hasBottomBar] (or no ShellChrome at all when
/// null) above it, and an optional measurable FAB.
Future<void> pumpPage(
  WidgetTester tester, {
  bool? hasBottomBar,
  bool withFab = false,
}) async {
  final Widget page = PageShell(
    fab: withFab
        ? const SizedBox(key: _fabKey, width: 56, height: 56)
        : null,
    children: const <Widget>[SizedBox(key: _bodyKey, height: 10)],
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Palette.light),
      home: Scaffold(
        body: hasBottomBar == null
            ? page
            : ShellChrome(hasBottomBar: hasBottomBar, child: page),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The `bottom` of the PageShell body's [EdgeInsetsDirectional] padding.
///
/// Scoping to the sheet's own [SingleChildScrollView] excludes the Scaffold's
/// body padding, which is an *ancestor* of the scroller and uses a resolved
/// [EdgeInsets] (not [EdgeInsetsDirectional]) anyway.
double bodyBottom(WidgetTester tester) {
  final Finder scroller = find
      .descendant(
        of: find.byType(PageShell),
        matching: find.byType(SingleChildScrollView),
      )
      .first;
  final Finder paddings = find.descendant(
    of: scroller,
    matching: find.byType(Padding),
  );
  for (final Element element in paddings.evaluate()) {
    final Padding p = element.widget as Padding;
    if (p.padding is EdgeInsetsDirectional) {
      return (p.padding as EdgeInsetsDirectional).bottom;
    }
  }
  throw StateError('PageShell body padding not found');
}

/// The [Positioned.bottom] of the FAB (its only Positioned ancestor — the
/// Positioned.fill wrapping the body is a sibling, not an ancestor).
double fabBottom(WidgetTester tester) => tester
    .widget<Positioned>(
      find
          .ancestor(of: find.byKey(_fabKey), matching: find.byType(Positioned))
          .first,
    )
    .bottom!;

void main() {
  // Base tail padding with no FAB: Sp.x6. The published inset: 76.
  const double base = Sp.x6;
  const double inset = Layout.tap + Sp.x8;
  // The FAB's resting offset above whatever inset applies.
  const double fabRest = Layout.fabInset + Sp.x2;

  group('ShellChrome', () {
    testWidgets('publishes the width-driven inset to PageShell', (
      tester,
    ) async {
      await pumpPage(tester, hasBottomBar: true);
      expect(bodyBottom(tester), base + inset);
    });

    testWidgets('no bar reserves nothing', (tester) async {
      await pumpPage(tester, hasBottomBar: false);
      expect(bodyBottom(tester), base);
    });

    testWidgets('the FAB clears the width-driven inset', (tester) async {
      await pumpPage(tester, hasBottomBar: true, withFab: true);
      expect(fabBottom(tester), fabRest + inset);
    });

    testWidgets('with no bar the FAB keeps its resting offset', (tester) async {
      await pumpPage(tester, hasBottomBar: false, withFab: true);
      expect(fabBottom(tester), fabRest);
    });

    testWidgets('a bare page keeps the old platform rule', (tester) async {
      // flutter_test reports android, so the pre-fix fallback is Layout.tap.
      // This is the behaviour every bare PageShell test was written against.
      await pumpPage(tester);
      expect(bodyBottom(tester), base + Layout.tap);
    });

    testWidgets('on a non-touch platform the bar still gets its inset', (
      tester,
    ) async {
      // This is the actual bug: isTouch is false here, so the old code
      // reserved nothing even though the shell draws a width-driven bar.
      // The override must be cleared inside the test body (try/finally):
      // addTearDown runs after the binding's debugAssertAllFoundationVarsUnset
      // check and would fail the test with "a foundation debug variable was
      // changed".
      final TargetPlatform? previous = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await pumpPage(tester, hasBottomBar: true);
        expect(
          bodyBottom(tester),
          base + inset,
          reason: 'the inset must not depend on the OS',
        );
      } finally {
        debugDefaultTargetPlatformOverride = previous;
      }
    });
  });
}
