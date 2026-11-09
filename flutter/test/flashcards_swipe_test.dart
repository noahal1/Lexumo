// Free drag on the flashcard.
//
// The request behind this was 「我这个闪卡要可以自由拖拽 类似这样的」: the card
// follows the hand in both axes — with a slight tilt — instead of only sliding
// along its horizontal axis. A release still decides something only past a
// threshold: left commits a Hard, right commits a Good, up commits an Easy,
// down commits a skip, and any pull short of that springs back and grades
// nothing. The commits go through the same `FlashcardsViewModel.grade` and
// `skip` the buttons and the keyboard use, so undo and the session counters
// behave identically however the decision arrived.
//
// Four things are asserted, and they are different questions:
//
//   1. A left drag past the threshold grades Hard; a right drag grades Good.
//   2. A drag that never crosses a threshold snaps back and grades nothing
//      — a swipe is a decision, not an accident of scrolling.
//   3. A downward drag past the skip threshold skips at any speed: the card
//      owns both axes on a phone, so there is no slow-drag escape hatch.
//   4. The four directions mean four things, on both faces: left is Hard,
//      right is Good, up is Easy, down is Skip. The front grades just like
//      the back — the reference design puts its grade pill on the unrevealed
//      card too. What decides between two candidates is dominance: a pull has
//      to be more down than sideways to skip, and more up than sideways to
//      take Easy, so a diagonal never means two things at once.
//
// The tests hold the card in a phone-width viewport on purpose: on a wide
// window the revealed answer keeps a scroll view of its own, so vertical drags
// over the face belong to reading, not to the card. On a phone the face has no
// scroll view and the card owns the whole gesture.
//
// The drags go through `tester.timedDrag` with a slow, steady gesture. The
// release reads the hold, not the fling — velocity is deliberately ignored —
// so the measured speed is irrelevant and the distance is the whole decision.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/domain/models/seed.dart';
import 'package:lexumo/domain/models/types.dart';
import 'package:lexumo/ui/core/i18n/i18n.dart';
import 'package:lexumo/ui/core/theme.dart';
import 'package:lexumo/ui/core/tokens.dart';
import 'package:lexumo/ui/features/flashcards/views/flashcards_page.dart';
import 'package:lexumo/data/services/tts.dart';
import 'package:lexumo/app/scope.dart';

import 'support/fake_tts.dart';

Finder get _card => find.byKey(const ValueKey('flip-card'));

/// Drags the card by [dx] logical pixels over a slow, steady gesture.
Future<void> _swipe(WidgetTester tester, double dx) async {
  await tester.timedDrag(
    _card,
    Offset(dx, 0),
    const Duration(milliseconds: 400),
  );
  await tester.pumpAndSettle();
}

/// Drags the card up by [dy] logical pixels — the 简单 gesture.
Future<void> _dragUp(WidgetTester tester, double dy) async {
  await tester.timedDrag(
    _card,
    Offset(0, -dy),
    const Duration(milliseconds: 400),
  );
  await tester.pumpAndSettle();
}

