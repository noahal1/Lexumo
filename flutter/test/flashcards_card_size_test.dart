import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/app/scope.dart';
import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/data/services/tts.dart';
import 'package:lexumo/domain/models/seed.dart';
import 'package:lexumo/domain/models/types.dart' show UiLang;
import 'package:lexumo/ui/core/i18n/i18n.dart';
import 'package:lexumo/ui/core/theme.dart';
import 'package:lexumo/ui/core/tokens.dart' show Palette;
import 'package:lexumo/ui/core/widgets/controls.dart';
import 'package:lexumo/ui/features/flashcards/views/flashcards_page.dart';

import 'support/fake_tts.dart';

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);
  setUp(() => debugSetSpeech(silentSpeech()));
  tearDown(() => debugSetSpeech(null));

  Future<void> pumpSession(WidgetTester tester, Size size) async {
    final Store store = Store(
      persistence: MemoryStore(),
      seed: seedData,
      saveDelayMs: 0,
    );
    await store.init();
    await store.flush();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      StoreScope(
        notifier: StoreNotifier(store),
        child: I18nScope(
          i18n: I18n(UiLang.zhCN),
          child: ToastScope(
            show: (text, kind, {actionLabel, onAction, durationMs}) {},
            child: NavScope(
              onNavigate: (_) {},
              child: MaterialApp(
                theme: buildTheme(Palette.light),
                home: const Scaffold(body: FlashcardsPage()),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始复习'));
    await tester.pumpAndSettle();
  }

  final Finder card = find.byKey(const ValueKey('flip-card'));
  final Finder answerButton = find.widgetWithText(LexButton, '显示答案');

  // A phone used to give the front face no height floor at all: it shrank to
  // its ~175dp of text while the revealed answer needed ~322dp. Turning the
  // card over therefore grew it by ~150dp and shoved the answer button, the
  // round action row and the grade row down the screen. The floor is now
  // applied on every window, so both faces hold one height and the controls
  // below the card stay put. These two sizes pin that on a phone and a desktop.
  for (final Size size in <Size>[
    const Size(411, 860), // phone
    const Size(1280, 860), // desktop
  ]) {
    testWidgets(
        '${size.width.toInt()}x${size.height.toInt()}: the card holds one height on both faces',
        (WidgetTester tester) async {
      await pumpSession(tester, size);

      final Rect front = tester.getRect(card);
      expect(answerButton, findsOneWidget);
      final double frontCardBottom = front.bottom;

      await tester.tap(answerButton);
      await tester.pumpAndSettle();

      final Rect back = tester.getRect(card);

      expect(
        front.height,
        greaterThanOrEqualTo(330.0),
        reason: 'the card must be a real surface, not shrink to its text',
      );
      expect(
        back.height,
        front.height,
        reason: 'turning the card must not resize it on a ${size.width.toInt()}dp window',
      );
      expect(back.top, front.top);
      expect(
        back.bottom,
        frontCardBottom,
        reason: 'every control below the card hangs off its bottom edge, so a '
            'steady bottom keeps the buttons in the same place on both faces',
      );
    });
  }
}
