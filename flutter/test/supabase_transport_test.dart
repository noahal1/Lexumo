// Tests for [SupabaseTransport], the seam that points sync at Supabase.
//
// These run against a real `dart:io` [HttpServer] on an ephemeral port rather
// than a mocked `HttpClient`. A mock would have to reimplement enough of
// `HttpClientResponse` to be a fake HTTP server anyway, and — more to the
// point — the things worth asserting here are exactly the wire details: which
// URL each engine path maps to, that `apikey` rides on every request, that the
// bearer token is the *access* token and not the refresh token, and that a 401
// triggers exactly one refresh and one retry. A local server observes all of
// that without pretending.
//
// The response shapes below are copied from what Supabase actually returns, so
// a wrong assumption about GoTrue or PostgREST fails here rather than on a
// device.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lexumo/data/services/sync_transport.dart';
import 'package:lexumo/data/services/supabase_transport.dart';

/// One captured request plus a canned response.
class _Call {
  _Call(this.method, this.path, this.headers, this.body);
  final String method;
  final String path;
  final Map<String, String> headers;
  final String body;

  Map<String, dynamic> get json => body.isEmpty
      ? const <String, dynamic>{}
      : jsonDecode(body) as Map<String, dynamic>;
}

/// A scripted server: the first [responses] entry answers the first request.
class _FakeSupabase {
  _FakeSupabase(this.responses);

  final List<({int status, Object? body})> responses;
  final List<_Call> calls = <_Call>[];
  HttpServer? _server;

  String get base => 'http://127.0.0.1:${_server!.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((HttpRequest request) async {
      final body = await utf8.decoder.bind(request).join();
      final headers = <String, String>{};
      request.headers.forEach((name, values) => headers[name.toLowerCase()] = values.join(','));
      calls.add(_Call(request.method, '${request.uri.path}${request.uri.hasQuery ? '?${request.uri.query}' : ''}', headers, body));

      final index = calls.length - 1;
      final reply = index < responses.length
          ? responses[index]
          : (status: 200, body: const <String, Object?>{});
      request.response.statusCode = reply.status;
      request.response.headers.contentType = ContentType.json;
      if (reply.body != null) {
        request.response.write(jsonEncode(reply.body));
      }
      await request.response.close();
    });
  }

  Future<void> stop() async => _server?.close(force: true);
}

({int status, Object? body}) _session({
  String access = 'access-1',
  String refresh = 'refresh-1',
  String email = 'a@b.co',
}) =>
    (
      status: 200,
      body: <String, Object?>{
        'access_token': access,
        'refresh_token': refresh,
        'expires_in': 3600,
        'token_type': 'bearer',
        'user': <String, Object?>{'id': 'u-1', 'email': email},
      },
    );

({int status, Object? body}) _syncReply({int rev = 1}) => (
      status: 200,
      body: <String, Object?>{
        'rev': rev,
        'serverTime': 1700000000000,
        'changes': <String, Object?>{
          'lists': <Object?>[],
          'words': <Object?>[],
          'logs': <Object?>[],
          'settings': null,
        },
      },
    );

