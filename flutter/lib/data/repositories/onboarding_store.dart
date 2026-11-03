/// Whether this device was set up to sync, or to stay local.
///
/// ## Why this is not a field on [Settings]
///
/// The same argument `FileUpdateStateStore` makes in `update_service.dart`: the
/// snapshot is synced wholesale, so a setting stored there follows the user to
/// their second machine. This is not a preference, it is a fact about *this
/// install* — "somebody has already answered the first-run question here". Put
/// it in the snapshot and the answer travels: signing in on a desktop would
/// silently mark a fresh laptop as configured, and the laptop would never ask,
/// which is precisely the screen this file exists to show.
///
/// It also deliberately survives `Store.wipeAll`. Emptying the library is a
/// decision made inside the app; re-asking how the app should be set up because
/// of it would be re-asking a question the user already answered.
///
/// ## Why a sidecar and not `SharedPreferences`
///
/// The app has no plugins for this. `sync.json` and `update-state.json` are
/// already sidecars in the same folder, written with the same
/// write-temp-then-rename dance, and reading one more small JSON file at boot
/// costs less than the platform channel a preferences plugin would need.
library;

import 'dart:convert';
import 'dart:io';

/// What the user chose on the first-run screen.
enum OnboardingChoice {
  /// No account. Everything stays in `lexumo.json` on this device.
  local,

  /// Signed in. The sync engine runs against the server in `sync.json`.
  sync,
}

/// Reads and writes [OnboardingChoice] for one install.
///
/// [choice] is synchronous on purpose: `main()` has to know whether to mount
/// the gate *before* the first frame, and an `await` between `runApp` and the
/// decision would paint the shell and then replace it. [load] is what fills it
/// in, once, at boot.
abstract class OnboardingStore {
  /// The answer, or null when this device has not been asked yet.
  OnboardingChoice? get choice;

  /// Read the answer from wherever it is kept. Never throws.
  Future<void> load();

  /// Record the answer. Never throws: a failure here costs one extra question
  /// on the next launch, which is not worth blocking the app for.
  Future<void> complete(OnboardingChoice choice);
}

/// A small JSON sidecar beside `lexumo.json`.
class FileOnboardingStore implements OnboardingStore {
  FileOnboardingStore(this.path);

  final String path;

  OnboardingChoice? _choice;

  @override
  OnboardingChoice? get choice => _choice;

  File get _file => File(path);

  @override
  Future<void> load() async {
    try {
      if (!await _file.exists()) return;
      final raw = jsonDecode(await _file.readAsString());
      if (raw is! Map) return;
      _choice = switch (raw['choice']) {
        'sync' => OnboardingChoice.sync,
        'local' => OnboardingChoice.local,
        // An unknown value is the same as no value: ask again rather than
        // guess which of the two the user meant.
        _ => null,
      };
    } on FileSystemException {
      // An unreadable sidecar means "not set up yet". The cost is one screen.
    } on FormatException {
      // A truncated file is the same story, and rewriting it on the next
      // answer repairs it.
    }
  }

  @override
  Future<void> complete(OnboardingChoice choice) async {
    _choice = choice;
    try {
      await _file.parent.create(recursive: true);
      // Write beside then rename, like `sync.json`: a crash mid-write would
      // otherwise leave a truncated file that reads as "not set up".
      final temp = File('$path.tmp');
      await temp.writeAsString(jsonEncode({'choice': choice.name}), flush: true);
      await temp.rename(path);
    } on FileSystemException {
      // Losing the write costs one extra question next launch.
    }
  }
}

/// In-memory store for tests and for a gate-less mount.
class MemoryOnboardingStore implements OnboardingStore {
  MemoryOnboardingStore({OnboardingChoice? choice}) : _choice = choice;

  OnboardingChoice? _choice;

  @override
  OnboardingChoice? get choice => _choice;

  @override
  Future<void> load() async {}

  @override
  Future<void> complete(OnboardingChoice choice) async {
    _choice = choice;
  }
}
