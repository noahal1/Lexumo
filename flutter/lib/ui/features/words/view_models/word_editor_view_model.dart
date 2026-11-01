/// The word editor's draft, its lookups and its save — with no widgets in it.
///
/// The dialog used to keep all of this in a `_EditorModel` living beside the
/// layout, which meant the file mixed a `ChangeNotifier` with a widget tree and
/// the lookup orchestration with the buttons that trigger it. The state object
/// is now this view model; `word_editor.dart` is layout and the two modal
/// widgets.
///
/// **Editing buffers are view state.** The seven `TextEditingController`s and
/// the focus node stay in the view, held by `_EditorBuffers`, because a
/// controller is an editing surface rather than screen state: it owns a
/// selection, an IME composition and a cursor that no view model should have an
/// opinion about. This class therefore keeps the draft as plain strings, and the
/// view pushes keystrokes in (`setTerm`, …) and mirrors lookup results out. That
/// is also what lets this file import `foundation` only — the same rule
/// `ui/core/view_model.dart` states for every view model.
///
/// Three behaviours are load-bearing and carried over unchanged:
///
///   * **nothing is written to the store until Save.** The draft is the only
///     mutable copy; the snapshot is read, never written, while the dialog is
///     open.
///   * **late answers are dropped twice over.** A lookup outlives the keystroke
///     that started it, so a result is applied only when its stamp is still the
///     current one *and* the field it was asked about still holds the same text.
///   * **a dirty draft asks before it closes.** `dirty` compares every field
///     against what was loaded, so a half-typed word counts too.
library;

// Same rationale as lib/data/repositories/store.dart: the constructor has
// three private fields it assigns straight from parameters.
// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';

import '../../../../data/repositories/store.dart';
import '../../../../data/services/translate.dart';
import '../../../../domain/models/srs.dart' show STATUS_ORDER;
import '../../../../domain/models/types.dart';
import '../../../core/view_model.dart';

/// What one lookup button is doing.
enum LookupPhase { idle, loading, failed }

/// Owns one add/edit dialog.
class WordEditorViewModel extends ViewModel {
  WordEditorViewModel({
    required Store store,
    required Feedback feedback,
    required this.word,
    required this.defaultListId,
    Lookup Function()? lookup,
    void Function()? resetCooldown,
  })  : _store = store,
        _feedback = feedback,
        // Lazy on purpose: `defaultLookup` builds an HTTP client and a
        // file-backed cache on first touch, and a dialog that is opened and
        // closed without a lookup should never construct either.
        _lookup = lookup ?? (() => defaultLookup),
        _resetCooldown = resetCooldown ?? resetProviderCooldown,
        listId = word?.listId ?? defaultListId,
        status = word?.status ?? WordStatus.new_,
        favorite = word?.favorite ?? false,
        phonetic = word?.phonetic ?? '',
        term = word?.term ?? '',
        pos = word?.pos ?? '',
        definition = word?.definition ?? '',
        definition2 = word?.definition2 ?? '',
        example = word?.example ?? '',
        exampleZh = word?.exampleZh ?? '',
        note = word?.note ?? '';

  final Store _store;
  final Feedback _feedback;
  final Lookup Function() _lookup;
  final void Function() _resetCooldown;

  /// The word being edited; null in create mode.
  final Word? word;

  /// The list the create form starts on (the page's active list).
  final String defaultListId;

  /* ---- draft ------------------------------------------------------- */

  String term;
  String pos;
  String definition;
  String definition2;
  String example;
  String exampleZh;
  String note;

  /// The IPA the dictionary returned, or the value the word already had.
  ///
  /// There is no field for it in the dialog — it is a by-product of a lookup —
  /// so it lives here rather than in a buffer, and Save writes it back.
  String phonetic;

  String listId;
  WordStatus status;
  bool favorite;
  String error = '';
  bool dismissOpen = false;

