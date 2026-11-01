/// Where the sync session lives — deliberately **not** in `lexumo.json`.
///
/// The web build kept `SyncConfig` in `localStorage` under `lexumo.sync.v1`
/// (`src/lib/sync.ts:62-89`), apart from the IndexedDB snapshot. That split is
/// not an accident of storage: [Settings] is part of [AppData], and
/// `collectChanges` packs the whole settings record into every upload. A bearer
/// token living in `Settings` would therefore be *synced to the server it
/// authenticates against* — and into every backup file the user exports.
///
/// So the token gets its own file, `sync.json`, a sibling of `lexumo.json` and
/// written with the same atomic discipline (temp file, flush, rename). Losing
/// it costs a re-login; leaking it costs an account.
///
/// The revision (`rev`) lives here too rather than in [AppData]: it is a
/// property of *this device's view of the server*, not of the user's words, and
/// two devices must be free to hold different values.
library;

import 'dart:convert';
import 'dart:io';

import '../services/app_dir.dart';

/// The default server shown in the settings form.
///
/// Points at the self-hosted reference server (`server/`) because that is what
/// runs on this machine during development. A Supabase deployment replaces the
/// transport, not this shape — see `docs/supabase-sync-plan.md`.
const String kDefaultServer = 'http://127.0.0.1:8787';

/// A signed-in session plus this device's sync cursor.
class SyncConfig {
  const SyncConfig({
    required this.server,
    required this.email,
    required this.token,
    this.anonKey = '',
    this.refreshToken = '',
    this.rev = 0,
    this.lastSyncAt = 0,
  });

  /// Normalised: no trailing slashes.
  final String server;
  final String email;
  final String token;

  /// Supabase's project anon key. Public by design (it ships in every web
  /// bundle of every Supabase app); it grants nothing on its own, but the
  /// gateway rejects requests without it. Empty when the session points at the
  /// reference server.
  final String anonKey;

  /// Supabase's refresh token. A Supabase access token lives an hour, where
  /// the reference server's opaque token lived thirty days; without this the
  /// session would die mid-day and the user would be asked to sign in again.
  /// Unlike [token] it is never sent to the sync function, only to the token
  /// endpoint.
  final String refreshToken;

  /// Highest server revision merged so far. `0` means "pull everything", which
  /// is what a freshly adopted session wants.
  final int rev;
  final int lastSyncAt;

  SyncConfig copyWith({
    String? server,
    String? email,
    String? token,
    String? anonKey,
    String? refreshToken,
    int? rev,
    int? lastSyncAt,
  }) {
    return SyncConfig(
      server: server ?? this.server,
      email: email ?? this.email,
      token: token ?? this.token,
      anonKey: anonKey ?? this.anonKey,
      refreshToken: refreshToken ?? this.refreshToken,
      rev: rev ?? this.rev,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'server': server,
        'email': email,
        'token': token,
        'anonKey': anonKey,
        'refreshToken': refreshToken,
        'rev': rev,
        'lastSyncAt': lastSyncAt,
      };

  /// Returns null for anything that cannot authenticate a request. A record
  /// missing `server`, `email` or `token` is a corrupt file, not a session.
  static SyncConfig? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final server = _text(raw['server']);
    final email = _text(raw['email']);
    final token = _text(raw['token']);
    if (server == null || email == null || token == null) return null;
    return SyncConfig(
      server: normalizeServer(server),
      email: email,
      token: token,
      anonKey: _text(raw['anonKey']) ?? '',
      refreshToken: _text(raw['refreshToken']) ?? '',
      rev: raw['rev'] is num ? (raw['rev'] as num).toInt() : 0,
      lastSyncAt: raw['lastSyncAt'] is num ? (raw['lastSyncAt'] as num).toInt() : 0,
    );
  }
}

String? _text(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;

/// Trim and drop trailing slashes so `server + path` never doubles up.
String normalizeServer(String server) {
  final trimmed = server.trim();
  var end = trimmed.length;
  while (end > 0 && trimmed[end - 1] == '/') {
    end--;
  }
  return trimmed.substring(0, end);
}

/// Reads and writes [SyncConfig] as a single JSON file.
abstract class SyncConfigStore {
  Future<SyncConfig?> load();
  Future<void> save(SyncConfig config);
  Future<void> clear();
}

/// The real store: `sync.json` beside `lexumo.json`.
class FileSyncConfigStore implements SyncConfigStore {
  const FileSyncConfigStore({this.path});

  /// Test hook: an explicit file path instead of [AppDir.dataDir].
  final String? path;

  String get file => path ?? '${AppDir.dataDir}${Platform.pathSeparator}sync.json';

  @override
  Future<SyncConfig?> load() async {
    try {
      final handle = File(file);
      if (!await handle.exists()) return null;
      final raw = jsonDecode(await handle.readAsString());
      return SyncConfig.fromJson(raw);
    } catch (_) {
      // A corrupt session file must not brick the app: treat it as signed out
      // and let the user log in again, which overwrites the file.
      return null;
    }
  }

  @override
  Future<void> save(SyncConfig config) async {
    final target = File(file);
    final tmp = File('$file.tmp');
    await tmp.parent.create(recursive: true);
    await tmp.writeAsString(jsonEncode(config.toJson()), flush: true);
    await tmp.rename(target.path);
  }

  @override
  Future<void> clear() async {
    for (final candidate in [file, '$file.tmp']) {
      try {
        final handle = File(candidate);
        if (await handle.exists()) await handle.delete();
      } catch (_) {
        /* best effort — the in-memory session is already gone */
      }
    }
  }
}

/// In-memory store for tests and for a session that should not persist.
class MemorySyncConfigStore implements SyncConfigStore {
  MemorySyncConfigStore([this._config]);

  SyncConfig? _config;

  @override
  Future<SyncConfig?> load() async => _config;

  @override
  Future<void> save(SyncConfig config) async => _config = config;

  @override
  Future<void> clear() async => _config = null;
}
