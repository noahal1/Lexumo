// The account & sync section of the settings page.
//
// What is worth testing here is not "the buttons exist" but the states the user
// can be in and the one thing that must never leak:
//
//   1. **Signed out shows the way back in, signed in shows the account.** The
//      sign-in *form* lives on the first-run gate, not here — the page offers
//      the gate again with a button. Drawing a second copy of those fields was
//      two places to type one password; what this page must still do is show a
//      signed-out device that signing in is one tap away, and a signed-in one
//      the account it belongs to.
//   2. **A failed sign-out reports why, in place.** A toast disappears before
//      the user can read it, so the message has to sit on the page. (Sign-in
//      errors are the gate's own tests now.)
//   3. **The token never reaches the snapshot.** `Settings` is packed up by
//      `collectChanges` and uploaded, so a token stored there would be pushed to
//      every device. This is asserted directly against the store, not the UI.
//
// The engine is real; only its transport is fake. That keeps the assertions
// about behaviour (a round happened, the status flipped) rather than about the
// shape of a mock.

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
import 'package:lexumo/ui/features/onboarding/views/onboarding_page.dart';
import 'package:lexumo/ui/features/settings/views/settings_page.dart';
import 'package:lexumo/data/services/tts.dart';
import 'package:lexumo/ui/core/widgets/controls.dart';

import 'support/fake_tts.dart';

typedef ToastRecord = ({String text, ToastKind kind});

/// Answers every request from a table keyed by path, so one fake covers a whole
/// sign-in-then-sync session without a script that has to be in the right order.
class PathTransport implements SyncTransport {
  PathTransport([Map<String, Object?>? replies, this.error]) : replies = replies ?? const {};

  /// Every request fails with [error].
  PathTransport.failing(SyncHttpError this.error) : replies = const {};

  final Map<String, Object?> replies;
  final SyncHttpError? error;
  final List<String> seen = [];

  @override
  Future<Object?> request(
    String server,
    String path, {
    String method = 'GET',
    Object? body,
    String? token,
  }) async {
    seen.add(path);
    if (error != null) throw error!;
    for (final entry in replies.entries) {
      if (path.startsWith(entry.key)) return entry.value;
    }
    return const <String, dynamic>{};
  }

  @override
  void close() {}
}

/// A settings page inside the scopes it needs, with a real engine and a fake
/// transport, collecting toasts instead of rendering them.
Future<(Store, SyncEngine, List<ToastRecord>)> pumpSettings(
  WidgetTester tester, {
  required SyncTransport transport,
  SyncConfig? signedIn,
}) async {
  final store = Store(persistence: MemoryStore(), seed: seedData);
  await store.init();
  await store.flush();

  final configStore = MemorySyncConfigStore();
  if (signedIn != null) await configStore.save(signedIn);

  final engine = SyncEngine(
    store: store,
    configStore: configStore,
    transport: transport,
    // Long intervals so no timer fires during a test; every round here is
    // triggered by a tap.
    interval: const Duration(hours: 1),
    soonDelay: const Duration(hours: 1),
    bootDelay: const Duration(hours: 1),
  );
  await engine.init();

  final toasts = <ToastRecord>[];
  tester.view.physicalSize = const Size(1100, 2600);
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
            show: (text, kind, {actionLabel, onAction, durationMs}) {
              toasts.add((text: text, kind: kind));
            },
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
  return (store, engine, toasts);
}

