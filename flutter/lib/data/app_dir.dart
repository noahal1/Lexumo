/// Where the single snapshot file lives, without a plugin.
///
/// `path_provider` would be the obvious answer, but it is a whole plugin for one
/// string, and the three cases below are short enough to spell out — which also
/// keeps the resolution unit-testable without a platform channel.
///
///   · Windows — `%APPDATA%\Lexumo\lexumo.json`.
///   · Android — the app's private files dir, found by asking the platform
///     through `dart:io`'s `HOME`/`TMPDIR` fallbacks.
///   · everywhere else / tests — `$XDG_DATA_HOME/lexumo` or `~/.lexumo`.
///
/// Note this is a *new* location, not the Tauri build's. That build persisted
/// to WebView2's IndexedDB under `%LOCALAPPDATA%\com.lexumo.app\EBWebView`, so
/// an existing Tauri install does not share data with this one and nothing here
/// can read it. Migrating would mean parsing a LevelDB store, which is why the
/// two builds are independent rather than one upgrading the other.
///
/// `AppDir.override` lets a test point at a temp directory.
library;

import 'dart:io';

/// The owning app identifier, used to build the Windows folder name.
const String kAppFolder = 'Lexumo';

abstract final class AppDir {
  /// Set by tests (and by the Android entrypoint once the platform hands us a
  /// path) to bypass platform detection entirely.
  static String? override;

  static String? _cached;

  /// Absolute path of the folder holding `lexumo.json`. Created on first use.
  static String get dataDir {
    final forced = override;
    if (forced != null) return forced;
    final cached = _cached;
    if (cached != null) return cached;

    final dir = _resolve();
    Directory(dir).createSync(recursive: true);
    _cached = dir;
    return dir;
  }

  static String get dataFile => '$dataDir${Platform.pathSeparator}lexumo.json';

  /// Sidecar written before the main file is replaced, so a crash mid-write
  /// leaves a recoverable copy rather than a half-written primary.
  static String get backupFile => '$dataFile.bak';

  /// Where a downloaded update is staged.
  ///
  /// Deliberately *not* inside [dataDir] on Android: that folder is the durable
  /// one, it is included in the backup, and a 20 MB APK is the least durable
  /// thing the app will ever write. Android wants it in the cache, and the
  /// `FileProvider` in `file_paths.xml` exposes exactly `<cacheDir>/updates/`,
  /// so writing anywhere else would mean copying the file again before the
  /// installer could read it.
  ///
  /// On desktop this folder never receives anything — the platform reports
  /// "download only" and the sheet opens the releases page instead.
  static String get updateDir {
    final sep = Platform.pathSeparator;
    if (Platform.isAndroid || Platform.isIOS) {
      // Flutter's Android embedder points TMPDIR at the app's cache dir.
      final cache = Platform.environment['TMPDIR'];
      if (cache != null && cache.isNotEmpty) return '$cache${sep}updates';
    }
    return '$dataDir${sep}updates';
  }

  static String _resolve() {
    final sep = Platform.pathSeparator;

    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'] ??
          Platform.environment['LOCALAPPDATA'];
      if (appData != null && appData.isNotEmpty) {
        return '$appData$sep$kAppFolder';
      }
      final profile = Platform.environment['USERPROFILE'];
      if (profile != null && profile.isNotEmpty) {
        return '$profile$sep$kAppFolder';
      }
    }

    if (Platform.isAndroid || Platform.isIOS) {
      // Flutter's Android embedder sets TMPDIR to the app's cache dir
      // (`/data/user/0/<pkg>/cache`). Its parent is the app's private files
      // dir, which is the right place for durable user data.
      final tmp = Platform.environment['TMPDIR'];
      if (tmp != null && tmp.isNotEmpty) {
        final idx = tmp.lastIndexOf('/cache');
        if (idx > 0) return '${tmp.substring(0, idx)}$sep$kAppFolder';
        return '$tmp$sep$kAppFolder';
      }
      final home = Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) return '$home$sep$kAppFolder';
    }

    final xdg = Platform.environment['XDG_DATA_HOME'];
    if (xdg != null && xdg.isNotEmpty) return '$xdg$sep$kAppFolder';
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home != null && home.isNotEmpty) return '$home$sep.lexumo';

    // Last resort: relative to the process, which is writable on desktop.
    return '${Directory.current.path}$sep.lexumo-data';
  }

  /// Forget the memoised path. Only tests need this.
  static void resetCache() => _cached = null;
}
