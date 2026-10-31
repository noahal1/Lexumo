/// The network half of sync: one HTTP client, one endpoint contract.
///
/// This is deliberately the *only* file that knows the wire protocol is
/// HTTP+JSON, and it is deliberately thin. Everything interesting — what to
/// send, what to do with what comes back, how to settle pending flags — lives
/// in `sync_merge.dart`, which is pure and already covered by tests. Swapping
/// the backend (a Postgres function behind Supabase RPC, say) means writing
/// another [SyncTransport], not touching the merge logic. See
/// `docs/supabase-sync-plan.md`.
///
/// Written on `dart:io`'s [HttpClient] rather than `package:http` because the
/// whole app has three dependencies and none of them is an HTTP client; adding
/// one for a few hundred lines would also mean the transport could no longer be
/// pointed at a local `127.0.0.1` server in a widget test without a plugin.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Why a round failed, in terms the UI can translate.
///
/// `offline` covers "no route to host", "connection refused" and timeouts
/// alike: from the user's side they are the same fact, and the recovery is the
/// same (try again when the network is back).
enum SyncError {
  offline('offline'),
  unauthorized('unauthorized'),
  server('server'),
  badCredentials('bad_credentials'),
  emailTaken('email_taken'),
  weakPassword('weak_password'),
  invalidEmail('invalid_email');

  const SyncError(this.wire);

  /// The string the server sends in `{"error": ...}`.
  final String wire;

  /// Map a server `error` code to a kind, defaulting by HTTP status.
  static SyncError fromCode(String? code, int status) {
    for (final value in SyncError.values) {
      if (value.wire == code && value != SyncError.offline && value != SyncError.server) {
        return value;
      }
    }
    return status == 401 ? SyncError.unauthorized : SyncError.server;
  }
}

/// A failed request, carrying the translated reason and the raw status.
class SyncHttpError implements Exception {
  const SyncHttpError(this.kind, this.status);

  final SyncError kind;
  final int status;

  @override
  String toString() => 'SyncHttpError(${kind.wire}, $status)';
}

/// The seam a backend swap replaces.
abstract class SyncTransport {
  /// Perform one request and return the decoded JSON body (`null` for 204).
  ///
  /// Throws [SyncHttpError] for anything that is not a 2xx, including the
  /// network being down ([SyncError.offline] with status `0`).
  Future<Object?> request(
    String server,
    String path, {
    String method = 'GET',
    Object? body,
    String? token,
  });

  void close();
}

/// A transport that needs credentials beyond the bearer token.
///
/// Supabase wants a project anon key on every request, and mints its short-lived
/// access tokens from a long-lived refresh token; the reference server wants
/// neither. The engine tests `transport is CredentialAware` rather than growing
/// two optional parameters that every other transport would have to ignore.
abstract class CredentialAware {
  /// Hand over the credentials for the session about to be used.
  ///
  /// Called on startup from the saved session and after every sign-in, because
  /// a transport may be reused across sign-outs and must not keep the previous
  /// user's key.
  void useCredentials({required String anonKey, required String refreshToken});

  /// Called with `{token, email}` whenever a new access token is minted, so the
  /// engine can persist it. Pass `null` to stop being called.
  set onTokenMinted(void Function(Map<String, Object?> session)? callback);
}

/// Real transport: `dart:io` [HttpClient].
class IoTransport implements SyncTransport {
  IoTransport({HttpClient? client, this.timeout = const Duration(seconds: 20)})
      : _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 10);
  }

  final HttpClient _client;

  /// Whole-request budget. A sync round is small, so anything slower than this
  /// is a broken network, not a slow server — and blocking the UI forever on a
  /// hung socket is worse than reporting `offline`.
  final Duration timeout;

  @override
  Future<Object?> request(
    String server,
    String path, {
    String method = 'GET',
    Object? body,
    String? token,
  }) async {
    final uri = Uri.parse('$server$path');
    final HttpClientResponse response;
    try {
      final request = await _client.openUrl(method, uri).timeout(timeout);
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      if (token != null && token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      if (body != null) {
        request.add(utf8.encode(jsonEncode(body)));
      }
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

    final text = await response.transform(utf8.decoder).join().timeout(timeout);

    if (response.statusCode == HttpStatus.noContent) return null;

    Object? payload;
    if (text.isNotEmpty) {
      try {
        payload = jsonDecode(text);
      } catch (_) {
        payload = null;
      }
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final code = payload is Map ? payload['error'] : null;
      throw SyncHttpError(
        SyncError.fromCode(code is String ? code : null, response.statusCode),
        response.statusCode,
      );
    }
    return payload;
  }

  @override
  void close() => _client.close(force: true);
}
