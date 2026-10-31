// Touch density: which platform grows the controls, and whether the grown
// target actually receives taps.
//
// The rule being pinned is that density follows the *pointer*, not the window
// width — a narrowed desktop window is still a mouse, a landscape tablet is
// still a fingertip. That is the same reasoning `keyboard_hints.dart` uses, and
// it is easy to regress back to a width query because width is right there.
//
// The second group exists because the first version of the fix was wrong in a
// way no geometry assertion would have caught: `TapTarget` padded the child out
// to 44dp but sat *outside* the `GestureDetector`, so the drawn box grew while
// the tappable box did not. Measuring the render box would have passed. Tapping
// near the edge is what fails, so that is what is asserted — a tap 19dp from the
// centre, which is outside the 32dp icon but inside the 44dp target.

import 'package:flutter/material.dart' hide Card;
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/design/tokens.dart';
import 'package:lexumo/ui/density.dart';

void main() {
  group('isTouchPlatform', () {
    test('phones and tablets are touch, desktops are not', () {
      expect(isTouchPlatform(platform: TargetPlatform.android), isTrue);
      expect(isTouchPlatform(platform: TargetPlatform.iOS), isTrue);
      expect(isTouchPlatform(platform: TargetPlatform.fuchsia), isTrue);
      expect(isTouchPlatform(platform: TargetPlatform.windows), isFalse);
      expect(isTouchPlatform(platform: TargetPlatform.macOS), isFalse);
      expect(isTouchPlatform(platform: TargetPlatform.linux), isFalse);
    });
  });

  group('Density', () {
    /// Pumps a probe so a [BuildContext] exists, and reports the numbers that
    /// context resolves to.
    Future<({double controlH, double controlHSm, double iconTarget})> probe(
      WidgetTester tester,
    ) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox();
            },
          ),
        ),
      );
      return (
        controlH: ctx.controlH,
        controlHSm: ctx.controlHSm,
        iconTarget: ctx.iconTarget,
      );
    }

    testWidgets('the host platform decides, and flutter_test is android', (
      WidgetTester tester,
    ) async {
      // `flutter test` reports android, so this exercises the touch branch. The
      // desktop numbers are pinned separately by the pure `isTouchPlatform`
      // test above rather than by overriding the platform here, because
      // `debugDefaultTargetPlatformOverride` is process-wide and leaks into the
      // tests that follow.
      final d = await probe(tester);
      expect(d.controlH, Layout.tap);
      expect(d.controlHSm, Layout.tap);
      expect(d.iconTarget, Layout.tap);
    });

    testWidgets('a target is never smaller than the design size', (
      WidgetTester tester,
    ) async {
      final d = await probe(tester);
      // Whatever the platform, the touch floor can only ever be an increase: a
      // mouse-sized control must not shrink to fit a rule meant for fingers,
      // and a finger-sized one must not fall back to 32.
      expect(d.iconTarget, greaterThanOrEqualTo(Layout.controlHSm));
      expect(d.controlH, greaterThanOrEqualTo(Layout.controlH));
    });
  });

  group('TapTarget', () {
    /// A 32dp icon button wrapped exactly the way `_RowAction` wraps it.
    Future<List<Offset>> pumpIconButton(
      WidgetTester tester, {
      required void Function() onTap,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: GestureDetector(
                onTap: onTap,
                behavior: HitTestBehavior.opaque,
                child: TapTarget(
                  child: Container(
                    width: Layout.controlHSm,
                    height: Layout.controlHSm,
                    color: const Color(0xFF000000),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final centre = tester.getCenter(find.byType(Container).first);
      return [centre, tester.getRect(find.byType(GestureDetector).first).topLeft];
    }

    testWidgets('the drawn box stays 32dp inside a 44dp target', (
      WidgetTester tester,
    ) async {
      await pumpIconButton(tester, onTap: () {});
      final drawn = tester.getSize(find.byType(Container).first);
      final target = tester.getSize(find.byType(GestureDetector).first);
      expect(drawn.width, Layout.controlHSm, reason: 'the shape keeps its design size');
      expect(target.width, Layout.tap, reason: 'the target grows to the touch floor');
    });

    testWidgets('a tap near the edge of the ring still lands', (
      WidgetTester tester,
    ) async {
      var taps = 0;
      final geometry = await pumpIconButton(tester, onTap: () => taps++);
      final centre = geometry.first;

      // 19dp out: past the 16dp half of the drawn icon, inside the 22dp half of
      // the target. This is the assertion the first, broken version failed.
      await tester.tapAt(centre + const Offset(19, 0));
      await tester.pump();
      expect(taps, 1, reason: 'the ring around the icon must be tappable');
    });

    testWidgets('a tap outside the target misses', (WidgetTester tester) async {
      var taps = 0;
      final geometry = await pumpIconButton(tester, onTap: () => taps++);
      final centre = geometry.first;

      await tester.tapAt(centre + const Offset(30, 0));
      await tester.pump();
      expect(taps, 0, reason: 'the target must stop at 44dp, not eat the row');
    });
  });
}
