/// Installing a downloaded APK, and knowing whether that is allowed — the one
/// part of the update flow Dart cannot do alone.
///
/// Why this is native at all: installing a package means handing a file to
/// Android's package installer, and no Dart API does that. `dart:io` can write
/// the file and check its bytes, so those stay on this side; the channel is
/// deliberately narrow — four calls, each doing exactly one thing the platform
/// owns.
///
/// Three platform paths, shaped the way `file_dialogs.dart` is:
///
///   · **Android** — the channel talks to `MainActivity.kt`. It launches the
///     installer, checks whether "install unknown apps" is granted for this
///     app, and opens the settings screen where it is granted. Nothing is
///     downloaded on the Kotlin side; the bytes arrive as a path into this
///     app's own cache, which is why the `FileProvider` in the manifest exposes
///     exactly `cache/updates/` and nothing else.
///
///   · **Windows** — no in-app installer. An installed application cannot
///     replace itself while running: the running `.exe` is locked by the OS, so
///     a self-update has to either quit first or hand off to a separate
///     updater. Lexumo has no updater process, so the Windows build reports
///     [InstallSupport.none] and the update row offers a download link instead.
///     Claiming support and then failing at the last step would be worse than
///     saying so up front.
///
///   · **Anything else / tests** — [InstallSupport.none].
///
/// Every method returns a [InstallerOutcome] rather than throwing. A missing
/// plugin, a refused permission and a user who changed their mind are all
/// ordinary answers here, and a `MissingPluginException` reaching the update
/// sheet would turn a `canInstall` probe into a red toast.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What this platform can do about installing a new build.
enum InstallSupport {
  /// The app can download, verify and hand the APK to the system installer.
  inApp,

  /// The app can download and verify, but the user must install the file
  /// themselves. Reported on desktop, where there is no installer to launch.
  downloadOnly,

  /// Nothing about updates is actionable here.
  none,
}

/// Why an [AppInstaller.install] call did not end with an installer on screen.
enum InstallRefusal {
  /// Android has not granted this app permission to install packages. The
  /// caller should offer [AppInstaller.openInstallSettings] and retry.
  needsPermission,

  /// The system accepted the intent but there is no activity to handle it —
  /// happens on stripped-down builds and on some vendor ROMs.
  noHandler,

  /// The file was gone or unreadable by the time the intent fired.
  missingFile,

  /// The channel itself was absent (desktop, tests, or a build where the
  /// native side was not updated). Not an error the user can act on.
  unavailable,
}

/// The result of asking the platform to install a file.
class InstallerOutcome {
  const InstallerOutcome._(this.launched, this.refusal);

  const InstallerOutcome.launched() : this._(true, null);

  const InstallerOutcome.refused(InstallRefusal reason) : this._(false, reason);

  /// The installer activity is on screen. It does **not** mean the package was
  /// installed: the user can still cancel, and Android's own dialog does not
  /// tell us which happened. The app re-checks its version on resume instead of
  /// assuming either way.
  final bool launched;
  final InstallRefusal? refusal;

  bool get succeeded => launched;
}

/// What this build knows about itself.
@immutable
class AppBuildInfo {
  const AppBuildInfo({
    required this.versionName,
    required this.buildNumber,
    this.packageName,
    this.isDebug = false,
  });

  /// `0.2.0`, from `pubspec.yaml`.
  final String versionName;

  /// `2`, from `pubspec.yaml`.
  final int buildNumber;

  /// `dev.lexumo.lexumo` on Android, null elsewhere.
  final String? packageName;

  /// A debug build cannot be installed over a release build (and vice versa):
  /// the certificates differ. The update sheet uses this to explain a failure
  /// instead of looping.
  final bool isDebug;

  static const AppBuildInfo unknown =
      AppBuildInfo(versionName: '0.0.0', buildNumber: 0);
}

/// The instance the UI talks to. Same shape as `fileDialogs` in
/// `lib/platform/file_dialogs.dart`: a mutable top-level, replaced wholesale by
/// widget tests.
AppInstaller appInstaller = const PlatformAppInstaller();

/// The install-side operations the update service needs. Abstract so the whole
/// flow can be tested without a device.
abstract class AppInstaller {
  /// What this platform supports. Synchronous: it depends only on the OS, and
  /// an async capability check would put an await in front of every build.
  InstallSupport get support;

  /// This build's version and package, as the platform reports them.
  ///
  /// Falls back to the `--dart-define` values the build pipeline passes when the
  /// channel is unavailable, so a `flutter run` build still knows its version.
  Future<AppBuildInfo> buildInfo();

  /// Whether the system will currently accept an install intent.
  ///
  /// `true` on platforms and setups where the question does not apply, so the
  /// caller has one check rather than a platform switch.
  Future<bool> canInstall();

  /// Open the OS screen where "install unknown apps" is granted.
  Future<void> openInstallSettings();

  /// Hand [file] to the system installer.
  Future<InstallerOutcome> install(File file);

  /// Verify that [file] is signed with the same certificate as the running app.
  ///
  /// Android refuses a mismatched signature with `INSTALL_FAILED_UPDATE_
  /// INCOMPATIBLE`, which the user experiences as "the installer said no" with
  /// no explanation. Checking first lets the app say the real reason. Returns
  /// `true` when the platform cannot answer — an unverifiable file is still
  /// worth attempting, and refusing on "don't know" would break every device
  /// where the native check is unavailable.
  Future<bool> verifySignature(File file);
}

