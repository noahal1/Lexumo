/// The entrance primitive, and the two places it is wired in.
///
/// [FadeRise] is deliberately the *only* entrance animation in the app: the web
/// build had six keyframes (`fade-in`, `pop-in`, `rise`, `row-in`, `tile-in`,
/// `bar-rise`) that differed only in how far the content travelled. Collapsing
/// them into one widget means the answer to "does this thing animate in?" is a
/// single grep, and it means the three constraints that keep the animation from
/// breaking layout are enforced in one place instead of six.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lexumo/ui/core/tokens.dart';
import 'package:lexumo/ui/core/widgets/entrance.dart';

/// Pumps [child] inside a [MediaQuery] whose motion preference the test controls.
Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  bool reduceMotion = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(body: Center(child: child)),
      ),
    ),
  );
}

/// The opacity [FadeRise] is currently painting at, or `null` when it is passing
/// its child through untouched.
double? _opacity(WidgetTester tester) {
  final Finder wrapper = find.ancestor(
    of: find.text('content'),
    matching: find.byType(Opacity),
  );
  if (wrapper.evaluate().isEmpty) return null;
  return tester.widget<Opacity>(wrapper.first).opacity;
}

/// How far below its final position the content currently sits, in logical
/// pixels. Read off the render object rather than the [Transform], so this is
/// the distance a finger would actually see.
double _travel(WidgetTester tester) => tester.getTopLeft(find.text('content')).dy;

void main() {
  group('FadeRise', () {
    testWidgets('starts transparent and settles fully opaque', (WidgetTester tester) async {
      await _pump(
        tester,
        const FadeRise(duration: Duration(milliseconds: 200), child: Text('content')),
      );
      await tester.pump();

      expect(_opacity(tester), 0);

      await tester.pumpAndSettle();

      // Settled means unwrapped, not "an Opacity of 1": asserting `== 1` would
      // also pass on a card that never finishes fading in.
      expect(_opacity(tester), isNull);
    });

    testWidgets('travels up into place and never overshoots', (WidgetTester tester) async {
      await _pump(
        tester,
        const FadeRise(
          offset: 12,
          duration: Duration(milliseconds: 200),
          child: Text('content'),
        ),
      );
      await tester.pump();

      final double start = _travel(tester);
      await tester.pump(const Duration(milliseconds: 100));
      final double middle = _travel(tester);
      await tester.pumpAndSettle();
      final double end = _travel(tester);

      expect(start - end, closeTo(12, 0.5));
      expect(middle, lessThan(start));
      expect(middle, greaterThanOrEqualTo(end));
      // Decelerating, so more than half the distance is covered in the first
      // half of the time — that is what `Motion.easeOut` buys.
      expect(start - middle, greaterThan((start - end) / 2));
    });

    testWidgets('moves nothing when offset is zero', (WidgetTester tester) async {
      await _pump(
        tester,
        const FadeRise(offset: 0, duration: Duration(milliseconds: 200), child: Text('content')),
      );
      await tester.pump();

      final double start = _travel(tester);
      await tester.pumpAndSettle();

      // The page body uses offset 0: a transform there would become the
      // containing block for anything positioned inside the page.
      expect(_travel(tester), start);
    });

    testWidgets('honours reduce motion by starting settled', (WidgetTester tester) async {
      await _pump(
        tester,
        const FadeRise(duration: Duration(milliseconds: 400), child: Text('content')),
        reduceMotion: true,
      );
      await tester.pump();

      // One frame in, already done: no entrance to sit through, and no timers
      // left behind either.
      expect(_opacity(tester), isNull);
      await tester.pumpAndSettle();
    });

    testWidgets('a delayed block uses no timer, so settle terminates', (WidgetTester tester) async {
      await _pump(
        tester,
        const FadeRise(
          duration: Duration(milliseconds: 120),
          delay: Duration(milliseconds: 320),
          child: Text('content'),
        ),
      );

      // The delay is an `Interval` inside one controller, not a `Timer`. A
      // timer would leave `pumpAndSettle` returning early and then trip the
      // pending-timer check at teardown; this finishes because the animation
      // itself accounts for the delay.
      await tester.pumpAndSettle();

      expect(_opacity(tester), isNull);
      expect(_travel(tester), isNotNull);
    });

    testWidgets('a delayed block stays put until its delay is over', (WidgetTester tester) async {
      await _pump(
        tester,
        const FadeRise(
          duration: Duration(milliseconds: 100),
          delay: Duration(milliseconds: 200),
          child: Text('content'),
        ),
      );
      await tester.pump();
      expect(_opacity(tester), 0);

      await tester.pump(const Duration(milliseconds: 100));
      // Halfway through the delay: still untouched, because the curve is an
      // interval that has not begun.
      expect(_opacity(tester), 0);

      await tester.pump(const Duration(milliseconds: 150));
      final double? midway = _opacity(tester);
      expect(midway, isNotNull);
      expect(midway, greaterThan(0));

      await tester.pumpAndSettle();
      expect(_opacity(tester), isNull);
    });

    testWidgets('does not rebuild its child while it animates', (WidgetTester tester) async {
      var builds = 0;
      await _pump(
        tester,
        FadeRise(
          duration: const Duration(milliseconds: 200),
          child: Builder(
            builder: (BuildContext context) {
              builds++;
              return const Text('content');
            },
          ),
        ),
      );
      await tester.pump();

      final int atMount = builds;
      expect(atMount, 1);

      // The subtree is a `child:` argument to [AnimatedBuilder], so the frames
      // of the animation must not reach it — otherwise every animated page
      // would rebuild its whole content tree sixty times a second.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 25));
        expect(builds, atMount);
      }

      await tester.pumpAndSettle();

      // Exactly one more build, and it is not a leak: once the entrance is over
      // the wrapper is dropped so a settled page carries no per-row [Opacity]
      // and [Transform] forever. That structural swap remounts the subtree once.
      expect(builds, atMount + 1);
    });
  });

  group('the stagger constants', () {
    test('the row and block caps are the web build’s', () {
      // Both are documented against the web source; pinning them here means a
      // future "let's make the stagger longer" edit has to be deliberate.
      expect(Motion.stagger, const Duration(milliseconds: 16));
      expect(Motion.dur3, const Duration(milliseconds: 260));
    });
  });
}
