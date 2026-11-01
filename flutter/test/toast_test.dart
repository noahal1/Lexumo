/// The toast stack, exercised through the real [ToastHost].
///
/// Every other test in the suite stubs `ToastScope` with a recording closure and
/// asserts on the calls, which is the right way to test a view model — but it
/// means nothing ever pumped the actual host. That gap hid a real defect: the
/// whole stack was wrapped in an `IgnorePointer` "so taps fall through to the
/// page", which also made the 撤销 action untappable. The card is the one part of
/// the overlay that must take input.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lexumo/ui/core/theme.dart';
import 'package:lexumo/ui/core/tokens.dart';
import 'package:lexumo/ui/core/view_model.dart' show ToastKind;
import 'package:lexumo/ui/core/widgets/toast.dart';

/// Pumps a page with a real [ToastHost] and returns its state so a test can
/// push messages the way the app does.
Future<ToastHostState> _pump(
  WidgetTester tester, {
  Size size = const Size(411, 866),
  bool reduceMotion = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final GlobalKey<ToastHostState> key = GlobalKey<ToastHostState>();
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: size, disableAnimations: reduceMotion),
      child: MaterialApp(
        theme: buildTheme(Palette.light),
        home: ToastHost(
          key: key,
          child: const Scaffold(body: SizedBox.expand()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return key.currentState!;
}

/// The opacity the toast card is currently drawn at, or `null` when it is drawn
/// unwrapped — which is what "fully opaque, nothing in flight" looks like, since
/// [_ToastCardState] returns its child as-is once the entrance is over.
double? _cardOpacity(WidgetTester tester) {
  final Finder wrapper = find.ancestor(
    of: find.text('已同步'),
    matching: find.byType(Opacity),
  );
  if (wrapper.evaluate().isEmpty) return null;
  return tester.widget<Opacity>(wrapper.first).opacity;
}

void main() {
  group('the toast card takes input', () {
    testWidgets('the action button can be tapped', (WidgetTester tester) async {
      final ToastHostState host = await _pump(tester);
      var undone = 0;

      host.show(
        '已删除 1 个词',
        ToastKind.ok,
        actionLabel: '撤销',
        onAction: () => undone++,
      );
      await tester.pumpAndSettle();

      expect(find.text('撤销'), findsOneWidget);
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();

      // The bug this covers: with the stack inside an `IgnorePointer` the tap
      // never reached the button, so this stayed 0 while the toast vanished as
      // if it had worked.
      expect(undone, 1);
      expect(find.text('已删除 1 个词'), findsNothing);
    });

    testWidgets('a toast with no action closes when tapped', (WidgetTester tester) async {
      final ToastHostState host = await _pump(tester);

      host.show('已同步', ToastKind.info);
      await tester.pumpAndSettle();
      expect(find.text('已同步'), findsOneWidget);

      await tester.tap(find.text('已同步'));
      await tester.pumpAndSettle();
      expect(find.text('已同步'), findsNothing);
    });

    testWidgets('a toast with an action stays open when its body is tapped', (
      WidgetTester tester,
    ) async {
      final ToastHostState host = await _pump(tester);

      host.show('已删除', ToastKind.ok, actionLabel: '撤销', onAction: () {});
      await tester.pumpAndSettle();

      await tester.tap(find.text('已删除'));
      await tester.pumpAndSettle();
      // Tapping the message means "read it", not "dismiss it", when there is
      // something to act on — otherwise the action would be easy to lose.
      expect(find.text('已删除'), findsOneWidget);
    });

    testWidgets('the close button closes it', (WidgetTester tester) async {
      final ToastHostState host = await _pump(tester);

      host.show('已同步', ToastKind.info);
      await tester.pumpAndSettle();

      // The close glyph is the last tappable box inside the card.
      await tester.tap(find.byType(GestureDetector).last);
      await tester.pumpAndSettle();
      expect(find.text('已同步'), findsNothing);
    });
  });

  group('the toast enters and leaves', () {
    testWidgets('it is transparent on the first frame and opaque once settled', (
      WidgetTester tester,
    ) async {
      final ToastHostState host = await _pump(tester);

      host.show('已同步', ToastKind.info);
      await tester.pump();

      // The wrapper is scoped to the card — Material internals use `Opacity`
      // too. Once the entrance is over the card is returned unwrapped, so
      // "settled" means "no opacity wrapper at all", not "an Opacity of 1":
      // asserting `== 1` would pass on a permanently half-faded card too.
      expect(_cardOpacity(tester), 0);

      await tester.pump(const Duration(milliseconds: 85));
      expect(_cardOpacity(tester), closeTo(0.5, 0.15));

      await tester.pumpAndSettle();
      expect(_cardOpacity(tester), isNull);
    });

    testWidgets('it travels, it does not jump', (WidgetTester tester) async {
      final ToastHostState host = await _pump(tester);

      host.show('已同步', ToastKind.info);
      await tester.pump();
      final Offset start = tester.getTopLeft(find.text('已同步'));

      await tester.pump(const Duration(milliseconds: 85));
      final Offset middle = tester.getTopLeft(find.text('已同步'));

      await tester.pumpAndSettle();
      final Offset end = tester.getTopLeft(find.text('已同步'));

      // Rising from below: the first frame sits lower than the settled one, and
      // the midpoint is strictly between them.
      expect(start.dy, greaterThan(end.dy));
      expect(middle.dy, lessThan(start.dy));
      expect(middle.dy, greaterThan(end.dy));
      expect(start.dx, end.dx);
    });

    testWidgets('reduced motion shows it at once and removes it at once', (
      WidgetTester tester,
    ) async {
      final ToastHostState host = await _pump(tester, reduceMotion: true);

      host.show('已同步', ToastKind.info);
      await tester.pump();
      // One frame, already settled: no entrance to sit through.
      expect(_cardOpacity(tester), isNull);

      await tester.tap(find.text('已同步'));
      await tester.pump();
      // And no exit either — one frame after the tap it is already gone.
      expect(find.text('已同步'), findsNothing);

      await tester.pumpAndSettle();
    });
  });

  group('the stack', () {
    testWidgets('keeps the newest three', (WidgetTester tester) async {
      final ToastHostState host = await _pump(tester);

      for (var i = 0; i < 5; i++) {
        host.show('消息 $i', ToastKind.info);
      }
      await tester.pumpAndSettle();

      expect(find.text('消息 0'), findsNothing);
      expect(find.text('消息 1'), findsNothing);
      expect(find.text('消息 2'), findsOneWidget);
      expect(find.text('消息 3'), findsOneWidget);
      expect(find.text('消息 4'), findsOneWidget);
    });

    testWidgets('the empty page behind it still takes taps', (WidgetTester tester) async {
      var behind = 0;
      tester.view.physicalSize = const Size(411, 866);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final GlobalKey<ToastHostState> key = GlobalKey<ToastHostState>();
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: Size(411, 866)),
          child: MaterialApp(
            theme: buildTheme(Palette.light),
            home: ToastHost(
              key: key,
              child: Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => behind++,
                    child: const Text('behind'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      key.currentState!.show('已同步', ToastKind.info);
      await tester.pumpAndSettle();

      // The overlay column spans the screen width; the gap above the card must
      // stay click-through, which is why the `IgnorePointer` belongs nowhere
      // and the card alone is allowed to consume hits.
      await tester.tap(find.text('behind'));
      await tester.pumpAndSettle();
      expect(behind, 1);
      expect(find.text('已同步'), findsOneWidget);
    });
  });
}