  /// A draft is dirty when any field differs from what was loaded. The create
  /// baseline is all-empty, so a word typed half-way counts too — closing after
  /// that must not throw the text away without asking.
  bool get dirty =>
      term != (word?.term ?? '') ||
      phonetic != (word?.phonetic ?? '') ||
      pos != (word?.pos ?? '') ||
      definition != (word?.definition ?? '') ||
      definition2 != (word?.definition2 ?? '') ||
      example != (word?.example ?? '') ||
      exampleZh != (word?.exampleZh ?? '') ||
      note != (word?.note ?? '') ||
      listId != (word?.listId ?? defaultListId) ||
      status != (word?.status ?? WordStatus.new_) ||
      favorite != (word?.favorite ?? false);

  /* ---- buffer writes ----------------------------------------------- */

  // Every setter is a no-op when the value is unchanged. The view pushes the
  // buffer's text on every keystroke and mirrors this object's text back into
  // the buffer when a lookup fills a field; without the equality check the two
  // directions would notify each other forever.

  void setTerm(String value) => _set(() => term = value, term != value);

  void setPos(String value) => _set(() => pos = value, pos != value);

  void setDefinition(String value) =>
      _set(() => definition = value, definition != value);

  void setDefinition2(String value) =>
      _set(() => definition2 = value, definition2 != value);

  void setExample(String value) => _set(() => example = value, example != value);

  void setExampleZh(String value) =>
      _set(() => exampleZh = value, exampleZh != value);

  void setNote(String value) => _set(() => note = value, note != value);

  void _set(VoidCallback mutate, bool changed) {
    if (!changed) return;
    update(mutate);
  }

  void setError(String value) {
    if (error == value) return;
    update(() => error = value);
  }

  void setDismissOpen(bool value) {
    if (dismissOpen == value) return;
    update(() => dismissOpen = value);
  }

  void setListId(String value) {
    if (listId == value) return;
    update(() => listId = value);
  }

  void setStatus(WordStatus value) {
    if (status == value) return;
    update(() => status = value);
  }

  void toggleFavorite() => update(() => favorite = !favorite);

  /* ---- derived ----------------------------------------------------- */

  /// The list's language pair, which decides the lookup direction.
  WordList? get _list {
    for (final WordList l in _store.data.lists) {
      if (l.id == listId) return l;
    }
    return null;
  }

  String get fromLang => _list?.sourceLang ?? 'en';

  String get toLang => _list?.targetLang ?? 'zh-CN';

  /// The word this draft would collide with, or null.
  Word? get duplicate {
    final String trimmed = term.trim();
    if (trimmed.isEmpty) return null;
    return findDuplicate(_store.data, trimmed, listId);
  }

  /// Whether to show the duplicate notice — editing a word is not a collision
  /// with itself.
  bool get showDuplicate {
    final Word? found = duplicate;
    return found != null && found.id != word?.id;
  }

  /// Statuses offered by the dialog's status picker.
  List<WordStatus> get statusOptions => STATUS_ORDER;

  /* ---- lookup ------------------------------------------------------ */

  LookupPhase forwardPhase = LookupPhase.idle;
  LookupFailure? forwardFailure;
  LookupPhase reversePhase = LookupPhase.idle;
  LookupFailure? reverseFailure;

  /// The line under a lookup button when it failed, already translated.
  String? get forwardFailureText => _failureText(forwardFailure);

  String? get reverseFailureText => _failureText(reverseFailure);

  String? _failureText(LookupFailure? failure) => switch (failure) {
        LookupFailure.rateLimited => _feedback.t('words.translationRateLimited'),
        LookupFailure.notFound => _feedback.t('words.translationNotFound'),
        LookupFailure.offline => _feedback.t('words.translationOffline'),
        null => _feedback.t('words.translationFailed'),
      };

  /// Bumped on every request and again on dispose.
  ///
  /// Dart has no `AbortController`, and the web build's was only ever used to
  /// answer "was this request superseded?" — so a counter carries the same
  /// information: a result whose stamp no longer matches belongs to a request
  /// that a newer click (or a closed dialog) has already replaced.
  int _forwardStamp = 0;
  int _reverseStamp = 0;

  int _beginForward() {
    update(() {
      forwardPhase = LookupPhase.loading;
      forwardFailure = null;
    });
    return ++_forwardStamp;
  }

  int _beginReverse() {
    update(() {
      reversePhase = LookupPhase.loading;
      reverseFailure = null;
    });
    return ++_reverseStamp;
  }