void main() {
  group('path routing', () {
    test('health maps to /auth/v1/health', () async {
      final fake = _FakeSupabase([(status: 200, body: {'ok': true})]);
      await fake.start();
      final transport = SupabaseTransport(anonKey: 'anon-key');
      addTearDown(() async {
        transport.close();
        await fake.stop();
      });

      await transport.request(fake.base, '/api/health');

      expect(fake.calls.single.method, 'GET');
      expect(fake.calls.single.path, '/auth/v1/health');
    });

    test('login maps to the password grant, and the session is reshaped', () async {
      final fake = _FakeSupabase([_session(email: 'me@example.com')]);
      await fake.start();
      final transport = SupabaseTransport(anonKey: 'anon-key');
      addTearDown(() async {
        transport.close();
        await fake.stop();
      });

      final payload = await transport.request(
        fake.base,
        '/api/auth/login',
        method: 'POST',
        body: {'email': 'me@example.com', 'password': 'pw'},
      );

      final call = fake.calls.single;
      expect(call.method, 'POST');
      // The grant type is in the query string, which is easy to get wrong.
      expect(call.path, '/auth/v1/token?grant_type=password');
      expect(call.json, {'email': 'me@example.com', 'password': 'pw'});

      // The engine expects `{token, email}`, not GoTrue's session object.
      expect(payload, isA<Map>());
      final body = payload! as Map;
      expect(body['token'], 'access-1');
      expect(body['email'], 'me@example.com');
      // The refresh token must not leak into the engine's view.
      expect(body.containsKey('refresh_token'), isFalse);
      expect(transport.canRefresh, isTrue);
    });

    test('register maps to signup', () async {
      final fake = _FakeSupabase([_session()]);
      await fake.start();
      final transport = SupabaseTransport(anonKey: 'anon-key');
      addTearDown(() async {
        transport.close();
        await fake.stop();
      });

      await transport.request(
        fake.base,
        '/api/auth/register',
        method: 'POST',
        body: {'email': 'a@b.co', 'password': 'password123'},
      );

      expect(fake.calls.single.path, '/auth/v1/signup');
    });

    test('sync maps to the rpc endpoint and keeps its body', () async {
      final fake = _FakeSupabase([_syncReply(rev: 7)]);
      await fake.start();
      final transport = SupabaseTransport(anonKey: 'anon-key');
      addTearDown(() async {
        transport.close();
        await fake.stop();
      });

      final payload = await transport.request(
        fake.base,
        '/api/sync',
        method: 'POST',
        token: 'access-1',
        body: {
          'since': 5,
          'changes': {
            'words': [
              {'id': 'w1', 'updatedAt': 100},
            ],
          },
        },
      );

      final call = fake.calls.single;
      expect(call.path, '/rest/v1/rpc/sync');
      expect(call.method, 'POST');
      // `since` and `changes` are the function's two arguments; renaming or
      // nesting them differently would make the RPC unreachable.
      expect(call.json['since'], 5);
      expect((call.json['changes'] as Map)['words'], hasLength(1));

      // The RPC reply is passed through untouched: it is already the shape
      // `decodeChangeSet` wants.
      expect((payload! as Map)['rev'], 7);
    });

    test('an unknown engine path is a server error, not a crash', () async {
      final transport = SupabaseTransport(anonKey: 'anon-key');
      addTearDown(transport.close);

      await expectLater(
        transport.request('http://127.0.0.1:1', '/api/nope'),
        throwsA(isA<SyncHttpError>().having((e) => e.kind, 'kind', SyncError.server)),
      );
    });
  });

  group('headers', () {
    test('apikey rides on every request, including ones with no token', () async {
      final fake = _FakeSupabase([(status: 200, body: {'ok': true})]);
      await fake.start();
      final transport = SupabaseTransport(anonKey: 'the-anon-key');
      addTearDown(() async {
        transport.close();
        await fake.stop();
      });

      await transport.request(fake.base, '/api/health');

      expect(fake.calls.single.headers['apikey'], 'the-anon-key');
      expect(fake.calls.single.headers.containsKey('authorization'), isFalse);
    });

    test('the bearer token is the access token passed in', () async {
      final fake = _FakeSupabase([_syncReply()]);
      await fake.start();
      final transport = SupabaseTransport(anonKey: 'anon-key');
      addTearDown(() async {
        transport.close();
        await fake.stop();
      });

      await transport.request(fake.base, '/api/sync', method: 'POST', token: 'access-1', body: {});

      expect(fake.calls.single.headers['authorization'], 'Bearer access-1');
    });

    test('a trailing slash on the project URL does not produce a double slash', () async {
      final fake = _FakeSupabase([(status: 200, body: {'ok': true})]);
      await fake.start();
      final transport = SupabaseTransport(anonKey: 'anon-key');
      addTearDown(() async {
        transport.close();
        await fake.stop();
      });

      await transport.request('${fake.base}/', '/api/health');

      expect(fake.calls.single.path, '/auth/v1/health');
    });
  });

  group('token refresh', () {
    test('a 401 refreshes once and retries, and the caller sees success', () async {
      final fake = _FakeSupabase([
        // 1. login — must come first, or the very first call is the 401.
        _session(access: 'access-1', refresh: 'refresh-1'),
        // 2. the sync call, rejected because the access token aged out.
        (status: 401, body: {'code': 'expired_jwt', 'message': 'jwt expired'}),
        // 3. the refresh exchange.
        (
          status: 200,
          body: {
            'access_token': 'access-2',
            'refresh_token': 'refresh-2',
            'user': {'email': 'a@b.co'},
          },
        ),
        // 4. the retried sync call.
        _syncReply(rev: 9),
      ]);
      await fake.start();
      final refreshed = <Map<String, Object?>>[];
      final transport = SupabaseTransport(
        anonKey: 'anon-key',
        onSessionRefreshed: refreshed.add,
      );
      addTearDown(() async {
        transport.close();
        await fake.stop();
      });

      // Establish a session so a refresh token is held.
      await transport.request(
        fake.base,
        '/api/auth/login',
        method: 'POST',
        body: {'email': 'a@b.co', 'password': 'pw'},
      );

      final payload = await transport.request(
        fake.base,
        '/api/sync',
        method: 'POST',
        token: 'access-1',
        body: {'since': 0, 'changes': {}},
      );

      // Four calls: login, the rejected sync, the refresh, the retried sync.
      expect(fake.calls, hasLength(4));
      expect(fake.calls[2].path, '/auth/v1/token?grant_type=refresh_token');
      expect(fake.calls[2].json['refresh_token'], 'refresh-1');
      // The retry must carry the NEW token, not the stale one.
      expect(fake.calls[3].headers['authorization'], 'Bearer access-2');
      expect((payload! as Map)['rev'], 9);

      // The caller is told about the new token so it can be persisted.
      expect(refreshed, isNotEmpty);
      expect(refreshed.last['token'], 'access-2');
      expect(transport.canRefresh, isTrue);
    });

    test('a second 401 after refreshing is reported, not retried forever', () async {
      final fake = _FakeSupabase([
        _session(),
        (status: 401, body: {'code': 'expired_jwt'}),
        (status: 200, body: {'access_token': 'access-2', 'refresh_token': 'refresh-2'}),
        (status: 401, body: {'code': 'expired_jwt'}),
      ]);
      await fake.start();
      final transport = SupabaseTransport(anonKey: 'anon-key');
      addTearDown(() async {
        transport.close();
        await fake.stop();
      });

      await transport.request(
        fake.base,
        '/api/auth/login',
        method: 'POST',
        body: {'email': 'a@b.co', 'password': 'pw'},
      );

      await expectLater(
        transport.request(fake.base, '/api/sync', method: 'POST', token: 'access-1', body: {}),
        throwsA(isA<SyncHttpError>().having((e) => e.kind, 'kind', SyncError.unauthorized)),
      );

      // login + 401 + refresh + retry = 4, and no further loop.
      expect(fake.calls, hasLength(4));
    });

    test('a 401 with no refresh token is reported straight away', () async {
      final fake = _FakeSupabase([(status: 401, body: {'code': 'expired_jwt'})]);
      await fake.start();
      final transport = SupabaseTransport(anonKey: 'anon-key');
      addTearDown(() async {
        transport.close();
        await fake.stop();
      });

      await expectLater(
        transport.request(fake.base, '/api/sync', method: 'POST', token: 'stale', body: {}),
        throwsA(isA<SyncHttpError>().having((e) => e.kind, 'kind', SyncError.unauthorized)),
      );
      // No refresh attempt was made, because there is nothing to refresh with.
      expect(fake.calls, hasLength(1));
    });

    test('hydrate adopts a persisted refresh token so a restart can recover', () async {
      final fake = _FakeSupabase([
        (status: 401, body: {'code': 'expired_jwt'}),
        (status: 200, body: {'access_token': 'access-2', 'refresh_token': 'refresh-2'}),
        _syncReply(),
      ]);
      await fake.start();
      final transport = SupabaseTransport(anonKey: 'anon-key');
      addTearDown(() async {
        transport.close();
        await fake.stop();
      });

      // Simulates app start: no session call, just the stored refresh token.
      transport.hydrate(refreshToken: 'persisted-refresh');
      expect(transport.canRefresh, isTrue);

      await transport.request(fake.base, '/api/sync', method: 'POST', token: 'stale', body: {});

      expect(fake.calls[1].path, '/auth/v1/token?grant_type=refresh_token');
      expect(fake.calls[1].json['refresh_token'], 'persisted-refresh');
    });
  });

  group('error classification', () {
    Future<SyncError> kindFor(int status, Object? body) async {
      final fake = _FakeSupabase([(status: status, body: body)]);
      await fake.start();
      final transport = SupabaseTransport(anonKey: 'anon-key');
      try {
        await transport.request(fake.base, '/api/auth/login', method: 'POST', body: {});
      } on SyncHttpError catch (err) {
        return err.kind;
      } finally {
        transport.close();
        await fake.stop();
      }
      fail('expected a SyncHttpError');
    }

    test('invalid credentials, in GoTrue wording', () async {
      expect(
        await kindFor(400, {'error_code': 'invalid_credentials', 'msg': 'Invalid login credentials'}),
        SyncError.badCredentials,
      );
    });

    test('an already-registered email', () async {
      expect(
        await kindFor(422, {'error_code': 'user_already_exists', 'msg': 'User already registered'}),
        SyncError.emailTaken,
      );
    });

    test('a weak password', () async {
      expect(
        await kindFor(422, {'error_code': 'weak_password', 'msg': 'Password should be at least 6 characters'}),
        SyncError.weakPassword,
      );
    });

    test('a malformed email', () async {
      expect(
        await kindFor(400, {'error_code': 'email_address_invalid', 'msg': 'Email address "x" is invalid'}),
        SyncError.invalidEmail,
      );
    });

    test('a missing table or bad RPC is a server error', () async {
      expect(
        await kindFor(404, {'code': 'PGRST202', 'message': 'Could not find the function'}),
        SyncError.server,
      );
    });

    test('a bare 401 without a code is unauthorized', () async {
      expect(await kindFor(401, null), SyncError.unauthorized);
    });
  });

  group('network failures', () {
    test('an unreachable host is offline, not an exception leak', () async {
      final transport = SupabaseTransport(anonKey: 'anon-key');
      addTearDown(transport.close);

      // Port 1 on loopback refuses connections immediately.
      await expectLater(
        transport.request('http://127.0.0.1:1', '/api/health'),
        throwsA(isA<SyncHttpError>().having((e) => e.kind, 'kind', SyncError.offline)),
      );
    });
  });
}
