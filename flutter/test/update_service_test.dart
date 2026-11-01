// The update flow end to end, with no network and no device.
//
// Every collaborator is a fake: the manifest arrives from a map, the APK bytes
// from a string, the installer from a list of calls. What is *not* faked is the
// hashing — the digest of the downloaded file is computed by the real code, so
// these tests catch the mistake that matters most here (staging a file that does
// not match the manifest) and not merely "the fake was called".
//
// The four orderings pinned below, because each is a plausible regression:
//
//   · a check happens before any download,
//   · the digest is verified before the file is offered,
//   · a cancelled download leaves nothing behind,
//   · nothing claims the install succeeded — only a moved build number does.

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/data/update_service.dart';
import 'package:lexumo/domain/update_manifest.dart';
import 'package:lexumo/domain/version.dart';
import 'package:lexumo/platform/app_installer.dart';

/// Bytes of the fake APK, and their real digest.
const String kApkBody = 'PK\u0003\u0004 fake apk payload';
String get kApkHash => sha256.convert(kApkBody.codeUnits).toString();

/// Serves a manifest and an APK, and records what was asked for.
class FakeNetwork implements UpdateNetwork {
  FakeNetwork({
    this.manifestText,
    this.apkBody = kApkBody,
    this.failText,
    this.failDownload,
    this.gameOver,
  });

  String? manifestText;
  String apkBody;

  /// When set, [fetchText] throws with this reason instead of answering.
  String? failText;

  /// When set, [download] throws with this reason.
  String? failDownload;

  /// Lets a test hold a download open so cancellation can be observed.
  Completer<void>? gameOver;

  final List<Uri> fetched = <Uri>[];
  final List<Uri> downloaded = <Uri>[];
  int closed = 0;

  @override
  Future<String> fetchText(Uri url) async {
    fetched.add(url);
    if (failText != null) throw UpdateNetworkException(failText!);
    return manifestText!;
  }

  @override
  Future<int> download(
    Uri url,
    File destination, {
    void Function(int received, int? total)? onProgress,
    FutureOr<bool> Function()? onCancel,
  }) async {
    downloaded.add(url);
    if (failDownload != null) throw UpdateNetworkException(failDownload!);

    // Deliver in two chunks so [onProgress] is exercised the way a real socket
    // would: a single write would never show a partial state.
    final bytes = apkBody.codeUnits;
    final half = bytes.length ~/ 2;
    final sink = destination.openWrite();
    try {
      onProgress?.call(half, bytes.length);
      sink.add(bytes.sublist(0, half));
      if (gameOver != null) await gameOver!.future;
      if (onCancel != null && await onCancel()) {
        throw const UpdateNetworkException('cancelled');
      }
      sink.add(bytes.sublist(half));
      onProgress?.call(bytes.length, bytes.length);
    } finally {
      await sink.close();
    }
    return bytes.length;
  }

  @override
  void close() => closed++;
}

