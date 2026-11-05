/// The first-run gate's state: the sign-in draft, the in-flight latch, and the
/// one decision the screen exists to collect.
///
/// **Why a gate at all.** The app used to open straight into the library with
/// sync silently switched on and no session, so a new user got a demo deck and
/// no idea that an account existed. The gate asks once, on the device, and the
/// answer is kept in `onboarding.json` rather than in the snapshot — see
/// `data/repositories/onboarding_store.dart` for why that distinction matters.
///
/// **Why both paths are equal.** "Use it without an account" is not a dismiss
/// link at the bottom; it is a real answer that writes a real record. A gate
/// that only offers sign-in is a nag, and a nag is what makes people close the
/// app.
///
/// **Why this is not [SettingsViewModel].** That model owns a whole settings
/// screen: voices, exports, the dictionary cache, the update card. The gate
/// needs three fields and two verbs, and importing the rest would mean building
/// the rest. The auth *behaviour* is copied from it deliberately (busy latch,
/// `SyncHttpError.kind` mapped to an inline message, a bare throw treated as
/// offline) because the two screens must not disagree about what went wrong.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../data/models/sync_config.dart'
    show kDefaultAnonKey, kDefaultServer;
import '../../../../data/repositories/onboarding_store.dart';
import '../../../../data/repositories/sync_engine.dart';
import '../../../../data/services/backend_transport.dart'
    show SyncBackend, detectBackend;
import '../../../../data/services/sync_transport.dart'
    show SyncError, SyncHttpError;
import '../../../core/view_model.dart';

class OnboardingViewModel extends ViewModel {
  OnboardingViewModel({
    required this._feedback,
    required this._onboarding,
    required this._engine,
    required this._onConfigured,
  }) {
    // The address a returning user already had, or the one this build ships
    // with. The engine's status is the only place a saved address can come from
    // before a session exists, and reading it here means the field is right on
    // the first frame rather than one rebuild later.
    final status = _engine.status;
    _server = status.server.isEmpty ? kDefaultServer : status.server;
    // Same for the project key. [SyncStatus] already falls back to the shipped
    // key when there is no session, so this only guards the empty case a
    // reference-server session leaves behind.
    _anonKey = status.anonKey;
  }

  final Feedback _feedback;
  final OnboardingStore _onboarding;
  final SyncEngine _engine;
  final VoidCallback _onConfigured;

  String _server = kDefaultServer;
  String _email = '';
  String _password = '';
  String _anonKey = kDefaultAnonKey;
  bool _busy = false;
  SyncError? _error;

  /// The server field's draft value.
  String get server => _server;

  /// The email field's draft value.
  String get email => _email;

  /// The password field's draft value.
  String get password => _password;

  /// The Supabase project key's draft value.
  String get anonKey => _anonKey;

  /// A request is in flight. Both buttons and the disclosure go quiet, so a
  /// second tap cannot start a second round against the same account.
  bool get busy => _busy;

  /// What went wrong last time, shown in place under the form.
  SyncError? get error => _error;

  /// Whether the typed address points at a Supabase project, whose gateway
  /// needs the project key on every request.
  bool get isSupabase => detectBackend(_server) == SyncBackend.supabase;

  void setServer(String value) => update(() => _server = value);

  void setEmail(String value) => update(() => _email = value);

  void setPassword(String value) => update(() => _password = value);

  void setAnonKey(String value) => update(() => _anonKey = value);

  /// Sign in with the draft, then record the answer.
  Future<void> signIn() => _submit(
        (engine) => engine.login(
          _server.trim(),
          _email.trim(),
          _password,
          anonKey: _anonKey.trim(),
        ),
      );

  /// Create an account with the draft, then record the answer.
  Future<void> signUp() => _submit(
        (engine) => engine.register(
          _server.trim(),
          _email.trim(),
          _password,
          anonKey: _anonKey.trim(),
        ),
      );

  /// Keep everything on this device and never ask again.
  ///
  /// Writes the record *before* handing control to the shell, so a crash in
  /// between costs one extra question rather than a device that looks set up
  /// and is not.
  Future<void> useLocal() async {
    if (_busy) return;
    update(() {
      _busy = true;
      _error = null;
    });
    await _onboarding.complete(OnboardingChoice.local);
    if (isDisposed) return;
    update(() => _busy = false);
    _onConfigured();
  }

  /// Check that the address answers `/api/health`.
  ///
  /// The key goes with it: a Supabase gateway rejects a keyless request, and
  /// the transport would report that as a failed connection rather than as a
  /// missing key.
  Future<void> testConnection() async {
    if (_busy) return;
    update(() => _busy = true);
    final ok = await _engine.testConnection(
      _server.trim(),
      anonKey: _anonKey.trim(),
    );
    if (isDisposed) return;
    update(() => _busy = false);
    _feedback.toast(
      _feedback.t(ok ? 'settings.syncTestOk' : 'settings.syncTestFail'),
      kind: ok ? ToastKind.ok : ToastKind.err,
    );
  }

  /// Translate a [SyncError] into the sentence the user needs.
  String errorLabel(SyncError error) => switch (error) {
        SyncError.offline => _feedback.t('settings.syncErrorOffline'),
        SyncError.unauthorized => _feedback.t('settings.syncErrorUnauthorized'),
        SyncError.server => _feedback.t('settings.syncErrorServer'),
        SyncError.badCredentials =>
          _feedback.t('settings.syncErrorBadCredentials'),
        SyncError.emailTaken => _feedback.t('settings.syncErrorEmailTaken'),
        SyncError.weakPassword => _feedback.t('settings.syncErrorWeakPassword'),
        SyncError.invalidEmail => _feedback.t('settings.syncErrorInvalidEmail'),
      };

  /// Runs one auth round, then records the answer on success.
  ///
  /// The record is written only after the engine accepted the session. Writing
  /// it on the tap instead would let a user who mistyped their password, or
  /// whose server is down, land in an app that is configured for sync and
  /// silently is not: exactly the state the gate exists to prevent.
  Future<void> _submit(Future<void> Function(SyncEngine engine) action) async {
    if (_busy) return;
    // An empty field cannot reach the server usefully; the two answers it would
    // get back (`invalid_email`, `bad_credentials`) both describe the address
    // rather than the thing actually missing.
    if (_email.trim().isEmpty || _password.isEmpty) {
      update(() => _error = SyncError.badCredentials);
      return;
    }
    update(() {
      _busy = true;
      _error = null;
    });
    try {
      await action(_engine);
      if (isDisposed) return;
      await _onboarding.complete(OnboardingChoice.sync);
      if (isDisposed) return;
      // The first round, run here rather than left to a background loop that
      // no longer exists: the account's words should be there when the shell
      // appears. Later rounds wait for the user to ask for one.
      unawaited(_engine.syncNow());
      update(() => _busy = false);
      _onConfigured();
    } on SyncHttpError catch (err) {
      if (isDisposed) return;
      update(() {
        _error = err.kind;
        _busy = false;
      });
    } catch (_) {
      if (isDisposed) return;
      update(() {
        _error = SyncError.offline;
        _busy = false;
      });
    }
  }
}
