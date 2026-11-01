/// Tests for the sync engine: `sync_config.dart`, `sync_transport.dart` and
/// `sync_engine.dart`.
///
/// The merge logic already has 36 cases in `sync_merge_test.dart`; what is new
/// here is everything *around* it — the session file, the HTTP envelope, and the
/// round loop. So the tests are shaped by what can actually go wrong there:
///
///   · the token must never reach `AppData` (it would be uploaded);
///   · two concurrent callers must share one request (else a double push);
///   · a round must settle before it merges (else an in-flight edit is lost);
///   · an `unauthorized` answer must clear the session (else a hot retry loop).
///
/// [FakeTransport] answers from a scripted list of responses, so no test touches
/// the network and every test can assert on exactly what was sent.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/data/models/sync_config.dart';
import 'package:lexumo/data/repositories/sync_engine.dart';
import 'package:lexumo/data/services/sync_transport.dart';
import 'package:lexumo/domain/models/types.dart';

const int T0 = 1700000000000;

/* ------------------------------------------------------------------ */
/* Fixtures                                                            */
/* ------------------------------------------------------------------ */

/// One recorded call, and the answer to give it.
class Call {
  Call({
    required this.path,
    required this.method,
    this.body,
    this.token,
    this.reply,
    this.error,
  });

  final String path;
  final String method;
  final Object? body;
  final String? token;

  /// Returned as the decoded JSON body.
  final Object? reply;

  /// Thrown instead of replying, for failure paths.
  final SyncHttpError? error;
}

class FakeTransport implements SyncTransport {
  FakeTransport([List<Call>? script]) : _script = script ?? [];

  final List<Call> _script;
  final List<Call> seen = [];
  bool closed = false;

  /// Queue another answer at the back.
  void push(Call call) => _script.add(call);

  @override
  Future<Object?> request(
    String server,
    String path, {
    String method = 'GET',
    Object? body,
    String? token,
  }) async {
    final call = _script.isNotEmpty
        ? _script.removeAt(0)
        : Call(path: path, method: method, reply: const <String, dynamic>{});
    seen.add(Call(
      path: path,
      method: method,
      body: body,
      token: token,
      reply: call.reply,
      error: call.error,
    ));
    if (call.error != null) throw call.error!;
    return call.reply;
  }

  @override
  void close() => closed = true;
}

AppData emptyData() => const AppData(
      lists: [
        WordList(
          id: DEFAULT_LIST_ID,
          name: 'Default',
          sourceLang: 'en',
          targetLang: 'zh',
          createdAt: T0,
          updatedAt: T0,
        ),
      ],
    );

/// A store with a frozen clock and no save debounce.
class Harness {
  Harness({int start = T0}) : _now = start {
    store = Store(
      persistence: MemoryStore(emptyData()),
      clock: () => _now,
      saveDelayMs: 0,
    );
  }

  late final Store store;
  int _now;

  int advance([int ms = 1000]) => _now += ms;

  AppData get data => store.data;
}

Future<Harness> freshStore({int start = T0}) async {
  final harness = Harness(start: start);
  await harness.store.init();
  return harness;
}

/// A transport that never answers, so a round can be observed mid-flight.
class HangingTransport implements SyncTransport {
  final Completer<Object?> completer = Completer<Object?>();
  int calls = 0;

  @override
  Future<Object?> request(
    String server,
    String path, {
    String method = 'GET',
    Object? body,
    String? token,
  }) {
    calls++;
    return completer.future;
  }

  @override
  void close() {}
}

SyncEngine engineFor(
  Harness harness,
  SyncTransport transport, {
  SyncConfigStore? configStore,
}) {
  return SyncEngine(
    store: harness.store,
    configStore: configStore ?? MemorySyncConfigStore(),
    transport: transport,
  );
}

const SyncConfig signedIn = SyncConfig(
  server: 'http://127.0.0.1:8787',
  email: 'a@b.c',
  token: 'tok-1',
  rev: 0,
);

