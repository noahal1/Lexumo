/// The update sheet's state and its four steps, with no widgets in them.
///
/// The sheet used to hold three things in `State`: the `_working` latch that
/// stopped a second download, and — spread between two `AnimatedBuilder`s —
/// every read of [UpdateService]'s snapshot. All of it lives here now, plus the
/// version this sheet last asked the service to skip, so the sheet can be read
/// as layout and nothing else.
///
/// ## What stayed in the view
///
/// The view still decides *which* widgets draw a phase, because that is layout.
/// What it no longer decides is which actions a phase offers: [actions] is a
/// derivation of the state, so "a required release has no *later*" and "a
/// refusal swaps Download for Open settings" are testable without a tree.
///
/// Two things deliberately did not move:
///
///   * **the pop.** `Navigator.of(context).maybePop()` is the view's, because a
///     view model has no route. [run] performs the side effect and the view
///     closes itself afterwards — the same order the old `_later` had.
///   * **which release note to show.** That needs the active UI language
///     (`context.i18n.lang.wire`), and [Feedback] exposes translation, not the
///     locale. The view picks the note; this class never needs to know.
///
/// ## Why the modal has two of these
///
/// [showLexModal] takes `body` and `footer` as separate slots, so the sheet is
/// two widgets, exactly as it was two `AnimatedBuilder`s. Each owns one of
/// these; the footer's is the one that carries [working], which is where that
/// flag lived before.
library;

// The constructor's parameter names (`service:`, `feedback:`) read better than
// the private field names — the same trade-off `words_view_model.dart` and
// `data/repositories/store.dart` make.
// ignore_for_file: prefer_initializing_formals

import '../../../../data/repositories/update_service.dart';
import '../../../../data/services/app_installer.dart';
import '../../../../domain/models/update_manifest.dart';
import '../../../../domain/models/version.dart';
import '../../../core/view_model.dart';

/// One button the sheet can offer, in the order it draws them.
///
/// An enum rather than a widget list: the view model names the action and the
/// view decides what it looks like — label, kind, icon — which is the same
/// split the rest of this refactor uses.
enum UpdateAction {
  /// Ask the manifest again, ignoring the interval and the dismissed build.
  check,

  /// Fetch the APK the current state names.
  download,

  /// Hand the verified file to the system installer.
  install,

  /// Re-check when there is no release, re-download when there is.
  retry,

  /// Stop an in-flight download. The partial file is deleted by the service.
  cancel,

  /// Send the user to the screen where "install unknown apps" is granted.
  openSettings,

  /// Remember this build as skipped, so automatic checks stop offering it.
  later,

  /// Close the sheet without touching the skipped-build memory.
  close,
}

/// The i18n key for a failure [reason] code.
///
/// One owner for the mapping, because it is read in two places that must agree:
/// the sheet, which offers a retry, and the settings row, which has no room for
/// a retry and therefore has to be right the first time. When this lived twice,
/// the row reported "no connection" for every failure — a bad digest and a
/// missing connection were indistinguishable from outside, and the only action
/// either suggests (check your network) was wrong half the time.
///
/// An unknown code falls back to the server sentence rather than inventing one:
/// a code the app does not recognise means a newer client wrote it, and
/// "something went wrong" is both true and useless.
String updateReasonKey(String? reason) => switch (reason) {
      'offline' => 'settings.updateReasonOffline',
      'server' => 'settings.updateReasonServer',
      'manifest' => 'settings.updateReasonManifest',
      'digest' => 'settings.updateReasonDigest',
      'signature' => 'settings.updateReasonSignature',
      'space' => 'settings.updateReasonSpace',
      'storage' => 'settings.updateReasonStorage',
      'unsupported' => 'settings.updateReasonUnsupported',
      'permission' => 'settings.updateReasonPermission',
      _ => 'settings.updateReasonServer',
    };

/// Bytes for humans: one decimal above a megabyte, whole numbers below.
String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.round()} KB';
  return '${(kb / 1024).toStringAsFixed(1)} MB';
}

/// Owns one region of the update sheet.
class UpdateViewModel extends ViewModel {
  UpdateViewModel({
    required UpdateService service,
    required Feedback feedback,
  })  : _service = service,
        _feedback = feedback,
        _state = service.state.value {
    _service.state.addListener(_onServiceState);
  }

  final UpdateService _service;
  final Feedback _feedback;

  /// The snapshot as this view model last saw it.
  ///
  /// Cached rather than read through [UpdateService.state] on every getter so
  /// the view model can be driven by a fake in a unit test with no
  /// `ValueNotifier` in the picture — and so a rebuild can never see two
  /// different snapshots in one frame.
  UpdateState _state;

