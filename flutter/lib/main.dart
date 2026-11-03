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
///   4. read this build's own version, which the update check compares against,
///   5. mount the shell.
///
/// A snapshot that fails to parse does not stop the app: [SnapshotStore] hands
/// back the `.bak` copy, or nothing at all, and the boot continues with what it
/// has. Losing a vocabulary list to a parse error would be worse than starting
/// clean and keeping the bad file for recovery.
///
/// The update check is the one thing here that is *not* awaited. It is a
/// network round trip, it runs at most every six hours, and nothing on screen
/// depends on it — so it starts after the first frame and the user never waits
/// for GitHub to answer before seeing their words.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app/scope.dart';
import 'app/update_scope.dart';
import 'data/models/sync_config.dart';
import 'data/repositories/onboarding_store.dart';
import 'data/repositories/store.dart';
import 'data/repositories/sync_engine.dart';
import 'data/repositories/update_service.dart';
import 'data/services/app_dir.dart';
import 'data/services/app_installer.dart';
import 'data/services/backend_transport.dart';
import 'data/services/snapshot_store.dart';
import 'domain/models/seed.dart';
import 'domain/models/types.dart';
import 'ui/core/i18n/i18n.dart';
import 'ui/core/system_ui.dart';
import 'ui/core/theme.dart';
import 'ui/core/tokens.dart';
import 'ui/core/widgets/toast.dart';
import 'ui/features/onboarding/views/onboarding_page.dart';
import 'ui/features/shell/views/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Draw under the system bars before anything is mounted, so the first frame
  // is already edge-to-edge. Awaiting matters here: `runApp` below would
  // otherwise race the platform channel and the first frame would be drawn
  // letterboxed, then jump.
  await enableEdgeToEdge();

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
  //
  // The project key is handed over here rather than left to the first sign-in:
  // it is the same public key for every install of this build, and priming it
  // means a "test connection" tap before anyone signs in still gets through the
  // gateway instead of coming back `unauthorized`.
  final transport = BackendTransport(key: kDefaultAnonKey);
  final sync = SyncEngine(
    store: store,
    configStore: const FileSyncConfigStore(),
    transport: transport,
  );
  await sync.init();

  final update = UpdateService(
    installer: appInstaller,
    network: IoUpdateNetwork(),
    // The check bookkeeping lives beside the snapshot but *outside* it: which
    // release the user dismissed is a fact about this device's attention, not a
    // preference to sync to their other machines.
    stateStore: FileUpdateStateStore(
      '${AppDir.dataDir}${Platform.pathSeparator}update-state.json',
    ),
    // Must be the folder `file_paths.xml` exposes, or the installer cannot read
    // what we hand it. See `AppDir.updateDir`.
    downloadDir: Directory(AppDir.updateDir),
    manifestUrl: updateManifestUrl(),
    now: DateTime.now,
  );
  // Before the first frame, so the settings page can draw the real version
  // immediately instead of flashing a placeholder. One platform round trip,
  // and a failure is absorbed: an unknown version means "cannot tell", not a
  // crash.
  await update.load();

  // Whether this device has been set up is a fact about *this install*, so it
  // lives in its own sidecar rather than in the snapshot — the argument is in
  // `onboarding_store.dart`. Reading it before the first frame is what lets the
  // gate be the first thing drawn instead of the shell flashing and being
  // replaced.
  final onboarding = FileOnboardingStore(
    '${AppDir.dataDir}${Platform.pathSeparator}onboarding.json',
  );
  await onboarding.load();

  runApp(LexumoApp(
    store: store,
    sync: sync,
    update: update,
    onboarding: onboarding,
  ));
}

class LexumoApp extends StatefulWidget {
  const LexumoApp({
    super.key,
    required this.store,
    required this.sync,
    required this.update,
    this.onboarding,
  });

  final Store store;
  final SyncEngine sync;
  final UpdateService update;

  /// Whether this device was set up to sync or to stay local.
  ///
  /// Optional so a test can mount the shell directly: when it is null the app
  /// behaves as if the question was already answered locally, which is what
  /// every widget test of the shell wants. Production always passes the
  /// [FileOnboardingStore] built in `main`.
  final OnboardingStore? onboarding;

  @override
  State<LexumoApp> createState() => _LexumoAppState();
}

