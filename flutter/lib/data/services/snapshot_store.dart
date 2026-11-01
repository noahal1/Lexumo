/// Persistence: one versioned JSON snapshot on disk.
///
/// The web build stored the snapshot in IndexedDB with a localStorage fallback
/// (`src/lib/db.ts`). A Flutter app has no IndexedDB, and the honest desktop
/// equivalent is a file — the same file the Tauri build's SQLite/JSON layer
/// would have used under `%APPDATA%`.
///
/// Three properties matter more than speed here, so the writes are boringly
/// careful:
///
///   · **atomic** — the new snapshot is written to `lexumo.json.tmp`, flushed,
///     then renamed over the primary. A crash leaves either the old file or
///     the new one, never a truncated one.
///   · **recoverable** — before the rename, the previous primary is copied to
///     `lexumo.json.bak`. [SnapshotStore.load] falls back to it when the
///     primary is missing or corrupt.
///   · **tolerant** — an unreadable file is reported, not thrown. A user with
///     a damaged snapshot should see the app with a warning, not a white
///     screen: losing a vocabulary list to a parse error is worse than
///     starting empty and keeping the bad file for recovery.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../domain/models/types.dart';
import 'app_dir.dart';

/// What a load attempt produced. `null` data means "no snapshot yet, seed me";
/// a non-null [error] with null data means "the snapshot exists but is broken".
class LoadResult {
  const LoadResult({this.data, this.error, this.recovered = false});

  final AppData? data;
  final String? error;

  /// True when the primary file was unusable and the `.bak` copy was read.
  final bool recovered;

  bool get isEmpty => data == null;
}

/// The narrow interface the store talks to. Swapping the file for SQLite later
/// means writing one more implementation of these three methods.
abstract class Persistence {
  Future<LoadResult> load();
  Future<void> save(AppData data);
  Future<void> clear();
}

/// File-backed [Persistence]. Every method is safe to call from the UI isolate
/// — the writes are small (tens of KB) and debounced by the store.
class SnapshotStore implements Persistence {
  // The parameter carries the public name `dirOverride`; the field is private
  // because nothing outside this class should read the override back out.
  // ignore: prefer_initializing_formals
  SnapshotStore({String? dirOverride}) : _dirOverride = dirOverride;

  final String? _dirOverride;

  String get _dir {
    final o = _dirOverride;
    if (o != null) return o;
    return AppDir.dataDir;
  }

  String get _primary => '$_dir${Platform.pathSeparator}lexumo.json';
  String get _backup => '$_primary.bak';
  String get _temp => '$_primary.tmp';

  @override
  Future<LoadResult> load() async {
    final primary = await _tryRead(_primary);
    if (primary.data != null) return primary;

    // Primary missing or corrupt — try the backup before giving up.
    final backup = await _tryRead(_backup);
    if (backup.data != null) {
      return LoadResult(
        data: backup.data,
        recovered: true,
        error: primary.error == null
            ? null
            : 'primary unreadable (${primary.error}); restored from backup',
      );
    }

    // Nothing readable. Report the primary's error if it had one, otherwise
    // this is a genuine first run.
    return LoadResult(error: primary.error);
  }

  Future<LoadResult> _tryRead(String path) async {
    final file = File(path);
    if (!await file.exists()) return const LoadResult();
    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return const LoadResult(error: 'empty snapshot file');
      }
      final decoded = jsonDecode(raw);
      final data = AppData.fromJson(decoded);
      if (data == null) {
        return const LoadResult(error: 'snapshot has an unsupported shape');
      }
      return LoadResult(data: data);
    } on FormatException catch (e) {
      return LoadResult(error: 'snapshot is not valid JSON: ${e.message}');
    } on FileSystemException catch (e) {
      return LoadResult(error: 'snapshot unreadable: ${e.message}');
    }
  }

  @override
  Future<void> save(AppData data) async {
    final dir = Directory(_dir);
    if (!await dir.exists()) await dir.create(recursive: true);

    final primary = File(_primary);
    final temp = File(_temp);

    await temp.writeAsString(jsonEncode(data.toJson()), flush: true);

    // Keep the previous snapshot as the backup. A failure here must not abort
    // the save — the backup is a convenience, the primary is the payload.
    if (await primary.exists()) {
      try {
        await primary.copy(_backup);
      } on FileSystemException {
        /* backup is best-effort */
      }
    }

    // `rename` over an existing file is atomic on both NTFS and POSIX.
    try {
      await temp.rename(_primary);
    } on FileSystemException {
      // Some Windows AV products hold a transient lock on the target. Retry
      // once after copying the bytes, which is why the temp file is still here.
      try {
        await temp.copy(_primary);
        await temp.delete();
      } on FileSystemException catch (e) {
        throw SnapshotWriteException(_primary, e);
      }
    }
  }

  @override
  Future<void> clear() async {
    for (final path in [_primary, _backup, _temp]) {
      final f = File(path);
      try {
        if (await f.exists()) await f.delete();
      } on FileSystemException {
        /* nothing to do: the store treats clear as best-effort */
      }
    }
  }
}

class SnapshotWriteException implements Exception {
  SnapshotWriteException(this.path, this.cause);
  final String path;
  final FileSystemException cause;

  @override
  String toString() => 'could not write $path: ${cause.message}';
}

/// An in-memory [Persistence] for widget tests.
class MemoryStore implements Persistence {
  AppData? _data;
  int saves = 0;

  MemoryStore([this._data]);

  @override
  Future<LoadResult> load() async => LoadResult(data: _data);

  @override
  Future<void> save(AppData data) async {
    _data = data;
    saves++;
  }

  @override
  Future<void> clear() async {
    _data = null;
  }
}
