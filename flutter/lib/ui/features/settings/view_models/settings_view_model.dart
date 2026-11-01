/// The settings screen's state and behaviour, with no `BuildContext`.
///
/// **Why this is not a widget.** Everything the page *decides* — which draft
/// values the sign-in form holds, whether a sign-in round is in flight, which
/// error the form shows, how many entries the dictionary cache holds, what an
/// export file is called — is a fact about the session, not about a frame.
/// Holding it in a `ChangeNotifier` lets the page be rebuilt (or thrown away and
/// rebuilt) with the answers unchanged, and lets the whole flow be driven from a
/// test with no widget tree at all.
///
/// What it owns:
///
///   · the store subscription, so a snapshot write rebuilds the page;
///   · the sync engine's and the update service's subscriptions, so a status
///     change rebuilds it too — neither is required, so a page pumped without a
///     `SyncScope`/`UpdateScope` still works and simply shows the signed-out,
///     version-less state;
///   · the sync form's draft (server, email, password, project key) plus its
///     busy flag and in-place error;
///   · the voice list and the sample sentence, through [SpeechPort];
///   · the dictionary cache count, through [LookupCachePort];
///   · export, import (including the preview prompt) and the wipe flow.
///
/// What it deliberately does not own: `TextEditingController`s, `FocusNode`s,
/// `ScrollController`s and dialog bodies. Those are widgets. The model keeps the
/// *values* and asks for the dialogs through [Feedback] and
/// [ImportPreviewPrompt]; the view keeps the controllers and draws the dialogs.
library;

// The constructor's parameter names (`store:`, `speech:`) read better than the
// private field names — the same trade-off `words_view_model.dart`,
// `update_view_model.dart` and `data/repositories/store.dart` make.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../data/models/sync_config.dart' show kDefaultServer;
import '../../../../data/repositories/store.dart';
import '../../../../data/repositories/sync_engine.dart';
import '../../../../data/repositories/update_service.dart';
import '../../../../data/services/backend_transport.dart'
    show SyncBackend, detectBackend;
import '../../../../data/services/file_dialogs.dart';
import '../../../../data/services/sync_transport.dart'
    show SyncError, SyncHttpError;
import '../../../../data/services/transfer.dart' as transfer;
import '../../../../domain/models/types.dart';
import '../../../core/view_model.dart';

/// One voice the picker may offer, in the three fields the picker and the
/// persisted `ttsVoiceURI` actually need.
typedef VoiceOption = ({String uri, String name, String lang});

/// What the view model needs from text-to-speech.
///
/// A port rather than the `Speech` class, for two reasons. First, `appSpeech` is
/// a process-wide singleton that `debugSetSpeech` swaps for a fake, and a
/// reference captured at construction time would freeze whichever one was
/// installed then — the read has to happen at call time. Second, the engine
/// behind it is a platform channel, and a class this easy to test has no
/// business opening one.
///
/// The implementation lives in the view, which reads `appSpeech` on every call.
abstract class SpeechPort {
  /// True when a 发音 control should be rendered.
  bool get supported;

  /// Voices for one language, best match first.
  List<VoiceOption> voicesForLang(String lang);

  /// Idempotent; a no-op when another page already warmed the engine.
  Future<void> warmUp();

  /// Speaks [text] in [lang] at [rate] (web scale, 1.0 = normal).
  Future<void> speak(
    String text, {
    String? lang,
    double? rate,
    String? voiceURI,
  });

  /// Subscribes to voice-list changes; returns the unsubscribe.
  VoidCallback onVoicesChanged(VoidCallback listener);
}

/// What the view model needs from the on-disk dictionary cache.
///
/// The same shape of argument as [SpeechPort]: `defaultLookup` is a process-wide
/// singleton that `debugSetLookup` swaps, so the read has to happen at call time
/// and the model must not hold a reference to it.
abstract class LookupCachePort {
  /// How many entries the cache holds.
  int cacheSize();

  /// Empty it.
  void clearCache();
}

/// Asks the user to confirm an import, showing what would be added.
///
/// The preview is a dialog, so it belongs to the view; the model only decides
/// *when* to ask and what the answer means.
typedef ImportPreviewPrompt = Future<bool> Function(
  ImportPreviewRequest request,
);

