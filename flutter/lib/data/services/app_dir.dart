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

import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

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

    final dir = _prepare(_candidates());
    _cached = dir;
    return dir;
  }

  /// Creates the first candidate the process can actually write to.
  ///
  /// This getter used to resolve a single path and call `createSync` on it with
  /// no guard. Every store, the sync engine and the update service reach it
  /// during `main`, so a read-only or missing parent threw *before the first
  /// frame*, and the phone showed the launch window instead of the app — white
  /// on a light theme, black on a dark one. A data directory the platform will
  /// not hand over is a bad day, not a reason to be unusable: the snapshot still
  /// loads, and the worst case is that later writes report the IO error in a
  /// place the user can see.
  ///
  /// If no candidate can be created the preferred one is returned unresolved;
  /// the first real write will then fail loudly with a path in the message
  /// rather than the app failing here with nothing on screen.
  static String _prepare(List<String> candidates) {
    for (final dir in candidates) {
      try {
        Directory(dir).createSync(recursive: true);
        return dir;
      } on FileSystemException catch (e) {
        // Read-only volume, a parent that is a file, or a sandbox denial.
        // Nothing to do but note it and try the next folder.
        developer.log('cannot use $dir: ${e.message}', name: 'AppDir');
      }
    }
    final first = candidates.first;
    developer.log('no writable data directory; falling back to $first',
        name: 'AppDir');
    return first;
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

  /// Every place durable data could live, best first.
  ///
  /// A list rather than one path because [dataDir] must be able to survive a
  /// folder it cannot create. The order is the same preference order the single
  /// resolver used to encode: the platform's private files dir first, then any
  /// user-writable location, then somewhere the process happens to sit.
  static List<String> _candidates() {
    final sep = Platform.pathSeparator;
    final found = <String>[];

    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'] ??
          Platform.environment['LOCALAPPDATA'];
      if (appData != null && appData.isNotEmpty) {
        found.add('$appData$sep$kAppFolder');
      }
      final profile = Platform.environment['USERPROFILE'];
      if (profile != null && profile.isNotEmpty) {
        found.add('$profile$sep$kAppFolder');
      }
    }

    if (Platform.isAndroid || Platform.isIOS) {
      // Flutter's Android embedder sets TMPDIR to the app's cache dir
      // (`/data/user/0/<pkg>/cache`). Its parent is the app's private files
      // dir, which is the right place for durable user data.
      final tmp = Platform.environment['TMPDIR'];
      if (tmp != null && tmp.isNotEmpty) {
        final idx = tmp.lastIndexOf('/cache');
        if (idx > 0) {
          found.add('${tmp.substring(0, idx)}$sep$kAppFolder');
        } else {
          found.add('$tmp$sep$kAppFolder');
        }
        // The cache dir itself is always writable, so it is the one fallback
        // that cannot be refused. Data there can be evicted by the system, which
        // costs the user their words — but a startable app that might forget is
        // better than an app that never starts at all.
        found.add('$tmp$sep$kAppFolder');
      }
      final home = Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) found.add('$home$sep$kAppFolder');
    }

    final xdg = Platform.environment['XDG_DATA_HOME'];
    if (xdg != null && xdg.isNotEmpty) found.add('$xdg$sep$kAppFolder');
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home != null && home.isNotEmpty) found.add('$home$sep.lexumo');

    // Last resort: relative to the process, which is writable on desktop.
    found.add('${Directory.current.path}$sep.lexumo-data');

    // Distinct order-preserving: an Android box can report the same cache dir
    // twice, and trying the same folder twice wastes a failed syscall.
    final unique = <String>[];
    for (final dir in found) {
      if (!unique.contains(dir)) unique.add(dir);
    }
    return unique;
  }

  /// Forget the memoised path. Only tests need this.
  static void resetCache() => _cached = null;

  /// Test-only: run the candidate walk over paths the test controls, so the
  /// "keep trying after a refusal" rule can be exercised without a read-only
  /// filesystem.
  @visibleForTesting
  static String debugPrepare(List<String> candidates) => _prepare(candidates);
}
