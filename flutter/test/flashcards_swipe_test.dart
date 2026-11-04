// Swipe-to-grade on the flashcard.
//
// The request behind this was 「把我的闪卡变成可以滑动的 向左困难那种」: once the
// answer is showing, dragging the card left commits a Hard and dragging it
// right commits a Good — the same grades the buttons and the 1/2 keys write,
// through the same `FlashcardsViewModel.grade`, so undo and the session
// counters behave identically however the grade arrived.
//
// Three things are asserted, and they are different questions:
//
//   1. A left drag past the threshold grades Hard; a right drag grades Good.
//   2. A drag that never crosses the threshold snaps back and grades nothing
//      — a swipe is a decision, not an accident of scrolling.
//   3. The front of the card does not swipe at all: `onSwipe` is only wired
//      while the answer is showing, the same gate the grade row uses.
//
// The drags go through `tester.timedDrag` with a slow, steady gesture so the
// measured velocity stays near zero — the threshold is on *distance*, and a
// fast fling in a fake-async test records velocities that would make the
// assertion about distance harder to reason about.

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

/// Flicks the card down by [dy] logical pixels — quick, the way a hand skips.
Future<void> _flickDown(WidgetTester tester, double dy) async {
  await tester.timedDrag(
    _card,
    Offset(0, dy),
    const Duration(milliseconds: 200),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);
  setUp(() => debugSetSpeech(silentSpeech()));
  tearDown(() => debugSetSpeech(null));

  Future<Store> pumpSession(WidgetTester tester) async {
    final store = Store(persistence: MemoryStore(), seed: seedData);
    await store.init();
    await store.flush();
    tester.view.physicalSize = const Size(1100, 1200);
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

  testWidgets('a downward flick skips without grading', (
    WidgetTester tester,
  ) async {
    final store = await pumpSession(tester);
    final int before = store.data.logs.length;
    // The card is revealed before the flick — '背面' is the back-of-card label.
    expect(find.text('背面'), findsOneWidget);

    await _flickDown(tester, 160);

    // Nothing was written to the schedule — a skip is not a grade — and the
    // card turned back to its front face for the next term.
    expect(store.data.logs.length, before);
    expect(find.text('正面'), findsOneWidget);
    expect(find.text('困难'), findsNothing);
  });

  testWidgets('a slow drag downwards is not a flick', (WidgetTester tester) async {
    final store = await pumpSession(tester);
    final int before = store.data.logs.length;

    // Reading a long definition means dragging down slowly and releasing; that
    // must not throw the card away as a skip.
    await tester.timedDrag(
      _card,
      const Offset(0, 160),
      const Duration(milliseconds: 1200),
    );
    await tester.pumpAndSettle();

    expect(store.data.logs.length, before);
    expect(find.text('困难'), findsOneWidget);
  });

  testWidgets('the front of the card does not swipe', (
    WidgetTester tester,
  ) async {    // A fresh session that stops before revealing: the card shows the term,
    // and a drag there must be ignored by the page's swipe-to-grade path.
    final store = Store(persistence: MemoryStore(), seed: seedData);
    await store.init();
    await store.flush();
    tester.view.physicalSize = const Size(1100, 1200);
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

    final int before = store.data.logs.length;
    await _swipe(tester, -160);

    expect(store.data.logs.length, before);
    // The card is still unrevealed: the grade row never appeared.
    expect(find.text('困难'), findsNothing);
  });
}
