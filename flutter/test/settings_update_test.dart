// The update surface on the settings page: the card, and the sheet it opens.
//
// Everything below the UI is already covered by `update_service_test.dart`
// against fakes for the network, the installer and the disk. What this file
// exists for is the seam the service cannot see: whether the page *draws* the
// state it is handed, and whether each phase offers the one action that makes
// sense — a check when there is nothing, a download when there is a release, an
// install when the file is ready, and no "later" on a release that is required.
//
// Those are exactly the kind of facts a refactor breaks silently. The service
// can keep returning `ready` while the button next to it says "check for
// updates", and no unit test would notice.
//
// Two rules shape how this is written, both learned by watching it hang:
//
//   · **No real file I/O inside `testWidgets`.** The test body runs in a
//     fake-async zone, and a `dart:io` future created there never completes:
//     the zone's clock never reaches the point where the real event loop would
//     answer. `check()` is safe because every await in it resolves
//     synchronously (a fake installer, an in-memory state store); `download()`
//     is not, because it writes a file. So the download phases are reached by
//     assigning `service.state.value` directly — which is also the sharper
//     test, since it isolates rendering from the machinery.
//   · **Find the card by key, not by button label.** The label is expected to
//     change; the card is the fixed point.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Card;
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/app/scope.dart';
import 'package:lexumo/app/update_scope.dart';
import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/data/models/sync_config.dart';
import 'package:lexumo/data/repositories/sync_engine.dart';
import 'package:lexumo/data/services/sync_transport.dart';
import 'package:lexumo/data/repositories/update_service.dart';
import 'package:lexumo/ui/core/theme.dart';
import 'package:lexumo/ui/core/tokens.dart';
import 'package:lexumo/domain/models/seed.dart';
import 'package:lexumo/domain/models/update_manifest.dart';
import 'package:lexumo/domain/models/version.dart';
import 'package:lexumo/ui/core/i18n/i18n.dart';
import 'package:lexumo/ui/features/settings/views/settings_page.dart';
import 'package:lexumo/data/services/app_installer.dart';
import 'package:lexumo/data/services/tts.dart';
import 'package:lexumo/ui/core/widgets/controls.dart';
import 'package:lexumo/ui/core/widgets/lex_icon.dart';
// `settings_page.dart` also hides Material's Card in favour of the app's own,
// so the two trees agree on what a card is.
import 'package:lexumo/ui/core/widgets/widgets.dart' show ProgressBar;

import 'support/fake_tts.dart';

/// A transport that is never reached: every request fails immediately, so the
/// sync engine settles instead of waiting on a timeout.
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

/// Serves one manifest text. Counts requests so a test can prove the card's
/// button actually asked rather than flipping a local flag.
class _Net implements UpdateNetwork {
  _Net({this.manifest = ''});

  String manifest;
  int fetched = 0;
  bool closed = false;

  @override
  Future<String> fetchText(Uri uri) async {
    fetched++;
    return manifest;
  }

  @override
  Future<int> download(
    Uri uri,
    File destination, {
    void Function(int received, int? total)? onProgress,
    FutureOr<bool> Function()? onCancel,
  }) async {
    // Never reached by these tests; see the file comment on real I/O.
    throw const UpdateNetworkException('offline');
  }

  @override
  void close() => closed = true;
}

const String _kSha =
    '1e10ba560383b17472b4cf72fef8f9e76c66815a3e6ae8c5a9b0c5e696b0bdf8';

String _manifestJson({
  String version = '0.2.0',
  int build = 2,
  int? minSupportedBuild,
}) {
  return '''
{
  "version": "$version",
  "build": $build,
  "apk": {
    "url": "https://example.test/lexumo.apk",
    "size": 9,
    "sha256": "$_kSha"
  }${minSupportedBuild == null ? '' : ',\n  "minSupportedBuild": $minSupportedBuild'}
}
''';
}

ReleaseManifest _manifest({int build = 2, String version = '0.2.0'}) =>
    ReleaseManifest.parse(_manifestJson(version: version, build: build))!;

