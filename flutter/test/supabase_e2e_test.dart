// The Dart client against a real Postgres, end to end.
//
// The unit tests fake the transport and the SQL tests fake the client; this is
// the only test where both real halves meet. What it can catch that neither of
// those can:
//
//   * **A path/verb the bridge does not serve** — `SupabaseTransport` rewrites
//     `/api/sync` to `/rest/v1/rpc/sync`; a typo there is invisible to a fake
//     that matches on the engine's own vocabulary.
//   * **GoTrue's snake_case session shape** — the client has to turn
//     `access_token` into the engine's `token` and carry `refresh_token` on. A
//     hand-written fake returns the shape the test author *thinks* GoTrue
//     returns.
//   * **The plpgsql function's actual return value** — `sync()` returns
//     `{rev, changes, settings}`; the client has to read that without a shim.
//
// Skipped unless the environment says where the bridge is, because it needs
// Docker and a Postgres container:
//
//   docker run -d --name lexumo-pg -e POSTGRES_PASSWORD=lexumo \
//     -e POSTGRES_DB=lexumo -p 55432:5432 postgres:latest
//   node supabase/tests/run.sh --keep          # migration + SQL tests
//   PORT=55433 node supabase/tests/rpc_bridge.cjs &
//   LEXUMO_SUPABASE_E2E=http://127.0.0.1:55433 flutter test test/supabase_e2e_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/data/services/backend_transport.dart';
import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/data/models/sync_config.dart';
import 'package:lexumo/data/repositories/sync_engine.dart';
import 'package:lexumo/data/services/sync_transport.dart';
import 'package:lexumo/domain/models/seed.dart';
import 'package:lexumo/domain/models/types.dart';

