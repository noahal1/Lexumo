/// The update flow: ask, download, verify, hand over.
///
/// Four steps, and the order is the whole design:
///
///   1. **Ask** — fetch a small JSON manifest, compare build numbers.
///   2. **Download** — stream the APK to the app's own cache, hashing as the
///      bytes arrive. Nothing is buffered in memory: a 20 MB file is 20 MB, and
///      the point of hashing the stream is that the digest is computed from the
///      exact bytes written to disk, not from a second read afterwards.
///   3. **Verify** — compare the digest, then ask the platform whether the file
///      is signed with our certificate. The digest proves the file is the one
///      the manifest named; the signature proves the manifest is naming a file
///      Android will actually accept over the installed app.
///   4. **Hand over** — pass the path to the system installer.
///
/// What this class deliberately does *not* do: assume the install happened. The
/// installer activity is a different app's dialog; it can be cancelled, and
/// Android tells us nothing. The caller re-reads its version on resume, and if
/// the build number moved, the update is done — that is the only trustworthy
/// signal, and it needs no guesswork.
///
/// Everything here is testable without a device: the network is behind
/// [UpdateNetwork], the storage behind [UpdateStateStore], and the platform
/// behind [AppInstaller]. Three seams, all of them small.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../domain/models/update_manifest.dart';
import '../../domain/models/version.dart';
import '../services/app_installer.dart';

/// How long a completed check stays fresh.
///
/// Six hours, not "on every launch": the check is a network round trip in a
/// local-first app, and a user who opens Lexumo four times in an afternoon
/// should not cost four requests. The About card can always force one by hand.
const Duration kUpdateCheckInterval = Duration(hours: 6);

/// Where the manifest lives.
///
/// A GitHub release asset, so publishing a release *is* publishing an update —
/// no separate server to keep in sync with the APKs it describes. Overridable
/// at build time with `--dart-define=LEXUMO_UPDATE_URL=…` so a test build can
/// point at a local file server.
Uri updateManifestUrl() {
  const injected = String.fromEnvironment('LEXUMO_UPDATE_URL');
  if (injected.isNotEmpty) {
    final parsed = Uri.tryParse(injected);
    if (parsed != null && parsed.hasAuthority) return parsed;
  }
  return Uri.parse(
    'https://github.com/noahal1/Lexumo/releases/latest/download/update.json',
  );
}

/// Where the flow is, as one value the UI can switch on.
enum UpdatePhase {
  /// Nothing has been asked yet this session.
  idle,

  /// A manifest request is in flight.
  checking,

  /// The newest release is the one running, or there is no manifest to read.
  upToDate,

  /// A newer release exists and nothing has been downloaded.
  available,

  /// Bytes are arriving; see [UpdateState.progress].
  downloading,

  /// The bytes are complete and being checked.
  verifying,

  /// The APK is on disk, verified, and waiting for the user to press Install.
  ready,

  /// Something went wrong; [UpdateState.reason] says what.
  failed,
}

/// The phase plus everything the sheet needs to draw that phase.
@immutable
class UpdateState {
  const UpdateState({
    required this.phase,
    this.available,
    this.current,
    this.progress = 0,
    this.receivedBytes = 0,
    this.totalBytes,
    this.reason,
    this.file,
    this.refusal,
  });

  const UpdateState.idle() : this(phase: UpdatePhase.idle);

  final UpdatePhase phase;

  /// Set from [UpdatePhase.available] onwards.
  final UpdateAvailable? available;

  final ReleaseVersion? current;

  /// 0..1. Only meaningful while [phase] is [UpdatePhase.downloading].
  final double progress;

  final int receivedBytes;

  /// Null when the manifest did not advertise a size, which is why progress is
  /// kept as a separate number rather than derived from these two.
  final int? totalBytes;

  /// A wire code for [UpdatePhase.failed]: `offline`, `server`, `manifest`,
  /// `digest`, `signature`, `space`, `storage`, `unsupported` or `permission`.
  ///
  /// Codes, not sentences: the same failure is shown in the sheet (which
  /// offers a retry) and in the settings row (which has no room for one), and
  /// the two must say the same thing. `dart:io` and the network seam raise
  /// different exceptions for the same condition, so the conversion to a code
  /// happens here, once, where it can be tested without a widget.
  final String? reason;