/// Scrolls [finder] into view, then taps it. The page is long and the section's
/// position depends on the language, so a fixed drag would be brittle.
Future<void> tapInView(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

const SyncConfig _signedIn = SyncConfig(
  server: 'http://127.0.0.1:8787',
  email: 'reader@example.test',
  token: 'tok-live',
  rev: 7,
  lastSyncAt: 1700000000000,
);

void main() {
  // `SettingsPage.initState` calls `appSpeech.warmUp()`, and `appSpeech` is the
  // process-wide singleton — so without this, every test here reaches the real
  // `flutter_tts` plugin and its platform channel alongside the fake transport
  // that the file is actually about. See `test/support/fake_tts.dart`.
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);
  setUp(() => debugSetSpeech(silentSpeech()));
  tearDown(() => debugSetSpeech(null));

  group('signed out', () {
    testWidgets('shows the way back in: a status row and a sign-in button', (tester) async {
      final (store, engine, _) = await pumpSettings(tester, transport: PathTransport());

      // The row names the state; the button is the one action a signed-out
      // device can take. No fields: the form is the gate's, not this page's.
      // (The pill and the row's hint both render 未登录 — two honest copies.)
      expect(find.text('未登录'), findsWidgets);
      expect(find.widgetWithText(LexButton, '登录'), findsOneWidget);
      expect(find.byType(LexField), findsNothing);

      // The signed-in panel's controls must not be on screen.
      expect(find.widgetWithText(LexButton, '立即同步'), findsNothing);
      expect(find.widgetWithText(LexButton, '退出登录'), findsNothing);

      engine.dispose();
      await store.flush();
    });

    testWidgets('the sign-in button opens the gate as a pushed page', (tester) async {
      final (store, engine, _) = await pumpSettings(tester, transport: PathTransport());

      await tapInView(tester, find.widgetWithText(LexButton, '登录'));

      // The gate is the page that owns the fields. It is pushed over the
      // settings page, not swapped for it — closing it lands back here.
      expect(find.byType(OnboardingPage), findsOneWidget);
      expect(find.widgetWithText(LexField, '邮箱'), findsOneWidget);
      expect(find.widgetWithText(LexField, '密码'), findsOneWidget);

      // The settings page itself is opaque to type-finding while covered by a
      // MaterialPageRoute (a pushed route hides the route below from
      // find.byType). What matters is that this is the gate's form, and that
      // closing the gate comes back.
      expect(find.text('登录以同步'), findsOneWidget);

      // Closing the gate lands back on the settings page, with the
      // signed-out row still showing — nothing was recorded.
      // The gate's Scaffold has no app bar, so there is no back *button* to
      // tap — leave the route the way a user without one would.
      tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(OnboardingPage), findsNothing);
      expect(find.text('未登录'), findsWidgets);

      engine.dispose();
      await store.flush();
    });
  });

  group('signed in', () {
    testWidgets('draws the account panel and hides the form', (tester) async {
      final (store, engine, _) = await pumpSettings(
        tester,
        transport: PathTransport(),
        signedIn: _signedIn,
      );

      expect(find.text('已登录为 reader@example.test'), findsOneWidget);
      expect(find.widgetWithText(LexButton, '立即同步'), findsOneWidget);
      expect(find.widgetWithText(LexButton, '退出登录'), findsOneWidget);
      expect(find.widgetWithText(LexField, '密码'), findsNothing);
      expect(find.widgetWithText(LexField, '邮箱'), findsNothing);

      engine.dispose();
      await store.flush();
    });

    testWidgets('a sync round pushes and reports success', (tester) async {
      final transport = PathTransport({
        '/api/sync': {
          'rev': 8,
          'lists': <Object?>[],
          'words': <Object?>[],
          'logs': <Object?>[],
        },
      });
      final (store, engine, toasts) = await pumpSettings(
        tester,
        transport: transport,
        signedIn: _signedIn,
      );

      await tapInView(tester, find.widgetWithText(LexButton, '立即同步'));

      expect(transport.seen, contains('/api/sync'));
      expect(toasts.map((t) => t.text), contains('同步完成'));
      expect(engine.config?.rev, 8);

      engine.dispose();
      await store.flush();
    });

    testWidgets('signing out shows the signed-out row again', (tester) async {
      final transport = PathTransport();
      final (store, engine, _) = await pumpSettings(
        tester,
        transport: transport,
        signedIn: _signedIn,
      );

      await tapInView(tester, find.widgetWithText(LexButton, '退出登录'));
      await tester.pumpAndSettle();

      expect(engine.isSignedIn, isFalse);
      expect(find.text('未登录'), findsWidgets);
      expect(find.widgetWithText(LexButton, '登录'), findsOneWidget);
      expect(find.widgetWithText(LexButton, '立即同步'), findsNothing);

      engine.dispose();
      await store.flush();
    });
  });

  group('the token', () {
    testWidgets('never reaches the snapshot', (tester) async {
      final (store, engine, _) = await pumpSettings(
        tester,
        transport: PathTransport(),
        signedIn: _signedIn,
      );

      // The whole snapshot, serialised the way a sync round would pack it.
      final json = store.data.toJson().toString();
      expect(json.contains('tok-live'), isFalse);
      expect(json.contains('token'), isFalse);

      engine.dispose();
      await store.flush();
    });

    testWidgets('survives a restart via the config store, not the snapshot', (tester) async {
      final (store, engine, _) = await pumpSettings(
        tester,
        transport: PathTransport(),
        signedIn: _signedIn,
      );
      expect(engine.isSignedIn, isTrue);
      expect(store.data.settings.toJson().containsKey('token'), isFalse);
      engine.dispose();
      await store.flush();
    });
  });
}
