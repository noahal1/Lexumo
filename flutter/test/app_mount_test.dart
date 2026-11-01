// Mounts the REAL `LexumoApp` — the same widget tree `main()` builds — and
// proves the app paints and takes taps.
//
// This file exists because of a shipped bug (0.2.4+5): the app opened on the
// home page and every tap did nothing. The cause was in `main.dart`, not in any
// page: `ToastHost` was wrapped AROUND `MaterialApp` instead of placed in its
// `builder`. `ToastHost` draws a bare `Stack`, a `Stack` resolves its default
// `AlignmentDirectional.topStart` through the ambient `Directionality`, and
// `MaterialApp` is what installs that — so above it there was none and the very
// first frame threw
//
//   Null check operator used on a null value
//   #0 AlignmentDirectional.resolve (painting/alignment.dart:651)
//   #2 RenderStack.performLayout (rendering/stack.dart:684)
//
// Nothing was painted; the window kept showing the previous frame, which reads
// as "stuck on the home page, taps do nothing".
//
// **Why no other test caught it**: every other widget test pumps `AppShell`
// directly (or `ToastHost(child: MaterialApp(...))`), i.e. with the toast host
// already inside a `MaterialApp`. Those trees are correct, so they could not
// see the bug. Only a test that mounts `LexumoApp` itself — the widget whose
// `build` holds the nesting — can.
//
// So the assertions here are deliberately structural (where `ToastHost` sits)
// AND behavioural (a tab tap actually navigates), because the failure mode was
// invisible to both "did it throw" checks in isolation and to any test that
// re-assembles the tree by hand.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/data/models/sync_config.dart';
import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/data/repositories/sync_engine.dart';
import 'package:lexumo/data/repositories/update_service.dart';
import 'package:lexumo/data/services/app_installer.dart';
import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/data/services/sync_transport.dart';
import 'package:lexumo/domain/models/seed.dart';
import 'package:lexumo/main.dart';
import 'package:lexumo/ui/core/widgets/toast.dart';
import 'package:lexumo/ui/features/home/views/home_page.dart';
import 'package:lexumo/ui/features/quiz/views/quiz_page.dart';
import 'package:lexumo/ui/features/words/views/words_page.dart';

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

/// A transport that fails every request immediately, so the sync engine settles
/// instead of sitting on a timeout. The engine is signed out in these tests, so
/// no request is even attempted.
class _DeadSyncTransport implements SyncTransport {
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

/// Everything `main()` wires up, with the I/O edges replaced.
///
/// The store uses an in-memory persistence and `saveDelayMs: 0` so no debounce
/// `Timer` outlives the test body; the sync engine is stopped by [LexumoApp]'s
/// own `dispose` when the tree is unmounted.
class _Harness {
  _Harness(this.store, this.sync, this.update);

  final Store store;
  final SyncEngine sync;
  final UpdateService update;

  static Future<_Harness> create() async {
    final store = Store(
      persistence: MemoryStore(),
      seed: seedData,
      saveDelayMs: 0,
    );
    await store.init();

    final sync = SyncEngine(
      store: store,
      configStore: MemorySyncConfigStore(),
      transport: _DeadSyncTransport(),
    );
    await sync.init();

    final update = UpdateService(
      // `none` means "nothing about updates is actionable here", which keeps
      // the post-frame check off the network entirely.
      installer: FakeAppInstaller(support: InstallSupport.none),
      network: _DeadUpdateNetwork(),
      stateStore: MemoryUpdateStateStore(),
      downloadDir: Directory.systemTemp,
      manifestUrl: Uri.parse('https://example.invalid/update.json'),
      now: DateTime.now,
    );
    await update.load();

    return _Harness(store, sync, update);
  }
}

/// Pumps the real app at a phone width and settles every entry animation.
Future<_Harness> _pumpApp(
  WidgetTester tester, {
  Size size = const Size(411, 866),
}) async {
  final harness = await _Harness.create();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    LexumoApp(store: harness.store, sync: harness.sync, update: harness.update),
  );
  await tester.pumpAndSettle();
  return harness;
}

/// Unmounts the tree so `LexumoApp.dispose` stops the sync engine's periodic
/// timers. Without this the test ends with `Pending timers` and a confusing
/// failure that has nothing to do with what was being tested.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  group('the app mounts', () {
    testWidgets('paints its first frame without throwing', (tester) async {
      await _pumpApp(tester);

      // The whole point: `main.dart`'s nesting must produce a laid-out tree.
      // Before the fix this was `Null check operator used on a null value`
      // from `AlignmentDirectional.resolve`.
      expect(tester.takeException(), isNull);

      // And something is actually on screen — "no exception" alone was not
      // enough to notice the frozen app, because a failed first frame throws
      // once and then simply paints nothing.
      expect(find.byType(HomePage), findsOneWidget);

      await _unmount(tester);
    });

    testWidgets('the toast host sits inside the material app', (tester) async {
      await _pumpApp(tester);

      // The structural invariant the fix established. `ToastHost` may live in
      // `MaterialApp.builder` (inside) but never above `MaterialApp`, because
      // its `Stack` needs the `Directionality` the app installs.
      final toast = find.byType(ToastHost);
      expect(toast, findsOneWidget);
      expect(
        find.ancestor(of: toast, matching: find.byType(MaterialApp)),
        findsOneWidget,
        reason: 'ToastHost must be a descendant of MaterialApp, never its '
            'ancestor: its bare Stack resolves AlignmentDirectional through '
            'the Directionality that MaterialApp provides.',
      );

      await _unmount(tester);
    });
  });

  group('the mounted app takes taps', () {
    testWidgets('a tab tap navigates away from the home page', (tester) async {
      await _pumpApp(tester);
      expect(find.byType(HomePage), findsOneWidget);

      // `测验` appears as a tab label and nowhere else on the home page (the
      // dashboard's own button reads `开始测验`, a different string).
      await tester.tap(find.text('测验'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(QuizPage), findsOneWidget);
      expect(find.byType(HomePage), findsNothing);

      await _unmount(tester);
    });

    testWidgets('a second tab tap reaches a different page', (tester) async {
      await _pumpApp(tester);

      await tester.tap(find.text('词库'));
      await tester.pumpAndSettle();

      expect(find.byType(WordsPage), findsOneWidget);

      await _unmount(tester);
    });
  });
}
