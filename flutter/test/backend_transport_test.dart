// Tests for the transport that routes between the two backends.
//
// The interesting part is not "does it forward a request" — it is the routing
// decision and the credential hand-off, because a mistake in either is silent:
// a bearer token sent to the wrong path comes back as a plain 404 the UI reads
// as `server`, and a stale anon key comes back as `unauthorized`, which the
// engine treats as "your session died" and signs the user out.
//
// Like `supabase_transport_test.dart`, this runs against a real `dart:io`
// [HttpServer]: a mocked `HttpClient` would have to reimplement half of
// `HttpClientResponse` to be a fake server anyway, and the seam worth testing
// is precisely which socket gets opened.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lexumo/data/services/backend_transport.dart';
import 'package:lexumo/data/services/sync_transport.dart';

/// A local server that records what arrived and answers with a fixed body.
class _Recorder {
  final List<String> paths = <String>[];
  final List<Map<String, String>> headers = <Map<String, String>>[];
  HttpServer? _server;

  String get base => 'http://127.0.0.1:${_server!.port}';

  Future<void> start([Object? body]) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((HttpRequest request) async {
      await utf8.decoder.bind(request).join();
      paths.add(request.uri.path);
      final seen = <String, String>{};
      request.headers.forEach((name, values) => seen[name.toLowerCase()] = values.join(','));
      headers.add(seen);

      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(body ?? const <String, Object?>{}));
      await request.response.close();
    });
  }

  Future<void> stop() async => _server?.close(force: true);
}

void main() {
  group('detectBackend', () {
    test('a hosted Supabase URL is recognised', () {
      expect(
        detectBackend('https://abcdefghijklmnop.supabase.co'),
        SyncBackend.supabase,
      );
      // The legacy `.in` domain still resolves for older projects.
      expect(
        detectBackend('https://abcdefghijklmnop.supabase.in'),
        SyncBackend.supabase,
      );
    });

    test('routing survives case and a trailing slash', () {
      // Users paste URLs straight out of a dashboard, which is all lowercase,
      // but nothing stops them from retyping one. `normalizeServer` strips the
      // trailing slash before a round, so only the casing is on this function.
      expect(detectBackend('HTTPS://ABC.SUPABASE.CO/'), SyncBackend.supabase);
    });

    test('the reference server is the default', () {
      expect(detectBackend('http://127.0.0.1:8787'), SyncBackend.reference);
      expect(detectBackend('http://localhost:8787'), SyncBackend.reference);
      expect(detectBackend('https://sync.example.com'), SyncBackend.reference);
      // A blank field is the state the settings page opens in.
      expect(detectBackend(''), SyncBackend.reference);
    });

    test('a lookalike domain is not mistaken for Supabase', () {
      // `.supabase.co` must be a domain boundary, not any substring: the host
      // below merely *contains* the word, and treating it as Supabase would
      // send the anon key and a bearer token to a stranger's server.
      expect(
        detectBackend('https://supabase.co.attacker.test'),
        SyncBackend.reference,
      );
      expect(detectBackend('https://mysupabase.co'), SyncBackend.reference);
    });
  });

  group('BackendTransport', () {
    test('an explicit backend overrides the URL', () {
      // Self-hosted Supabase runs on a custom domain, where the URL says
      // nothing about the wire. Without the override those users could never
      // sync at all.
      final transport = BackendTransport(backend: SyncBackend.supabase);
      addTearDown(transport.close);
      expect(
        transport.backendFor('https://sync.example.com'),
        SyncBackend.supabase,
      );
    });

    test('a Supabase session without a key fails as unauthorized', () async {
      final transport = BackendTransport();
      addTearDown(transport.close);

      // Not offline and not server: the user pointed at Supabase but never
      // pasted the project key. `unauthorized` is the one kind the settings
      // page already explains, so no new error string is needed.
      expect(
        () => transport.request('https://x.supabase.co', '/api/sync', method: 'POST'),
        throwsA(
          isA<SyncHttpError>()
              .having((e) => e.kind, 'kind', SyncError.unauthorized),
        ),
      );
    });

    test('a reference-server session keeps using the plain transport', () async {
      // The decisive test for the seam. A user who once pasted a Supabase key
      // must not have their reference server break afterwards: if routing
      // keyed on "do we have a key" rather than "where does this go", every
      // later request would head for the wrong endpoints.
      final server = _Recorder();
      await server.start(<String, Object?>{'ok': true});
      addTearDown(server.stop);

      final transport = BackendTransport(key: 'anon-1', storedRefresh: 'r');
      addTearDown(transport.close);
      transport.useCredentials(anonKey: 'anon-1', refreshToken: 'r');

      expect(transport.backendFor(server.base), SyncBackend.reference);
      final body = await transport.request(server.base, '/api/health');
      expect(body, <String, Object?>{'ok': true});
      expect(server.paths, <String>['/api/health']);
    });

    test('Supabase traffic goes to the translated paths', () async {
      // The other half of the seam: with a key and a Supabase URL, the
      // reference path must be rewritten rather than forwarded. `/api/sync`
      // becomes an RPC call, which is the whole reason the transport exists.
      final server = _Recorder();
      await server.start(<String, Object?>{'rev': 0, 'changes': <String, Object?>{}});
      addTearDown(server.stop);

      final transport = BackendTransport(key: 'anon-1', backend: SyncBackend.supabase);
      addTearDown(transport.close);
      transport.useCredentials(anonKey: 'anon-1', refreshToken: '');

      await transport.request(server.base, '/api/sync', method: 'POST');
      expect(server.paths, <String>['/rest/v1/rpc/sync']);
      // The project key rides every request; without it the gateway 401s.
      expect(server.headers.single['apikey'], 'anon-1');
    });

    test('the key can be swapped between sessions', () async {
      // Signing out and back in as someone else changes the project key. The
      // cached Supabase transport holds the previous one and is dropped, so
      // the next request must carry the new key.
      final server = _Recorder();
      await server.start(<String, Object?>{'rev': 0, 'changes': <String, Object?>{}});
      addTearDown(server.stop);

      final transport = BackendTransport(key: 'anon-1', backend: SyncBackend.supabase);
      addTearDown(transport.close);

      transport.useCredentials(anonKey: 'anon-1', refreshToken: '');
      await transport.request(server.base, '/api/sync', method: 'POST');

      transport.useCredentials(anonKey: 'anon-2', refreshToken: '');
      await transport.request(server.base, '/api/sync', method: 'POST');

      expect(server.headers.map((h) => h['apikey']), <String>['anon-1', 'anon-2']);
    });

    test('the token callback fires through the routing layer', () async {
      // A refresh replaces a one-hour access token mid-session. The engine
      // persists whatever the callback receives, so the routing layer must not
      // be a dead end for it.
      final server = _Recorder();
      await server.start(
        <String, Object?>{
          'access_token': 'fresh-access',
          'refresh_token': 'fresh-refresh',
          'user': <String, Object?>{'email': 'me@example.com'},
        },
      );
      addTearDown(server.stop);

      final transport = BackendTransport(key: 'anon-1', backend: SyncBackend.supabase);
      addTearDown(transport.close);
      Map<String, Object?>? minted;
      transport.onTokenMinted = (session) => minted = session;

      transport.useCredentials(anonKey: 'anon-1', refreshToken: 'stale-refresh');
      await transport.request(server.base, '/api/auth/login', method: 'POST');

      expect(minted?['token'], 'fresh-access');
      expect(minted?['refreshToken'], 'fresh-refresh');
      expect(minted?['email'], 'me@example.com');
    });
  });
}