/// Pumps the settings page with a mounted [UpdateService].
///
/// Returns the service so a test can drive it and then assert on the page; the
/// page itself only ever calls the service, never the network.
Future<({UpdateService service, FakeAppInstaller installer, SyncEngine engine, _Net net})>
    pumpWithUpdates(
  WidgetTester tester, {
  String manifest = '',
  bool installable = true,
  double width = 411,
  double height = 866,
  InstallSupport support = InstallSupport.inApp,
  Uri? manifestUrl,
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

  final installer = FakeAppInstaller(installable: installable, support: support);
  final net = _Net(manifest: manifest);
  final service = UpdateService(
    installer: installer,
    network: net,
    stateStore: MemoryUpdateStateStore(),
    // Never touched: these tests render phases and drive `check()`. Only
    // `download()` writes here, and it is out of scope for the reason in the
    // file header.
    downloadDir: Directory('unused'),
    manifestUrl: manifestUrl ?? Uri.parse('https://example.test/update.json'),
    now: () => DateTime.utc(2026, 3, 1, 12),
  );
  await service.load();
  addTearDown(service.dispose);

  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    StoreScope(
      notifier: StoreNotifier(store),
      child: SyncScope(
        notifier: SyncStatusNotifier(engine),
        child: UpdateScope(
          notifier: UpdateNotifier(service),
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
    ),
  );
  await tester.pumpAndSettle();
  return (service: service, installer: installer, engine: engine, net: net);
}

Finder get _updateCard => find.byKey(const ValueKey('update-card'));

Finder get _cardButtons =>
    find.descendant(of: _updateCard, matching: find.byType(LexButton));

/// Scrolls the card's button into view, then taps it.
///
/// The settings page runs ~2700dp tall, so the card sits far below the fold at
/// a phone viewport. Tapping without this does nothing at all — and Flutter
/// only warns, which is how a passing-looking test can prove nothing.
Future<void> _tapCard(WidgetTester tester) async {
  final button = _cardButtons;
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

/// The one button in the card carrying [icon].
///
/// The label changes with the phase by design, so a finder keyed on text would
/// break exactly when the behaviour under test changes; the icon is the part
/// that says *which action this is*.
LexButton _buttonByIcon(WidgetTester tester, String icon) {
  final matches =
      tester.widgetList<LexButton>(_cardButtons).where((b) => b.icon == icon).toList();
  expect(matches, hasLength(1), reason: 'expected one card button with icon $icon');
  return matches.single;
}

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);
  setUp(() => debugSetSpeech(silentSpeech()));
  tearDown(() => debugSetSpeech(null));

  group('the update card', () {
    testWidgets('names the running build before any check has run', (
      WidgetTester tester,
    ) async {
      final h = await pumpWithUpdates(tester);

      // FakeAppInstaller defaults to 0.1.0 build 1 — the page must print what
      // the platform reported, not a literal typed into the widget.
      expect(
        find.descendant(of: _updateCard, matching: find.textContaining('0.1.0')),
        findsOneWidget,
      );

      // And nothing has been asked of the network: a settings page has to be
      // readable offline, and the boot-time check lives in the shell, not here.
      expect(h.net.fetched, 0);

      h.engine.dispose();
    });

    testWidgets('the card opens the sheet, and the sheet is what asks', (
      WidgetTester tester,
    ) async {
      final h = await pumpWithUpdates(tester);

      final before = _buttonByIcon(tester, Ic.refresh);
      expect(before.kind, BtnKind.normal, reason: 'no release to install yet');

      // The card's button opens the sheet; it does not itself go to the
      // network. A page the user opened to change the theme must not start a
      // request just because its row was touched.
      await _tapCard(tester);
      expect(find.byType(Dialog), findsOneWidget);
      expect(h.net.fetched, 0);

      await tester.tap(find.descendant(
        of: find.byType(Dialog),
        matching: find.byWidgetPredicate(
          (w) => w is LexButton && w.icon == Ic.refresh,
        ),
      ));
      await tester.pumpAndSettle();

      expect(h.net.fetched, 1);

      h.engine.dispose();
    });

    testWidgets('a found release turns the action primary and names it', (
      WidgetTester tester,
    ) async {
      final h = await pumpWithUpdates(tester, manifest: _manifestJson());

      await h.service.check(force: true);
      await tester.pumpAndSettle();

      expect(
        find.descendant(of: _updateCard, matching: find.textContaining('0.2.0')),
        findsOneWidget,
      );

      // Downloading a release is the one thing on this page worth drawing
      // attention to, so it is the one primary button.
      final button = _buttonByIcon(tester, Ic.download);
      expect(button.kind, BtnKind.primary);
      expect(button.onPressed, isNotNull);

      h.engine.dispose();
    });

    testWidgets('a check in flight disables the button instead of lying', (
      WidgetTester tester,
    ) async {
      final h = await pumpWithUpdates(tester);

      // Stuck mid-check: the phase the service reports while a request is out.
      h.service.state.value =
          h.service.state.value.copyWith(phase: UpdatePhase.checking);
      await tester.pumpAndSettle();

      final button = _buttonByIcon(tester, Ic.refresh);
      expect(
        button.onPressed,
        isNull,
        reason: 'a live-looking button that does nothing is the worse lie',
      );

      h.engine.dispose();
    });

    testWidgets('a download in progress shows a bar and a cancel', (
      WidgetTester tester,
    ) async {
      final h = await pumpWithUpdates(tester);

      h.service.state.value = UpdateState(
        phase: UpdatePhase.downloading,
        current: ReleaseVersion(name: SemVer(0, 1, 0), build: 1),
        available: UpdateAvailable(
          current: ReleaseVersion(name: SemVer(0, 1, 0), build: 1),
          manifest: _manifest(),
          required: false,
        ),
        progress: 0.42,
        receivedBytes: 8600000,
        totalBytes: 20462854,
      );
      await tester.pumpAndSettle();

      expect(
        find.descendant(of: _updateCard, matching: find.byType(ProgressBar)),
        findsOneWidget,
      );

      h.engine.dispose();
    });

    testWidgets('a ready install is offered, and installing is the user\'s call', (
      WidgetTester tester,
    ) async {
      final h = await pumpWithUpdates(tester);

      h.service.state.value = UpdateState(
        phase: UpdatePhase.ready,
        current: ReleaseVersion(name: SemVer(0, 1, 0), build: 1),
        available: UpdateAvailable(
          current: ReleaseVersion(name: SemVer(0, 1, 0), build: 1),
          manifest: _manifest(),
          required: false,
        ),
        progress: 1,
        file: File('lexumo-0.2.0-2.apk'),
      );
      await tester.pumpAndSettle();

      expect(_buttonByIcon(tester, Ic.download).kind, BtnKind.primary);
      // Downloading is not installing: nothing has handed the file to the
      // platform yet, and it must not happen without a tap.
      expect(h.installer.installed, isEmpty);

      h.engine.dispose();
    });

    testWidgets('a failed check says what happened, not that it is broken', (
      WidgetTester tester,
    ) async {
      final h = await pumpWithUpdates(tester);

      // A check that could not reach the server is silent in the state — the
      // card falls back to naming the build rather than shouting. Only a
      // *download* failure earns a retry, because that is the one the user
      // started.
      h.service.state.value = h.service.state.value.copyWith(phase: UpdatePhase.idle);
      await tester.pumpAndSettle();

      expect(
        find.descendant(of: _updateCard, matching: find.textContaining('0.1.0')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: _updateCard, matching: find.textContaining('重试')),
        findsNothing,
      );

      h.engine.dispose();
    });

    // The reason code decides which sentence appears, and the two places that
    // draw it (this row and the sheet) must agree. The row used to hardcode the
    // offline sentence for every failure, so a bad digest sent the user to check
    // their Wi-Fi — invisible from the service, which still said `digest`.
    testWidgets('each failure reason draws its own sentence', (
      WidgetTester tester,
    ) async {
      final h = await pumpWithUpdates(tester);

      const cases = <String, String>{
        'offline': '没能连上更新服务器',
        'digest': '与发布记录不一致',
        'signature': '签名与本机版本不一致',
        'space': '设备空间不足',
        'storage': '没能写入设备',
        'unsupported': '不支持应用内更新',
        'permission': '系统不允许安装',
      };

      for (final entry in cases.entries) {
        h.service.state.value = h.service.state.value.copyWith(
          phase: UpdatePhase.failed,
          reason: entry.key,
        );
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: _updateCard, matching: find.textContaining(entry.value)),
          findsOneWidget,
          reason: 'reason "${entry.key}" should say "${entry.value}"',
        );
      }

      h.engine.dispose();
    });
  });

  group('the update sheet', () {
    testWidgets('a required release hides the way out', (WidgetTester tester) async {
      final h = await pumpWithUpdates(
        tester,
        manifest: _manifestJson(minSupportedBuild: 5),
      );

      await h.service.check(force: true);
      await tester.pumpAndSettle();

      await _tapCard(tester);

      // A release the user cannot skip must not offer to be postponed; that
      // would be the app arguing with its own floor.
      expect(find.text('稍后'), findsNothing);
      expect(find.textContaining('下载'), findsWidgets);

      h.engine.dispose();
    });

    testWidgets('a desktop build is told to use the releases page', (
      WidgetTester tester,
    ) async {
      // Windows holds its own executable open, so an in-place install cannot
      // work. Saying so beats a button that opens a folder and stops.
      final h = await pumpWithUpdates(
        tester,
        manifest: _manifestJson(),
        support: InstallSupport.downloadOnly,
      );

      await h.service.check(force: true);
      await tester.pumpAndSettle();

      await _tapCard(tester);

      // The sheet says where the build lives instead of offering an install it
      // cannot perform, and prints the URL so it can be copied.
      expect(find.textContaining('发布页'), findsWidgets);
      expect(
        find.textContaining('example.test'),
        findsWidgets,
        reason: 'the releases URL is shown so it can be copied',
      );

      h.engine.dispose();
    });

    testWidgets('the releases URL is derived from the manifest location', (
      WidgetTester tester,
    ) async {
      // The default manifest URL is a release *asset*; the page a person wants
      // is its parent. Derived rather than configured, so one URL stays the
      // only thing to change.
      final h = await pumpWithUpdates(
        tester,
        manifest: _manifestJson(),
        support: InstallSupport.downloadOnly,
        manifestUrl: Uri.parse(
          'https://github.com/noahal1/Lexumo/releases/latest/download/update.json',
        ),
      );

      await h.service.check(force: true);
      await tester.pumpAndSettle();

      await _tapCard(tester);

      expect(
        find.textContaining('https://github.com/noahal1/Lexumo/releases'),
        findsOneWidget,
      );
      expect(
        find.textContaining('/download/update.json'),
        findsNothing,
        reason: 'a person needs the page, not the asset behind it',
      );

      h.engine.dispose();
    });

    testWidgets('the release notes come from the manifest', (
      WidgetTester tester,
    ) async {
      final h = await pumpWithUpdates(
        tester,
        manifest: '''
{
  "version": "0.2.0",
  "build": 2,
  "notes": { "zh": "更快地打开词库。", "en": "Faster library opening." },
  "apk": {
    "url": "https://example.test/lexumo.apk",
    "size": 9,
    "sha256": "$_kSha"
  }
}
''',
      );

      await h.service.check(force: true);
      await tester.pumpAndSettle();

      await _tapCard(tester);

      // The zh-CN dictionary is the reference locale; the note is written once
      // at release time, not translated by the app.
      expect(find.textContaining('更快地打开词库'), findsOneWidget);

      h.engine.dispose();
    });
  });
}