/// What the preview dialog needs to draw itself.
@immutable
class ImportPreviewRequest {
  const ImportPreviewRequest({
    required this.fileName,
    required this.formatLabel,
    required this.result,
  });

  /// The picked file's name, shown under the title.
  final String fileName;

  /// The recognised format, already translated.
  final String formatLabel;

  /// The parsed words: previewed first, committed after.
  final transfer.ImportResult result;
}

/// The model behind `SettingsPage`.
///
/// Every mutation goes through [update], so the page is rebuilt exactly once per
/// change; a write to the store comes back through the store listener as a
/// [refresh]. Async actions re-check [isDisposed] after each `await` before they
/// touch the model or raise a toast.
class SettingsViewModel extends ViewModel {
  SettingsViewModel({
    required Store store,
    required Feedback feedback,
    required SpeechPort speech,
    required LookupCachePort lookupCache,
    required ImportPreviewPrompt previewImport,
    SyncEngine? engine,
    UpdateService? update,
    int Function()? clock,
  })  : _store = store,
        _feedback = feedback,
        _speech = speech,
        _lookupCache = lookupCache,
        _previewImport = previewImport,
        _engine = engine,
        _update = update,
        _clock = clock ?? _systemClock {
    // One relay closure, stored, so subscribe and unsubscribe are guaranteed to
    // use the same callable.
    _relay = refresh;
    _detachStore = _store.addListener(_relay);
    _detachEngine = _engine?.addListener(_relay);
    _update?.state.addListener(_relay);
    // The voice list arrives asynchronously (Android's engine answers nothing
    // until it has initialised), so the model subscribes instead of reading it
    // once — the same shape `onVoicesChanged` had in the web build.
    _offVoices = _speech.onVoicesChanged(_relay);
    // Read once, the way the old `initState` did: the count only changes when
    // this page clears it.
    _cacheSize = _lookupCache.cacheSize();
    // The session that exists now is the one the form prefills from: signing
    // out wipes it before the form is drawn, and a 200-character project key
    // asked for again on every sign-in is enough friction to abandon sync.
    final status = _engine?.status;
    _syncServer = status?.server ?? kDefaultServer;
    _syncAnonKey = status?.anonKey ?? '';
    // Idempotent; a no-op when another page already warmed the engine.
    unawaited(_speech.warmUp());
  }

  final Store _store;
  final Feedback _feedback;
  final SpeechPort _speech;
  final LookupCachePort _lookupCache;
  final ImportPreviewPrompt _previewImport;
  final SyncEngine? _engine;
  final UpdateService? _update;
  final int Function() _clock;

  /// [refresh] as a stored closure, for the listener lists below.
  late final VoidCallback _relay;
  late final void Function() _detachStore;
  void Function()? _detachEngine;
  late final VoidCallback _offVoices;

  static int _systemClock() => DateTime.now().millisecondsSinceEpoch;

  /// How many words the dictionary cache holds.
  int _cacheSize = 0;

  String _syncServer = kDefaultServer;
  String _syncEmail = '';
  String _syncPassword = '';
  String _syncAnonKey = '';
  bool _syncBusy = false;
  SyncError? _syncFormError;

  @override
  void dispose() {
    _offVoices();
    _update?.state.removeListener(_relay);
    _detachEngine?.call();
    _detachStore();
    super.dispose();
  }

  /* ---------------------------------------------------------------- */
  /* The snapshot                                                      */
  /* ---------------------------------------------------------------- */

  /// The current snapshot. Rebuilt whenever the store writes.
  AppData get data => _store.data;

  /// The current settings, for the controls to read.
  Settings get settings => data.settings;

  /// Apply a settings change.
  ///
  /// The store notifies every listener — including this model — so the rebuild
  /// arrives through [_relay] rather than from here. Wrapping the write in
  /// [update] as well would notify twice for one change.
  void patch(Settings Function(Settings settings) fn) =>
      _store.updateSettings(fn);

  /* ---------------------------------------------------------------- */
  /* Speech                                                            */
  /* ---------------------------------------------------------------- */

  /// Language whose voices the picker should offer: the first list's source
  /// language, exactly as `SettingsPage.tsx:42` derived `studyLang`.
  String get studyLang =>
      data.lists.isNotEmpty ? data.lists.first.sourceLang : 'en';

