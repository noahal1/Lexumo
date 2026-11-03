// The first-run gate: the one screen that decides whether this device syncs.
//
// Three things are worth testing, and none of them is "the buttons exist":
//
//   1. **A fresh install lands on the gate, not on the library.** The bug this
//      screen fixes was the opposite: a new user opened the app, saw a demo
//      deck, and had no idea an account existed.
//   2. **Answering it hands the shell over, and the answer survives a restart.**
//      The record is a sidecar file, not a snapshot field, so it has to be
//      asserted against the file rather than against `store.data`.
//   3. **A failed sign-in writes nothing.** Recording "sync" before the server
//      accepted the session would leave a user whose password was mistyped in
//      an app that is configured to sync and silently is not — which is exactly
//      the state the gate exists to prevent. This is the assertion that keeps
//      the ordering inside `_submit` honest.
//
// The engine is real; only its transport is fake, so the assertions are about
// behaviour (a round happened, the session was adopted) rather than about the
// shape of a mock.
//
// `flutter analyze`/`flutter test` cannot run in this checkout, so the
// invariants that *can* be checked mechanically are checked by
// `tool/scan_i18n.cjs` (both languages, no dead keys) and by the bracket
// balance of this file.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/data/models/sync_config.dart';
import 'package:lexumo/data/repositories/onboarding_store.dart';
import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/data/repositories/sync_engine.dart';
import 'package:lexumo/data/repositories/update_service.dart';
import 'package:lexumo/data/services/app_installer.dart';
import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/data/services/sync_transport.dart';
import 'package:lexumo/domain/models/seed.dart';
import 'package:lexumo/main.dart';
import 'package:lexumo/ui/core/widgets/controls.dart';
import 'package:lexumo/ui/features/home/views/home_page.dart';
import 'package:lexumo/ui/features/onboarding/view_models/onboarding_view_model.dart';
import 'package:lexumo/ui/features/onboarding/views/onboarding_page.dart';

import 'support/fake_feedback.dart';

/// Answers every request from a table keyed by path prefix.
class PathTransport implements SyncTransport {
  PathTransport([Map<String, Object?>? replies, this.error])
      : replies = replies ?? const <String, Object?>{};

  /// Every request fails with [error].
  PathTransport.failing(SyncHttpError this.error)
      : replies = const <String, Object?>{};

  final Map<String, Object?> replies;
  final SyncHttpError? error;
  final List<String> seen = <String>[];

  @override
  Future<Object?> request(
    String server,
    String path, {
    String method = 'GET',
    Object? body,
    String? token,
  }) async {
    seen.add(path);
    final failure = error;
    if (failure != null) throw failure;
    for (final MapEntry<String, Object?> entry in replies.entries) {
      if (path.startsWith(entry.key)) return entry.value;
    }
    return const <String, dynamic>{};
  }

  @override
  void close() {}
}

/// An engine with the timers pushed out of reach, so every round in these tests
/// is one the test asked for.
SyncEngine buildEngine(Store store, SyncTransport transport) {
  return SyncEngine(
    store: store,
    configStore: MemorySyncConfigStore(),
    transport: transport,
    interval: const Duration(hours: 1),
    soonDelay: const Duration(hours: 1),
    bootDelay: const Duration(hours: 1),
  );
}

Future<Store> freshStore() async {
  // `saveDelayMs: 0` so no debounce timer outlives a widget test body.
  final Store store = Store(
    persistence: MemoryStore(),
    seed: seedData,
    saveDelayMs: 0,
  );
  await store.init();
  return store;
}

/// Never reached: `InstallSupport.none` short-circuits the check before any
/// request. Present only because `UpdateService` requires a network.
class _DeadUpdateNetwork implements UpdateNetwork {
  @override
  Future<String> fetchText(Uri url) async =>
      throw const UpdateNetworkException('offline');

  @override
  Future<int> download(
    Uri url,
    File destination, {
    void Function(int received, int? total)? onProgress,
    FutureOr<bool> Function()? onCancel,
  }) async =>
      throw const UpdateNetworkException('offline');

  @override
  void close() {}
}

/// Everything `main()` wires up, with the I/O edges replaced and the gate left
/// unanswered — the state a fresh install is in.
class _Harness {
  _Harness(this.store, this.sync, this.update, this.onboarding);

  final Store store;
  final SyncEngine sync;
  final UpdateService update;
  final OnboardingStore onboarding;

