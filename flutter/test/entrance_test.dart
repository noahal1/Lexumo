/// The entrance primitive, and the two places it is wired in.
///
/// [FadeRise] is deliberately the *only* entrance animation in the app: the web
/// build had six keyframes (`fade-in`, `pop-in`, `rise`, `row-in`, `tile-in`,
/// `bar-rise`) that differed only in how far the content travelled. Collapsing
/// them into one widget means the answer to "does this thing animate in?" is a
/// single grep, and it means the three constraints that keep the animation from
/// breaking layout are enforced in one place instead of six.
///
/// The animation lives in a render object ([RenderFadeRise]) rather than in
/// `Opacity`/`Transform` widgets, so the widget tree has the same shape at every
/// frame. These tests read the render object's [RenderFadeRise.progress]
/// directly; there is no longer an `Opacity` widget to count, and that absence
/// is the point (see 'keeps its subtree mounted').
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

/// The render object that paints [FadeRise]'s child — the innermost one, since
/// a page nests an entrance inside an entrance.
RenderFadeRise _render(WidgetTester tester) => tester.renderObject<RenderFadeRise>(
      find
          .ancestor(
            of: find.text('content'),
            matching: find.byType(FadeRiseBody),
          )
          .first,
    );

/// How opaque the child currently is, `0`..`1`.
double _progress(WidgetTester tester) => _render(tester).progress;

/// How far below its final position the content is currently painted, in
/// logical pixels. This is the distance a finger would actually see — it is
/// applied at paint time, so it never shows up in `getTopLeft`.
double _paintedOffset(WidgetTester tester) => _render(tester).paintedOffset;

/// A child that counts its builds, so a test can prove the animation does not
/// rebuild the subtree.
class _Counting extends StatefulWidget {
  const _Counting({required this.onBuild});

  final VoidCallback onBuild;

  @override
  State<_Counting> createState() => _CountingState();
}

class _CountingState extends State<_Counting> {
  @override
  Widget build(BuildContext context) {
    widget.onBuild();
    return const Text('content');
  }
}

void main() {
  group('FadeRise', () {
    testWidgets('starts transparent and settles fully opaque', (WidgetTester tester) async {
      await _pump(
        tester,
        const FadeRise(duration: Duration(milliseconds: 200), child: Text('content')),
      );
      await tester.pump();

      expect(_progress(tester), 0);
      // Nothing is painted at progress 0 — the child is skipped entirely rather
      // than composited at zero alpha.
      expect(_render(tester).paintsChild(_render(tester).child!), isFalse);

      await tester.pumpAndSettle();

      // Settled means fully opaque and painted directly, not "an Opacity of 1":
      // asserting `paintsChild` alongside the progress catches a wrapper that
      // never finishes fading in.
      expect(_progress(tester), 1);
      expect(_render(tester).paintsChild(_render(tester).child!), isTrue);
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

      final double start = _paintedOffset(tester);
      await tester.pump(const Duration(milliseconds: 100));
      final double middle = _paintedOffset(tester);
      await tester.pumpAndSettle();
      final double end = _paintedOffset(tester);

      expect(start, closeTo(12, 0.5));
      expect(end, closeTo(0, 0.5));
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

      // The page body uses offset 0: a transform there would become the
      // containing block for anything positioned inside the page.
      expect(_paintedOffset(tester), 0);
      await tester.pumpAndSettle();
      expect(_paintedOffset(tester), 0);
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
      expect(_progress(tester), 1);
      await tester.pumpAndSettle();
      expect(_progress(tester), 1);
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

      expect(_progress(tester), 1);
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
      expect(_progress(tester), 0);

      await tester.pump(const Duration(milliseconds: 100));
      // Halfway through the delay: still untouched, because the curve is an
      // interval that has not begun.
      expect(_progress(tester), 0);

      await tester.pump(const Duration(milliseconds: 150));
      final double midway = _progress(tester);
      expect(midway, greaterThan(0));
      expect(midway, lessThan(1));

      await tester.pumpAndSettle();
      expect(_progress(tester), 1);
    });

    testWidgets('does not rebuild its child while it animates', (WidgetTester tester) async {
      var builds = 0;
      await _pump(
        tester,
        FadeRise(
          duration: const Duration(milliseconds: 200),
          child: _Counting(onBuild: () => builds++),
        ),
      );
      await tester.pump();

      final int atMount = builds;
      expect(atMount, 1);

      // The progress lives in the render object, so the frames of the animation
      // must not reach the child — otherwise every animated page would rebuild
      // its whole content tree sixty times a second.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 25));
        expect(builds, atMount);
      }

      await tester.pumpAndSettle();

      // Still exactly one build: there is no structural swap at the end of the
      // entrance any more, so settling does not remount the subtree.
      expect(builds, atMount);
    });

    testWidgets('keeps its subtree mounted once the entrance ends',
        (WidgetTester tester) async {
      // The regression this pins: the entrance used to wrap its child in
      // `Opacity`/`Transform` and drop the wrapper at `t >= 1`. Changing the
      // tree's shape made Flutter discard the whole subtree below, so every
      // nested [FadeRise] restarted from zero and every row's `_hover` state was
      // lost mid-fade — reported as "进首页、词库、统计页动画会跳动一下" and as rows
      // flickering under the pointer.
      await _pump(
        tester,
        const FadeRise(
          offset: 8,
          duration: Duration(milliseconds: 200),
          child: _Counting(onBuild: _noop),
        ),
      );
      await tester.pump();

      final Element before = tester.element(find.byType(_Counting));
      expect(_progress(tester), 0);

      await tester.pumpAndSettle();

      final Element after = tester.element(find.byType(_Counting));
      expect(identical(before, after), isTrue,
          reason: 'settling the entrance must not remount the subtree');
      expect(_progress(tester), 1);
    });

    testWidgets('an inner entrance is not restarted by an outer one finishing',
        (WidgetTester tester) async {
      // Two nested entrances, as on a page: the shell fades in at offset 0 and
      // each block staggers inside it. The inner one must reach 1 exactly once
      // and stay there.
      await _pump(
        tester,
        const FadeRise(
          offset: 0,
          duration: Duration(milliseconds: 120),
          child: FadeRise(
            offset: 8,
            duration: Duration(milliseconds: 120),
            delay: Duration(milliseconds: 32),
            child: Text('content'),
          ),
        ),
      );

      final List<Element> bodies = find.byType(FadeRiseBody).evaluate().toList();
      final List<int> ids = bodies.map((Element e) => e.hashCode).toList();

      final List<double> track = <double>[];
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        track.add(_progress(tester));
        expect(
          find.byType(FadeRiseBody).evaluate().map((Element e) => e.hashCode).toList(),
          ids,
          reason: 'no entrance element may be replaced mid-animation',
        );
      }

      await tester.pumpAndSettle();
      expect(_progress(tester), 1);
      // Monotonic: a restart would show up as a drop back toward 0.
      for (var i = 1; i < track.length; i++) {
        expect(track[i], greaterThanOrEqualTo(track[i - 1]));
      }
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

void _noop() {}
