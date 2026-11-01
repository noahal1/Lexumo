/// The access token can be replaced *during* a round.
///
/// A Supabase access token lives an hour, so a round that begins with a valid
/// one can still come back 401 — and the transport answers that by exchanging
/// the refresh token and retrying. The refresh hands back a new refresh token
/// too, and the old one is dead from that moment on.
///
/// Which makes the end of the round dangerous: it saves the session file. If it
/// saved the fields it captured *before* the request, it would write the
/// superseded refresh token back over the fresh one, and the next launch would
/// try to refresh with a token the server has already rotated away. The bug is
/// invisible until a second launch, which is why it needs its own test rather
/// than being left to the end-to-end suite (which only catches it because it
/// deliberately kills the access token first).
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/data/models/sync_config.dart';
import 'package:lexumo/data/repositories/sync_engine.dart';
import 'package:lexumo/data/services/sync_transport.dart';
import 'package:lexumo/domain/models/types.dart';

const int T0 = 1700000000000;

/// A transport that mints a new session in the middle of a sync round, the way
/// `SupabaseTransport` does after a 401.
class RefreshingTransport implements SyncTransport, CredentialAware {
  RefreshingTransport(this.configStore);

  final SyncConfigStore configStore;
  void Function(Map<String, Object?> session)? _onTokenMinted;
  String anonKey = '';
  String refreshToken = '';
  int calls = 0;

  @override
  void useCredentials({required String anonKey, required String refreshToken}) {
    this.anonKey = anonKey;
    this.refreshToken = refreshToken;
  }

  @override
  set onTokenMinted(void Function(Map<String, Object?> session)? callback) {
    _onTokenMinted = callback;
  }

  @override
  Future<Object?> request(
    String server,
    String path, {
    String method = 'GET',
    Object? body,
    String? token,
  }) async {
    calls++;
    // Mid-request: the server rotated both tokens. This lands between the
    // engine reading its config and the engine saving it.
    refreshToken = 'refresh-2';
    _onTokenMinted?.call({
      'token': 'token-2',
      'email': 'a@b.c',
      'refreshToken': 'refresh-2',
    });
    return <String, dynamic>{
      'rev': 7,
      'serverTime': T0 + 5000,
      'changes': <String, dynamic>{},
    };
  }

  @override
  void close() {}
}

AppData seeded() => const AppData(
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

void main() {
  test('a round keeps the token minted during it, not the one it started with',
      () async {
    final store = Store(persistence: MemoryStore(seeded()), saveDelayMs: 0);
    await store.init();

    final configStore = MemorySyncConfigStore(
      const SyncConfig(
        server: 'https://demo.supabase.co',
        email: 'a@b.c',
        token: 'token-1',
        anonKey: 'anon-key',
        refreshToken: 'refresh-1',
      ),
    );
    final transport = RefreshingTransport(configStore);

    final engine = SyncEngine(
      store: store,
      configStore: configStore,
      transport: transport,
    );
    await engine.init();
    addTearDown(engine.dispose);

    expect(await engine.syncNow(), isTrue);
    expect(transport.calls, 1);

    // In memory: the round advanced the revision *and* kept the new session.
    expect(engine.config!.rev, 7);
    expect(engine.config!.token, 'token-2');
    expect(engine.config!.refreshToken, 'refresh-2');

    // On disk: the same. This is the assertion that fails if the round saves
    // the config it captured before the request.
    final saved = (await configStore.load())!;
    expect(saved.rev, 7);
    expect(saved.token, 'token-2');
    expect(saved.refreshToken, 'refresh-2');
    expect(saved.anonKey, 'anon-key');
  });
}