  static Future<_Harness> create({
    required SyncTransport transport,
    OnboardingChoice? choice,
  }) async {
    final Store store = await freshStore();
    final SyncEngine sync = buildEngine(store, transport);
    await sync.init();

    final UpdateService update = UpdateService(
      installer: FakeAppInstaller(support: InstallSupport.none),
      network: _DeadUpdateNetwork(),
      stateStore: MemoryUpdateStateStore(),
      downloadDir: Directory.systemTemp,
      manifestUrl: Uri.parse('https://example.invalid/update.json'),
      now: DateTime.now,
    );
    await update.load();

    return _Harness(
      store,
      sync,
      update,
      MemoryOnboardingStore(choice: choice),
    );
  }
}

/// Pumps the real app at a desktop width, where the gate's two panels sit side
/// by side and nothing has to be scrolled to be tapped.
Future<_Harness> pumpApp(
  WidgetTester tester, {
  required SyncTransport transport,
  OnboardingChoice? choice,
}) async {
  final _Harness harness = await _Harness.create(
    transport: transport,
    choice: choice,
  );
  tester.view.physicalSize = const Size(1100, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    LexumoApp(
      store: harness.store,
      sync: harness.sync,
      update: harness.update,
      onboarding: harness.onboarding,
    ),
  );
  await tester.pumpAndSettle();
  return harness;
}

/// Unmounts the tree so `LexumoApp.dispose` stops the engine's timers.
Future<void> unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

/// Types into the `LexInput` under the [label] `LexField`.
Future<void> fill(WidgetTester tester, String label, String text) async {
  final Finder field = find.widgetWithText(LexField, label).first;
  await tester.ensureVisible(field);
  await tester.pumpAndSettle();
  await tester.enterText(
    find.descendant(of: field, matching: find.byType(EditableText)).first,
    text,
  );
  await tester.pumpAndSettle();
}