void main() {
  final base = Platform.environment['LEXUMO_SUPABASE_E2E'] ?? '';
  final skip = base.isEmpty ? 'set LEXUMO_SUPABASE_E2E to the bridge URL' : null;

  // An anon key is not checked by the bridge, but `SupabaseTransport` refuses
  // to run without one — that refusal is what the app relies on to catch a
  // missing key before the first request.
  const anonKey = 'test-anon-key';

  Store freshStore() => Store(persistence: MemoryStore(), seed: seedData);

  Future<SyncEngine> boot(Store store) async {
    final engine = SyncEngine(
      store: store,
      configStore: MemorySyncConfigStore(),
      transport: BackendTransport(backend: SyncBackend.supabase, key: anonKey),
      interval: const Duration(hours: 1),
      soonDelay: const Duration(hours: 1),
      bootDelay: const Duration(hours: 1),
    );
    await engine.init();
    return engine;
  }

  test('signs up, pushes, and pulls the same words back', () async {
    final email = 'e2e-${DateTime.now().microsecondsSinceEpoch}@example.test';
    final a = freshStore();
    await a.init();
    await a.flush();
    final engineA = await boot(a);
    addTearDown(engineA.dispose);

    await engineA.register(base, email, 'correct horse battery');
    expect(engineA.isSignedIn, isTrue);

    // A local edit, then one round: this is the ordinary path a user takes.
    a.addWord(
      const NewWordInput(term: 'petrichor', definition: '雨后泥土的气味', listId: DEFAULT_LIST_ID),
    );
    final pushed = await engineA.syncNow();
    expect(pushed, isTrue, reason: 'the round should have gone through');
    expect(engineA.status.error, isNull);
    expect(engineA.status.pending, 0, reason: 'a successful round clears the queue');

    // A second device with the same credentials. Signing in on it has to hand
    // back the saved session, and a round has to pull the word down.
    final b = freshStore();
    await b.init();
    await b.flush();
    final engineB = await boot(b);
    addTearDown(engineB.dispose);
    await engineB.login(base, email, 'correct horse battery');

    final pulled = await engineB.syncNow();
    expect(pulled, isTrue);
    final terms = b.data.words.map((Word w) => w.term).toList();
    expect(terms, contains('petrichor'));
    // Not `.first`: this store seeds a demo word list, so the first word is
  }, skip: skip);

  test('a second device edits and the first one sees it next round', () async {
    final email = 'e2e-${DateTime.now().microsecondsSinceEpoch}@example.test';
    final a = freshStore();
    await a.init();
    await a.flush();
    final engineA = await boot(a);
    addTearDown(engineA.dispose);
    await engineA.register(base, email, 'correct horse battery');

    final b = freshStore();
    await b.init();
    await b.flush();
    final engineB = await boot(b);
    addTearDown(engineB.dispose);
    await engineB.login(base, email, 'correct horse battery');

    final word = a.addWord(
      const NewWordInput(term: 'sonder', definition: '意识到他人各有其人生', listId: DEFAULT_LIST_ID),
    );
    expect(await engineA.syncNow(), isTrue);
    expect(await engineB.syncNow(), isTrue);
    expect(b.data.words.map((Word w) => w.term), contains('sonder'));

    // B grades it. The review log is append-only, so A must receive it whole.
    //
    // The timestamp is now, not a fixture constant: merging is last-write-wins
    // on `updatedAt`, so grading with a 2023 stamp would lose to the copy A
    // pulled a moment ago — and A would correctly keep its own, which looks
    // exactly like a broken sync.
    b.gradeWord(word.id, Grade.good);
    expect(await engineB.syncNow(), isTrue);
    expect(await engineA.syncNow(), isTrue);

    final onA = a.data.words.firstWhere((Word w) => w.id == word.id);
    expect(onA.srs, isNotNull);
    expect(onA.srs!.reviewCount, 1);
  }, skip: skip);

  test('a bad password is reported as unauthorized, not as a server fault', () async {
    final email = 'e2e-${DateTime.now().microsecondsSinceEpoch}@example.test';
    final store = freshStore();
    await store.init();
    await store.flush();
    final engine = await boot(store);
    addTearDown(engine.dispose);

    await engine.register(base, email, 'correct horse battery');
    await engine.signOut();

    // GoTrue answers `invalid_grant` with 400, and the client has to call that
    // "wrong credentials" — not `unauthorized`, which the UI renders as "your
    // session expired, sign in again", and not `server`, which says try later.
    // This is the difference between "check the password" and "wait for us".
    await expectLater(
      engine.login(base, email, 'wrong password here'),
      throwsA(
        isA<SyncHttpError>().having(
          (SyncHttpError e) => e.kind,
          'error',
          SyncError.badCredentials,
        ),
      ),
    );
  }, skip: skip);

  test('signing up twice with one address is refused', () async {
    final email = 'e2e-${DateTime.now().microsecondsSinceEpoch}@example.test';
    final store = freshStore();
    await store.init();
    await store.flush();
    final engine = await boot(store);
    addTearDown(engine.dispose);

    await engine.register(base, email, 'correct horse battery');
    await engine.signOut();

    // 409 from GoTrue. The user needs to be told the account exists, not that
    // something broke — otherwise they make a second account by mistake.
    await expectLater(
      engine.register(base, email, 'correct horse battery'),
      throwsA(isA<SyncHttpError>()),
    );
  }, skip: skip);

  test('the refresh token mints a new access token', () async {
    final email = 'e2e-${DateTime.now().microsecondsSinceEpoch}@example.test';
    final store = freshStore();
    await store.init();
    await store.flush();
    final configStore = MemorySyncConfigStore();
    final engine = SyncEngine(
      store: store,
      configStore: configStore,
      transport: BackendTransport(backend: SyncBackend.supabase, key: anonKey),
      interval: const Duration(hours: 1),
      soonDelay: const Duration(hours: 1),
      bootDelay: const Duration(hours: 1),
    );
    await engine.init();
    addTearDown(engine.dispose);

    await engine.register(base, email, 'correct horse battery');
    final saved = engine.config!;
    expect(saved.refreshToken, isNotEmpty);

    // A dead access token, and the refresh token that can replace it. Without
    // this the relaunch below would simply reuse a still-valid access token and
    // prove nothing about refreshing.
    await configStore.save(
      saved.copyWith(token: 'access-expired-on-the-server'),
    );

    // A fresh engine adopts the saved session the way a relaunch would, then
    // syncs with a token the server will reject. The round must still succeed:
    // the 401 is the signal to exchange the refresh token and retry once.
    final relaunch = SyncEngine(
      store: store,
      configStore: configStore,
      transport: BackendTransport(backend: SyncBackend.supabase, key: anonKey),
      interval: const Duration(hours: 1),
      soonDelay: const Duration(hours: 1),
      bootDelay: const Duration(hours: 1),
    );
    await relaunch.init();
    addTearDown(relaunch.dispose);
    expect(relaunch.isSignedIn, isTrue);
    expect(await relaunch.syncNow(), isTrue);

    // And the minted session is written back, so the *next* launch starts with
    // a working token instead of refreshing again on every round.
    //
    // The write is deliberately fire-and-forget — blocking a request on disk
    // I/O would stall the call behind it — so the file lags the memory by a
    // turn. Waiting is the test's job, not the engine's.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final after = (await configStore.load())!;
    expect(after.token, isNot('access-expired-on-the-server'));
    expect(after.refreshToken, isNotEmpty);
  }, skip: skip);
}