  bool isCurrentForward(int stamp) => !isDisposed && stamp == _forwardStamp;

  bool isCurrentReverse(int stamp) => !isDisposed && stamp == _reverseStamp;

  void _endForward(int stamp, LookupFailure? failure) {
    if (!isCurrentForward(stamp)) return;
    update(() {
      forwardPhase = failure == null ? LookupPhase.idle : LookupPhase.failed;
      forwardFailure = failure;
    });
  }

  void _endReverse(int stamp, LookupFailure? failure) {
    if (!isCurrentReverse(stamp)) return;
    update(() {
      reversePhase = failure == null ? LookupPhase.idle : LookupPhase.failed;
      reverseFailure = failure;
    });
  }

  /// Run the forward lookup: term → meaning.
  ///
  /// Only the button calls this. Nothing runs on typing or on blur — a lookup
  /// costs a network round trip and rewrites fields the user may be half-way
  /// through, so it waits to be asked. That makes every call an explicit
  /// overwrite, which is why `force` is set: a click is also how a stale cached
  /// entry gets refreshed.
  Future<void> forwardLookup() async {
    final String query = term.trim();
    if (query.isEmpty) return;
    // Retrying after a failure means the user is overriding the 90-second
    // cooldown a 429 put on every provider. Without this the retry button can
    // only fail for a minute and a half, which reads as a broken button.
    //
    // This does not let anyone hammer a provider: a provider that is still
    // limiting answers 429 again and re-arms its own cooldown. The window exists
    // to avoid pointless requests, not to enforce the provider's limit.
    if (forwardPhase == LookupPhase.failed) _resetCooldown();
    final int stamp = _beginForward();
    try {
      final LookupResult result = await _lookup().lookupTerm(
        query,
        LookupOptions(from: fromLang, to: toLang, force: true),
      );
      // Two independent reasons to drop an answer, and both happen in practice.
      // The stamp catches "a newer click superseded this one"; the term check
      // catches "the user kept typing" — a slow answer for `cat` must not land
      // in a draft that is now about `catalogue`, because the meaning it would
      // write belongs to a different word and the user has no reason to expect
      // it.
      if (!isCurrentForward(stamp)) return;
      if (term.trim() != query) {
        _endForward(stamp, null);
        return;
      }
      applyLookup(result);
      _endForward(stamp, null);
      if (!result.fromCache) {
        _feedback.toast(_feedback.t('words.translationApplied'),
            kind: ToastKind.ok);
      }
    } on Object catch (e) {
      if (!isCurrentForward(stamp)) return;
      _endForward(
        stamp,
        e is LookupError ? e.reason : LookupFailure.offline,
      );
    }
  }

  /// Run the reverse lookup: meaning → term.
  ///
  /// This is what makes a wordbook usable the way people actually fill one in —
  /// you know "苹果" and want "りんご", so typing the meaning first is the natural
  /// order. The pair is simply swapped.
  ///
  /// The engine order matters here in a way it does not forward: Youdao
  /// translates *out of* Chinese as machine translation and renders a bare noun
  /// as a polite sentence (`苹果` → `りんごです`), which nobody would add to a
  /// wordbook. Google returns the lemma and MyMemory a close variant, so both
  /// are pushed ahead of Youdao.
  Future<void> reverseLookup() async {
    final String query = definition.trim();
    if (query.isEmpty) return;
    // Same reason as the forward pass: retrying is an override, not a new idea.
    if (reversePhase == LookupPhase.failed) _resetCooldown();
    final int stamp = _beginReverse();
    try {
      final LookupResult result = await _lookup().lookupTerm(
        query,
        LookupOptions(
          // Swapped on purpose: the gloss is in the list's *meaning* language
          // and the word wanted is in its *learning* language.
          from: toLang,
          to: fromLang,
          force: true,
          prefer: const <ProviderId>[ProviderId.google, ProviderId.myMemory],
        ),
      );
      if (!isCurrentReverse(stamp)) return;
      // Same guard in the other direction: the gloss is the query, so if it has
      // been retyped the answer is for a meaning the draft no longer has.
      if (definition.trim() != query) {
        _endReverse(stamp, null);
        return;
      }
      applyReverse(result);
      _endReverse(stamp, null);
      if (!result.fromCache) {
        _feedback.toast(_feedback.t('words.reverseApplied'), kind: ToastKind.ok);
      }
    } on Object catch (e) {
      if (!isCurrentReverse(stamp)) return;
      _endReverse(
        stamp,
        e is LookupError ? e.reason : LookupFailure.offline,
      );
    }
  }