Future<void> tapButton(WidgetTester tester, String label) async {
  final Finder button = find.widgetWithText(LexButton, label);
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  group('FileOnboardingStore', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('lexumo-onboarding');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    String pathIn(Directory dir) =>
        '${dir.path}${Platform.pathSeparator}onboarding.json';

    test('reports no answer before anything was written', () async {
      final FileOnboardingStore store = FileOnboardingStore(pathIn(dir));
      await store.load();
      expect(store.choice, isNull);
    });

    test('an answer survives a restart', () async {
      final String path = pathIn(dir);
      await FileOnboardingStore(path).complete(OnboardingChoice.local);

      // A second instance stands in for the next launch: the value has to come
      // off disk, not out of the object that wrote it.
      final FileOnboardingStore reopened = FileOnboardingStore(path);
      await reopened.load();
      expect(reopened.choice, OnboardingChoice.local);
    });

    test('records the sync answer too', () async {
      final String path = pathIn(dir);
      await FileOnboardingStore(path).complete(OnboardingChoice.sync);

      final FileOnboardingStore reopened = FileOnboardingStore(path);
      await reopened.load();
      expect(reopened.choice, OnboardingChoice.sync);
    });

    test('a truncated file reads as unanswered rather than throwing', () async {
      final String path = pathIn(dir);
      await File(path).writeAsString('{"choice": "lo');

      final FileOnboardingStore store = FileOnboardingStore(path);
      await store.load();
      expect(store.choice, isNull);
    });

    test('an unknown value reads as unanswered', () async {
      final String path = pathIn(dir);
      await File(path).writeAsString('{"choice": "maybe"}');

      final FileOnboardingStore store = FileOnboardingStore(path);
      await store.load();
      expect(store.choice, isNull);
    });
  });

  group('OnboardingViewModel', () {
    late Store store;
    late SyncEngine engine;
    late MemoryOnboardingStore onboarding;
    late FakeFeedback feedback;
    late int configured;
    late OnboardingViewModel vm;

    void build(SyncTransport transport) {
      engine = buildEngine(store, transport);
      onboarding = MemoryOnboardingStore();
      feedback = FakeFeedback();
      configured = 0;
      vm = OnboardingViewModel(
        feedback: feedback,
        onboarding: onboarding,
        engine: engine,
        onConfigured: () => configured++,
      );
    }

    setUp(() async {
      store = await freshStore();
    });

    tearDown(() async {
      vm.dispose();
      engine.dispose();
      await store.flush();
    });

    test('starts on the built-in server', () async {
      build(PathTransport());
      await engine.init();
      expect(vm.server, kDefaultServer);
      expect(vm.email, isEmpty);
      expect(vm.password, isEmpty);
      expect(vm.error, isNull);
      expect(vm.busy, isFalse);
    });

    test('an empty draft never reaches the server', () async {
      final PathTransport transport = PathTransport();
      build(transport);
      await engine.init();

      await vm.signIn();

      expect(transport.seen, isEmpty);
      expect(vm.error, SyncError.badCredentials);
      expect(onboarding.choice, isNull);
      expect(configured, 0);
      expect(vm.busy, isFalse);
    });

    test('a blank email is treated the same as an empty one', () async {
      final PathTransport transport = PathTransport();
      build(transport);
      await engine.init();

      vm.setEmail('   ');
      vm.setPassword('correct horse');
      await vm.signIn();

      expect(transport.seen, isEmpty);
      expect(vm.error, SyncError.badCredentials);
      expect(configured, 0);
    });

    test('a successful sign-in records the answer and hands over', () async {
      final PathTransport transport = PathTransport(<String, Object?>{
        '/api/auth/login': <String, Object?>{
          'token': 'tok-new',
          'email': 'reader@example.test',
        },
      });
      build(transport);
      await engine.init();

      vm.setEmail('reader@example.test');
      vm.setPassword('correct horse');
      await vm.signIn();
      // The post-sign-in pull is deliberately not awaited by the view model, so
      // let its microtasks run before asserting on the engine.
      await Future<void>.delayed(Duration.zero);

      expect(transport.seen, contains('/api/auth/login'));
      expect(engine.isSignedIn, isTrue);
      expect(engine.config?.token, 'tok-new');
      expect(onboarding.choice, OnboardingChoice.sync);
      expect(configured, 1);
      expect(vm.error, isNull);
      expect(vm.busy, isFalse);
    });

    test('a rejected password records nothing and stays put', () async {
      build(PathTransport.failing(const SyncHttpError(SyncError.badCredentials, 401)));
      await engine.init();

      vm.setEmail('reader@example.test');
      vm.setPassword('wrong');
      await vm.signIn();

      expect(vm.error, SyncError.badCredentials);
      expect(onboarding.choice, isNull, reason: 'a failed round must not mark '
          'the device as set up to sync');
      expect(configured, 0);
      expect(engine.isSignedIn, isFalse);
      expect(vm.busy, isFalse);
    });

    test('a dead server reports offline, not bad credentials', () async {
      build(PathTransport.failing(const SyncHttpError(SyncError.offline, 0)));
      await engine.init();

      vm.setEmail('reader@example.test');
      vm.setPassword('correct horse');
      await vm.signIn();

      expect(vm.error, SyncError.offline);
      expect(onboarding.choice, isNull);
      expect(configured, 0);
    });

    test('a thrown non-HTTP failure is reported as offline', () async {
      build(_ThrowingTransport());
      await engine.init();

      vm.setEmail('reader@example.test');
      vm.setPassword('correct horse');
      await vm.signIn();

      expect(vm.error, SyncError.offline);
      expect(configured, 0);
    });

    test('creating an account records the answer too', () async {
      final PathTransport transport = PathTransport(<String, Object?>{
        '/api/auth/register': <String, Object?>{
          'token': 'tok-fresh',
          'email': 'new@example.test',
        },
      });
      build(transport);
      await engine.init();

      vm.setEmail('new@example.test');
      vm.setPassword('correct horse');
      await vm.signUp();
      await Future<void>.delayed(Duration.zero);

      expect(transport.seen, contains('/api/auth/register'));
      expect(onboarding.choice, OnboardingChoice.sync);
      expect(configured, 1);
    });

    test('staying local records the answer without touching the server', () async {
      final PathTransport transport = PathTransport();
      build(transport);
      await engine.init();

      await vm.useLocal();

      expect(transport.seen, isEmpty);
      expect(onboarding.choice, OnboardingChoice.local);
      expect(configured, 1);
      expect(engine.isSignedIn, isFalse);
      expect(vm.busy, isFalse);
    });

    test('a saved session prefills the server field', () async {
      final MemorySyncConfigStore configStore = MemorySyncConfigStore();
      await configStore.save(
        const SyncConfig(
          server: 'http://example.test:9000',
          email: 'reader@example.test',
          token: 'tok-live',
        ),
      );
      engine = SyncEngine(
        store: store,
        configStore: configStore,
        transport: PathTransport(),
        interval: const Duration(hours: 1),
        soonDelay: const Duration(hours: 1),
        bootDelay: const Duration(hours: 1),
      );
      // Init first: the address lives on the engine's status, which `init`
      // publishes from the saved session. `main()` does the same before
      // `runApp`, so this ordering is the one the gate really sees.
      await engine.init();

      onboarding = MemoryOnboardingStore();
      feedback = FakeFeedback();
      configured = 0;
      vm = OnboardingViewModel(
        feedback: feedback,
        onboarding: onboarding,
        engine: engine,
        onConfigured: () => configured++,
      );

      expect(vm.server, 'http://example.test:9000');
    });

    test('a successful connection test says so', () async {
      build(PathTransport());
      await engine.init();

      await vm.testConnection();

      expect(feedback.toasts, hasLength(1));
      expect(feedback.toasts.single.text, '连接正常');
    });

    test('a failed connection test says so', () async {
      build(PathTransport.failing(const SyncHttpError(SyncError.offline, 0)));
      await engine.init();

      await vm.testConnection();

      expect(feedback.toasts.single.text, '无法连接服务器');
    });

    test('the Supabase key field appears only for a Supabase address', () async {
      build(PathTransport());
      await engine.init();

      expect(vm.isSupabase, isFalse);
      vm.setServer('https://abcdefg.supabase.co');
      expect(vm.isSupabase, isTrue);
    });
  });

  group('the gate', () {
    testWidgets('a fresh install opens on it, not on the library',
        (WidgetTester tester) async {
      await pumpApp(tester, transport: PathTransport());

      expect(tester.takeException(), isNull);
      expect(find.byType(OnboardingPage), findsOneWidget);
      expect(find.byType(HomePage), findsNothing);
      expect(find.text('先安顿好这台设备'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('a device that already answered opens on the library',
        (WidgetTester tester) async {
      await pumpApp(
        tester,
        transport: PathTransport(),
        choice: OnboardingChoice.local,
      );

      expect(find.byType(OnboardingPage), findsNothing);
      expect(find.byType(HomePage), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('staying local hands the shell over and records the answer',
        (WidgetTester tester) async {
      final _Harness harness = await pumpApp(tester, transport: PathTransport());

      await tapButton(tester, '仅本地使用');

      expect(harness.onboarding.choice, OnboardingChoice.local);
      expect(find.byType(OnboardingPage), findsNothing);
      expect(find.byType(HomePage), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('signing in hands the shell over and records sync',
        (WidgetTester tester) async {
      final _Harness harness = await pumpApp(
        tester,
        transport: PathTransport(<String, Object?>{
          '/api/auth/login': <String, Object?>{
            'token': 'tok-new',
            'email': 'reader@example.test',
          },
        }),
      );

      await fill(tester, '邮箱', 'reader@example.test');
      await fill(tester, '密码', 'correct horse');
      await tapButton(tester, '登录');

      expect(harness.onboarding.choice, OnboardingChoice.sync);
      expect(harness.sync.isSignedIn, isTrue);
      expect(find.byType(OnboardingPage), findsNothing);
      expect(find.byType(HomePage), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('a failed sign-in keeps the gate and says why',
        (WidgetTester tester) async {
      final _Harness harness = await pumpApp(
        tester,
        transport: PathTransport.failing(
          const SyncHttpError(SyncError.badCredentials, 401),
        ),
      );

      await fill(tester, '邮箱', 'reader@example.test');
      await fill(tester, '密码', 'wrong');
      await tapButton(tester, '登录');

      expect(find.byType(OnboardingPage), findsOneWidget);
      expect(find.byType(HomePage), findsNothing);
      expect(find.text('邮箱或密码不正确'), findsOneWidget);
      expect(harness.onboarding.choice, isNull);
      expect(harness.sync.isSignedIn, isFalse);

      await unmount(tester);
    });

    testWidgets('the server disclosure is folded away by default',
        (WidgetTester tester) async {
      await pumpApp(tester, transport: PathTransport());

      expect(find.widgetWithText(LexField, '服务器地址'), findsNothing);
      expect(find.widgetWithText(LexButton, '测试连接'), findsNothing);

      await tester.tap(find.text('服务器地址'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(LexField, '服务器地址'), findsOneWidget);
      expect(find.widgetWithText(LexButton, '测试连接'), findsOneWidget);

      await unmount(tester);
    });
  });
}

/// Throws something that is not a [SyncHttpError], to prove the view model's
/// catch-all maps it to "offline" rather than letting it escape.
class _ThrowingTransport implements SyncTransport {
  @override
  Future<Object?> request(
    String server,
    String path, {
    String method = 'GET',
    Object? body,
    String? token,
  }) async =>
      throw StateError('socket closed');

  @override
  void close() {}
}
