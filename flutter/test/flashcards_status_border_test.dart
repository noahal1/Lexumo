// The flashcard border shares the word library's four status colours. A
// sideways drag on the revealed card must wear the colour of the status that
// grade would land on; a skip keeps the word's current colour. Screenshots
// cannot verify a colour, so these tests read the AnimatedContainer's border
// while the drag is still held down.
library;

import 'package:flutter/material.dart' hide Card;
import 'package:flutter_test/flutter_test.dart';
import 'package:lexumo/app/scope.dart';
import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/data/services/tts.dart';
import 'package:lexumo/domain/models/srs.dart' show DAY_MS, previewGrades, CardState;
import 'package:lexumo/domain/models/types.dart';
import 'package:lexumo/ui/core/i18n/i18n.dart';
import 'package:lexumo/ui/core/theme.dart';
import 'package:lexumo/ui/core/tokens.dart';
import 'package:lexumo/ui/features/flashcards/views/flashcards_page.dart';
import 'support/fake_tts.dart';

const Palette _p = Palette.light;

/// One reviewable word: status `reviewing`, interval 4 days, two reviews.
/// A hard grade resets the interval to 1 (still `reviewing` -> blue); a good
/// grade earns 4 * 2.5 = 10 days (`learning` -> amber). So the two sideways
/// drags must wear two different colours from the library's palette.
AppData _seed(int now) {
  return AppData(
    lists: [
      WordList(
        id: DEFAULT_LIST_ID,
        name: 'Test',
        sourceLang: 'en',
        targetLang: 'zh-CN',
        createdAt: now - 7 * DAY_MS,
        updatedAt: now - 7 * DAY_MS,
      ),
    ],
    words: [
      Word(
        id: 'w1',
        term: 'resilient',
        definition: '有韧性的',
        definition2: '能迅速恢复的',
        example: 'Children are resilient.',
        note: '',
        status: WordStatus.reviewing,
        favorite: false,
        listId: DEFAULT_LIST_ID,
        sourceLang: 'en',
        targetLang: 'zh-CN',
        listenCount: 0,
        srs: SrsState(
          ease: 2.5,
          intervalDays: 4,
          dueAt: now - DAY_MS,
          reviewCount: 2,
          correctCount: 2,
        ),
        createdAt: now - 7 * DAY_MS,
        updatedAt: now - 7 * DAY_MS,
      ),
    ],
    settings: const Settings(),
  );
}

Finder get _card => find.byKey(const ValueKey('flip-card'));

Future<void> _pump(WidgetTester tester) async {
  final Store store = Store(
    persistence: MemoryStore(),
    seed: _seed,
    saveDelayMs: 0,
  );
  await store.init();
  await store.flush();
  tester.view.physicalSize = const Size(660, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    StoreScope(
      notifier: StoreNotifier(store),
      child: I18nScope(
        i18n: I18n(store.data.settings.uiLang),
        child: ToastScope(
          show: (String text, ToastKind kind,
              {String? actionLabel,
              VoidCallback? onAction,
              int? durationMs}) {},
          child: NavScope(
            onNavigate: (String _) {},
            child: MaterialApp(
              theme: buildTheme(_p),
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
  await tester.tap(find.text('显示答案'));
  await tester.pumpAndSettle();
}

/// Hold a drag at [offset] without releasing, then read the border colour off
/// the card's AnimatedContainer. Release and let the session settle afterwards.
Future<Color> _borderWhileDragging(
    WidgetTester tester, Offset offset) async {
  final TestGesture gesture =
      await tester.startGesture(tester.getCenter(_card));
  await gesture.moveBy(offset);
  await tester.pump();
  // The card's own AnimatedContainer is not the only one in the subtree —
  // the volume LexButton in the head has one too. The card is the tall one:
  // its minHeight is the 330–520dp figure, a button never exceeds ~56dp.
  final AnimatedContainer container = tester.widget<AnimatedContainer>(
    find.descendant(
      of: _card,
      matching: find.byWidgetPredicate(
        (Widget w) =>
            w is AnimatedContainer &&
            w.constraints != null &&
            w.constraints!.minHeight >= 300,
      ),
    ),
  );
  final Color color =
      ((container.decoration! as BoxDecoration).border! as Border).top.color;
  await gesture.up();
  await tester.pumpAndSettle();
  return color;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => debugSetSpeech(silentSpeech()));
  tearDown(() => debugSetSpeech(null));

  test('one status colour per status, in both themes', () {
    final List<Color> light = <Color>[
      for (final WordStatus s in WordStatus.values) _p.statusColor(s),
    ];
    final List<Color> dark = <Color>[
      for (final WordStatus s in WordStatus.values)
        Palette.dark.statusColor(s),
    ];
    expect(light.toSet().length, 4,
        reason: 'four statuses must be four distinguishable hues');
    expect(dark.toSet().length, 4,
        reason: 'the dark theme must not collapse two hues into one');
    expect(light, <Color>[_p.ink4, _p.info, _p.warn, _p.ok]);
    expect(dark,
        <Color>[Palette.dark.ink4, Palette.dark.info, Palette.dark.warn, Palette.dark.ok]);
  });

  testWidgets('a left pull wears the hard grade\'s destination colour',
      (WidgetTester tester) async {
    await _pump(tester);
    final Word w = _seed(0).words.single;
    final WordStatus destination = previewGrades(
      CardState(srs: w.srs, status: w.status),
      0,
    )[Grade.hard]!.status;
    expect(destination, WordStatus.reviewing);
    // A literal, not `statusColor(destination)`: the expectation must not
    // route through the function under test, or a mapping that collapses all
    // four statuses into one colour would keep this green.
    expect(
      await _borderWhileDragging(tester, const Offset(-120, 0)),
      _p.info,
      reason: 'left = hard -> still reviewing, so the border must be blue',
    );
  });

  testWidgets('a right pull wears the good grade\'s destination colour',
      (WidgetTester tester) async {
    await _pump(tester);
    final Word w = _seed(0).words.single;
    final WordStatus destination = previewGrades(
      CardState(srs: w.srs, status: w.status),
      0,
    )[Grade.good]!.status;
    expect(destination, WordStatus.learning);
    expect(
      await _borderWhileDragging(tester, const Offset(120, 0)),
      _p.warn,
      reason: 'right = good -> learning, so the border must be amber',
    );
  });

  testWidgets('a skip pull keeps the word\'s own status colour',
      (WidgetTester tester) async {
    await _pump(tester);
    expect(
      await _borderWhileDragging(tester, const Offset(0, 140)),
      _p.info,
      reason: 'skipping a reviewing word keeps its blue, invents no new hue',
    );
  });

  testWidgets('a drag below the threshold keeps the neutral border',
      (WidgetTester tester) async {
    await _pump(tester);
    expect(
      await _borderWhileDragging(tester, const Offset(40, 0)),
      _p.line,
      reason: 'an indecisive pull must not claim a status',
    );
  });
}
