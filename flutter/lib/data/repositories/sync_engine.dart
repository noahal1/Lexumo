/// The sync engine: one round at a time, and the loop that schedules rounds.
///
/// A port of the web build's `sync.ts` (389 lines). The shape is unchanged because the
/// shape is the design: **one `POST /api/sync` per round** that both pushes
/// everything pending and pulls everything newer than this device's cursor. The
/// server applies before it answers, so a round is a single exchange and there
/// is no "did my push land" state to reconcile.
///
/// Three properties are load-bearing and easy to break:
///
///   · **Concurrent callers share one request.** Two taps on "sync now" while a
///     round is in flight must not send two rounds; two in-flight rounds
///     would push the same pending records twice and race on the cursor.
///   · **Encode at the edge.** The snapshot may hold records decoded from the
///     wire; re-encoding through [encodeChangeSet] is what keeps `_rev` (and an
///     empty string where the server expects an absent key) out of the request.
///   · **An `unauthorized` answer signs out.** A revoked token retried every 15
///     seconds forever is a hot loop against a server that will never say yes.
///
/// The engine holds no UI state. [SyncStatus] is published to listeners and the
/// settings page renders it; nothing here imports a widget.
library;

import 'dart:async';

import 'store.dart';
import '../models/sync_config.dart';
import '../models/sync_merge.dart';
import '../services/sync_transport.dart';
import '../models/wire.dart';

/// What the settings page shows.
enum SyncState { signedOut, idle, syncing, error }

/// A snapshot of sync state for rendering.
class SyncStatus {
  const SyncStatus({
    required this.state,
    this.error,
    this.lastSyncAt = 0,
    this.pending = 0,
    this.email = '',
    this.server = kDefaultServer,
    this.anonKey = kDefaultAnonKey,
  });

  final SyncState state;
  final SyncError? error;
  final int lastSyncAt;
  final int pending;
  final String email;
  final String server;

  /// The Supabase project key of the saved session, so the sign-in form can
  /// prefill it. Falls back to [kDefaultAnonKey] when there is no session, which
  /// is what a fresh install should show.
  final String anonKey;

  bool get isSignedIn => state != SyncState.signedOut;

  SyncStatus copyWith({
    SyncState? state,
    SyncError? error,
    bool clearError = false,
    int? lastSyncAt,
    int? pending,
    String? email,
    String? server,
    String? anonKey,
  }) {
    return SyncStatus(
      state: state ?? this.state,
      error: clearError ? null : (error ?? this.error),
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      pending: pending ?? this.pending,
      email: email ?? this.email,
      server: server ?? this.server,
      anonKey: anonKey ?? this.anonKey,
    );
  }
}

class SyncEngine {
  SyncEngine({
    required this.store,
    required this.configStore,
    required this.transport,
  });

  final Store store;
  final SyncConfigStore configStore;
  final SyncTransport transport;

  SyncConfig? _config;
  SyncStatus _status = const SyncStatus(state: SyncState.signedOut);
  final List<void Function()> _listeners = [];

  bool _started = false;

  /// Detaches the pending-count listener installed by [start].
  void Function()? _detachStore;

  /// In-flight round, shared by every concurrent caller.
  Future<bool>? _inFlight;

  /// Set while the app is being torn down, so a late response does not publish.
  bool _disposed = false;

  /// The Supabase project key of the sign-in in flight. Held only until the
  /// resulting [SyncConfig] exists and can carry it durably.
  String _pendingAnonKey = '';

  SyncStatus get status => _status;
  SyncConfig? get config => _config;
  bool get isSignedIn => _config != null;

