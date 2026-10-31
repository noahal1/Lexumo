// The account & sync section of the settings page.
//
// What is worth testing here is not "the buttons exist" but the three states the
// user can be in and the one thing that must never leak:
//
//   1. **Signed out shows the form, signed in shows the account.** These are two
//      different panels, and drawing the wrong one either hides the only way in
//      or offers a sign-in form to someone already signed in.
//   2. **A failed sign-in reports why, in place.** A toast disappears before the
//      user can fix the field it refers to, so the message has to sit next to the
//      form. The wrong *reason* is worse than no reason: "wrong password" for a
//      server that is simply down sends the user to reset a password that was
//      fine.
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
import 'package:lexumo/data/snapshot_store.dart';
import 'package:lexumo/data/store.dart';
import 'package:lexumo/data/sync_config.dart';
import 'package:lexumo/data/sync_engine.dart';
import 'package:lexumo/data/sync_transport.dart';
import 'package:lexumo/design/theme.dart';
import 'package:lexumo/design/tokens.dart';
import 'package:lexumo/domain/seed.dart';
import 'package:lexumo/i18n/i18n.dart';
import 'package:lexumo/pages/settings_page.dart';
import 'package:lexumo/platform/tts.dart';
import 'package:lexumo/ui/controls.dart';

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

/// Types into the LexInput sitting under the [label] LexField.
///
/// `find.widgetWithText(LexField, label)` finds the field, but the editable is a
/// descendant, so the text goes to the first `EditableText` inside it.
Future<void> fill(WidgetTester tester, String label, String text) async {
  final field = find.widgetWithText(LexField, label).first;
  await tester.ensureVisible(field);
  await tester.pumpAndSettle();
  await tester.enterText(
    find.descendant(of: field, matching: find.byType(EditableText)).first,
    text,
  );
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
    testWidgets('draws the form and no account panel', (tester) async {
      final (store, engine, _) = await pumpSettings(tester, transport: PathTransport());

      expect(find.widgetWithText(LexField, '服务器地址'), findsOneWidget);
      expect(find.widgetWithText(LexField, '邮箱'), findsOneWidget);
      expect(find.widgetWithText(LexField, '密码'), findsOneWidget);
      expect(find.widgetWithText(LexButton, '登录'), findsOneWidget);
      expect(find.widgetWithText(LexButton, '创建账号'), findsOneWidget);

      // The signed-in panel's controls must not be on screen.
      expect(find.widgetWithText(LexButton, '立即同步'), findsNothing);
      expect(find.widgetWithText(LexButton, '退出登录'), findsNothing);

      // The old "this build cannot sync" notice is gone for good.
      expect(find.textContaining('暂不支持同步'), findsNothing);

      engine.dispose();
      await store.flush();
    });

    testWidgets('the server field starts at the default', (tester) async {
      final (store, engine, _) = await pumpSettings(tester, transport: PathTransport());
      final input = tester.widget<EditableText>(
        find.descendant(
          of: find.widgetWithText(LexField, '服务器地址').first,
          matching: find.byType(EditableText),
        ).first,
      );
      expect(input.controller.text, kDefaultServer);
      engine.dispose();
      await store.flush();
    });

    testWidgets('a successful sign-in swaps the form for the account', (tester) async {
      final transport = PathTransport({
        '/api/auth/login': {'token': 'tok-new', 'email': 'reader@example.test'},
      });
      final (store, engine, toasts) = await pumpSettings(tester, transport: transport);

      await fill(tester, '邮箱', 'reader@example.test');
      await fill(tester, '密码', 'correct horse');
      await tapInView(tester, find.widgetWithText(LexButton, '登录'));

      expect(transport.seen, contains('/api/auth/login'));
      expect(engine.isSignedIn, isTrue);
      // The token the server issued, not the password.
      expect(engine.config?.token, 'tok-new');
      expect(toasts.map((t) => t.text), contains('同步完成'));

      await tester.pumpAndSettle();
      expect(find.widgetWithText(LexButton, '立即同步'), findsOneWidget);
      expect(find.widgetWithText(LexButton, '退出登录'), findsOneWidget);
      expect(find.widgetWithText(LexField, '密码'), findsNothing);

      engine.dispose();
      await store.flush();
    });

    testWidgets('a bad password says so next to the form', (tester) async {
      final transport = PathTransport.failing(const SyncHttpError(SyncError.badCredentials, 401));
      final (store, engine, _) = await pumpSettings(tester, transport: transport);

      await fill(tester, '邮箱', 'reader@example.test');
      await fill(tester, '密码', 'nope');
      await tapInView(tester, find.widgetWithText(LexButton, '登录'));

      // The form is still there, and the reason is on the page — not only in a
      // toast that will vanish.
      expect(find.widgetWithText(LexField, '密码'), findsOneWidget);
      expect(find.text('邮箱或密码不正确'), findsOneWidget);
      expect(engine.isSignedIn, isFalse);

      engine.dispose();
      await store.flush();
    });

    testWidgets('an unreachable server is not reported as a bad password', (tester) async {
      final transport = PathTransport.failing(const SyncHttpError(SyncError.offline, 0));
      final (store, engine, _) = await pumpSettings(tester, transport: transport);

      await fill(tester, '邮箱', 'reader@example.test');
      await fill(tester, '密码', 'correct horse');
      await tapInView(tester, find.widgetWithText(LexButton, '登录'));

      expect(find.text('无法连接服务器，请检查网络与地址'), findsOneWidget);
      expect(find.text('邮箱或密码不正确'), findsNothing);

      engine.dispose();
      await store.flush();
    });

    testWidgets('testing the connection reports both outcomes', (tester) async {
      final ok = PathTransport({'/api/health': {'ok': true}});
      final (store, engine, toasts) = await pumpSettings(tester, transport: ok);
      await tapInView(tester, find.widgetWithText(LexButton, '测试连接'));
      expect(toasts.last.text, '连接正常');
      engine.dispose();
      await store.flush();

      final bad = PathTransport.failing(const SyncHttpError(SyncError.offline, 0));
      final (store2, engine2, toasts2) = await pumpSettings(tester, transport: bad);
      await tapInView(tester, find.widgetWithText(LexButton, '测试连接'));
      expect(toasts2.last.text, '无法连接服务器');
      engine2.dispose();
      await store2.flush();
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

    testWidgets('signing out returns to the form', (tester) async {
      final transport = PathTransport();
      final (store, engine, _) = await pumpSettings(
        tester,
        transport: transport,
        signedIn: _signedIn,
      );

      await tapInView(tester, find.widgetWithText(LexButton, '退出登录'));
      await tester.pumpAndSettle();

      expect(engine.isSignedIn, isFalse);
      expect(find.widgetWithText(LexField, '密码'), findsOneWidget);
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
