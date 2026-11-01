/// A [SyncTransport] that talks to Supabase instead of the reference server.
///
/// This file is the payoff of the seam described in `sync_transport.dart`:
/// [SyncEngine] only knows this interface, so pointing the app at Supabase is
/// a constructor argument, not a rewrite. Nothing in `sync_merge.dart`,
/// `wire.dart`, `journal.dart` or `store.dart` changes.
///
/// The mapping, from the reference server's REST paths to Supabase's:
///
/// | engine asks for              | Supabase endpoint                                  |
/// | ---------------------------- | -------------------------------------------------- |
/// | `GET  /api/health`           | `GET  /auth/v1/health`                             |
/// | `POST /api/auth/register`    | `POST /auth/v1/signup`                             |
/// | `POST /api/auth/login`       | `POST /auth/v1/token?grant_type=password`          |
/// | `POST /api/auth/logout`      | `POST /auth/v1/logout`                             |
/// | `POST /api/sync`             | `POST /rest/v1/rpc/sync`                           |
///
/// Two things differ in shape and are translated here rather than upstream:
///
/// 1. **The session object.** GoTrue returns `{access_token, refresh_token,
///    expires_at, user: {email, ...}}`; the engine expects `{token, email}`.
///    Adopting the engine's own shape keeps [SyncEngine] ignorant of which
///    auth provider is behind it.
/// 2. **The token expires.** A Supabase access token lasts an hour, where the
///    reference server's opaque token lasted thirty days. A refresh token is
///    therefore kept alongside it and exchanged on a 401, once, before the
///    failure is reported. Without this the sync would silently stop working
///    an hour after sign-in — a bug that only shows up on long sessions.
///
/// The `apikey` header is required on every request by Supabase's gateway. It
/// is the project's *anon* key: public by design, safe to embed, and it grants
/// nothing without a signed-in session (the RLS policies and the
/// `security definer` function do the authorising).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'sync_transport.dart';