  /// Subscribe to [status] changes. Returns an unsubscribe function.
  void Function() addListener(void Function() listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void _publish(SyncStatus next) {
    if (_disposed) return;
    _status = next.copyWith(pending: store.pendingChangeCount());
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  SyncStatus _derived(SyncConfig? config, {SyncState? state, SyncError? error, bool clearError = false}) {
    return SyncStatus(
      state: state ?? (config == null ? SyncState.signedOut : SyncState.idle),
      error: clearError ? null : error,
      lastSyncAt: config?.lastSyncAt ?? 0,
      pending: store.pendingChangeCount(),
      email: config?.email ?? '',
      server: config?.server ?? kDefaultServer,
      anonKey: config?.anonKey ?? kDefaultAnonKey,
    );
  }

  /// Read the saved session, then boot the engine.
  Future<void> init() async {
    _config = await configStore.load();
    _adoptCredentials(_config);
    _publish(_derived(_config));
    start();
  }

  /// Hand the session's credentials to the transport, if it wants any.
  ///
  /// Only Supabase does: it needs the project anon key on every request and
  /// mints one-hour access tokens from a refresh token. The reference server
  /// needs neither, and a plain [IoTransport] is not
  /// [CredentialAware], so this is a no-op for it.
  void _adoptCredentials(SyncConfig? config) {
    final conn = _credentials;
    if (conn == null) return;
    // Nothing saved yet means nothing to adopt. Calling through anyway would
    // be harmless — the transport ignores an empty key — but a round trip
    // through an empty config is the kind of thing that later grows a bug.
    if (config == null) return;
    conn.useCredentials(
      anonKey: config.anonKey,
      refreshToken: config.refreshToken,
    );
    conn.onTokenMinted = (session) {
      final current = _config;
      // A refresh can land after the user signed out; writing it back would
      // resurrect a session the user just ended.
      if (current == null) return;
      final token = session['token'];
      final refresh = session['refreshToken'];
      final email = session['email'];
      final next = current.copyWith(
        token: token is String && token.isNotEmpty ? token : null,
        refreshToken: refresh is String && refresh.isNotEmpty ? refresh : null,
        email: email is String && email.isNotEmpty ? email : null,
      );
      _config = next;
      // Fire and forget: a failed write costs the user one sign-in, and
      // blocking a refresh on disk I/O would stall the request ahead of it.
      unawaited(configStore.save(next));
    };
  }

  /// Boot the engine (idempotent).
  ///
  /// Sync is manual by design: nothing here schedules a round behind the
  /// user's back — no poll timer, no push-after-edit debounce. The one
  /// automatic round is the **first** one for a device that has never
  /// completed a sync (`lastSyncAt == 0`): a fresh sign-in, or one whose
  /// first round was cut short because the app closed mid-flight. Without
  /// it the account's words would stay invisible until the user found
  /// "sync now", which is not what signing in promises.
  void start() {
    if (_started) return;
    _started = true;

    // Republish when the pending count moves, so the settings page's "N records
    // waiting" line stays honest between manual rounds. This only records a
    // number — it schedules nothing.
    _detachStore = store.addListener(() {
      if (_status.pending == store.pendingChangeCount()) return;
      _publish(_status);
    });

    final config = _config;
    if (config != null && config.lastSyncAt == 0) {
      unawaited(syncNow());
    }
  }

  void stop() {
    _detachStore?.call();
    _detachStore = null;
    _started = false;
  }

  /// Release listeners and the socket pool.
  void dispose() {
    _disposed = true;
    stop();
    _listeners.clear();
    transport.close();
  }

  /* ---------------------------------------------------------------- */
  /* Auth                                                             */
  /* ---------------------------------------------------------------- */

  /// Check that a server answers `/api/health`. Never throws.
  ///
  /// [anonKey] is only meaningful for Supabase, whose gateway rejects every
  /// request without the project key. It has to be primed here too: a health
  /// check runs before any [SyncConfig] exists, so nothing has handed the
  /// transport a key yet, and `BackendTransport` answers a keyless Supabase
  /// request with `unauthorized` — which would read as "cannot reach the
  /// server" when the server was fine and only the key was missing.
  Future<bool> testConnection(String server, {String anonKey = ''}) async {
    _primeCredentials(anonKey);
    try {
      await transport.request(normalizeServer(server), '/api/health');
      return true;
    } on SyncHttpError {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Register, then adopt the session. Throws [SyncHttpError] on failure.
  Future<void> register(
    String server,
    String email,
    String password, {
    String anonKey = '',
  }) async {
    _primeCredentials(anonKey);
    final payload = await transport.request(
      normalizeServer(server),
      '/api/auth/register',
      method: 'POST',
      body: {'email': email, 'password': password},
    );
    await _adoptSession(server, payload);
  }

  /// Log in, then adopt the session. Throws [SyncHttpError] on failure.
  ///
  /// [anonKey] is only meaningful for Supabase, whose gateway rejects every
  /// request without the project key. The reference server ignores it.
  Future<void> login(
    String server,
    String email,
    String password, {
    String anonKey = '',
  }) async {
    _primeCredentials(anonKey);
    final payload = await transport.request(
      normalizeServer(server),
      '/api/auth/login',
      method: 'POST',
      body: {'email': email, 'password': password},
    );
    await _adoptSession(server, payload);
  }

  /// Give the transport the project key before the first auth call.
  ///
  /// Needed because a sign-in happens before any [SyncConfig] exists — there
  /// is no saved session yet — so [init] cannot have seeded it.
  void _primeCredentials(String anonKey) {
    // An empty key means "nothing new to say", not "forget the key": the
    // reference server never sends one, and a caller that omits it should
    // not silently strip a Supabase project key out from under the transport.
    if (anonKey.isEmpty) return;
    _pendingAnonKey = anonKey;
    final conn = _credentials;
    if (conn == null) return;
    conn.useCredentials(anonKey: anonKey, refreshToken: _config?.refreshToken ?? '');
  }

  /// The transport as a credential-carrying one, or null when it is not.
  ///
  /// The `as dynamic` is deliberate. `CredentialAware` is a sibling interface of
  /// [SyncTransport], not a subtype, and Dart only promotes a value to a
  /// *subtype* of its declared type — so `conn is CredentialAware` on a
  /// `SyncTransport`-typed variable narrows nothing, and returning it fails to
  /// compile. Starting from `dynamic` makes the check an ordinary downcast.
  CredentialAware? get _credentials {
    final conn = transport as dynamic;
    return conn is CredentialAware ? conn : null;
  }

  Future<void> _adoptSession(String server, Object? payload) async {
    final body = payload is Map ? payload : const <String, dynamic>{};
    final token = body['token'];
    if (token is! String || token.isEmpty) {
      throw const SyncHttpError(SyncError.server, 0);
    }
    final config = SyncConfig(
      server: normalizeServer(server),
      email: body['email'] is String ? body['email'] as String : '',
      token: token,
      anonKey: _pendingAnonKey,
      refreshToken: body['refreshToken'] is String ? body['refreshToken'] as String : '',
      // Start from zero so the first round pulls the whole account down; local
      // pending records go out in that same round.
      rev: 0,
      lastSyncAt: 0,
    );
    _config = config;
    await configStore.save(config);
    _publish(_derived(config, clearError: true));
  }

  /// Drop the local session, best-effort revoking it on the server.
  Future<void> signOut() async {
    final previous = _config;
    _config = null;
    await configStore.clear();
    _publish(_derived(null, clearError: true));
    if (previous == null) return;
    try {
      await transport.request(
        previous.server,
        '/api/auth/logout',
        method: 'POST',
        token: previous.token,
      );
    } catch (_) {
      /* the local session is already gone; the server will expire the token */
    }
  }

  /* ---------------------------------------------------------------- */
  /* Rounds                                                           */
  /* ---------------------------------------------------------------- */

  /// Push local changes and merge whatever the server has newer.
  ///
  /// Returns true when the round succeeded. Concurrent callers share one
  /// request.
  Future<bool> syncNow() {
    final running = _inFlight;
    if (running != null) return running;
    // The wrapped future is what gets stored, not the inner one: `whenComplete`
    // returns a *new* future, so storing `round` would hand the second caller a
    // different object and quietly break the sharing contract.
    final shared = _runSync().whenComplete(() {
      _inFlight = null;
    });
    _inFlight = shared;
    return shared;
  }

  Future<bool> _runSync() async {
    final config = _config;
    if (config == null) {
      _publish(_derived(null));
      return false;
    }

    _publish(_derived(config, state: SyncState.syncing, clearError: true));

    // Two forms of the same thing, and both are needed: the typed delta is what
    // `applyRound` settles against, the encoded map is what goes on the wire.
    final delta = collectChanges(store.data);
    final sent = encodeChangeSet(delta);

    try {
      final payload = await transport.request(
        config.server,
        '/api/sync',
        method: 'POST',
        token: config.token,
        body: {
          'since': config.rev,
          'changes': hasChanges(delta) ? sent : EMPTY_CHANGES.toJson(),
        },
      );

      final body = payload is Map ? payload : const <String, dynamic>{};
      final rev = body['rev'] is num ? (body['rev'] as num).toInt() : config.rev;
      final serverTime = body['serverTime'] is num ? (body['serverTime'] as num).toInt() : 0;

      // One round, one call: `applyRound` owns the settle-then-merge order, so
      // the "clear before merge" rule cannot be forgotten here. Decoding first
      // keeps the server's `_rev` out of the snapshot and out of any backup.
      store.applyMerged(applyRound(
        store.data,
        SyncRound(sent: delta, received: decodeChangeSet(body['changes'])),
      ));

      // Rebase on the *current* config, not the snapshot taken before the
      // request. A 401 mid-round can mint a new access token (and a new
      // refresh token); saving over that with the stale fields would discard
      // the only credentials that still work, so the next launch would try to
      // refresh with a token the server has already rotated away.
      final next = (_config ?? config).copyWith(
        rev: rev,
        lastSyncAt: serverTime != 0 ? serverTime : DateTime.now().millisecondsSinceEpoch,
      );
      _config = next;
      await configStore.save(next);
      _publish(_derived(next, clearError: true));
      return true;
    } on SyncHttpError catch (err) {
      if (err.kind == SyncError.unauthorized) {
        _config = null;
        await configStore.clear();
        _publish(_derived(null, error: SyncError.unauthorized));
        return false;
      }
      _publish(_derived(config, state: SyncState.error, error: err.kind));
      return false;
    } catch (_) {
      _publish(_derived(config, state: SyncState.error, error: SyncError.offline));
      return false;
    }
  }

  /// The changes this device would push right now, for the settings page's
  /// "N records waiting" line and for tests.
  ChangeSet pendingChanges() => collectChanges(store.data);
}