class _LexumoAppState extends State<LexumoApp> with WidgetsBindingObserver {
  late final StoreNotifier _notifier;
  late final SyncStatusNotifier _syncNotifier;
  late final UpdateNotifier _updateNotifier;
  late final OnboardingStore _onboarding;
  final GlobalKey<ToastHostState> _toastKey = GlobalKey<ToastHostState>();

  /// True once the first-run question has an answer, from either the sidecar at
  /// boot or the gate this session. Read as a plain field rather than from the
  /// store so the transition is one `setState`, not a new notifier.
  late bool _configured;

  /// Guards against two checks being started by two resume events during one
  /// cold start. The service joins concurrent calls anyway; this keeps the
  /// intent readable.
  bool _asked = false;

  @override
  void initState() {
    super.initState();
    _notifier = StoreNotifier(widget.store);
    _syncNotifier = SyncStatusNotifier(widget.sync);
    _updateNotifier = UpdateNotifier(widget.update);
    _onboarding = widget.onboarding ?? MemoryOnboardingStore(
      choice: OnboardingChoice.local,
    );
    _configured = _onboarding.choice != null;
    // The store saves on a debounce; a window that closes inside the delay
    // would otherwise lose the last edit. Flushing on detach is cheap.
    widget.store.addListener(_onStoreWrite);
    WidgetsBinding.instance.addObserver(this);
    // After the first frame, so a slow or offline check never delays the words.
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkForUpdates());
  }

  void _onStoreWrite() => setState(() {});

  /// The first-run question has been answered and recorded; hand the screen
  /// over to the shell.
  ///
  /// Swapping `home` rather than pushing a route means the gate is not on the
  /// back stack: there is no "back" from the library into a question that has
  /// already been answered.
  void _onConfigured() {
    if (!mounted) return;
    setState(() => _configured = true);
  }

  /// Ask the manifest once, when it is due.
  ///
  /// Not forced: a launch inside the six-hour window reads the remembered
  /// answer instead of making a request. The About card's button forces.
  Future<void> _checkForUpdates() async {
    if (_asked || !mounted) return;
    _asked = true;
    try {
      await widget.update.check();
    } catch (_) {
      // `check` reports failures through its state; nothing here can act on a
      // throw, and an update check must never be the reason a launch fails.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The only trustworthy "the update installed" signal: the installer was a
    // different app's dialog, the user may have cancelled it, and Android says
    // nothing either way. If the build number moved, it happened.
    if (state == AppLifecycleState.resumed) {
      unawaited(_confirmInstalled());
    }
  }

  Future<void> _confirmInstalled() async {
    final updated = await widget.update.confirmInstalled();
    if (!updated || !mounted) return;
    _toastKey.currentState?.show(
      I18n(widget.store.data.settings.uiLang).t('settings.updateDone'),
      ToastKind.ok,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.store.flush();
    widget.update.dispose();
    widget.sync.dispose();
    _updateNotifier.dispose();
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
        child: UpdateScope(
          notifier: _updateNotifier,
          child: I18nScope(
            i18n: i18n,
            child: _ThemeHost(
              mode: settings.theme,
              child: MaterialApp(
                title: i18n.t('common.appName'),
                debugShowCheckedModeBanner: false,
                theme: buildTheme(Palette.light),
                darkTheme: buildTheme(Palette.dark),
                themeMode: _themeMode(settings.theme),
                // The toast stack goes in `builder`, never above `MaterialApp`.
                //
                // [ToastHost] draws a bare [Stack], and a `Stack` resolves its
                // default `AlignmentDirectional.topStart` through the ambient
                // [Directionality]. `MaterialApp` is what installs that; above
                // it there is none, so layout threw
                // `Null check operator used on a null value` inside
                // `AlignmentDirectional.resolve` on the very first frame, no
                // page was ever painted, and the app looked frozen showing
                // whatever the window happened to hold.
                //
                // `builder` runs *inside* MaterialApp (Directionality,
                // MediaQuery and Theme all present) but *around* the Navigator,
                // so a toast still floats above every page and every dialog
                // pushed on top of them.
                builder: (BuildContext context, Widget? child) => ToastHost(
                  key: _toastKey,
                  child: child ?? const SizedBox.shrink(),
                ),
                home: _configured
                    ? const AppShell()
                    : OnboardingPage(
                        engine: widget.sync,
                        onboarding: _onboarding,
                        onConfigured: _onConfigured,
                      ),
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
