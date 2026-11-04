// Free drag on the flashcard.
//
// The request behind this was 「我这个闪卡要可以自由拖拽 类似这样的」: the card
// follows the hand in both axes — with a slight tilt — instead of only sliding
// along its horizontal axis. A release still decides something only past a
// threshold: left commits a Hard, right commits a Good, down commits a skip,
// and any pull short of that springs back and grades nothing. The commits go
// through the same `FlashcardsViewModel.grade` and `skip` the buttons and the
// keyboard use, so undo and the session counters behave identically however
// the decision arrived.
//
// Four things are asserted, and they are different questions:
//
//   1. A left drag past the threshold grades Hard; a right drag grades Good.
//   2. A drag that never crosses a threshold snaps back and grades nothing
//      — a swipe is a decision, not an accident of scrolling.
//   3. A downward drag past the skip threshold skips at any speed: the card
//      owns both axes on a phone, so there is no slow-drag escape hatch.
//   4. The front of the card plays with the drag but never commits: both
//      callbacks are only wired while the answer is showing, the same gate
//      the grade row uses.
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
    final store = Store(persistence: MemoryStore(), seed: seedData);
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

  testWidgets('the front of the card does not swipe', (
    WidgetTester tester,
  ) async {
    // A fresh session that stops before revealing: the card shows the term,
    // and a drag there plays with the card but must commit nothing.
    final store = Store(persistence: MemoryStore(), seed: seedData);
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

    final int before = store.data.logs.length;
    await _swipe(tester, -160);

    expect(store.data.logs.length, before);
    // The card is still unrevealed: the grade row never appeared.
    expect(find.text('正面'), findsOneWidget);
    expect(find.text('困难'), findsNothing);
  });
}