  /// Write a lookup's payload into the draft.
  ///
  /// The example halves go in together or not at all: a translation only means
  /// something under the sentence it came with, so it is never attached to a
  /// sentence the user typed themselves — that would put two unrelated lines on
  /// one card.
  void applyLookup(LookupResult result) {
    final String posText = posTags(result).join(' ');
    final String primary = primaryMeaning(result);
    final String secondary = alternativeMeaning(result);
    update(() {
      if (posText.isNotEmpty) pos = posText;
      if (primary.isNotEmpty) definition = primary;
      if (secondary.isNotEmpty) definition2 = secondary;
      if (result.examples.isNotEmpty) {
        final DictExample sample = result.examples.first;
        if (sample.en.isNotEmpty) {
          example = sample.en;
          final String? zh = sample.zh;
          if (zh != null && zh.isNotEmpty) exampleZh = zh;
        }
      }
      if (result.phonetic.isNotEmpty) phonetic = result.phonetic;
      error = '';
    });
  }

  /// Write the word a reverse lookup found, leaving the meaning alone.
  void applyReverse(LookupResult result) {
    final String found = primaryMeaning(result).trim();
    if (found.isEmpty) return;
    update(() {
      term = found;
      error = '';
    });
  }

  /* ---- save -------------------------------------------------------- */

  /// Write the draft through the store. Returns false when it refused, having
  /// set [error] — the caller keeps the dialog open in that case.
  bool save() {
    final String trimmed = term.trim();
    if (trimmed.isEmpty) {
      setError(_feedback.t('words.termRequired'));
      return false;
    }

    final String phoneticTrimmed = phonetic.trim();
    final String posTrimmed = pos.trim();
    final String exampleZhTrimmed = exampleZh.trim();
    final Word? editing = word;

    if (editing != null) {
      _store.updateWord(
        editing.id,
        // Explicit reconstruction rather than `copyWith`: an emptied phonetic,
        // pos or translated example has to become null, and `copyWith` treats
        // null as "keep the old value".
        (current) => Word(
          id: current.id,
          term: trimmed,
          phonetic: phoneticTrimmed.isEmpty ? null : phoneticTrimmed,
          pos: posTrimmed.isEmpty ? null : posTrimmed,
          definition: definition.trim(),
          definition2: definition2.trim(),
          example: example.trim(),
          exampleZh: exampleZhTrimmed.isEmpty ? null : exampleZhTrimmed,
          note: note.trim(),
          status: status,
          favorite: favorite,
          listId: listId,
          sourceLang: current.sourceLang,
          targetLang: current.targetLang,
          listenCount: current.listenCount,
          srs: current.srs,
          createdAt: current.createdAt,
          updatedAt: current.updatedAt,
        ),
      );
      _feedback.toast(_feedback.t('words.wordUpdated'), kind: ToastKind.ok);
    } else {
      _store.addWord(
        NewWordInput(
          term: trimmed,
          phonetic: phoneticTrimmed,
          pos: posTrimmed.isEmpty ? null : posTrimmed,
          definition: definition,
          definition2: definition2,
          example: example,
          exampleZh: exampleZh,
          note: note,
          listId: listId,
          status: status,
        ),
      );
      _feedback.toast(
        _feedback.t('words.wordAdded', <String, Object>{'term': trimmed}),
        kind: ToastKind.ok,
      );
    }
    return true;
  }

  /// Invalidate every request in flight, so a late answer is dropped.
  void cancelLookups() {
    _forwardStamp++;
    _reverseStamp++;
  }

  @override
  void dispose() {
    // A lookup in flight resolves into a disposed view model otherwise: the
    // future outlives the dialog, and notifying a disposed `ChangeNotifier`
    // throws. Bumping the stamps makes every pending result a no-op.
    cancelLookups();
    super.dispose();
  }
}