/// Translate the reference server's paths into Supabase's.
class SupabaseTransport implements SyncTransport {
  SupabaseTransport({
    required this.anonKey,
    HttpClient? client,
    this.timeout = const Duration(seconds: 20),
    this.onSessionRefreshed,
  }) : _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 10);
  }

  /// The project's anon key. Public; see the library doc.
  final String anonKey;

  final HttpClient _client;
  final Duration timeout;

  /// Called with `{token, email, refreshToken}` whenever a refresh produced a
  /// new access token, so the caller can persist it. Persisting is the
  /// caller's job because this class deliberately holds no storage.
  ///
  /// Mutable rather than final: [BackendTransport] installs it after
  /// construction, because its own callback closes over the field that routes
  /// the next request.
  void Function(Map<String, Object?> session)? onSessionRefreshed;

  /// Refresh token from the last successful auth call, if any. Kept in memory
  /// only; `sync_config.dart` owns durability for the access token.
  String? _refreshToken;

  /// The access token the last refresh returned, so a single 401 does not
  /// trigger a refresh storm across queued calls.
  String? _refreshedAccessToken;

  @override
  Future<Object?> request(
    String server,
    String path, {
    String method = 'GET',
    Object? body,
    String? token,
  }) async {
    final base = _normalize(server);
    final call = _route(base, path, method, body);

    final response = await _send(call, token);
    if (response.statusCode != 401 || _refreshToken == null) {
      return _decode(response);
    }

    // 401 with a refresh token in hand: the access token aged out. Exchange it
    // and retry exactly once — a second 401 is a real credential problem.
    final refreshed = await _refresh(base);
    if (refreshed == null) return _decode(response);
    return _decode(await _send(call, refreshed));
  }

  /// A prepared request, separated from sending so the 401 retry can resend it.
  ({String url, String method, Map<String, String> headers, String? body}) _route(
    String base,
    String path,
    String method,
    Object? body,
  ) {
    final encoded = body == null ? null : jsonEncode(body);
    final headers = <String, String>{
      'apikey': anonKey,
      'content-type': 'application/json',
    };

    switch (path) {
      case '/api/health':
        return (url: '$base/auth/v1/health', method: 'GET', headers: headers, body: null);

      case '/api/auth/register':
        // `signup` returns a session when email confirmation is off, which is
        // the configuration `supabase/config.toml` sets up.
        return (url: '$base/auth/v1/signup', method: 'POST', headers: headers, body: encoded);

      case '/api/auth/login':
        return (
          url: '$base/auth/v1/token?grant_type=password',
          method: 'POST',
          headers: headers,
          body: encoded,
        );

      case '/api/auth/logout':
        return (url: '$base/auth/v1/logout', method: 'POST', headers: headers, body: null);

      case '/api/sync':
        // The one substantive endpoint. `sync` is the RPC defined in
        // `supabase/migrations/0001_sync.sql`.
        return (url: '$base/rest/v1/rpc/sync', method: 'POST', headers: headers, body: encoded);

      default:
        throw SyncHttpError(SyncError.server, 404);
    }
  }

  Future<HttpClientResponse> _send(
    ({String url, String method, Map<String, String> headers, String? body}) call,
    String? token,
  ) async {
    final HttpClientResponse response;
    try {
      final request = await _client.openUrl(call.method, Uri.parse(call.url)).timeout(timeout);
      call.headers.forEach(request.headers.set);
      if (token != null && token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      if (call.body != null) request.add(utf8.encode(call.body!));
      response = await request.close().timeout(timeout);
    } on TimeoutException {
      throw const SyncHttpError(SyncError.offline, 0);
    } on SocketException {
      throw const SyncHttpError(SyncError.offline, 0);
    } on HttpException {
      throw const SyncHttpError(SyncError.offline, 0);
    } on HandshakeException {
      throw const SyncHttpError(SyncError.offline, 0);
    }
    return response;
  }

  Future<Object?> _decode(HttpClientResponse response) async {
    final text = await response.transform(utf8.decoder).join().timeout(timeout);
    Object? payload;
    if (text.isNotEmpty) {
      try {
        payload = jsonDecode(text);
      } catch (_) {
        payload = null;
      }
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SyncHttpError(_classify(payload, response.statusCode), response.statusCode);
    }

    // Reshape GoTrue's session into what the engine expects, and remember the
    // refresh token while doing it.
    if (payload is Map && _looksLikeSession(payload)) {
      return _adoptSession(payload);
    }
    return payload;
  }

  bool _looksLikeSession(Map payload) =>
      payload['access_token'] is String || payload['refresh_token'] is String;

  Map<String, Object?> _adoptSession(Map payload) {
    final access = payload['access_token'];
    final refresh = payload['refresh_token'];
    final user = payload['user'];

    final token = access is String && access.isNotEmpty
        ? access
        : payload['token'] is String
            ? payload['token'] as String
            : null;
    if (token == null) throw const SyncHttpError(SyncError.server, 0);

    if (refresh is String && refresh.isNotEmpty) _refreshToken = refresh;
    _refreshedAccessToken = payload['token'] is String ? null : token;

    final email = user is Map && user['email'] is String ? user['email'] as String : '';
    final session = <String, Object?>{
      'token': token,
      'email': email,
      'refreshToken': _refreshToken ?? '',
    };
    onSessionRefreshed?.call(session);
    return session;
  }

  /// Exchange the refresh token. Returns the new access token, or null.
  Future<String?> _refresh(String base) async {
    final refresh = _refreshToken;
    if (refresh == null || refresh.isEmpty) return null;

    final encoded = jsonEncode({'refresh_token': refresh});
    final response = await _send(
      (
        url: '$base/auth/v1/token?grant_type=refresh_token',
        method: 'POST',
        headers: {'apikey': anonKey, 'content-type': 'application/json'},
        body: encoded,
      ),
      null,
    );

    final body = await _readOrNull(response);
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    if (body is! Map) return null;

    final next = body['refresh_token'];
    if (next is String && next.isNotEmpty) _refreshToken = next;

    final access = body['access_token'];
    if (access is! String || access.isEmpty) return null;
    _refreshedAccessToken = access;

    final user = body['user'];
    final email = user is Map && user['email'] is String ? user['email'] as String : '';
    onSessionRefreshed?.call({
      'token': access,
      'email': email,
      'refreshToken': _refreshToken ?? '',
    });
    return access;
  }

  Future<Object?> _readOrNull(HttpClientResponse response) async {
    try {
      final text = await response.transform(utf8.decoder).join().timeout(timeout);
      if (text.isEmpty) return null;
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  /// Supabase reports failures as HTTP status plus a body shaped either
  /// `{code, message, msg}` (GoTrue) or `{code, message, details, hint}`
  /// (PostgREST). Map both onto the engine's [SyncError] set.
  SyncError _classify(Object? payload, int status) {
    final map = payload is Map ? payload : const {};
    final code = '${map['error_code'] ?? map['code'] ?? map['error'] ?? ''}'.toLowerCase();
    final message = '${map['msg'] ?? map['message'] ?? ''}'.toLowerCase();

    if (code.contains('invalid_credentials') || message.contains('invalid login credentials')) {
      return SyncError.badCredentials;
    }
    if (code.contains('user_already_exists') ||
        code.contains('email_exists') ||
        message.contains('already registered')) {
      return SyncError.emailTaken;
    }
    if (code.contains('weak_password') || message.contains('password should be')) {
      return SyncError.weakPassword;
    }
    if (code.contains('email_address_invalid') ||
        code.contains('validation_failed') ||
        message.contains('invalid email') ||
        message.contains('unable to validate email')) {
      return SyncError.invalidEmail;
    }
    if (status == 401 || status == 403 || code.contains('unauthorized')) {
      return SyncError.unauthorized;
    }
    return SyncError.server;
  }

  /// Project URLs are stored without a trailing slash; the `${base}/auth/...`
  /// concatenations above assume that.
  String _normalize(String server) {
    var value = server.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  /// Whether a refresh token is held, i.e. whether a 401 can be recovered from.
  bool get canRefresh => _refreshToken != null;

  /// Adopt a refresh token from persisted storage on startup, so a session that
  /// outlived its access token can recover without a re-login.
  void hydrate({String? refreshToken}) {
    if (refreshToken != null && refreshToken.isNotEmpty) _refreshToken = refreshToken;
  }

  /// The most recent access token obtained by a refresh, if any.
  String? get refreshedAccessToken => _refreshedAccessToken;

  @override
  void close() => _client.close(force: true);
}