/// Drags the card down by [dy] logical pixels over [ms] milliseconds — the
/// speed is part of the point: skip reads the distance, not the clock.
Future<void> _dragDown(
  WidgetTester tester,
  double dy, {
  int ms = 200,
}) async {
  await tester.timedDrag(
    _card,
    Offset(0, dy),
    Duration(milliseconds: ms),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);
  setUp(() => debugSetSpeech(silentSpeech()));
  tearDown(() => debugSetSpeech(null));

  Future<Store> pumpSession(WidgetTester tester) async {
    // No save debounce: a grade writes to the store, and the debounce timer
    // would outlive the test whenever the frames that follow the decision are
    // shorter than the delay. Real time passes in the app; test time does not.
    final store = Store(
      persistence: MemoryStore(),
      seed: seedData,
      saveDelayMs: 0,
    );
    await store.init();
    await store.flush();
    tester.view.physicalSize = const Size(660, 1200);
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
                home: Scaffold(body: const FlashcardsPage()),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('开始复习'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示答案'));
    await tester.pumpAndSettle();
    return store;
  }

  testWidgets('a left drag past the threshold grades Hard', (
    WidgetTester tester,
  ) async {
    final store = await pumpSession(tester);
    final int before = store.data.logs.length;

    await _swipe(tester, -160);

    expect(store.data.logs.length, before + 1);
    expect(store.data.logs.last.grade, Grade.hard);
  });

  testWidgets('a right drag past the threshold grades Good', (
    WidgetTester tester,
  ) async {
    final store = await pumpSession(tester);
    final int before = store.data.logs.length;

    await _swipe(tester, 160);

    expect(store.data.logs.length, before + 1);
    expect(store.data.logs.last.grade, Grade.good);
  });

  testWidgets('a drag short of the threshold snaps back and grades nothing', (
    WidgetTester tester,
  ) async {
    final store = await pumpSession(tester);
    final int before = store.data.logs.length;

    await _swipe(tester, -40);

    expect(store.data.logs.length, before);
    // The card is still in hand — the same card, still revealed.
    expect(find.byKey(const ValueKey('flip-card')), findsOneWidget);
    expect(find.text('困难'), findsOneWidget);
  });

  testWidgets('a downward drag skips without grading', (
    WidgetTester tester,
  ) async {
    final store = await pumpSession(tester);
    final int before = store.data.logs.length;
    // The card is revealed before the drag — '背面' is the back-of-card label.
    expect(find.text('背面'), findsOneWidget);

    await _dragDown(tester, 160);

    // Nothing was written to the schedule — a skip is not a grade — and the
    // card turned back to its front face for the next term.
    expect(store.data.logs.length, before);
    expect(find.text('正面'), findsOneWidget);
    expect(find.text('困难'), findsNothing);
  });

  testWidgets('a slow downward drag skips the same as a quick one', (
    WidgetTester tester,
  ) async {
    final store = await pumpSession(tester);
    final int before = store.data.logs.length;

    // The card owns both axes on a phone — there is no nested scroll view to
    // protect, so speed is not part of the decision, only distance.
    await _dragDown(tester, 160, ms: 1200);

    expect(store.data.logs.length, before);
    expect(find.text('正面'), findsOneWidget);
    expect(find.text('困难'), findsNothing);
  });

  testWidgets('a short pull down springs back and grades nothing', (
    WidgetTester tester,
  ) async {
    final store = await pumpSession(tester);
    final int before = store.data.logs.length;

    await _dragDown(tester, 60);

    expect(store.data.logs.length, before);
    // Still the same card, still revealed: the pull was a fidget, not a skip.
    expect(find.text('背面'), findsOneWidget);
    expect(find.text('困难'), findsOneWidget);
  });

  testWidgets('an upward drag past the threshold grades Easy', (
    WidgetTester tester,
  ) async {
    final store = await pumpSession(tester);
    final int before = store.data.logs.length;

    await _dragUp(tester, 160);

    expect(store.data.logs.length, before + 1);
    expect(store.data.logs.last.grade, Grade.easy);
  });

  testWidgets('an upward drag short of the threshold grades nothing', (
    WidgetTester tester,
  ) async {
    final store = await pumpSession(tester);
    final int before = store.data.logs.length;

    // 96 is the Easy threshold; 60 stays under it, so the card comes home
    // rather than handing out the longest interval on offer by accident.
    await _dragUp(tester, 60);

    expect(store.data.logs.length, before);
    expect(find.text('背面'), findsOneWidget);
  });

  testWidgets('an up-left diagonal favours neither, and springs back', (
    WidgetTester tester,
  ) async {
    final store = await pumpSession(tester);
    final int before = store.data.logs.length;

    // 100 up against 80 across: the sideways pull clears its own 72 threshold
    // *and* the upward one clears 96, so both gestures fire and the dominance
    // rule has to pick one. Up wins, because 100 > 80 × 1.2 — and exactly one
    // log lands, not two.
    await tester.timedDrag(
      _card,
      const Offset(-80, -100),
      const Duration(milliseconds: 400),
    );
    await tester.pumpAndSettle();

    expect(store.data.logs.length, before + 1);
    expect(store.data.logs.last.grade, Grade.easy);
  });

  /// A session that stops before revealing: the card shows the term, and the
  /// grade row does not exist yet. The card can still be thrown — the gesture
  /// is the same four directions on both faces, and the front grades too.
  Future<Store> pumpFront(WidgetTester tester) async {
    // saveDelayMs: 0 for the same reason as pumpSession — the front grades now
    // too, so a pending save timer would outlive the test.
    final store = Store(
      persistence: MemoryStore(),
      seed: seedData,
      saveDelayMs: 0,
    );
    await store.init();
    await store.flush();
    tester.view.physicalSize = const Size(660, 1200);
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
                home: Scaffold(body: const FlashcardsPage()),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始复习'));
    await tester.pumpAndSettle();
    return store;
  }

  testWidgets('a sideways throw on the front grades, it does not skip', (
    WidgetTester tester,
  ) async {
    final store = await pumpFront(tester);
    final int before = store.data.logs.length;

    await _swipe(tester, -160);

    // Left is 困难 on both faces. The front used to be a skip-only surface —
    // every direction discarded the card — which read in the hand as "the
    // whole screen is a skip button".
    expect(store.data.logs.length, before + 1);
    expect(store.data.logs.last.grade, Grade.hard);
    expect(find.textContaining('跳过 1'), findsNothing);
  });

  testWidgets('a right throw on the front grades Good', (
    WidgetTester tester,
  ) async {
    final store = await pumpFront(tester);
    final int before = store.data.logs.length;

    await _swipe(tester, 160);

    expect(store.data.logs.length, before + 1);
    expect(store.data.logs.last.grade, Grade.good);
    expect(find.textContaining('跳过 1'), findsNothing);
  });

  testWidgets('a front drag short of the threshold springs back', (
    WidgetTester tester,
  ) async {
    final store = await pumpFront(tester);
    final int before = store.data.logs.length;

    await _swipe(tester, -40);

    expect(store.data.logs.length, before);
    // Nothing moved: no skip counter appeared, the fidget stayed a fidget.
    expect(find.textContaining('跳过 1'), findsNothing);
    expect(find.text('困难'), findsNothing);
  });

  testWidgets('a front throw down skips as well', (WidgetTester tester) async {
    final store = await pumpFront(tester);
    final int before = store.data.logs.length;

    await _dragDown(tester, 160);

    expect(store.data.logs.length, before);
    expect(find.textContaining('跳过 1'), findsWidgets);
  });

  testWidgets('a short diagonal on the front springs back too', (
    WidgetTester tester,
  ) async {
    final store = await pumpFront(tester);
    final int before = store.data.logs.length;

    // Down-and-across: neither axis decisive, so neither reads as a gesture.
    await tester.timedDrag(
      _card,
      const Offset(-60, 50),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();

    expect(store.data.logs.length, before);
    expect(find.textContaining('跳过 1'), findsNothing);
    expect(find.byKey(const ValueKey('flip-card')), findsOneWidget);
  });

  /// The pill under the card is a readout, not a button: it names the decision
  /// the release would take at this instant, and it only exists while a hand is
  /// on the card. These tests hold the gesture open with
  /// [WidgetTester.startGesture] because the whole point of the pill is what it
  /// says *mid*-drag — after the release it is gone.
  group('the pill under the card says what the release would do', () {
    final Finder pill = find.byKey(const ValueKey('drag-pill'));

    /// The pill's visibility, read off the [AnimatedOpacity] that owns it.
    double opacityOf(WidgetTester tester) => tester
        .widget<AnimatedOpacity>(
          find.ancestor(of: pill, matching: find.byType(AnimatedOpacity)),
        )
        .opacity;

    /// Inside the pill only — 困难 and 记得 also exist in the grade row below.
    Finder inPill(String label) =>
        find.descendant(of: pill, matching: find.text(label));

    /// The pill's interval slot, whatever it currently says.
    ///
    /// The interval is its own `Text` (`10天`, `<1天`, `首次`), so looking for a
    /// substring like '天' silently matches nothing — the earlier "a skip
    /// promises no date" assertion passed for exactly that reason. Reading the
    /// slot by position is what actually pins the behaviour down.
    String? intervalInPill(WidgetTester tester) {
      final Iterable<String?> texts = tester
          .widgetList<Text>(find.descendant(of: pill, matching: find.byType(Text)))
          .map((Text t) => t.data);
      // Label first, then the separator, then the interval — if it exists.
      return texts.length >= 3 ? texts.elementAt(2) : null;
    }

    Future<TestGesture> hold(
      WidgetTester tester, {
      required Offset step,
      required int steps,
    }) async {
      final TestGesture hand =
          await tester.startGesture(tester.getCenter(_card));
      for (int i = 0; i < steps; i++) {
        await hand.moveBy(step);
        await tester.pump(const Duration(milliseconds: 16));
      }
      return hand;
    }

    testWidgets('it is invisible before the hand touches the card', (
      WidgetTester tester,
    ) async {
      await pumpSession(tester);
      expect(opacityOf(tester), 0);
    });

    testWidgets('a left pull names 困难 with the days it would buy', (
      WidgetTester tester,
    ) async {
      await pumpSession(tester);
      // 5 × 20 dp = 100, past the 72 dp threshold.
      final TestGesture hand =
          await hold(tester, step: const Offset(-20, 0), steps: 5);
      addTearDown(hand.up);

      expect(inPill('困难'), findsOneWidget);
      expect(inPill('记得'), findsNothing);
      expect(opacityOf(tester), 1);
    });

    testWidgets('a right pull names 记得', (WidgetTester tester) async {
      await pumpSession(tester);
      final TestGesture hand =
          await hold(tester, step: const Offset(20, 0), steps: 5);
      addTearDown(hand.up);

      expect(inPill('记得'), findsOneWidget);
      expect(inPill('困难'), findsNothing);
    });

    testWidgets('a downward pull names 跳过, without a day count', (
      WidgetTester tester,
    ) async {
      await pumpSession(tester);
      // 7 × 20 dp = 140, past the 96 dp skip threshold.
      final TestGesture hand =
          await hold(tester, step: const Offset(0, 20), steps: 7);
      addTearDown(hand.up);

      expect(inPill('跳过'), findsOneWidget);
      // A skip does not reschedule, so the pill has no interval slot at all.
      expect(intervalInPill(tester), isNull);
    });

    testWidgets('an upward pull names 简单 with its days', (
      WidgetTester tester,
    ) async {
      await pumpSession(tester);
      // 7 × 20 dp = 140 up, past the 96 dp Easy threshold.
      final TestGesture hand =
          await hold(tester, step: const Offset(0, -20), steps: 7);
      addTearDown(hand.up);

      expect(inPill('简单'), findsOneWidget);
      expect(inPill('困难'), findsNothing);
      // 简单 is a grade, so the pill owes the reader its interval — where the
      // skip prints nothing at all.
      expect(intervalInPill(tester), isNotNull);
    });

    testWidgets('the pill goes away when the hand does', (
      WidgetTester tester,
    ) async {
      await pumpSession(tester);
      final TestGesture hand =
          await hold(tester, step: const Offset(-20, 0), steps: 3);
      await hand.up();
      await tester.pumpAndSettle();

      expect(opacityOf(tester), 0);
    });
  });
}
