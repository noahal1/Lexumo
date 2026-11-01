/// Picks the right [SyncTransport] for the server the session points at.
///
/// Two backends speak the same protocol through different wires:
///
/// - the reference server (`server/`, 653 lines of Node) over its own REST
///   paths, driven by [IoTransport];
/// - Supabase, over GoTrue + PostgREST, driven by [SupabaseTransport].
///
/// [SyncEngine] holds one transport and passes it `(server, path, …)` per call,
/// so this class can route on the server URL and the engine never learns that
/// there are two implementations. That is the whole point of the seam.
///
/// **Detection is by URL shape**, because that is the only information the
/// engine hands over and it is unambiguous: a Supabase project URL is always
/// `https://<ref>.supabase.co`. A self-hosted Supabase uses a custom domain,
/// so the `backend:` argument exists for the case where the URL lies.
///
/// The Supabase credentials (anon key, refresh token) are configured here
/// rather than read from disk: `sync_config.dart` persists them and the caller
/// feeds them in, which keeps this class free of storage and therefore
/// testable without a file system.
library;

import 'dart:io';

import 'sync_transport.dart';
import 'supabase_transport.dart';

/// Which wire a session uses.
enum SyncBackend {
  /// `server/` — the reference implementation.
  reference,

  /// Supabase (GoTrue for auth, one Postgres function for sync).
  supabase,
}

/// Guess the backend from a server URL.
///
/// `project.supabase.co` is the hosted shape; `:8787` and bare loopback are
/// the reference server. Anything else defaults to the reference server, which
/// is the safer guess: if a Supabase URL is misread as a reference server the
/// user sees a clear connection error, whereas the reverse would send a bearer
/// token to a path that does not exist.
SyncBackend detectBackend(String server) {
  final value = server.trim().toLowerCase();
  if (value.contains('.supabase.co') || value.contains('.supabase.in')) {
    return SyncBackend.supabase;
  }
  return SyncBackend.reference;
}

class BackendTransport implements SyncTransport, CredentialAware {
  BackendTransport({
    IoTransport? reference,
    HttpClientFactory? httpClient,
    String? key,
    String? storedRefresh,
    SyncBackend? backend,
  })  : _reference = reference ?? IoTransport(),
        _clientFactory = httpClient,
        _anonKey = key,
        _refreshToken = storedRefresh,
        _forced = backend;

  final IoTransport _reference;
  final HttpClientFactory? _clientFactory;
  final SyncBackend? _forced;

  String? _anonKey;
  String? _refreshToken;
  SupabaseTransport? _supabase;

  /// Called with `{token, email}` when Supabase hands back a fresh access
  /// token, so the session file can be updated.
  void Function(Map<String, Object?> session)? _onTokenMinted;

  @override
  set onTokenMinted(void Function(Map<String, Object?> session)? callback) {
    _onTokenMinted = callback;
    _supabase?.onSessionRefreshed = callback;
  }

  /// The access token from the most recent refresh, if a refresh happened.
  String? get refreshedAccessToken => _supabase?.refreshedAccessToken;

  SyncBackend backendFor(String server) => _forced ?? detectBackend(server);

  /// Adopt credentials for the session about to be used.
  ///
  /// The cached Supabase transport is dropped rather than mutated: it holds the
  /// previous user's refresh token, and reusing it across a sign-out would let
  /// the next session inherit the last one's identity if a refresh raced the
  /// switch.
  @override
  void useCredentials({required String anonKey, required String refreshToken}) {
    // An empty key means "nothing new to say", not "forget the key" — the key
    // may have been supplied when this transport was constructed, and the
    // reference server never has one. Wiping it here would make the next
    // Supabase request 401 against its own gateway, which the UI can only
    // report as a credentials problem. The key is public either way.
    if (anonKey.isNotEmpty) _anonKey = anonKey;
    // The refresh token is a secret and is cleared unconditionally: after a
    // sign-out the next session must not inherit the last one's identity.
    _refreshToken = refreshToken;
    _supabase?.close();
    _supabase = null;
  }

  SupabaseTransport _supabaseFor() {
    final existing = _supabase;
    if (existing != null) return existing;

    final key = _anonKey;
    if (key == null || key.isEmpty) {
      // Not a network condition: the user pointed at Supabase but has not
      // pasted a key. Surfacing it as `unauthorized` keeps the UI honest
      // without inventing a new error kind the engine does not know.
      throw const SyncHttpError(SyncError.unauthorized, 401);
    }

    final transport = SupabaseTransport(
      anonKey: key,
      client: _clientFactory?.call(),
    );
    transport.onSessionRefreshed = (session) {
      // The new refresh token supersedes the one this session started with;
      // keeping the old one would make the *next* refresh fail.
      final next = session['refreshToken'];
      if (next is String && next.isNotEmpty) _refreshToken = next;
      _onTokenMinted?.call(session);
    };
    transport.hydrate(refreshToken: _refreshToken);
    _supabase = transport;
    return transport;
  }

  @override
  Future<Object?> request(
    String server,
    String path, {
    String method = 'GET',
    Object? body,
    String? token,
  }) {
    if (backendFor(server) == SyncBackend.supabase) {
      return _supabaseFor().request(server, path, method: method, body: body, token: token);
    }
    return _reference.request(server, path, method: method, body: body, token: token);
  }

  @override
  void close() {
    _reference.close();
    _supabase?.close();
    _supabase = null;
  }
}

/// Injected so tests can hand [SupabaseTransport] a client without reaching
/// for `HttpClient` themselves.
typedef HttpClientFactory = HttpClient Function();