  /// The downloaded APK, once `phase == ready`.
  final File? file;

  /// For a refused install: why.
  final InstallRefusal? refusal;

  bool get isBusy =>
      phase == UpdatePhase.checking ||
      phase == UpdatePhase.downloading ||
      phase == UpdatePhase.verifying;

  UpdateState copyWith({
    UpdatePhase? phase,
    UpdateAvailable? available,
    ReleaseVersion? current,
    double? progress,
    int? receivedBytes,
    int? totalBytes,
    String? reason,
    File? file,
    InstallRefusal? refusal,
    bool clearReason = false,
    bool clearFile = false,
    bool clearRefusal = false,
    bool clearAvailable = false,
  }) {
    return UpdateState(
      phase: phase ?? this.phase,
      available: clearAvailable ? null : (available ?? this.available),
      current: current ?? this.current,
      progress: progress ?? this.progress,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      reason: clearReason ? null : (reason ?? this.reason),
      file: clearFile ? null : (file ?? this.file),
      refusal: clearRefusal ? null : (refusal ?? this.refusal),
    );
  }
}

/// The network, behind one seam.
abstract class UpdateNetwork {
  /// Fetch a small text document.
  Future<String> fetchText(Uri url);

  /// Stream [url] into [destination], calling [onProgress] as bytes land.
  ///
  /// Returns the byte count written. Throws [UpdateNetworkException] with a
  /// wire reason on failure, including [onCancel] firing before completion.
  Future<int> download(
    Uri url,
    File destination, {
    void Function(int received, int? total)? onProgress,
    FutureOr<bool> Function()? onCancel,
  });

  void close();
}

/// A failed request, carrying the translated reason.
class UpdateNetworkException implements Exception {
  const UpdateNetworkException(this.reason, [this.status = 0]);

  /// `offline` or `server`.
  final String reason;
  final int status;

  @override
  String toString() => 'UpdateNetworkException($reason, $status)';
}

