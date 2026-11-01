// Phone-width layout for the settings page.
//
// These exist because of a defect the audit found by accident: pumping the page
// at 411dp threw `A RenderFlex overflowed by 40 pixels on the right` from the
// text-to-speech row. The row *knew* to stack its label above its control below
// 520 — but the control itself was a fixed 260px select plus a button, so
// stacking the label did not make the control narrower. A fixed width that was
// really a desktop measurement masqueraded as a minimum.
//
// Two things are asserted here, and the difference matters:
//
//   · **no overflow at phone width**, from `takeException()` — the defect;
//   · **the controls still work at phone width**, because "make it fit" is
//     trivially satisfiable by hiding the control, and a settings page whose
//     voice picker cannot be opened is not fixed.
//
// The vehicle is the whole page rather than the row: the overflow surfaced from
// deep inside it, and a test that reaches into private widgets would have to be
// rewritten the next time the row is restructured.

import 'package:flutter/material.dart' hide Card;
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/app/scope.dart';
import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/data/models/sync_config.dart';
import 'package:lexumo/data/repositories/sync_engine.dart';
import 'package:lexumo/data/services/sync_transport.dart';
import 'package:lexumo/ui/core/theme.dart';
import 'package:lexumo/ui/core/tokens.dart';
import 'package:lexumo/domain/models/seed.dart';
import 'package:lexumo/ui/core/i18n/i18n.dart';
import 'package:lexumo/ui/features/settings/views/settings_page.dart';
import 'package:lexumo/data/services/tts.dart';
import 'package:lexumo/ui/core/widgets/controls.dart';

import 'support/fake_tts.dart';

/// A transport that is never reached: every request fails immediately, so the
/// engine settles instead of waiting on a timeout.
class _DeadTransport implements SyncTransport {
  @override
  Future<Object?> request(
    String server,
    String path, {
    String method = 'GET',
    Object? body,
    String? token,
  }) async =>
      throw const SyncHttpError(SyncError.offline, 0);
  @override
  void close() {}
}

/// Pumps [SettingsPage] at an exact logical size. Portrait phone by default.
///
/// Returns the engine the page needs, because `SyncEngine.start` arms a periodic
/// poll timer and `flutter_test` fails a test that ends with a timer pending. The
/// caller must `engine.dispose()` as the last statement of the body — not in a
/// tear-down, which runs after the pending-timer assertion has already fired.
Future<SyncEngine> pumpSettingsAt(
  WidgetTester tester, {
  double width = 411,
  double height = 866,
}) async {
  final store = Store(persistence: MemoryStore(), seed: seedData);
  await store.init();
  await store.flush();

  final engine = SyncEngine(
    store: store,
    configStore: MemorySyncConfigStore(),
    transport: _DeadTransport(),
    interval: const Duration(hours: 1),
    soonDelay: const Duration(hours: 1),
    bootDelay: const Duration(hours: 1),
  );
  await engine.init();

  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    StoreScope(
      notifier: StoreNotifier(store),
      child: SyncScope(
        notifier: SyncStatusNotifier(engine),
        child: I18nScope(
          i18n: I18n(store.data.settings.uiLang),
          child: ToastScope(
            show: (text, kind, {actionLabel, onAction, durationMs}) {},
            child: NavScope(
              onNavigate: (_) {},
              child: MaterialApp(
                theme: buildTheme(Palette.light),
                home: Scaffold(body: SettingsPage()),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return engine;
}

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);
  setUp(() => debugSetSpeech(silentSpeech()));
  tearDown(() => debugSetSpeech(null));

  group('settings at phone width', () {
    testWidgets('nothing overflows horizontally', (WidgetTester tester) async {
      final engine = await pumpSettingsAt(tester);
      // The original defect was a 40px overflow on the text-to-speech row; an
      // overflow reports through the exception hook rather than by failing the
      // pump, so it has to be drained explicitly.
      expect(
        tester.takeException(),
        isNull,
        reason: 'a phone-width settings page must not overflow',
      );
      engine.dispose();
    });

    testWidgets('the voice picker is still reachable and openable', (
      WidgetTester tester,
    ) async {
      final engine = await pumpSettingsAt(tester);

      final select = find.byType(LexSelect<String>);
      expect(select, findsOneWidget, reason: 'the voice picker must still be drawn');

      // Fitting by hiding is not fitting: the control has to stay wide enough to
      // be a control. 120 is a floor, not a target — at 297 of row width a
      // Flexible select lands somewhere near 200.
      final box = tester.getSize(select);
      expect(box.width, greaterThan(120));
      expect(box.width, lessThanOrEqualTo(260));

      await tester.ensureVisible(select);
      await tester.pumpAndSettle();
      await tester.tap(select);
      await tester.pumpAndSettle();
      // `''` is the automatic entry; opening the menu must offer at least it.
      expect(find.text('自动选择'), findsWidgets);
      expect(tester.takeException(), isNull);
      engine.dispose();
    });

    testWidgets('every control on the page meets the 44dp touch floor', (
      WidgetTester tester,
    ) async {
      final engine = await pumpSettingsAt(tester);

      final short = <String>[];
      for (final e in find.byType(LexButton).evaluate()) {
        final s = tester.getSize(find.byWidget(e.widget));
        if (s.height < Layout.tap - 0.5) {
          short.add('LexButton ${(e.widget as LexButton).label} ${s.height}');
        }
      }
      for (final e in find.byType(LexSelect<String>).evaluate()) {
        final s = tester.getSize(find.byWidget(e.widget));
        if (s.height < Layout.tap - 0.5) short.add('LexSelect ${s.height}');
      }
      expect(
        short,
        isEmpty,
        reason: 'controls a finger has to hit must be ${Layout.tap}dp tall: $short',
      );
      engine.dispose();
    });

    testWidgets('the two hand-drawn controls meet the floor as well', (
      WidgetTester tester,
    ) async {
      final engine = await pumpSettingsAt(tester);

      // `_LexSwitch` and `_RateSlider` are painted, not built from `LexButton`,
      // so the sweep above cannot see them. Both were 24dp and 20dp tall — the
      // two smallest targets on the page, on the two controls that change a
      // setting without any confirmation step.
      final toggle = find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.toggled != null,
      );
      final slider = find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.slider == true,
      );
      expect(toggle, findsWidgets, reason: 'the switches must still be drawn');
      expect(slider, findsWidgets, reason: 'the rate slider must still be drawn');

      final short = <String>[];
      for (final f in [toggle, slider]) {
        for (final e in f.evaluate()) {
          final s = tester.getSize(find.byWidget(e.widget));
          if (s.height < Layout.tap - 0.5) {
            short.add('${(e.widget as Semantics).properties.slider == true ? 'slider' : 'switch'} ${s.height}');
          }
        }
      }
      expect(short, isEmpty, reason: 'every painted control must be ${Layout.tap}dp tall: $short');
      engine.dispose();
    });
  });
}