  /// True when a 发音 control should be rendered.
  ///
  /// Only note the absence once the engine has actually said no; before warm-up
  /// `supported` answers true on purpose so the picker does not flash in and
  /// out.
  bool get speechSupported => _speech.supported;

  /// The voices the picker may offer for [studyLang].
  List<VoiceOption> get voices => _speech.voicesForLang(studyLang);

  /// How a persisted voice handle is named in the picker.
  ///
  /// `''` is the "automatic" entry, so the persisted value always matches an
  /// option even after the chosen voice was uninstalled.
  String voiceLabel(String uri) {
    if (uri.isEmpty) return _feedback.t('settings.ttsVoiceAuto');
    for (final voice in voices) {
      if (voice.uri == uri) return '${voice.name} · ${voice.lang}';
    }
    return uri;
  }

  /// Says one sample sentence through the currently selected voice, so the
  /// picker has audible feedback before the user meets it on a card.
  Future<void> testVoice() async {
    final settings = this.settings;
    final lang = studyLang;
    await _speech.speak(
      _feedback.t('settings.voiceSample'),
      lang: lang,
      rate: settings.ttsRate,
      voiceURI: settings.ttsVoiceURI,
    );
  }

  /* ---------------------------------------------------------------- */
  /* Dictionary cache                                                  */
  /* ---------------------------------------------------------------- */

  /// How many words the dictionary cache holds.
  int get cacheSize => _cacheSize;

  /// Empty the dictionary cache and report the new size.
  ///
  /// The cache is disposable by design — every entry can be refetched — so this
  /// asks for no confirmation. It exists because the entries are the one thing
  /// the app writes to disk that the user never typed.
  void clearLookupCache() {
    _lookupCache.clearCache();
    update(() => _cacheSize = _lookupCache.cacheSize());
    _feedback.toast(_feedback.t('settings.cacheCleared'), kind: ToastKind.ok);
  }

  /* ---------------------------------------------------------------- */
  /* Sync: state                                                       */
  /* ---------------------------------------------------------------- */

  /// The engine's status, or null when no engine is mounted.
  SyncStatus? get syncStatus => _engine?.status;

  /// A login/register round is in flight. Separate from `SyncState.syncing`,
  /// which is about data rounds, not auth.
  bool get syncBusy => _syncBusy;

  /// Kept on screen instead of a toast: an auth failure is the kind of message
  /// the user needs while fixing the field it refers to.
  SyncError? get syncFormError => _syncFormError;

  /// The server field's draft value.
  String get syncServer => _syncServer;

  /// The email field's draft value.
  String get syncEmail => _syncEmail;

  /// The password field's draft value. The controller that owns the text is
  /// what clears it from memory; this is only the copy the request reads.
  String get syncPassword => _syncPassword;

  /// The project key field's draft value.
  String get syncAnonKey => _syncAnonKey;

  /// Whether the address the user typed points at a Supabase project.
  ///
  /// Recomputed from the draft on every read rather than stored: the draft is
  /// the single source of truth, and a stale flag would show or hide the key at
  /// the wrong moment.
  bool get syncIsSupabase => detectBackend(_syncServer) == SyncBackend.supabase;

  /// Who the signed-in panel names.
  String get syncSignedInAs {
    final email = syncStatus?.email ?? '';
    if (email.isEmpty) return _feedback.t('settings.syncStatusSignedOut');
    return _feedback.t('settings.syncSignedInAs', {'email': email});
  }