  /// Set while a download or install call is awaiting, so a second press does
  /// not start a second one. The service guards too; this keeps the button from
  /// looking live while it is not.
  bool _working = false;

  /// The build this sheet last asked the service to skip, or null.
  ReleaseVersion? _dismissed;

  void _onServiceState() => update(() => _state = _service.state.value);

  /* ---- state -------------------------------------------------------- */

  UpdateState get state => _state;

  UpdateAvailable? get available => _state.available;

  UpdatePhase get phase => _state.phase;

  InstallRefusal? get refusal => _state.refusal;

  /// True while the button must not be pressable again.
  bool get working => _working;

  /// The build this sheet last dismissed, for a test to assert on.
  ReleaseVersion? get dismissedVersion => _dismissed;

  /// A release the user cannot skip: the build below the floor cannot talk to
  /// the server, so dismissing it would only postpone a failure the user cannot
  /// attribute.
  bool get isRequired => _state.available?.required ?? false;

  /* ---- the body's derivations --------------------------------------- */

  /// The headline for a release that exists, whatever the phase — the sheet
  /// keeps naming it while it downloads and verifies.
  String? get availableHeadline {
    final UpdateAvailable? release = _state.available;
    if (release == null) return null;
    return _feedback.t('settings.updateAvailable', {
      'version': release.manifest.version.name.toString(),
    });
  }

  /// The second line under [availableHeadline].
  String? get availableDetail {
    final UpdateAvailable? release = _state.available;
    if (release == null) return null;
    if (release.required) return _feedback.t('settings.updateRequired');
    final int? bytes = release.manifest.apk.bytes;
    if (bytes == null) return '';
    // Not `updateDownloaded`: the sheet is still offering the download, and
    // telling someone "19.5 MB downloaded" before they pressed anything is the
    // kind of small untruth that makes every other number here suspect.
    return _feedback.t('settings.updateSize', {'size': _formatBytes(bytes)});
  }

  /// The headline for a state that has no release to name.
  ///
  /// Null while [available] is set, because the sheet names the release instead
  /// — and null for `idle`, `downloading`, `verifying` and `failed`, which draw
  /// something else.
  String? get statusHeadline {
    if (_state.available != null) return null;
    return switch (_state.phase) {
      UpdatePhase.upToDate => _feedback.t('settings.updateUpToDate'),
      UpdatePhase.checking => _feedback.t('settings.updateChecking'),
      _ => null,
    };
  }

  /// The headline for a verified APK waiting on the user.
  String? get readyHeadline =>
      _state.phase == UpdatePhase.ready ? _feedback.t('settings.updateReady') : null;

  /// The second line under [readyHeadline]: how big the file is.
  String? get readyDetail => _state.phase == UpdatePhase.ready && _state.file != null
      ? _feedback.t('settings.updateDownloaded', {
          'size': _formatBytes(_state.totalBytes ?? 0),
        })
      : null;

  /// Whether the release notes are drawn — while the release is on offer, being
  /// fetched, or being verified.
  bool get showNotes =>
      _state.available != null &&
      (_state.phase == UpdatePhase.available ||
          _state.phase == UpdatePhase.downloading ||
          _state.phase == UpdatePhase.verifying);

  /// Whether the progress bar is drawn.
  bool get showProgress => _state.isBusy;

  /// The line beside the progress bar.
  String get progressLabel {
    final int pct = (_state.progress * 100).clamp(0, 100).round();
    return switch (_state.phase) {
      UpdatePhase.verifying => _feedback.t('settings.updateVerifying'),
      UpdatePhase.checking => _feedback.t('settings.updateChecking'),
      _ => _feedback.t('settings.updateDownloading', {'percent': '$pct'}),
    };
  }

  /// Bytes received so far, or null when the manifest advertised no size and a
  /// number would be a guess.
  String? get progressBytes =>
      _state.totalBytes == null ? null : _formatBytes(_state.receivedBytes);

  /// Whether the failure notice is drawn.
  bool get showProblem => _state.phase == UpdatePhase.failed;

  /// The sentence for the current failure.
  String get problemText => _feedback.t(updateReasonKey(_state.reason));

  /// Whether the "grant install permission" notice is drawn.
  bool get showPermissionNotice => _state.refusal == InstallRefusal.needsPermission;

  /// The permission notice's sentence.
  String get permissionText => _feedback.t('settings.updatePermission');