void main() {
  /* ---------------------------------------------------------------- */
  /* SyncConfig                                                       */
  /* ---------------------------------------------------------------- */

  group('SyncConfig', () {
    test('round-trips through JSON', () {
      const config = SyncConfig(
        server: 'http://example.test',
        email: 'me@example.test',
        token: 'abc',
        rev: 42,
        lastSyncAt: 1700000000000,
      );
      final back = SyncConfig.fromJson(jsonDecode(jsonEncode(config.toJson())));
      expect(back, isNotNull);
      expect(back!.server, 'http://example.test');
      expect(back.email, 'me@example.test');
      expect(back.token, 'abc');
      expect(back.rev, 42);
      expect(back.lastSyncAt, 1700000000000);
    });

    test('a record missing server, email or token is not a session', () {
      expect(SyncConfig.fromJson(null), isNull);
      expect(SyncConfig.fromJson('nope'), isNull);
      expect(SyncConfig.fromJson(<String, dynamic>{}), isNull);
      expect(
        SyncConfig.fromJson({'email': 'a@b.c', 'token': 't'}),
        isNull,
        reason: 'no server',
      );
      expect(
        SyncConfig.fromJson({'server': 'http://x', 'token': 't'}),
        isNull,
        reason: 'no email',
      );
      expect(
        SyncConfig.fromJson({'server': 'http://x', 'email': 'a@b.c'}),
        isNull,
        reason: 'no token',
      );
    });

    test('a blank string is treated as missing', () {
      expect(
        SyncConfig.fromJson({'server': 'http://x', 'email': '  ', 'token': 't'}),
        isNull,
      );
    });

    test('fromJson normalises the server and defaults the cursor', () {
      final config = SyncConfig.fromJson({
        'server': 'http://x///',
        'email': 'a@b.c',
        'token': 't',
      });
      expect(config!.server, 'http://x');
      expect(config.rev, 0);
      expect(config.lastSyncAt, 0);
    });

    test('non-numeric rev falls back to zero rather than throwing', () {
      final config = SyncConfig.fromJson({
        'server': 'http://x',
        'email': 'a@b.c',
        'token': 't',
        'rev': 'lots',
        'lastSyncAt': null,
      });
      expect(config!.rev, 0);
      expect(config.lastSyncAt, 0);
    });

    test('normalizeServer trims whitespace and every trailing slash', () {
      expect(normalizeServer('  http://x  '), 'http://x');
      expect(normalizeServer('http://x/'), 'http://x');
      expect(normalizeServer('http://x///'), 'http://x');
      expect(normalizeServer('/'), '');
      expect(normalizeServer('http://x/path/'), 'http://x/path');
    });
  });

  group('MemorySyncConfigStore', () {
    test('load/save/clear', () async {
      final store = MemorySyncConfigStore();
      expect(await store.load(), isNull);
      await store.save(signedIn);
      expect((await store.load())!.token, 'tok-1');
      await store.clear();
      expect(await store.load(), isNull);
    });
  });

  /* ---------------------------------------------------------------- */
  /* SyncError mapping                                                */
  /* ---------------------------------------------------------------- */

  group('SyncError.fromCode', () {
    test('maps every server error code', () {
      expect(SyncError.fromCode('unauthorized', 401), SyncError.unauthorized);
      expect(SyncError.fromCode('bad_credentials', 401), SyncError.badCredentials);
      expect(SyncError.fromCode('email_taken', 409), SyncError.emailTaken);
      expect(SyncError.fromCode('weak_password', 400), SyncError.weakPassword);
      expect(SyncError.fromCode('invalid_email', 400), SyncError.invalidEmail);
    });

    test('an unknown code falls back on the status', () {
      expect(SyncError.fromCode('internal_error', 500), SyncError.server);
      expect(SyncError.fromCode(null, 401), SyncError.unauthorized);
      expect(SyncError.fromCode(null, 500), SyncError.server);
      expect(SyncError.fromCode('', 200), SyncError.server);
    });
  });

  /* ---------------------------------------------------------------- */
  /* Engine: session                                                  */
  /* ---------------------------------------------------------------- */

  group('session', () {
    test('init with no saved session reports signed out', () async {
      final harness = await freshStore();
      final engine = engineFor(harness, FakeTransport());
      await engine.init();
      addTearDown(engine.dispose);

      expect(engine.isSignedIn, isFalse);
      expect(engine.status.state, SyncState.signedOut);
      expect(engine.status.pending, 0);
      expect(engine.status.server, kDefaultServer);
    });

    test('init restores a saved session and its cursor', () async {
      final harness = await freshStore();
      final engine = engineFor(
        harness,
        FakeTransport(),
        configStore: MemorySyncConfigStore(signedIn.copyWith(rev: 7)),
      );
      await engine.init();
      addTearDown(engine.dispose);

      expect(engine.isSignedIn, isTrue);
      expect(engine.status.state, SyncState.idle);
      expect(engine.status.email, 'a@b.c');
      expect(engine.config!.rev, 7);
    });

    test('login adopts the session and persists it', () async {
      final harness = await freshStore();
      final configStore = MemorySyncConfigStore();
      final transport = FakeTransport([
        Call(
          path: '/api/auth/login',
          method: 'POST',
          reply: {'token': 'fresh', 'email': 'me@x.y', 'rev': 0},
        ),
      ]);
      final engine = engineFor(harness, transport, configStore: configStore);
      await engine.init();
      addTearDown(engine.dispose);

      await engine.login('http://h:1/', 'me@x.y', 'secret');

      final sent = transport.seen.single;
      expect(sent.method, 'POST');
      expect(sent.body, {'email': 'me@x.y', 'password': 'secret'});
      expect(sent.token, isNull, reason: 'login carries no bearer');

      expect(engine.isSignedIn, isTrue);
      expect(engine.config!.token, 'fresh');
      expect(engine.config!.server, 'http://h:1', reason: 'normalised');
      expect((await configStore.load())!.token, 'fresh');
    });

    test('a login answer without a token is a server error', () async {
      final harness = await freshStore();
      final transport = FakeTransport([
        Call(path: '/api/auth/login', method: 'POST', reply: {'email': 'me@x.y'}),
      ]);
      final engine = engineFor(harness, transport);
      await engine.init();
      addTearDown(engine.dispose);

      await expectLater(
        engine.login('http://h:1', 'me@x.y', 'secret'),
        throwsA(isA<SyncHttpError>()
            .having((e) => e.kind, 'kind', SyncError.server)),
      );
      expect(engine.isSignedIn, isFalse);
    });

    test('register posts the credentials and adopts the session', () async {
      final harness = await freshStore();
      final transport = FakeTransport([
        Call(
          path: '/api/auth/register',
          method: 'POST',
          reply: {'token': 'reg', 'email': 'new@x.y', 'rev': 0},
        ),
      ]);
      final engine = engineFor(harness, transport);
      await engine.init();
      addTearDown(engine.dispose);

      await engine.register('http://h:1', 'new@x.y', 'secret');

      expect(transport.seen.single.path, '/api/auth/register');
      expect(engine.config!.token, 'reg');
    });

    test('signOut clears the session and revokes the token best-effort', () async {
      final harness = await freshStore();
      final configStore = MemorySyncConfigStore(signedIn);
      final transport = FakeTransport([
        Call(path: '/api/auth/logout', method: 'POST', reply: null),
      ]);
      final engine = engineFor(harness, transport, configStore: configStore);
      await engine.init();
      addTearDown(engine.dispose);

      await engine.signOut();

      expect(engine.isSignedIn, isFalse);
      expect(engine.status.state, SyncState.signedOut);
      expect(await configStore.load(), isNull);
      expect(transport.seen.single.token, 'tok-1');
    });

    test('signOut still clears locally when the revoke request fails', () async {
      final harness = await freshStore();
      final configStore = MemorySyncConfigStore(signedIn);
      final transport = FakeTransport([
        Call(
          path: '/api/auth/logout',
          method: 'POST',
          error: const SyncHttpError(SyncError.offline, 0),
        ),
      ]);
      final engine = engineFor(harness, transport, configStore: configStore);
      await engine.init();
      addTearDown(engine.dispose);

      await engine.signOut();

      expect(engine.isSignedIn, isFalse);
      expect(await configStore.load(), isNull);
    });

    test('testConnection reports true on a 2xx and false otherwise', () async {
      final harness = await freshStore();
      final transport = FakeTransport([
        Call(path: '/api/health', method: 'GET', reply: {'ok': true}),
        Call(
          path: '/api/health',
          method: 'GET',
          error: const SyncHttpError(SyncError.offline, 0),
        ),
      ]);
      final engine = engineFor(harness, transport);
      await engine.init();
      addTearDown(engine.dispose);

      expect(await engine.testConnection('http://h:1'), isTrue);
      expect(await engine.testConnection('http://h:1'), isFalse);
    });
  });

  /* ---------------------------------------------------------------- */
  /* Engine: rounds                                                   */
  /* ---------------------------------------------------------------- */

  group('rounds', () {
    test('syncNow without a session does nothing and reports false', () async {
      final harness = await freshStore();
      final transport = FakeTransport();
      final engine = engineFor(harness, transport);
      await engine.init();
      addTearDown(engine.dispose);

      expect(await engine.syncNow(), isFalse);
      expect(transport.seen, isEmpty);
    });

    test('a round sends since, the bearer and the encoded changes', () async {
      final harness = await freshStore();
      final transport = FakeTransport([
        Call(
          path: '/api/sync',
          method: 'POST',
          reply: {
            'rev': 5,
            'serverTime': T0 + 99,
            'changes': {'words': [], 'lists': [], 'logs': [], 'settings': null},
          },
        ),
      ]);
      final engine = engineFor(
        harness,
        transport,
        configStore: MemorySyncConfigStore(signedIn.copyWith(rev: 3)),
      );
      await engine.init();
      addTearDown(engine.dispose);

      harness.store.addWord(const NewWordInput(
        term: 'alpha',
        definition: 'first',
        listId: DEFAULT_LIST_ID,
      ));

      expect(await engine.syncNow(), isTrue);

      final sent = transport.seen.single;
      expect(sent.path, '/api/sync');
      expect(sent.method, 'POST');
      expect(sent.token, 'tok-1');
      final body = sent.body! as Map;
      expect(body['since'], 3);
      final changes = body['changes'] as Map;
      expect((changes['words'] as List).length, 1);
      expect(((changes['words'] as List).first as Map)['term'], 'alpha');
      expect(changes.containsKey('settings'), isTrue);

      expect(engine.config!.rev, 5);
      expect(engine.config!.lastSyncAt, T0 + 99);
      expect(engine.status.state, SyncState.idle);
      expect(engine.status.lastSyncAt, T0 + 99);
    });

    test('an empty round still transmits an empty change set', () async {
      final harness = await freshStore();
      final transport = FakeTransport([
        Call(
          path: '/api/sync',
          method: 'POST',
          reply: {'rev': 1, 'serverTime': T0, 'changes': {}},
        ),
      ]);
      final engine = engineFor(
        harness,
        transport,
        configStore: MemorySyncConfigStore(signedIn),
      );
      await engine.init();
      addTearDown(engine.dispose);

      expect(await engine.syncNow(), isTrue);

      final body = transport.seen.single.body! as Map;
      final changes = body['changes'] as Map;
      expect(changes['words'], isEmpty);
      expect(changes['lists'], isEmpty);
      expect(changes['logs'], isEmpty);
      expect(changes['settings'], isNull);
    });

    test('a successful round clears the pending flags it pushed', () async {
      final harness = await freshStore();
      final transport = FakeTransport([
        Call(
          path: '/api/sync',
          method: 'POST',
          reply: {'rev': 2, 'serverTime': T0, 'changes': {}},
        ),
      ]);
      final engine = engineFor(
        harness,
        transport,
        configStore: MemorySyncConfigStore(signedIn),
      );
      await engine.init();
      addTearDown(engine.dispose);

      harness.store.addWord(const NewWordInput(
        term: 'beta',
        definition: 'second',
        listId: DEFAULT_LIST_ID,
      ));
      expect(harness.store.pendingChangeCount(), greaterThan(0));

      await engine.syncNow();

      expect(harness.store.pendingChangeCount(), 0);
      expect(engine.status.pending, 0);
    });

    test('the remote change set is merged into the snapshot', () async {
      final harness = await freshStore();
      final transport = FakeTransport([
        Call(
          path: '/api/sync',
          method: 'POST',
          reply: {
            'rev': 9,
            'serverTime': T0,
            'changes': {
              'words': [
                {
                  'id': 'w_remote',
                  'term': 'remote',
                  'definition': 'from the server',
                  'listId': DEFAULT_LIST_ID,
                  'sourceLang': 'en',
                  'targetLang': 'zh',
                  'status': 'new',
                  'favorite': false,
                  'listenCount': 0,
                  'createdAt': T0,
                  'updatedAt': T0,
                },
              ],
              'lists': [],
              'logs': [],
              'settings': null,
            },
          },
        ),
      ]);
      final engine = engineFor(
        harness,
        transport,
        configStore: MemorySyncConfigStore(signedIn),
      );
      await engine.init();
      addTearDown(engine.dispose);

      await engine.syncNow();

      final words = harness.store.data.words;
      expect(words.length, 1);
      expect(words.single.id, 'w_remote');
      expect(words.single.definition, 'from the server');
    });

    test('a remote record never carries _rev into the snapshot', () async {
      final harness = await freshStore();
      final transport = FakeTransport([
        Call(
          path: '/api/sync',
          method: 'POST',
          reply: {
            'rev': 4,
            'serverTime': T0,
            'changes': {
              'words': [
                {
                  'id': 'w_r',
                  'term': 'r',
                  'definition': '',
                  'listId': DEFAULT_LIST_ID,
                  'sourceLang': 'en',
                  'targetLang': 'zh',
                  'status': 'new',
                  'favorite': false,
                  'listenCount': 0,
                  'createdAt': T0,
                  'updatedAt': T0,
                  '_rev': 4,
                },
              ],
              'lists': [],
              'logs': [],
              'settings': null,
            },
          },
        ),
      ]);
      final engine = engineFor(
        harness,
        transport,
        configStore: MemorySyncConfigStore(signedIn),
      );
      await engine.init();
      addTearDown(engine.dispose);

      await engine.syncNow();

      final json = jsonEncode(harness.store.data.toJson());
      expect(json.contains('_rev'), isFalse);
    });

    test('an unauthorized answer signs out and clears the session', () async {
      final harness = await freshStore();
      final configStore = MemorySyncConfigStore(signedIn);
      final transport = FakeTransport([
        Call(
          path: '/api/sync',
          method: 'POST',
          error: const SyncHttpError(SyncError.unauthorized, 401),
        ),
      ]);
      final engine = engineFor(harness, transport, configStore: configStore);
      await engine.init();
      addTearDown(engine.dispose);

      expect(await engine.syncNow(), isFalse);

      expect(engine.isSignedIn, isFalse);
      expect(engine.status.state, SyncState.signedOut);
      expect(engine.status.error, SyncError.unauthorized);
      expect(await configStore.load(), isNull);
    });

    test('an offline answer keeps the session and the pending flags', () async {
      final harness = await freshStore();
      final configStore = MemorySyncConfigStore(signedIn);
      final transport = FakeTransport([
        Call(
          path: '/api/sync',
          method: 'POST',
          error: const SyncHttpError(SyncError.offline, 0),
        ),
      ]);
      final engine = engineFor(harness, transport, configStore: configStore);
      await engine.init();
      addTearDown(engine.dispose);

      harness.store.addWord(const NewWordInput(
        term: 'kept',
        definition: 'still here',
        listId: DEFAULT_LIST_ID,
      ));
      final before = harness.store.pendingChangeCount();

      expect(await engine.syncNow(), isFalse);

      expect(engine.isSignedIn, isTrue);
      expect(engine.status.state, SyncState.error);
      expect(engine.status.error, SyncError.offline);
      expect(harness.store.pendingChangeCount(), before);
      expect(await configStore.load(), isNotNull);
    });

    test('an unexpected exception is reported as offline', () async {
      final harness = await freshStore();
      final engine = engineFor(
        harness,
        _ThrowingTransport(),
        configStore: MemorySyncConfigStore(signedIn),
      );
      await engine.init();
      addTearDown(engine.dispose);

      expect(await engine.syncNow(), isFalse);
      expect(engine.status.error, SyncError.offline);
    });

    test('a server answer without a rev keeps the cursor', () async {
      final harness = await freshStore();
      final transport = FakeTransport([
        Call(path: '/api/sync', method: 'POST', reply: {'changes': {}}),
      ]);
      final engine = engineFor(
        harness,
        transport,
        configStore: MemorySyncConfigStore(signedIn.copyWith(rev: 11)),
      );
      await engine.init();
      addTearDown(engine.dispose);

      expect(await engine.syncNow(), isTrue);
      expect(engine.config!.rev, 11);
    });

    test('concurrent callers share one request', () async {
      final harness = await freshStore();
      final transport = HangingTransport();
      final engine = engineFor(
        harness,
        transport,
        configStore: MemorySyncConfigStore(signedIn),
      );
      await engine.init();
      addTearDown(engine.dispose);

      final first = engine.syncNow();
      final second = engine.syncNow();
      expect(identical(first, second), isTrue,
          reason: 'the second caller must get the first future');

      transport.completer.complete({'rev': 1, 'serverTime': T0, 'changes': {}});
      expect(await first, isTrue);
      expect(transport.calls, 1);
    });

    test('a new round starts once the previous one finished', () async {
      final harness = await freshStore();
      final transport = FakeTransport([
        Call(
          path: '/api/sync',
          method: 'POST',
          reply: {'rev': 1, 'serverTime': T0, 'changes': {}},
        ),
        Call(
          path: '/api/sync',
          method: 'POST',
          reply: {'rev': 2, 'serverTime': T0, 'changes': {}},
        ),
      ]);
      final engine = engineFor(
        harness,
        transport,
        configStore: MemorySyncConfigStore(signedIn),
      );
      await engine.init();
      addTearDown(engine.dispose);

      await engine.syncNow();
      await engine.syncNow();

      expect(transport.seen.length, 2);
      expect(engine.config!.rev, 2);
      expect((transport.seen.last.body! as Map)['since'], 1);
    });

    test('the status is syncing while a round is in flight', () async {
      final harness = await freshStore();
      final transport = HangingTransport();
      final engine = engineFor(
        harness,
        transport,
        configStore: MemorySyncConfigStore(signedIn),
      );
      await engine.init();
      addTearDown(engine.dispose);

      final round = engine.syncNow();
      await Future<void>.delayed(Duration.zero);
      expect(engine.status.state, SyncState.syncing);

      transport.completer.complete({'rev': 1, 'serverTime': T0, 'changes': {}});
      await round;
      expect(engine.status.state, SyncState.idle);
    });

    test('listeners fire on state changes', () async {
      final harness = await freshStore();
      final transport = FakeTransport([
        Call(
          path: '/api/sync',
          method: 'POST',
          reply: {'rev': 1, 'serverTime': T0, 'changes': {}},
        ),
      ]);
      final engine = engineFor(
        harness,
        transport,
        configStore: MemorySyncConfigStore(signedIn),
      );
      await engine.init();
      addTearDown(engine.dispose);

      var fired = 0;
      final off = engine.addListener(() => fired++);

      await engine.syncNow();
      expect(fired, greaterThan(0));

      off();
      final before = fired;
      await engine.syncNow();
      expect(fired, before, reason: 'unsubscribed');
    });

    test('pendingChanges exposes what a round would push', () async {
      final harness = await freshStore();
      final engine = engineFor(harness, FakeTransport());
      await engine.init();
      addTearDown(engine.dispose);

      expect(engine.pendingChanges().isEmpty, isTrue);

      harness.store.addWord(const NewWordInput(
        term: 'shown',
        definition: 'x',
        listId: DEFAULT_LIST_ID,
      ));

      expect(engine.pendingChanges().words.length, 1);
    });
  });

  /* ---------------------------------------------------------------- */
  /* Engine: the loop                                                 */
  /* ---------------------------------------------------------------- */

  group('loop', () {
    test('autoSync off means the timer does nothing', () async {
      final harness = await freshStore();
      final transport = FakeTransport();
      final engine = SyncEngine(
        store: harness.store,
        configStore: MemorySyncConfigStore(signedIn),
        transport: transport,
        interval: const Duration(milliseconds: 20),
        soonDelay: const Duration(milliseconds: 5),
        bootDelay: const Duration(milliseconds: 5),
      );
      await engine.init();
      addTearDown(engine.dispose);

      harness.store.updateSettings((s) => s.copyWith(autoSync: false));

      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(transport.seen, isEmpty);
    });

    test('a local edit schedules a push after the debounce', () async {
      final harness = await freshStore();
      final transport = FakeTransport();
      final engine = SyncEngine(
        store: harness.store,
        configStore: MemorySyncConfigStore(signedIn),
        transport: transport,
        // Long poll so only the debounced push can fire.
        interval: const Duration(hours: 1),
        soonDelay: const Duration(milliseconds: 10),
        bootDelay: const Duration(hours: 1),
      );
      await engine.init();
      addTearDown(engine.dispose);

      harness.store.addWord(const NewWordInput(
        term: 'debounced',
        definition: 'x',
        listId: DEFAULT_LIST_ID,
      ));

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(transport.seen.length, 1);
      expect(transport.seen.single.path, '/api/sync');
    });

    test('several edits inside the debounce window send one round', () async {
      final harness = await freshStore();
      final transport = FakeTransport();
      final engine = SyncEngine(
        store: harness.store,
        configStore: MemorySyncConfigStore(signedIn),
        transport: transport,
        interval: const Duration(hours: 1),
        soonDelay: const Duration(milliseconds: 30),
        bootDelay: const Duration(hours: 1),
      );
      await engine.init();
      addTearDown(engine.dispose);

      for (var i = 0; i < 5; i++) {
        harness.store.addWord(NewWordInput(
          term: 'word$i',
          definition: 'x',
          listId: DEFAULT_LIST_ID,
        ));
      }

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(transport.seen.length, 1);
      final changes = (transport.seen.single.body! as Map)['changes'] as Map;
      expect((changes['words'] as List).length, 5);
    });

    test('the poll timer keeps running while signed in', () async {
      final harness = await freshStore();
      final transport = FakeTransport();
      final engine = SyncEngine(
        store: harness.store,
        configStore: MemorySyncConfigStore(signedIn),
        transport: transport,
        interval: const Duration(milliseconds: 20),
        soonDelay: const Duration(hours: 1),
        bootDelay: const Duration(hours: 1),
      );
      await engine.init();
      addTearDown(engine.dispose);

      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(transport.seen.length, greaterThanOrEqualTo(2));
    });

    test('stop cancels the timers', () async {
      final harness = await freshStore();
      final transport = FakeTransport();
      final engine = SyncEngine(
        store: harness.store,
        configStore: MemorySyncConfigStore(signedIn),
        transport: transport,
        interval: const Duration(milliseconds: 20),
        soonDelay: const Duration(hours: 1),
        bootDelay: const Duration(hours: 1),
      );
      await engine.init();
      addTearDown(engine.dispose);

      engine.stop();
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(transport.seen, isEmpty);
    });

    test('start is idempotent', () async {
      final harness = await freshStore();
      final transport = FakeTransport();
      final engine = SyncEngine(
        store: harness.store,
        configStore: MemorySyncConfigStore(signedIn),
        transport: transport,
        interval: const Duration(milliseconds: 30),
        soonDelay: const Duration(hours: 1),
        bootDelay: const Duration(hours: 1),
      );
      await engine.init();
      addTearDown(engine.dispose);

      engine.start();
      engine.start();

      await Future<void>.delayed(const Duration(milliseconds: 80));
      // Two timers would double the request count; one timer at 30ms over 80ms
      // gives 2, three timers would give ~6.
      expect(transport.seen.length, lessThanOrEqualTo(3));
    });

    test('dispose closes the transport and stops publishing', () async {
      final harness = await freshStore();
      final transport = FakeTransport();
      final engine = engineFor(
        harness,
        transport,
        configStore: MemorySyncConfigStore(signedIn),
      );
      await engine.init();

      var fired = 0;
      engine.addListener(() => fired++);
      engine.dispose();

      expect(transport.closed, isTrue);
      expect(fired, 0);
    });
  });

  /* ---------------------------------------------------------------- */
  /* IoTransport                                                      */
  /* ---------------------------------------------------------------- */

  group('IoTransport', () {
    late HttpServer server;
    late IoTransport transport;
    late List<Map<String, Object?>> received;

    Future<void> start(
      Future<void> Function(HttpRequest request) handler,
    ) async {
      received = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        received.add({
          'method': request.method,
          'path': request.uri.path,
          'auth': request.headers.value(HttpHeaders.authorizationHeader),
          'contentType': request.headers.value(HttpHeaders.contentTypeHeader),
          'body': body,
        });
        await handler(request);
      });
      transport = IoTransport();
    }

    tearDown(() async {
      transport.close();
      await server.close(force: true);
    });

    test('a GET decodes JSON and sends no bearer when none is given', () async {
      await start((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'ok': true}));
        await request.response.close();
      });

      final reply = await transport.request('http://127.0.0.1:${server.port}', '/api/health');

      expect(reply, {'ok': true});
      expect(received.single['method'], 'GET');
      expect(received.single['auth'], isNull);
      expect(received.single['contentType'], contains('application/json'));
    });

    test('a POST sends the bearer and a JSON body', () async {
      await start((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'rev': 3}));
        await request.response.close();
      });

      final reply = await transport.request(
        'http://127.0.0.1:${server.port}',
        '/api/sync',
        method: 'POST',
        body: {'since': 0, 'changes': {'words': []}},
        token: 'secret-token',
      );

      expect(reply, {'rev': 3});
      expect(received.single['method'], 'POST');
      expect(received.single['auth'], 'Bearer secret-token');
      expect(jsonDecode(received.single['body']! as String), {
        'since': 0,
        'changes': {'words': []},
      });
    });

    test('204 decodes to null', () async {
      await start((request) async {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
      });

      final reply = await transport.request('http://127.0.0.1:${server.port}', '/x');

      expect(reply, isNull);
    });

    test('a 401 becomes unauthorized', () async {
      await start((request) async {
        request.response.statusCode = HttpStatus.unauthorized;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'unauthorized'}));
        await request.response.close();
      });

      await expectLater(
        transport.request('http://127.0.0.1:${server.port}', '/api/sync'),
        throwsA(isA<SyncHttpError>()
            .having((e) => e.kind, 'kind', SyncError.unauthorized)
            .having((e) => e.status, 'status', 401)),
      );
    });

    test('a 409 email_taken keeps its specific kind', () async {
      await start((request) async {
        request.response.statusCode = HttpStatus.conflict;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'email_taken'}));
        await request.response.close();
      });

      await expectLater(
        transport.request('http://127.0.0.1:${server.port}', '/api/auth/register'),
        throwsA(isA<SyncHttpError>()
            .having((e) => e.kind, 'kind', SyncError.emailTaken)),
      );
    });

    test('a non-JSON error body still fails on the status', () async {
      await start((request) async {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write('<html>boom</html>');
        await request.response.close();
      });

      await expectLater(
        transport.request('http://127.0.0.1:${server.port}', '/api/sync'),
        throwsA(isA<SyncHttpError>()
            .having((e) => e.kind, 'kind', SyncError.server)
            .having((e) => e.status, 'status', 500)),
      );
    });

    test('a refused connection becomes offline', () async {
      // No `start()`: this case needs a port with nothing behind it, so the
      // transport is created here rather than shared with the other cases.
      final quick = IoTransport();
      addTearDown(quick.close);
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();

      await expectLater(
        quick.request('http://127.0.0.1:$port', '/api/health'),
        throwsA(isA<SyncHttpError>()
            .having((e) => e.kind, 'kind', SyncError.offline)
            .having((e) => e.status, 'status', 0)),
      );
    });

    test('a timeout becomes offline', () async {
      await start((request) async {
        await Future<void>.delayed(const Duration(seconds: 5));
        await request.response.close();
      });

      final quick = IoTransport(timeout: const Duration(milliseconds: 120));
      addTearDown(quick.close);

      await expectLater(
        quick.request('http://127.0.0.1:${server.port}', '/api/sync'),
        throwsA(isA<SyncHttpError>()
            .having((e) => e.kind, 'kind', SyncError.offline)),
      );
    });
  });
}

/// Throws something that is not a [SyncHttpError], to prove the catch-all.
class _ThrowingTransport implements SyncTransport {
  @override
  Future<Object?> request(
    String server,
    String path, {
    String method = 'GET',
    Object? body,
    String? token,
  }) async {
    throw StateError('unexpected');
  }

  @override
  void close() {}
}