  /// When the last round ran, or "never".
  String get syncLastSyncLabel {
    final at = syncStatus?.lastSyncAt ?? 0;
    if (at == 0) return _feedback.t('settings.syncNever');
    final when = DateTime.fromMillisecondsSinceEpoch(at);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${when.year}-${two(when.month)}-${two(when.day)} '
        '${two(when.hour)}:${two(when.minute)}';
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

  /* ---------------------------------------------------------------- */
  /* Sync: the form's draft                                            */
  /* ---------------------------------------------------------------- */

  void setSyncServer(String value) => update(() => _syncServer = value);

  void setSyncEmail(String value) => update(() => _syncEmail = value);

  void setSyncPassword(String value) => update(() => _syncPassword = value);

  void setSyncAnonKey(String value) => update(() => _syncAnonKey = value);

  /* ---------------------------------------------------------------- */
  /* Sync: the actions                                                 */
  /* ---------------------------------------------------------------- */

  /// Sign in with the current draft.
  ///
  /// The trimming mirrors the old form's getters exactly: the address, the
  /// email and the key are trimmed, the password is not — a password may
  /// legitimately end in a space.
  Future<void> signIn() => _formAction(
        (engine) => engine.login(
          _syncServer.trim(),
          _syncEmail.trim(),
          _syncPassword,
          anonKey: _syncAnonKey.trim(),
        ),
      );

  /// Create an account with the current draft.
  Future<void> signUp() => _formAction(
        (engine) => engine.register(
          _syncServer.trim(),
          _syncEmail.trim(),
          _syncPassword,
          anonKey: _syncAnonKey.trim(),
        ),
      );

  /// Drop the local session.
  Future<void> signOut() => _formAction((engine) => engine.signOut());

  /// Runs one auth action, keeping the form's busy flag and error in step.
  Future<void> _formAction(
    Future<void> Function(SyncEngine engine) action,
  ) async {
    final engine = _engine;
    if (engine == null || _syncBusy) return;
    update(() {
      _syncBusy = true;
      _syncFormError = null;
    });
    try {
      await action(engine);
      if (isDisposed) return;
      _feedback.toast(_feedback.t('settings.syncDone'), kind: ToastKind.ok);
    } on SyncHttpError catch (err) {
      if (isDisposed) return;
      update(() => _syncFormError = err.kind);
    } catch (_) {
      if (isDisposed) return;
      update(() => _syncFormError = SyncError.offline);
    } finally {
      update(() => _syncBusy = false);
    }
  }

  /// Check that the address in the draft answers `/api/health`.
  Future<void> testConnection() async {
    final engine = _engine;
    if (engine == null || _syncBusy) return;
    update(() => _syncBusy = true);
    final ok = await engine.testConnection(_syncServer.trim());
    if (isDisposed) return;
    update(() => _syncBusy = false);
    _feedback.toast(
      _feedback.t(ok ? 'settings.syncTestOk' : 'settings.syncTestFail'),
      kind: ok ? ToastKind.ok : ToastKind.err,
    );
  }

  /// Push local changes and merge whatever the server has newer.
  Future<void> syncNow() async {
    final engine = _engine;
    if (engine == null) return;
    final ok = await engine.syncNow();
    if (isDisposed) return;
    final error = engine.status.error;
    if (ok) {
      _feedback.toast(_feedback.t('settings.syncDone'), kind: ToastKind.ok);
    } else {
      _feedback.toast(
        errorLabel(error ?? SyncError.offline),
        kind: ToastKind.err,
      );
    }
  }

  /* ---------------------------------------------------------------- */
  /* Wipe                                                              */
  /* ---------------------------------------------------------------- */

  /// Empty the whole library, after a confirmation.
  Future<void> wipe() async {
    // Read before the dialog's await: nothing here depends on the outcome, and
    // a disposed model must not be reached across the gap.
    final doneMessage = _feedback.t('settings.wipeDone');
    final ok = await _feedback.confirm(
      title: _feedback.t('settings.wipeConfirm'),
      subtitle: _feedback.t('settings.wipeConfirmBody'),
      confirmLabel: _feedback.t('settings.wipeData'),
      danger: true,
    );
    if (!ok) return;
    await _store.wipeAll();
    if (isDisposed) return;
    _feedback.toast(doneMessage, kind: ToastKind.ok);
  }

  /* ---------------------------------------------------------------- */
  /* Export                                                            */
  /* ---------------------------------------------------------------- */

  /// Writes the whole snapshot out as JSON.
  ///
  /// The toast is only shown once [fileDialogs] reports the bytes landed; a
  /// cancel is silent, because a dialog the user dismissed is not a failure.
  Future<void> exportJson() async {
    final name = transfer.exportJsonFilename(_clock());
    final content = transfer.exportJson(data);
    final okMessage = _feedback.t('settings.exportJsonDone');
    final failedMessage = _feedback.t('settings.exportFailed');

    final saved = await fileDialogs.saveTextFile(
      suggestedName: name,
      content: content,
      mimeType: 'application/json',
    );
    if (isDisposed) return;
    if (!saved) {
      // A cancel and a write failure both come back false. The dialog layer
      // cannot tell them apart — Android's channel reports only the write — so
      // the message names the one thing the user can act on.
      _feedback.toast(failedMessage, kind: ToastKind.err);
      return;
    }
    _feedback.toast(okMessage, kind: ToastKind.ok);
  }

  /// Writes the words as a CSV a spreadsheet can open.
  Future<void> exportCsv() async {
    final name = transfer.exportCsvFilename(_clock());
    final content = transfer.exportCsv(data.words);
    final okMessage = _feedback.t('settings.exportCsvDone');
    final failedMessage = _feedback.t('settings.exportFailed');

    final saved = await fileDialogs.saveTextFile(
      suggestedName: name,
      content: content,
      mimeType: 'text/csv',
    );
    if (isDisposed) return;
    if (!saved) {
      _feedback.toast(failedMessage, kind: ToastKind.err);
      return;
    }
    _feedback.toast(okMessage, kind: ToastKind.ok);
  }

  /* ---------------------------------------------------------------- */
  /* Import                                                            */
  /* ---------------------------------------------------------------- */

  /// Picks a file, parses it, and shows what would be added before adding it.
  ///
  /// The preview is not a nicety: importing is the one operation here that can
  /// touch hundreds of words at once, and the parsers are forgiving by design
  /// (a file with no recognisable header is read as term-in-column-one). The
  /// user should see the result of that forgiveness before it is committed.
  Future<void> pickImport() async {
    final data = this.data;
    final listId =
        data.lists.isNotEmpty ? data.lists.first.id : DEFAULT_LIST_ID;

    final picked = await fileDialogs.pickTextFile();
    if (isDisposed || picked == null) return;

    final result = transfer.parseImport(picked.text, listId);
    if (result.format == transfer.ImportFormat.unknown ||
        result.words.isEmpty) {
      _feedback.toast(
        _feedback.t('settings.importFailed', {
          'msg': _feedback.t('settings.importUnrecognised'),
        }),
        kind: ToastKind.err,
      );
      return;
    }

    final confirmed = await _previewImport(
      ImportPreviewRequest(
        fileName: picked.name,
        formatLabel: formatLabel(result.format),
        result: result,
      ),
    );
    if (!confirmed || isDisposed) return;

    commitImport(result);
  }

  /// Adds the parsed words, skipping terms already in the library.
  ///
  /// Duplicates are matched with [findDuplicate], the same function the word
  /// editor uses to warn about them — so "duplicate" means the same thing
  /// whether the word arrived from a form or a file.
  void commitImport(transfer.ImportResult result) {
    final data = this.data;
    final listId =
        data.lists.isNotEmpty ? data.lists.first.id : DEFAULT_LIST_ID;

    var added = 0;
    var duplicated = 0;
    for (final word in result.words) {
      if (findDuplicate(_store.data, word.term, listId) != null) {
        duplicated += 1;
        continue;
      }
      _store.addWord(word);
      added += 1;
    }

    if (added > 0) {
      _feedback.toast(
        _feedback.t('settings.importSuccess', {'n': added}),
        kind: ToastKind.ok,
      );
    }
    if (duplicated > 0) {
      _feedback.toast(
        _feedback.t('settings.importSkippedDuplicates', {'n': duplicated}),
        kind: ToastKind.info,
      );
    }
    if (added == 0 && duplicated == 0) {
      _feedback.toast(
        _feedback.t('settings.importFailed', {
          'msg': _feedback.t('settings.importNothing'),
        }),
        kind: ToastKind.err,
      );
    }
  }

  /// How a recognised format is named in the preview's subtitle.
  String formatLabel(transfer.ImportFormat format) => switch (format) {
        transfer.ImportFormat.json => _feedback.t('settings.formatJson'),
        transfer.ImportFormat.csv => 'CSV',
        transfer.ImportFormat.anki => 'Anki TXT',
        transfer.ImportFormat.unknown => _feedback.t('settings.formatUnknown'),
      };

  /* ---------------------------------------------------------------- */
  /* Updates                                                           */
  /* ---------------------------------------------------------------- */

  /// The update service, or null when none is mounted.
  UpdateService? get updateService => _update;

  /// The service's current state, kept live by the subscription above.
  UpdateState? get updateState => _update?.state.value;
}
