/// The app entry point: load the snapshot, then mount the shell in the right
/// theme and language.
///
/// The boot order matters and is the same as the web build's:
///
///   1. resolve the data folder and read `lexumo.json` (seeding a demo deck on
///      first run),
///   2. decide the language from the snapshot — every label below the root
///      depends on it,
///   3. decide light/dark from the snapshot, following the system when the
///      setting says `system`,
///   4. mount the shell.
///
/// A snapshot that fails to parse does not stop the app: [SnapshotStore] hands
/// back the `.bak` copy, or nothing at all, and the boot continues with what it
/// has. Losing a vocabulary list to a parse error would be worse than starting
/// clean and keeping the bad file for recovery.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'app/scope.dart';
import 'app/shell.dart';
import 'app/toast.dart';
import 'data/backend_transport.dart';
import 'data/snapshot_store.dart';
import 'data/store.dart';
import 'data/sync_config.dart';
import 'data/sync_engine.dart';
import 'design/theme.dart';
import 'design/tokens.dart';
import 'domain/seed.dart';
import 'domain/types.dart';
import 'i18n/i18n.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final store = Store(
    persistence: SnapshotStore(),
    seed: seedData,
  );
  await store.init();

  // The sync engine starts here, after the snapshot is readable, because its
  // loop asks `settings.autoSync` on every tick. Failing to read the saved
  // session is not fatal: the engine comes up signed out.
  //
  // One transport serves both backends; it routes on the server URL, so the
  // engine never learns whether it is talking to server/ or to Supabase.
  final transport = BackendTransport();
  final sync = SyncEngine(
    store: store,
    configStore: const FileSyncConfigStore(),
    transport: transport,
  );
  await sync.init();

  runApp(LexumoApp(store: store, sync: sync));
}

class LexumoApp extends StatefulWidget {
  const LexumoApp({super.key, required this.store, required this.sync});

  final Store store;
  final SyncEngine sync;

  @override
  State<LexumoApp> createState() => _LexumoAppState();
}

class _LexumoAppState extends State<LexumoApp> {
  late final StoreNotifier _notifier;
  late final SyncStatusNotifier _syncNotifier;
  final GlobalKey<ToastHostState> _toastKey = GlobalKey<ToastHostState>();

  @override
  void initState() {
    super.initState();
    _notifier = StoreNotifier(widget.store);
    _syncNotifier = SyncStatusNotifier(widget.sync);
    // The store saves on a debounce; a window that closes inside the delay
    // would otherwise lose the last edit. Flushing on detach is cheap.
    widget.store.addListener(_onStoreWrite);
  }

  void _onStoreWrite() => setState(() {});

  @override
  void dispose() {
    widget.store.flush();
    widget.sync.dispose();
    _syncNotifier.dispose();
    _notifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.store.data;
    final settings = data.settings;
    final i18n = I18n(settings.uiLang);

    return StoreScope(
      notifier: _notifier,
      child: SyncScope(
        notifier: _syncNotifier,
        child: I18nScope(
          i18n: i18n,
          child: _ThemeHost(
            mode: settings.theme,
            child: ToastHost(
              key: _toastKey,
              child: MaterialApp(
                title: i18n.t('common.appName'),
                debugShowCheckedModeBanner: false,
                theme: buildTheme(Palette.light),
                darkTheme: buildTheme(Palette.dark),
                themeMode: _themeMode(settings.theme),
                home: const AppShell(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  ThemeMode _themeMode(ThemeMode_ mode) => switch (mode) {
        ThemeMode_.light => ThemeMode.light,
        ThemeMode_.dark => ThemeMode.dark,
        ThemeMode_.system => ThemeMode.system,
      };
}

/// Rebuilds every descendant when the palette flips, so [Palette.of] — which
/// reads the theme extension — returns the new values without any widget having
/// to listen for the change itself.
class _ThemeHost extends StatelessWidget {
  const _ThemeHost({required this.mode, required this.child});

  final ThemeMode_ mode;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
