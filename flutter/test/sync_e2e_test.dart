/// End-to-end sync against a *real* server over real HTTP.
///
/// Every other sync test replaces the transport with a fake, which is what makes
/// them fast and deterministic — but it also means nothing in the suite proves
/// the wire format actually matches what a server accepts. This file closes that
/// gap: it drives [SyncEngine] through [IoTransport] against a live
/// `POST /api/sync` implementation and asserts the round trip, the LWW rule and
/// two-device convergence.
///
/// **Skipped by default.** A test that needs a listening socket cannot run in CI
/// or on a phone, so it opts in through the environment:
///
/// ```bash
/// # terminal 1
/// cd server && DATA_DIR=/tmp/lexumo-e2e PORT=8788 node src/index.js
/// # terminal 2
/// cd flutter && LEXUMO_E2E_SERVER=http://127.0.0.1:8788 ../.flutter-sdk/flutterc test test/sync_e2e_test.dart
/// ```
///
/// Each run registers a throwaway account (`e2e-<random>@example.test`), so the
/// server's data directory accumulates users; point `DATA_DIR` at a temp folder.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/data/snapshot_store.dart';
import 'package:lexumo/data/store.dart';
import 'package:lexumo/data/sync_config.dart';
import 'package:lexumo/data/sync_engine.dart';
import 'package:lexumo/data/sync_transport.dart';
import 'package:lexumo/domain/types.dart';

const int T0 = 1700000000000;

/// The server under test, or null to skip the whole file.
final String? server = Platform.environment['LEXUMO_E2E_SERVER'];