  /// Whether this platform cannot install in-app, and must be told where the
  /// build lives instead.
  bool get downloadOnly =>
      _service.installer.support == InstallSupport.downloadOnly;

  /// The sentence explaining the desktop case.
  String get desktopText => _feedback.t('settings.updateDesktop');

  /// The releases page, as text, so it can be copied without a launcher plugin.
  String get releasesUrlText => _releasesUrl(_service.manifestUrl).toString();

  /* ---- the footer's derivations ------------------------------------- */

  /// The buttons this phase offers, in draw order.
  ///
  /// Empty while a check is in flight: the state says "working", and a button
  /// that does nothing is the worse lie.
  List<UpdateAction> get actions {
    final List<UpdateAction> out = <UpdateAction>[];
    switch (_state.phase) {
      case UpdatePhase.idle:
      case UpdatePhase.upToDate:
        out.add(UpdateAction.check);
      case UpdatePhase.checking:
        break;
      case UpdatePhase.available:
        if (!isRequired) out.add(UpdateAction.later);
        out.add(_state.refusal == InstallRefusal.needsPermission
            ? UpdateAction.openSettings
            : UpdateAction.download);
      case UpdatePhase.downloading:
      case UpdatePhase.verifying:
        out.add(UpdateAction.cancel);
      case UpdatePhase.ready:
        if (!isRequired) out.add(UpdateAction.later);
        out.add(_state.refusal == InstallRefusal.needsPermission
            ? UpdateAction.openSettings
            : UpdateAction.install);
      case UpdatePhase.failed:
        out.add(UpdateAction.close);
        out.add(UpdateAction.retry);
    }
    return out;
  }

  /// Whether [action] can be pressed right now.
  ///
  /// Only the three that await a long call are gated: a second Download or
  /// Install must not start a second one, and Retry goes through the same path.
  bool isEnabled(UpdateAction action) => switch (action) {
        UpdateAction.download ||
        UpdateAction.install ||
        UpdateAction.retry =>
          !_working,
        _ => true,
      };

  /* ---- intents ------------------------------------------------------ */

  /// Perform [action].
  ///
  /// Everything except [UpdateAction.close] — which is the view's own pop, and
  /// is a no-op here — and [UpdateAction.later]'s dismissal, whose pop the view
  /// performs once this future completes.
  Future<void> run(UpdateAction action) async {
    switch (action) {
      case UpdateAction.check:
        await _service.check(force: true);
      case UpdateAction.download:
        await download();
      case UpdateAction.install:
        await install();
      case UpdateAction.retry:
        await retry();
      case UpdateAction.cancel:
        _service.cancel();
      case UpdateAction.openSettings:
        await _service.installer.openInstallSettings();
      case UpdateAction.later:
        await dismissRelease();
      case UpdateAction.close:
        break;
    }
  }

  /// Fetch the APK. A second press while one is in flight is dropped.
  Future<void> download() async {
    if (_working) return;
    update(() => _working = true);
    await _service.download();
    if (isDisposed) return;
    update(() => _working = false);
  }

  /// Hand the verified file to the installer, then offer the settings screen
  /// when the platform refused for lack of permission.
  Future<void> install() async {
    if (_working) return;
    update(() => _working = true);
    final InstallerOutcome outcome = await _service.install();
    if (isDisposed) return;
    update(() => _working = false);
    if (!outcome.launched && outcome.refusal == InstallRefusal.needsPermission) {
      await _service.installer.openInstallSettings();
    }
  }

  /// Re-check when there is no release to fetch, re-download when there is.
  Future<void> retry() async {
    if (_state.available == null) {
      await _service.check(force: true);
    } else {
      await download();
    }
  }

  /// Remember this build as skipped. The caller closes the sheet.
  Future<void> dismissRelease() async {
    final UpdateAvailable? release = _state.available;
    if (release == null) return;
    update(() => _dismissed = release.manifest.version);
    await _service.dismiss(release.manifest.version);
  }

  @override
  void dispose() {
    _service.state.removeListener(_onServiceState);
    super.dispose();
  }
}

/// Where a desktop user should go instead: the manifest URL with its asset path
/// peeled off, which is the releases page that published it.
///
/// Derived rather than configured so a test build pointed at a local file
/// server still names a real page, and so there is one URL to change.
Uri _releasesUrl(Uri manifest) {
  final List<String> segments = [...manifest.pathSegments];
  final int drop = segments.lastIndexOf('releases');
  if (drop >= 0) {
    return manifest.replace(pathSegments: segments.sublist(0, drop + 1), query: '');
  }
  return manifest.replace(query: '');
}