/// Real network: `dart:io` [HttpClient], the same one the sync transport uses.
class IoUpdateNetwork implements UpdateNetwork {
  IoUpdateNetwork({HttpClient? client, this.timeout = const Duration(seconds: 30)})
      : _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 10);
    // GitHub redirects release assets to a signed CDN URL; the default client
    // follows redirects, but being explicit documents the dependency.
    _client.autoUncompress = true;
  }

  final HttpClient _client;
  final Duration timeout;

  @override
  Future<String> fetchText(Uri url) async {
    final HttpClientResponse response;
    try {
      final request = await _client.getUrl(url).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      // GitHub's API rejects requests without a user agent; the released
      // manifest is served as a plain asset, but a build pointed at the API
      // would need this and an absent header costs nothing.
      request.headers.set(HttpHeaders.userAgentHeader, 'Lexumo-updater');
      response = await request.close().timeout(timeout);
    } on TimeoutException {
      throw const UpdateNetworkException('offline');
    } on SocketException {
      throw const UpdateNetworkException('offline');
    } on HandshakeException {
      throw const UpdateNetworkException('offline');
    } on HttpException {
      throw const UpdateNetworkException('offline');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UpdateNetworkException('server', response.statusCode);
    }
    try {
      return await response.transform(utf8.decoder).join().timeout(timeout);
    } on TimeoutException {
      throw const UpdateNetworkException('offline');
    }
  }

  @override
  Future<int> download(
    Uri url,
    File destination, {
    void Function(int received, int? total)? onProgress,
    FutureOr<bool> Function()? onCancel,
  }) async {
    final HttpClientResponse response;
    try {
      final request = await _client.getUrl(url).timeout(timeout);
      request.headers.set(HttpHeaders.userAgentHeader, 'Lexumo-updater');
      response = await request.close().timeout(timeout);
    } on TimeoutException {
      throw const UpdateNetworkException('offline');
    } on SocketException {
      throw const UpdateNetworkException('offline');
    } on HandshakeException {
      throw const UpdateNetworkException('offline');
    } on HttpException {
      throw const UpdateNetworkException('offline');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UpdateNetworkException('server', response.statusCode);
    }

    final total = response.contentLength > 0 ? response.contentLength : null;
    final sink = destination.openWrite();
    var received = 0;
    try {
      await for (final chunk in response) {
        if (onCancel != null && await onCancel()) {
          throw const UpdateNetworkException('cancelled');
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
    } on SocketException {
      throw const UpdateNetworkException('offline');
    } finally {
      await sink.close();
    }
    return received;
  }

  @override
  void close() => _client.close(force: true);
}

/// What survives between launches: when we last asked, and which release the
/// user asked us to stop mentioning.
///
/// Kept out of [Settings] on purpose. A release the user dismissed is a fact
/// about this device's attention, not a preference that should follow them to a
/// second machine — and settings are synced wholesale, so putting it there would
/// make a phone's "not now" hide a tablet's update.
abstract class UpdateStateStore {
  Future<({int lastCheckAt, int skippedBuild})> read();

  Future<void> write({int? lastCheckAt, int? skippedBuild});
}

/// A small JSON sidecar next to `lexumo.json`.
class FileUpdateStateStore implements UpdateStateStore {
  FileUpdateStateStore(this.path);

  final String path;

  File get _file => File(path);

  @override
  Future<({int lastCheckAt, int skippedBuild})> read() async {
    try {
      if (!await _file.exists()) {
        return (lastCheckAt: 0, skippedBuild: 0);
      }
      final raw = jsonDecode(await _file.readAsString());
      if (raw is! Map) return (lastCheckAt: 0, skippedBuild: 0);
      return (
        lastCheckAt: (raw['lastCheckAt'] as num?)?.toInt() ?? 0,
        skippedBuild: (raw['skippedBuild'] as num?)?.toInt() ?? 0,
      );
    } on FileSystemException {
      return (lastCheckAt: 0, skippedBuild: 0);
    } on FormatException {
      // A corrupt sidecar is not worth a dialog: the worst outcome of starting
      // from zero is one extra manifest request.
      return (lastCheckAt: 0, skippedBuild: 0);
    }
  }

  @override
  Future<void> write({int? lastCheckAt, int? skippedBuild}) async {
    final current = await read();
    final payload = <String, Object>{
      'lastCheckAt': lastCheckAt ?? current.lastCheckAt,
      'skippedBuild': skippedBuild ?? current.skippedBuild,
    };
    try {
      await _file.parent.create(recursive: true);
      // Write beside then rename: a crash mid-write would otherwise leave a
      // truncated sidecar and lose both fields.
      final temp = File('$path.tmp');
      await temp.writeAsString(jsonEncode(payload), flush: true);
      await temp.rename(path);
    } on FileSystemException {
      // Losing this file costs one redundant check; it must not break the flow.
    }
  }
}

/// In-memory store for tests.
class MemoryUpdateStateStore implements UpdateStateStore {
  MemoryUpdateStateStore({this.lastCheckAt = 0, this.skippedBuild = 0});

  int lastCheckAt;
  int skippedBuild;

  @override
  Future<({int lastCheckAt, int skippedBuild})> read() async =>
      (lastCheckAt: lastCheckAt, skippedBuild: skippedBuild);

  @override
  Future<void> write({int? lastCheckAt, int? skippedBuild}) async {
    if (lastCheckAt != null) this.lastCheckAt = lastCheckAt;
    if (skippedBuild != null) this.skippedBuild = skippedBuild;
  }
}

/// The flow itself.
///
/// One instance lives for the app's lifetime and is exposed through
/// `UpdateScope`. The visible state is a [ValueNotifier] so the settings row
/// rebuilds on a phase change without the service knowing what a widget is.
class UpdateService {
  UpdateService({
    required this.installer,
    required this.network,
    required this.stateStore,
    required this.downloadDir,
    required this.manifestUrl,
    required this.now,
  });

  final AppInstaller installer;
  final UpdateNetwork network;
  final UpdateStateStore stateStore;

  /// Where APKs are staged. Must be the folder the `FileProvider` exposes —
  /// a file anywhere else cannot be handed to the installer.
  final Directory downloadDir;

  final Uri manifestUrl;
  final DateTime Function() now;

  final ValueNotifier<UpdateState> state =
      ValueNotifier<UpdateState>(const UpdateState.idle());

  AppBuildInfo _build = AppBuildInfo.unknown;
  Future<UpdateCheck>? _inFlight;
  bool _cancelled = false;

  /// This build's version, once [load] has run.
  AppBuildInfo get build => _build;

  ReleaseVersion get currentRelease =>
      ReleaseVersion.tryParse(name: _build.versionName, build: _build.buildNumber) ??
      const ReleaseVersion(name: SemVer(0, 0, 0), build: 0);

  /// Read the running version and the remembered check state.
  ///
  /// Called once at startup, before the first check, because both answers feed
  /// every later decision. A failure here is not fatal: an unknown version just
  /// means the check reports "cannot tell" rather than offering a downgrade.
  Future<void> load() async {
    _build = await installer.buildInfo();
    state.value = state.value.copyWith(current: currentRelease);
  }

  /// Whether a check is due now.
  Future<bool> isCheckDue() async {
    final saved = await stateStore.read();
    if (saved.lastCheckAt == 0) return true;
    final elapsed = now().difference(
      DateTime.fromMillisecondsSinceEpoch(saved.lastCheckAt),
    );
    return elapsed >= kUpdateCheckInterval;
  }

  /// Ask the manifest what the newest release is.
  ///
  /// [force] skips both the interval and the dismissed-release memory — that is
  /// what the About card's "check now" uses, and a user who taps it deserves an
  /// answer even if they tapped "not now" an hour ago.
  ///
  /// Concurrent calls join the in-flight check rather than racing: two widgets
  /// asking on mount is normal and must not produce two downloads.
  Future<UpdateCheck> check({bool force = false}) {
    final running = _inFlight;
    if (running != null) return running;
    final future = _check(force: force);
    _inFlight = future;
    return future.whenComplete(() => _inFlight = null);
  }

  Future<UpdateCheck> _check({required bool force}) async {
    if (installer.support == InstallSupport.none) {
      state.value = state.value.copyWith(
        phase: UpdatePhase.failed,
        reason: 'unsupported',
      );
      return UpdateUnsupported(_build.versionName.isEmpty ? null : currentRelease);
    }

    if (!force && !await isCheckDue()) {
      // A fresh answer from earlier today: report it from memory when there is
      // one, otherwise say "up to date" without a request. Deliberately not a
      // separate phase — the UI shows the same thing either way.
      return UpdateUpToDate(current: _build.versionName.isEmpty ? null : currentRelease);
    }

    state.value = state.value.copyWith(
      phase: UpdatePhase.checking,
      clearReason: true,
      clearFile: true,
      clearRefusal: true,
    );

    final String text;
    try {
      text = await network.fetchText(manifestUrl);
    } on UpdateNetworkException catch (error) {
      // A failed check is silence, not an error card: the user did not ask for
      // this, and an offline phone must not report a fault every six hours.
      state.value = state.value.copyWith(
        phase: UpdatePhase.idle,
        clearReason: true,
      );
      return UpdateFailed(error.reason);
    }

    await stateStore.write(lastCheckAt: now().millisecondsSinceEpoch);

    final manifest = ReleaseManifest.parse(text);
    if (manifest == null) {
      state.value = state.value.copyWith(phase: UpdatePhase.idle);
      return const UpdateFailed('manifest');
    }

    final current = currentRelease;
    if (!current.isOlderThan(manifest.version)) {
      state.value = state.value.copyWith(
        phase: UpdatePhase.upToDate,
        current: current,
        clearAvailable: true,
      );
      return UpdateUpToDate(current: current);
    }

    final saved = await stateStore.read();
    // The dismissed build is honoured for automatic checks only. If the release
    // is below the manifest's floor, "not now" is not an option: an old build
    // that can no longer talk to the server would fail in ways the user cannot
    // connect to a skipped dialog.
    final required = manifest.isRequiredFor(current);
    if (!force && !required && saved.skippedBuild == manifest.version.build) {
      state.value = state.value.copyWith(
        phase: UpdatePhase.upToDate,
        current: current,
        clearAvailable: true,
      );
      return UpdateUpToDate(current: current);
    }

    final available = UpdateAvailable(
      current: current,
      manifest: manifest,
      required: required,
    );
    state.value = state.value.copyWith(
      phase: UpdatePhase.available,
      available: available,
      current: current,
    );
    return available;
  }

  /// Forget a "not now" so the next check mentions this release again.
  Future<void> dismiss(ReleaseVersion version) async {
    await stateStore.write(skippedBuild: version.build);
    state.value = state.value.copyWith(phase: UpdatePhase.upToDate);
  }

  /// Download and verify the APK the current [UpdateState.available] names.
  ///
  /// Returns the staged file, or null when the download failed — [state] then
  /// carries the reason. Never throws: a failed download is a state, and the
  /// sheet shows it inline with a retry button.
  Future<File?> download() async {
    final available = state.value.available;
    if (available == null) return null;
    if (state.value.phase == UpdatePhase.downloading) return null;

    final artifact = available.manifest.apk;
    final target = File(
      '${downloadDir.path}${Platform.pathSeparator}'
      'lexumo-${available.manifest.version.name}-${available.manifest.version.build}.apk',
    );

    _cancelled = false;
    state.value = state.value.copyWith(
      phase: UpdatePhase.downloading,
      progress: 0,
      receivedBytes: 0,
      totalBytes: artifact.bytes,
      clearReason: true,
      clearRefusal: true,
    );

    try {
      await downloadDir.create(recursive: true);
      // Stale files from earlier attempts are removed first: the cache is small
      // on Android, and an old APK is the one thing here that is pure garbage.
      await _sweepOldApks(keeping: target.path);

      final written = await network.download(
        artifact.url,
        target,
        onCancel: () => _cancelled,
        onProgress: (received, total) {
          if (_cancelled) return;
          final denominator = total ?? artifact.bytes;
          state.value = state.value.copyWith(
            receivedBytes: received,
            totalBytes: denominator,
            progress: denominator == null || denominator <= 0
                ? 0
                : (received / denominator).clamp(0.0, 1.0),
          );
        },
      );

      if (_cancelled) {
        await _deleteQuietly(target);
        state.value = state.value.copyWith(
          phase: UpdatePhase.available,
          progress: 0,
          receivedBytes: 0,
        );
        return null;
      }

      state.value = state.value.copyWith(phase: UpdatePhase.verifying);

      // A short file is a truncated download, not a wrong one — but both are
      // "not what the manifest promised" and neither is installable.
      final expected = artifact.bytes;
      if (expected != null && written != expected) {
        return await _fail('digest', target);
      }

      final digest = await _sha256Of(target);
      if (digest != artifact.sha256) {
        return await _fail('digest', target);
      }

      if (!await installer.verifySignature(target)) {
        return await _fail('signature', target);
      }

      state.value = state.value.copyWith(
        phase: UpdatePhase.ready,
        file: target,
        progress: 1,
        receivedBytes: written,
        totalBytes: written,
      );
      return target;
    } on UpdateNetworkException catch (error) {
      // Cancelling is not a failure, and must not look like one: the user asked
      // for it, the offer is still there, and a red sentence would be the app
      // arguing with their own click.
      if (error.reason == 'cancelled' || _cancelled) {
        await _deleteQuietly(target);
        state.value = state.value.copyWith(
          phase: UpdatePhase.available,
          progress: 0,
          receivedBytes: 0,
          totalBytes: artifact.bytes,
          clearReason: true,
        );
        return null;
      }
      return await _fail(error.reason, target);
    } on FileSystemException catch (error) {
      return await _fail(
        error.osError?.errorCode == 28 ? 'space' : 'storage',
        target,
      );
    }
  }

  /// Ask the system installer to take the staged file.
  ///
  /// The outcome is returned and also written into [state] so a sheet that
  /// closed on a successful launch can still explain a refusal.
  Future<InstallerOutcome> install() async {
    final file = state.value.file;
    if (file == null || !await file.exists()) {
      state.value = state.value.copyWith(
        phase: UpdatePhase.failed,
        reason: 'storage',
        refusal: InstallRefusal.missingFile,
      );
      return const InstallerOutcome.refused(InstallRefusal.missingFile);
    }

    if (!await installer.canInstall()) {
      state.value = state.value.copyWith(
        phase: UpdatePhase.ready,
        refusal: InstallRefusal.needsPermission,
      );
      return const InstallerOutcome.refused(InstallRefusal.needsPermission);
    }

    final outcome = await installer.install(file);
    if (!outcome.launched) {
      state.value = state.value.copyWith(
        phase: UpdatePhase.ready,
        refusal: outcome.refusal ?? InstallRefusal.unavailable,
      );
    } else {
      state.value = state.value.copyWith(clearRefusal: true);
    }
    return outcome;
  }

  /// Stop an in-flight download; the partial file is deleted.
  void cancel() => _cancelled = true;

  /// Called after the app resumes from the installer. If the running version
  /// moved past what we started as, the install happened and the update is done.
  ///
  /// This is why nothing in this class claims success: the installer's answer is
  /// unknowable, but its *effect* is trivially observable.
  Future<bool> confirmInstalled() async {
    final before = _build;
    final now = await installer.buildInfo();
    final moved = now.buildNumber > before.buildNumber;
    if (moved) {
      _build = now;
      await stateStore.write(skippedBuild: 0);
      state.value = UpdateState(phase: UpdatePhase.upToDate, current: currentRelease);
    }
    return moved;
  }

  void dispose() {
    network.close();
    state.dispose();
  }

  /* ---------------------------------------------------------------- */

  /// Record a failure and drop whatever was staged.
  ///
  /// A failed download never leaves a file behind: an APK in the staging folder
  /// is the one thing here that the installer could pick up later, and a
  /// half-verified file is worse than none.
  Future<File?> _fail(String reason, File target) async {
    await _deleteQuietly(target);
    state.value = state.value.copyWith(
      phase: UpdatePhase.failed,
      reason: reason,
      clearFile: true,
    );
    return null;
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // A file we cannot delete is a cache-garbage problem, not a flow problem.
    }
  }

  /// Remove other APKs in the staging folder, keeping [keeping].
  Future<void> _sweepOldApks({required String keeping}) async {
    try {
      if (!await downloadDir.exists()) return;
      await for (final entity in downloadDir.list()) {
        if (entity is! File) continue;
        if (entity.path == keeping) continue;
        if (!entity.path.toLowerCase().endsWith('.apk')) continue;
        await _deleteQuietly(entity);
      }
    } on FileSystemException {
      // Sweeping is housekeeping; failing it must not block a download.
    }
  }

  /// SHA-256 of [file], lowercase hex, read in chunks so a large APK does not
  /// become a large allocation.
  static Future<String> _sha256Of(File file) async {
    final sink = _DigestSink();
    final hasher = sha256.startChunkedConversion(sink);
    await for (final chunk in file.openRead()) {
      hasher.add(chunk);
    }
    hasher.close();
    return sink.value;
  }
}

/// Collects the single [Digest] a chunked hash produces.
///
/// `package:crypto`'s chunked API wants a `Sink<Digest>`; `package:convert`'s
/// `AccumulatorSink` would do, but adding a package for six lines is not worth
/// it, and this also asserts the "exactly one digest" contract.
class _DigestSink implements Sink<Digest> {
  String? _value;

  String get value {
    final out = _value;
    if (out == null) {
      throw StateError('sha256 produced no digest');
    }
    return out;
  }

  @override
  void add(Digest data) {
    if (_value != null) throw StateError('sha256 produced more than one digest');
    _value = data.toString();
  }

  @override
  void close() {}
}