/// The real implementation.
class PlatformAppInstaller implements AppInstaller {
  const PlatformAppInstaller();

  static const MethodChannel _channel =
      MethodChannel('dev.lexumo.lexumo/app');

  /// Values injected by `tool/release.sh` at build time.
  ///
  /// `--dart-define=LEXUMO_VERSION=0.2.0` and
  /// `--dart-define=LEXUMO_BUILD=2`. They exist so a build always knows its own
  /// version even where the channel is missing, and so the release script has
  /// one place to bump. The channel's answer still wins — it reads
  /// `PackageManager`, which is the same source Android compares against.
  static const String _defineVersion =
      String.fromEnvironment('LEXUMO_VERSION', defaultValue: '');
  static const int _defineBuild =
      int.fromEnvironment('LEXUMO_BUILD', defaultValue: 0);

  @override
  InstallSupport get support {
    if (Platform.isAndroid) return InstallSupport.inApp;
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      return InstallSupport.downloadOnly;
    }
    return InstallSupport.none;
  }

  @override
  Future<AppBuildInfo> buildInfo() async {
    try {
      final Map<Object?, Object?>? raw =
          await _channel.invokeMapMethod<Object?, Object?>('info');
      if (raw != null) {
        final name = raw['versionName'];
        // `versionCode` is the Android name for the same number; accepting both
        // keeps this side working against a native build from either side of the
        // rename, which matters because the two halves ship separately during
        // development.
        final build = raw['buildNumber'] ?? raw['versionCode'];
        if (name is String && name.isNotEmpty) {
          return AppBuildInfo(
            versionName: name,
            buildNumber: build is int ? build : _defineBuild,
            packageName: raw['packageName'] is String
                ? raw['packageName'] as String
                : null,
            isDebug: raw['isDebug'] == true,
          );
        }
      }
    } on MissingPluginException {
      // Desktop, tests, or a native side older than this Dart code.
    } on PlatformException {
      // Same: fall through to the compiled-in values.
    }
    if (_defineVersion.isEmpty) return AppBuildInfo.unknown;
    return AppBuildInfo(
      versionName: _defineVersion,
      buildNumber: _defineBuild,
    );
  }

  @override
  Future<bool> canInstall() async {
    if (support != InstallSupport.inApp) return false;
    try {
      final bool? allowed = await _channel.invokeMethod<bool>('canInstall');
      // Null means the native side answered "I don't know"; on Android the
      // permission defaults to denied, so treat unknown as denied and let the
      // settings screen grant it.
      return allowed ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> openInstallSettings() async {
    if (support != InstallSupport.inApp) return;
    try {
      await _channel.invokeMethod<void>('openInstallSettings');
    } on MissingPluginException {
      // Nothing to open; the UI's instruction text still tells the user where
      // to look.
    } on PlatformException {
      // Same.
    }
  }

  @override
  Future<InstallerOutcome> install(File file) async {
    if (support != InstallSupport.inApp) {
      return const InstallerOutcome.refused(InstallRefusal.unavailable);
    }
    try {
      final String? state = await _channel.invokeMethod<String>(
        'installApk',
        <String, String>{'path': file.path},
      );
      switch (state) {
        case 'launched':
          return const InstallerOutcome.launched();
        case 'noHandler':
          return const InstallerOutcome.refused(InstallRefusal.noHandler);
        case 'missingFile':
          return const InstallerOutcome.refused(InstallRefusal.missingFile);
        default:
          return const InstallerOutcome.refused(InstallRefusal.needsPermission);
      }
    } on MissingPluginException {
      return const InstallerOutcome.refused(InstallRefusal.unavailable);
    } on PlatformException {
      return const InstallerOutcome.refused(InstallRefusal.unavailable);
    }
  }

  @override
  Future<bool> verifySignature(File file) async {
    if (support != InstallSupport.inApp) return true;
    try {
      final bool? matches = await _channel.invokeMethod<bool>(
        'verifySignature',
        <String, String>{'path': file.path},
      );
      return matches ?? true;
    } on MissingPluginException {
      return true;
    } on PlatformException {
      return true;
    }
  }
}

/// Stands in for the platform in tests, the way `FakeFileDialogs` does.
class FakeAppInstaller implements AppInstaller {
  FakeAppInstaller({
    this.support = InstallSupport.inApp,
    this.info = const AppBuildInfo(
      versionName: '0.1.0',
      buildNumber: 1,
      packageName: 'dev.lexumo.lexumo',
    ),
    this.installable = true,
    this.signatureMatches = true,
    this.outcome = const InstallerOutcome.launched(),
  });

  @override
  final InstallSupport support;

  AppBuildInfo info;

  bool installable;

  bool signatureMatches;

  InstallerOutcome outcome;

  /// Every file [install] was asked about, in order.
  final List<File> installed = <File>[];

  int settingsOpened = 0;

  @override
  Future<AppBuildInfo> buildInfo() async => info;

  @override
  Future<bool> canInstall() async => installable;

  @override
  Future<void> openInstallSettings() async => settingsOpened++;

  @override
  Future<InstallerOutcome> install(File file) async {
    installed.add(file);
    return outcome;
  }

  @override
  Future<bool> verifySignature(File file) async => signatureMatches;
}