/// A manifest naming [build], with a correct digest for [kApkBody].
String manifestTextFor({
  String version = '0.2.0',
  int build = 2,
  int? minSupportedBuild,
  String? sha,
}) {
  final digest = sha ?? kApkHash;
  return '{"version":"$version","build":$build,'
      '"notes":{"zh":"修好了长词条的行距","en":"Fixed long-entry spacing"},'
      '${minSupportedBuild == null ? '' : '"minSupportedBuild":$minSupportedBuild,'}'
      '"apk":{"url":"https://example.test/a.apk","size":${kApkBody.codeUnits.length},'
      '"sha256":"$digest"}}';
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('lexumo-update-test');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  /// A service with a phone-shaped fake platform at build [build].
  UpdateService serviceWith(
    FakeNetwork network, {
    int build = 1,
    String version = '0.1.0',
    InstallSupport support = InstallSupport.inApp,
    InstallerOutcome outcome = const InstallerOutcome.launched(),
    bool installable = true,
    bool signatureMatches = true,
    UpdateStateStore? stateStore,
    DateTime? now,
  }) {
    return UpdateService(
      installer: FakeAppInstaller(
        support: support,
        info: AppBuildInfo(
          versionName: version,
          buildNumber: build,
          packageName: 'dev.lexumo.lexumo',
        ),
        installable: installable,
        signatureMatches: signatureMatches,
        outcome: outcome,
      ),
      network: network,
      stateStore: stateStore ?? MemoryUpdateStateStore(),
      downloadDir: Directory('${temp.path}${Platform.pathSeparator}updates'),
      manifestUrl: Uri.parse('https://example.test/update.json'),
      now: () => now ?? DateTime.utc(2026, 11, 3, 12),
    );
  }

  group('check', () {
    test('a higher build number is an available update', () async {
      final network = FakeNetwork(manifestText: manifestTextFor(build: 2));
      final service = serviceWith(network, build: 1);
      await service.load();

      final result = await service.check(force: true);

      expect(result, isA<UpdateAvailable>());
      final available = result as UpdateAvailable;
      expect(available.manifest.version.build, 2);
      expect(available.manifest.version.name, const SemVer(0, 2, 0));
      expect(available.required, isFalse);
      expect(available.target, '0.2.0');
      expect(service.state.value.phase, UpdatePhase.available);
      expect(network.fetched, hasLength(1));
    });

    test('the same build is not an update', () async {
      final network = FakeNetwork(manifestText: manifestTextFor(build: 1));
      final service = serviceWith(network, build: 1);
      await service.load();

      expect(await service.check(force: true), isA<UpdateUpToDate>());
      expect(service.state.value.phase, UpdatePhase.upToDate);
    });

    test('a newer name with the same build is not an update', () async {
      // The device would answer INSTALL_FAILED_VERSION_DOWNGRADE, so this must
      // never become an offer.
      final network = FakeNetwork(
        manifestText: manifestTextFor(version: '0.9.0', build: 1),
      );
      final service = serviceWith(network, build: 1, version: '0.1.0');
      await service.load();

      expect(await service.check(force: true), isA<UpdateUpToDate>());
      expect(network.downloaded, isEmpty);
    });

    test('an unreachable manifest is silence, not an error card', () async {
      final network = FakeNetwork(failText: 'offline');
      final service = serviceWith(network);
      await service.load();

      final result = await service.check(force: true);

      expect(result, isA<UpdateFailed>());
      expect((result as UpdateFailed).reason, 'offline');
      // The row must fall back to saying nothing rather than reporting a fault
      // the user did not ask about.
      expect(service.state.value.phase, UpdatePhase.idle);
      expect(service.state.value.reason, isNull);
    });

    test('a mangled manifest reports the document, not the network', () async {
      final network = FakeNetwork(manifestText: '{"version": "not-a-version"}');
      final service = serviceWith(network);
      await service.load();

      expect(
        (await service.check(force: true) as UpdateFailed).reason,
        'manifest',
      );
    });

    test('a fresh check is skipped unless forced', () async {
      final network = FakeNetwork(manifestText: manifestTextFor(build: 2));
      final service = serviceWith(network, build: 1);
      await service.load();

      await service.check(force: true);
      expect(network.fetched, hasLength(1));

      // Within the interval: no second request.
      await service.check();
      expect(network.fetched, hasLength(1));

      // Forced: asks again.
      await service.check(force: true);
      expect(network.fetched, hasLength(2));
    });

    test('a check becomes due again once the interval passes', () async {
      final store = MemoryUpdateStateStore(
        lastCheckAt: DateTime.utc(2026, 11, 3, 5).millisecondsSinceEpoch,
      );
      final network = FakeNetwork(manifestText: manifestTextFor(build: 2));
      final service = serviceWith(network, build: 1, stateStore: store);
      await service.load();

      // 12:00 - 05:00 is seven hours, past the six-hour interval.
      expect(await service.isCheckDue(), isTrue);
    });

    test('concurrent checks join the request in flight', () async {
      final network = FakeNetwork(manifestText: manifestTextFor(build: 2));
      final service = serviceWith(network, build: 1);
      await service.load();

      // Two widgets asking on mount is normal; two requests are not.
      await Future.wait([
        service.check(force: true),
        service.check(force: true),
        service.check(force: true),
      ]);
      expect(network.fetched, hasLength(1));
    });

    test('a dismissed release stays quiet, a required one does not', () async {
      final network = FakeNetwork(manifestText: manifestTextFor(build: 2));
      final store = MemoryUpdateStateStore();
      final service = serviceWith(network, build: 1, stateStore: store);
      await service.load();

      await service.check(force: true);
      await service.dismiss(
        ReleaseVersion.tryParse(name: '0.2.0', build: 2)!,
      );

      // Automatic check: dismissed, so nothing is offered.
      expect(await service.check(), isA<UpdateUpToDate>());

      // Below the floor, the same release is mandatory and "not now" is not an
      // option — an old build that can no longer reach the server must not be
      // left there by a dismissed dialog.
      final requiredNetwork = FakeNetwork(
        manifestText: manifestTextFor(build: 3, minSupportedBuild: 2),
      );
      final requiredService = serviceWith(
        requiredNetwork,
        build: 1,
        stateStore: MemoryUpdateStateStore(skippedBuild: 3),
      );
      await requiredService.load();
      final result = await requiredService.check();
      expect(result, isA<UpdateAvailable>());
      expect((result as UpdateAvailable).required, isTrue);
    });

    test('an unsupported platform says so instead of pretending', () async {
      final network = FakeNetwork(manifestText: manifestTextFor(build: 2));
      final service = serviceWith(network, support: InstallSupport.none);
      await service.load();

      expect(await service.check(force: true), isA<UpdateUnsupported>());
      expect(service.state.value.reason, 'unsupported');
      expect(network.fetched, isEmpty);
    });
  });

  group('download', () {
    test('stages a verified file and reports progress', () async {
      final network = FakeNetwork(manifestText: manifestTextFor(build: 2));
      final service = serviceWith(network, build: 1);
      await service.load();
      await service.check(force: true);

      final phases = <UpdatePhase>[];
      service.state.addListener(() => phases.add(service.state.value.phase));

      final file = await service.download();

      expect(file, isNotNull);
      expect(await file!.exists(), isTrue);
      expect(await file.readAsString(), kApkBody);
      expect(service.state.value.phase, UpdatePhase.ready);
      expect(service.state.value.file, file);
      // Progress reaches 1 only after verification, never before.
      expect(service.state.value.progress, 1);
      expect(phases, containsAllInOrder(<UpdatePhase>[
        UpdatePhase.downloading,
        UpdatePhase.verifying,
        UpdatePhase.ready,
      ]));
    });

    test('the staged file is named for its version', () async {
      final network = FakeNetwork(manifestText: manifestTextFor(build: 2));
      final service = serviceWith(network, build: 1);
      await service.load();
      await service.check(force: true);

      final file = await service.download();

      expect(file!.uri.pathSegments.last, 'lexumo-0.2.0-2.apk');
    });

    test('a digest mismatch is refused and the file removed', () async {
      // The manifest names the right length but the wrong digest: the file
      // arrived intact and is still not ours.
      final network = FakeNetwork(
        manifestText: manifestTextFor(build: 2, sha: 'f' * 64),
      );
      final service = serviceWith(network, build: 1);
      await service.load();
      await service.check(force: true);

      expect(await service.download(), isNull);
      expect(service.state.value.phase, UpdatePhase.failed);
      expect(service.state.value.reason, 'digest');
      expect(service.state.value.file, isNull);

      // Nothing installable is left in the staging folder.
      final leftovers = await service.downloadDir
          .list()
          .where((e) => e.path.toLowerCase().endsWith('.apk'))
          .toList();
      expect(leftovers, isEmpty);
    });

    test('a signature mismatch is refused before the installer is asked', () async {
      final network = FakeNetwork(manifestText: manifestTextFor(build: 2));
      final installer = FakeAppInstaller(signatureMatches: false);
      final service = UpdateService(
        installer: installer,
        network: network,
        stateStore: MemoryUpdateStateStore(),
        downloadDir: Directory('${temp.path}${Platform.pathSeparator}updates'),
        manifestUrl: Uri.parse('https://example.test/update.json'),
        now: () => DateTime.utc(2026, 11, 3, 12),
      );
      await service.load();
      await service.check(force: true);

      expect(await service.download(), isNull);
      expect(service.state.value.reason, 'signature');
      expect(installer.installed, isEmpty);
    });

    test('a network failure leaves the update retryable', () async {
      final network = FakeNetwork(
        manifestText: manifestTextFor(build: 2),
        failDownload: 'offline',
      );
      final service = serviceWith(network, build: 1);
      await service.load();
      await service.check(force: true);

      expect(await service.download(), isNull);
      expect(service.state.value.phase, UpdatePhase.failed);
      expect(service.state.value.reason, 'offline');
      // The offer survives: the sheet must keep showing "retry", which needs
      // the manifest still in hand.
      expect(service.state.value.available, isNotNull);
    });

    test('cancelling removes the partial file and keeps the offer', () async {
      final network = FakeNetwork(manifestText: manifestTextFor(build: 2));
      final gate = Completer<void>();
      network.gameOver = gate;
      final service = serviceWith(network, build: 1);
      await service.load();
      await service.check(force: true);

      final pending = service.download();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      service.cancel();
      gate.complete();

      expect(await pending, isNull);
      expect(service.state.value.phase, UpdatePhase.available);

      final staged = await service.downloadDir
          .list()
          .where((e) => e.path.toLowerCase().endsWith('.apk'))
          .toList();
      expect(staged, isEmpty);
    });

    test('a stale APK from an earlier attempt is swept away', () async {
      final network = FakeNetwork(manifestText: manifestTextFor(build: 2));
      final service = serviceWith(network, build: 1);
      await service.load();
      await service.check(force: true);

      await service.downloadDir.create(recursive: true);
      final stale = File(
        '${service.downloadDir.path}${Platform.pathSeparator}lexumo-0.1.0-1.apk',
      );
      await stale.writeAsString('old');
      // A non-APK is left alone: the folder is the app's cache, and this class
      // has no business deleting files it did not stage.
      final other = File(
        '${service.downloadDir.path}${Platform.pathSeparator}notes.txt',
      );
      await other.writeAsString('keep');

      await service.download();

      expect(await stale.exists(), isFalse);
      expect(await other.exists(), isTrue);
    });

    test('downloading before a check does nothing', () async {
      final network = FakeNetwork(manifestText: manifestTextFor(build: 2));
      final service = serviceWith(network, build: 1);
      await service.load();

      expect(await service.download(), isNull);
      expect(network.downloaded, isEmpty);
    });
  });

  group('install', () {
    Future<UpdateService> ready(FakeNetwork network,
        {FakeAppInstaller? withInstaller, bool installable = true}) async {
      final service = UpdateService(
        installer:
            withInstaller ?? FakeAppInstaller(installable: installable),
        network: network,
        stateStore: MemoryUpdateStateStore(),
        downloadDir: Directory('${temp.path}${Platform.pathSeparator}updates'),
        manifestUrl: Uri.parse('https://example.test/update.json'),
        now: () => DateTime.utc(2026, 11, 3, 12),
      );
      await service.load();
      await service.check(force: true);
      await service.download();
      return service;
    }

    test('hands the staged file to the platform', () async {
      final installer = FakeAppInstaller();
      final service = await ready(
        FakeNetwork(manifestText: manifestTextFor(build: 2)),
        withInstaller: installer,
      );

      final outcome = await service.install();

      expect(outcome.launched, isTrue);
      expect(installer.installed, hasLength(1));
      expect(installer.installed.single.path, service.state.value.file!.path);
    });

    test('a refused install explains itself without losing the file', () async {
      final installer = FakeAppInstaller(installable: false);
      final service = await ready(
        FakeNetwork(manifestText: manifestTextFor(build: 2)),
        withInstaller: installer,
      );

      final outcome = await service.install();

      expect(outcome.launched, isFalse);
      expect(outcome.refusal, InstallRefusal.needsPermission);
      // Still ready: the user grants permission and presses Install again
      // without re-downloading 20 MB.
      expect(service.state.value.phase, UpdatePhase.ready);
      expect(await service.state.value.file!.exists(), isTrue);
      expect(installer.installed, isEmpty);
    });

    test('a launcher that says no handler keeps the offer', () async {
      final installer = FakeAppInstaller(
        outcome: const InstallerOutcome.refused(InstallRefusal.noHandler),
      );
      final service = await ready(
        FakeNetwork(manifestText: manifestTextFor(build: 2)),
        withInstaller: installer,
      );

      expect((await service.install()).refusal, InstallRefusal.noHandler);
      expect(service.state.value.phase, UpdatePhase.ready);
      expect(service.state.value.refusal, InstallRefusal.noHandler);
    });

    test('installing with nothing staged reports a missing file', () async {
      final service = serviceWith(FakeNetwork());
      await service.load();

      final outcome = await service.install();

      expect(outcome.refusal, InstallRefusal.missingFile);
      expect(service.state.value.phase, UpdatePhase.failed);
    });
  });

  group('confirmInstalled', () {
    test('a moved build number is the only proof of success', () async {
      final installer = FakeAppInstaller(
        info: const AppBuildInfo(
          versionName: '0.1.0',
          buildNumber: 1,
          packageName: 'dev.lexumo.lexumo',
        ),
      );
      final service = UpdateService(
        installer: installer,
        network: FakeNetwork(),
        stateStore: MemoryUpdateStateStore(),
        downloadDir: Directory('${temp.path}${Platform.pathSeparator}updates'),
        manifestUrl: Uri.parse('https://example.test/update.json'),
        now: () => DateTime.utc(2026, 11, 3, 12),
      );
      await service.load();
      expect(service.currentRelease.build, 1);

      // The dialog was cancelled: nothing moved.
      expect(await service.confirmInstalled(), isFalse);
      expect(service.currentRelease.build, 1);

      // Now the install really happened.
      installer.info = const AppBuildInfo(
        versionName: '0.2.0',
        buildNumber: 2,
        packageName: 'dev.lexumo.lexumo',
      );
      expect(await service.confirmInstalled(), isTrue);
      expect(service.currentRelease.build, 2);
      expect(service.state.value.phase, UpdatePhase.upToDate);
    });
  });

  group('defaults', () {
    test('the manifest url is https and override-able', () {
      // Dart's `String.fromEnvironment` is compile-time, so this asserts the
      // shape of the default rather than the override, which is exercised by
      // the release script's own build.
      final url = updateManifestUrl();
      expect(url.scheme, 'https');
      expect(url.path, endsWith('update.json'));
    });

    test('the check interval is hours, not minutes', () {
      // A local-first app: a six-hour interval is the difference between "asks
      // once a session" and "asks every launch".
      expect(kUpdateCheckInterval, const Duration(hours: 6));
    });
  });
}