String freshEmail() {
  final stamp = DateTime.now().microsecondsSinceEpoch;
  return 'e2e-$stamp@example.test';
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

/// A device: its own store, its own session file, its own transport.
class Device {
  Device._(this.store, this.engine, this.transport);

  final Store store;
  final SyncEngine engine;
  final SyncTransport transport;

  static Future<Device> boot(int now) async {
    final store = Store(
      persistence: MemoryStore(emptyData()),
      clock: () => now,
      saveDelayMs: 0,
    );
    await store.init();
    final transport = IoTransport();
    final engine = SyncEngine(
      store: store,
      configStore: MemorySyncConfigStore(),
      transport: transport,
      // No background loop in a test: rounds are driven explicitly.
      interval: const Duration(hours: 1),
      soonDelay: const Duration(hours: 1),
      bootDelay: const Duration(hours: 1),
    );
    await engine.init();
    return Device._(store, engine, transport);
  }

  void dispose() => engine.dispose();
}

void main() {
  if (server == null) {
    test('sync e2e (skipped: set LEXUMO_E2E_SERVER)', () {}, skip: true);
    return;
  }

  final base = server!;
  const password = 'e2e-password-123';

  test('register, push a word, and read it back on a second device', () async {
    final email = freshEmail();
    final phone = await Device.boot(T0);
    addTearDown(phone.dispose);
    final desktop = await Device.boot(T0);
    addTearDown(desktop.dispose);

    // --- health -----------------------------------------------------
    expect(await phone.engine.testConnection(base), isTrue,
        reason: 'a server should answer /api/health');

    // --- register ---------------------------------------------------
    await phone.engine.register(base, email, password);
    expect(phone.engine.isSignedIn, isTrue);
    expect(phone.engine.config!.rev, 0);

    // --- push -------------------------------------------------------
    phone.store.addWord(const NewWordInput(
      term: 'serendipity',
      definition: '意外发现美好事物的运气',
      listId: DEFAULT_LIST_ID,
      phonetic: '/ˌserənˈdɪpəti/',
      pos: 'n.',
    ));
    expect(await phone.engine.syncNow(), isTrue);
    expect(phone.store.pendingChangeCount(), 0,
        reason: 'a successful round settles what it pushed');
    expect(phone.engine.config!.rev, greaterThan(0));

    // --- second device logs in and pulls ----------------------------
    await desktop.engine.login(base, email, password);
    expect(await desktop.engine.syncNow(), isTrue);

    expect(desktop.store.data.words.length, 1);
    final pulled = desktop.store.data.words.single;
    expect(pulled.term, 'serendipity');
    expect(pulled.definition, '意外发现美好事物的运气');
    expect(pulled.phonetic, '/ˌserənˈdɪpəti/');
    expect(pulled.pos, 'n.');
    expect(desktop.store.data.words.single.listId, DEFAULT_LIST_ID);

    // The list itself has to arrive too, or the word would be orphaned.
    expect(
      desktop.store.data.lists.any((l) => l.id == DEFAULT_LIST_ID),
      isTrue,
    );

    // --- and a second round is a no-op ------------------------------
    expect(await desktop.engine.syncNow(), isTrue);
    expect(desktop.store.data.words.length, 1,
        reason: 'pulling the same revision twice must not duplicate');
  });

  test('two devices converge on both edits', () async {
    final email = freshEmail();
    final a = await Device.boot(T0);
    addTearDown(a.dispose);
    final b = await Device.boot(T0);
    addTearDown(b.dispose);

    await a.engine.register(base, email, password);
    await b.engine.login(base, email, password);

    a.store.addWord(const NewWordInput(
      term: 'alpha',
      definition: 'A',
      listId: DEFAULT_LIST_ID,
    ));
    await a.engine.syncNow();

    b.store.addWord(const NewWordInput(
      term: 'beta',
      definition: 'B',
      listId: DEFAULT_LIST_ID,
    ));
    await b.engine.syncNow();

    await a.engine.syncNow();

    final aTerms = a.store.data.words.map((w) => w.term).toSet();
    final bTerms = b.store.data.words.map((w) => w.term).toSet();
    expect(aTerms, {'alpha', 'beta'});
    expect(bTerms, {'alpha', 'beta'});
  });

  test('the newer definition wins and the loser sees it', () async {
    final email = freshEmail();
    final a = await Device.boot(T0);
    addTearDown(a.dispose);
    final b = await Device.boot(T0);
    addTearDown(b.dispose);

    await a.engine.register(base, email, password);
    await b.engine.login(base, email, password);

    final word = a.store.addWord(const NewWordInput(
      term: 'shift',
      definition: 'original',
      listId: DEFAULT_LIST_ID,
    ));
    await a.engine.syncNow();
    await b.engine.syncNow();
    expect(b.store.data.words.single.definition, 'original');

    // `a` edits later, so `a`'s version is the one that should survive.
    a.store.updateWord(word.id, (w) => w.copyWith(definition: 'edited on a'));
    await a.engine.syncNow();
    await b.engine.syncNow();

    expect(b.store.data.words.single.definition, 'edited on a');
  });

  test('a delete propagates as a tombstone, not as a re-upload', () async {
    final email = freshEmail();
    final a = await Device.boot(T0);
    addTearDown(a.dispose);
    final b = await Device.boot(T0);
    addTearDown(b.dispose);

    await a.engine.register(base, email, password);
    await b.engine.login(base, email, password);

    final word = a.store.addWord(const NewWordInput(
      term: 'doomed',
      definition: 'x',
      listId: DEFAULT_LIST_ID,
    ));
    await a.engine.syncNow();
    await b.engine.syncNow();
    expect(b.store.data.words.length, 1);

    a.store.deleteWord(word.id);
    await a.engine.syncNow();
    await b.engine.syncNow();

    expect(a.store.data.words, isEmpty);
    expect(b.store.data.words, isEmpty,
        reason: 'the tombstone must beat the copy b still holds');
  });

  test('a wrong password is reported as bad_credentials', () async {
    final email = freshEmail();
    final device = await Device.boot(T0);
    addTearDown(device.dispose);

    await device.engine.register(base, email, password);
    await device.engine.signOut();

    await expectLater(
      device.engine.login(base, email, 'not-the-password'),
      throwsA(isA<SyncHttpError>()
          .having((e) => e.kind, 'kind', SyncError.badCredentials)),
    );
    expect(device.engine.isSignedIn, isFalse);
  });

  test('registering the same email twice is email_taken', () async {
    final email = freshEmail();
    final device = await Device.boot(T0);
    addTearDown(device.dispose);

    await device.engine.register(base, email, password);

    await expectLater(
      device.engine.register(base, email, password),
      throwsA(isA<SyncHttpError>()
          .having((e) => e.kind, 'kind', SyncError.emailTaken)),
    );
  });

  test('a short password is weak_password', () async {
    final device = await Device.boot(T0);
    addTearDown(device.dispose);

    await expectLater(
      device.engine.register(base, freshEmail(), 'short'),
      throwsA(isA<SyncHttpError>()
          .having((e) => e.kind, 'kind', SyncError.weakPassword)),
    );
  });

  test('a bad email is invalid_email', () async {
    final device = await Device.boot(T0);
    addTearDown(device.dispose);

    await expectLater(
      device.engine.register(base, 'not-an-email', password),
      throwsA(isA<SyncHttpError>()
          .having((e) => e.kind, 'kind', SyncError.invalidEmail)),
    );
  });

  test('a revoked token signs the device out on the next round', () async {
    final email = freshEmail();
    final device = await Device.boot(T0);
    addTearDown(device.dispose);

    await device.engine.register(base, email, password);
    await device.engine.syncNow();

    // Log out on the server directly, so the local session still holds a token
    // the server no longer honours — the exact state a stale phone is in.
    final config = device.engine.config!;
    final probe = IoTransport();
    addTearDown(probe.close);
    await probe.request(
      config.server,
      '/api/auth/logout',
      method: 'POST',
      token: config.token,
    );

    expect(await device.engine.syncNow(), isFalse);
    expect(device.engine.isSignedIn, isFalse);
    expect(device.engine.status.error, SyncError.unauthorized);
  });

  test('another account cannot see these words', () async {
    final alice = await Device.boot(T0);
    addTearDown(alice.dispose);
    final bob = await Device.boot(T0);
    addTearDown(bob.dispose);

    await alice.engine.register(base, freshEmail(), password);
    alice.store.addWord(const NewWordInput(
      term: 'alice-only',
      definition: 'private',
      listId: DEFAULT_LIST_ID,
    ));
    await alice.engine.syncNow();

    await bob.engine.register(base, freshEmail(), password);
    await bob.engine.syncNow();

    expect(bob.store.data.words, isEmpty);
  });
}
