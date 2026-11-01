// The Supabase half of the account & sync section.
//
// Two things are worth pinning down here, and nothing else is:
//
//   1. **The key field appears only for a Supabase address.** It is a long
//      opaque string the user pastes out of a dashboard; showing it beside a
//      self-hosted server address would be an invitation to paste the key into
//      a server that has no idea what it is. It appears and disappears as the
//      address is typed.
//
//   2. **The key reaches the transport before the first auth call.** A sign-in
//      happens before any saved session exists, so the engine has to hand the
//      key over on the way in. If it did not, every Supabase sign-in would come
//      back 401 and read as "wrong password".
//
// The transport is a fake that records the order of what it was told; the engine
// and the page are real.

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

/// A transport that is *both* a [SyncTransport] and a [CredentialAware], the way
/// `BackendTransport` is, and that records credentials and requests in one
/// ordered log.
///
/// One log rather than two lists because the whole point of the priming test is
/// *ordering*: the key has to arrive before the request, and two lists would
/// only prove both happened.
class RecordingTransport implements SyncTransport, CredentialAware {
  final List<String> log = [];
  Object? reply;
  SyncHttpError? error;

  @override
  void useCredentials({required String anonKey, required String refreshToken}) {
    log.add('key:$anonKey');
  }

  @override
  void Function(Map<String, Object?> session)? onTokenMinted;

  @override
  Future<Object?> request(
    String server,
    String path, {
    String method = 'GET',
    Object? body,
    String? token,
  }) async {
    log.add('request:$path');
    if (error != null) throw error!;
    return reply ?? const <String, dynamic>{};
  }

  @override
  void close() {}
}

Future<(Store, SyncEngine, RecordingTransport)> pumpSync(
  WidgetTester tester, {
  SyncConfig? signedIn,
}) async {
  final store = Store(persistence: MemoryStore(), seed: seedData);
  await store.init();
  await store.flush();

  final configStore = MemorySyncConfigStore();
  if (signedIn != null) await configStore.save(signedIn);

  final transport = RecordingTransport();
  final engine = SyncEngine(
    store: store,
    configStore: configStore,
    transport: transport,
    interval: const Duration(hours: 1),
    soonDelay: const Duration(hours: 1),
    bootDelay: const Duration(hours: 1),
  );
  await engine.init();

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
  return (store, engine, transport);
}

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

Future<void> tapInView(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

const SyncConfig _supabaseSession = SyncConfig(
  server: 'https://abcdefghij.supabase.co',
  email: 'reader@example.test',
  token: 'tok-live',
  anonKey: 'anon-saved',
  refreshToken: 'refresh-saved',
);

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);
  setUp(() => debugSetSpeech(silentSpeech()));
  tearDown(() => debugSetSpeech(null));

  group('the project key field', () {
    testWidgets('is hidden for a self-hosted server', (tester) async {
      final (store, engine, _) = await pumpSync(tester);

      // The default address is the reference server, which has no notion of a
      // project key.
      expect(find.widgetWithText(LexField, 'Supabase anon key'), findsNothing);

      engine.dispose();
      await store.flush();
    });

    testWidgets('appears as the address turns into a Supabase one', (tester) async {
      final (store, engine, _) = await pumpSync(tester);

      await fill(tester, '服务器地址', 'https://abcdefghij.supabase.co');
      expect(find.widgetWithText(LexField, 'Supabase anon key'), findsOneWidget);

      // ...and goes away again if the user corrects the address back. A field
      // that only ever appears is a trap: the user cannot tell whether the key
      // they pasted is still in play.
      await fill(tester, '服务器地址', 'http://127.0.0.1:8787');
      expect(find.widgetWithText(LexField, 'Supabase anon key'), findsNothing);

      engine.dispose();
      await store.flush();
    });

    testWidgets('is prefilled from the session being signed out of', (tester) async {
      final (store, engine, _) = await pumpSync(tester, signedIn: _supabaseSession);

      // Sign out, which brings the form back with the saved address.
      await tapInView(tester, find.widgetWithText(LexButton, '退出登录'));

      final field = find.widgetWithText(LexField, 'Supabase anon key');
      expect(field, findsOneWidget);
      // The key survives the sign-out. It is 200-odd opaque characters; asking
      // for it again on every sign-in is enough friction to abandon sync.
      expect(
        find.descendant(of: field.first, matching: find.text('anon-saved')),
        findsOneWidget,
      );

      engine.dispose();
      await store.flush();
    });
  });

  group('signing in to Supabase', () {
    Future<void> signIn(WidgetTester tester) async {
      await fill(tester, '服务器地址', 'https://abcdefghij.supabase.co');
      await fill(tester, 'Supabase anon key', 'anon-typed');
      await fill(tester, '邮箱', 'reader@example.test');
      await fill(tester, '密码', 'correct horse');
      await tapInView(tester, find.widgetWithText(LexButton, '登录'));
    }

    testWidgets('hands the key over before the request goes out', (tester) async {
      final (store, engine, transport) = await pumpSync(tester);
      // What `SupabaseTransport` returns after a successful grant: already
      // mapped out of GoTrue's snake_case, because the engine speaks the sync
      // protocol's vocabulary regardless of which backend is behind it.
      transport.reply = const <String, Object?>{
        'token': 'tok',
        'refreshToken': 'refresh-from-gotrue',
        'email': 'reader@example.test',
      };

      await signIn(tester);

      final keyAt = transport.log.indexOf('key:anon-typed');
      final loginAt = transport.log.indexOf('request:/api/auth/login');
      expect(keyAt, isNonNegative, reason: 'the key was never handed over');
      expect(loginAt, isNonNegative, reason: 'no sign-in request went out');
      expect(
        keyAt,
        lessThan(loginAt),
        reason: 'the key must arrive before the request, or the gateway 401s '
            'and the user is told their password is wrong',
      );

      // And it is persisted with the session, so the next launch can refresh
      // without asking the user to paste it again.
      expect(engine.config?.anonKey, 'anon-typed');

      engine.dispose();
      await store.flush();
    });

    testWidgets('keeps the refresh token, never the password', (tester) async {
      final (store, engine, transport) = await pumpSync(tester);
      transport.reply = const <String, Object?>{
        'token': 'tok',
        'refreshToken': 'refresh-from-gotrue',
        'email': 'reader@example.test',
      };

      await signIn(tester);

      final config = engine.config!;
      expect(config.refreshToken, 'refresh-from-gotrue');
      // An expired access token is mended with the refresh token; a stored
      // password would be a second, worse copy of the user's secret.
      expect(config.toJson().toString().contains('correct horse'), isFalse);
      // And the key belongs to the session file, not to the snapshot: the
      // snapshot's settings are packed up and pushed to every device.
      expect(store.data.toJson().toString().contains('anon-typed'), isFalse);

      engine.dispose();
      await store.flush();
    });
  });
}
