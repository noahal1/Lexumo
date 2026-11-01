/// The word library's state and behaviour, with no widgets in it.
///
/// The page used to keep five things in one `State`: the filter atom, select
/// mode's selection set, the "adopt the first list" latch, the derived index,
/// and the actions that write through the store. All five live here now, so the
/// view can be read as layout and nothing else.
///
/// Three decisions carried over from the page, restated because they are the
/// view model's contract now:
///
///   * **one [WordQuery] atom.** List, status, sort, favourite-only and the
///     search text are a single value, so switching a list and resetting the
///     filters cannot disagree about what the others are.
///   * **the index is built once per snapshot**, not once per read — the header
///     counts, the status segmented control and the table all read the same
///     buckets, so a plain repaint can never shift a count under the user. The
///     cache is keyed on the snapshot identity plus the clock reading, so a
///     store write or a minute rolling over rebuilds it exactly once.
///   * **the view shape is remembered, the query is not.** Reopening the page
///     with a stale search would look like the library had lost its words.
///
/// It never imports `material` or `widgets`: dialogs, toasts and speech arrive
/// through [Feedback] and the injected [speak] port, which is what makes this
/// class testable without pumping a tree.
library;

// The constructor's parameter names (`store:`, `feedback:`) read better
// than the private field names, and `_clock`/`_speak` need defaults — the same
// trade-off `data/repositories/store.dart` makes.
// ignore_for_file: prefer_initializing_formals

import '../../../../data/repositories/store.dart';
import '../../../../domain/models/types.dart';
import '../../../../domain/use_cases/word_query.dart';
import '../../../core/view_model.dart';

/// Status tallies for a list the index has no bucket for yet.
const Map<String, int> kEmptyCounts = <String, int>{
  'all': 0,
  'new': 0,
  'reviewing': 0,
  'learning': 0,
  'mastered': 0,
};

/// Owns the word library screen.
class WordsViewModel extends ViewModel {
  WordsViewModel({
    required Store store,
    required Feedback feedback,
    Future<void> Function(Word word)? speak,
    int Function()? clock,
  })  : _store = store,
        _feedback = feedback,
        _speak = speak,
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _detach = _store.addListener(_onStoreWrite);
  }

  final Store _store;
  final Feedback _feedback;

  /// Unsubscribes from the store. Held so [dispose] can drop the listener —
  /// the store outlives every page, so a closure left behind would keep this
  /// view model (and its snapshot cache) alive for the rest of the session.
  late final void Function() _detach;

  /// Speaks a term and records the listen — `speakWord` in production. A port
  /// rather than a direct call because the real one reads the settings off a
  /// `BuildContext`, which this class must not have.
  final Future<void> Function(Word word)? _speak;

  final int Function() _clock;

  /* ---- filter state ------------------------------------------------ */

  /// The single filter atom for the whole toolbar.
  ///
  /// `listId` starts empty and is filled on the first read, because the
  /// snapshot is not readable in the constructor — the store may still be
  /// loading.
  WordQuery _filters = const WordQuery(listId: '');

  /// Guards the one-time "adopt the first list" step so a user who deliberately
  /// ends up with no list selected is not overruled on every rebuild.
  bool _adoptedList = false;

  WordQuery get filters => _filters;

  /// Locale for term collation, pushed in by the view from the active `I18n`.
  ///
  /// Dart has no locale-sensitive collation in the core library, so the sort is
  /// plain code-unit order regardless; the field exists because `queryWords`
  /// takes it and the page used to pass the UI language.
  String? uiLang;

  /// Tell the view model which language the labels are in. Idempotent, so the
  /// view may call it from every build.
  void setUiLang(String wire) {
    if (uiLang == wire) return;
    uiLang = wire;
  }

  /// The list the toolbar and the table are scoped to.
  String get listId => _filters.listId;

  /// The active search text, trimmed — what the row highlighter matches on.
  String get trimmedQuery => (_filters.query ?? '').trim();

  /* ---- selection --------------------------------------------------- */

  bool _selectMode = false;
  final Set<String> _selected = <String>{};

  bool get selectMode => _selectMode;

  /// Ids of the words ticked in select mode.
  Set<String> get selected => Set<String>.unmodifiable(_selected);

  int get selectedCount => _selected.length;

  /* ---- derived state ----------------------------------------------- */

  AppData get data => _store.data;

  /// The snapshot time this read is priced against, so the row's due badge and
  /// the index agree on what "now" is.
  int get now => _clock();

  WordIndex? _indexCache;
  AppData? _indexData;
  int? _indexNow;

  /// The per-list buckets, status tallies and due buckets for the current
  /// snapshot.
  ///
  /// Rebuilt only when the snapshot identity or the clock reading changes, so
  /// the header count, the segmented control and the table cannot disagree
  /// mid-frame.
  WordIndex get index {
    final AppData data = _store.data;
    final int now = _clock();
    final WordIndex? cached = _indexCache;
    if (cached != null && identical(_indexData, data) && _indexNow == now) {
      return cached;
    }
    final WordIndex built = buildWordIndex(data, now);
    _indexCache = built;
    _indexData = data;
    _indexNow = now;
    return built;
  }

  /// Word count of the active list.
  int get listCount => index.byList[listId]?.length ?? 0;

  /// Status tallies of the active list.
  StatusCounts get counts => index.countsByList[listId] ?? kEmptyCounts;

  /// Due count of the active list, for the page subtitle.
  int get dueCount => index.dueByList[listId]?.length ?? 0;

  /// The rows the table shows: the active list after search, status, favourite
  /// and sort are applied.
  List<Word> get filtered => queryWords(
        index,
        WordQuery(
          listId: listId,
          query: _filters.query,
          status: _filters.status,
          favoriteOnly: _filters.favoriteOnly,
          sort: _filters.sort,
          lang: uiLang,
        ),
      );

  /// The ticked words, resolved against the snapshot. A word deleted while it
  /// was ticked simply drops out rather than throwing.
  List<Word> get selectedWords =>
      data.words.where((w) => _selected.contains(w.id)).toList();

  /// True when every visible row is ticked — drives the bulk bar's "全选".
  bool get allVisibleSelected =>
      filtered.isNotEmpty && _selected.length == filtered.length;

  /// True when the list has no words at all, so the page shows the "add your
  /// first word" card rather than the "no matches" one.
  bool get isListEmpty => data.lists.isEmpty || listCount == 0;

  bool get hasResults => filtered.isNotEmpty;

  /* ---- store plumbing ---------------------------------------------- */

  void _onStoreWrite() {
    // The snapshot changed: the cached index is stale and the adopted list may
    // have been deleted elsewhere. Re-reading lazily in the getters is enough;
    // this only has to repaint.
    _reconcileList();
    refresh();
  }

  /// Adopt the first list once, then keep the selection pointing at a list that
  /// still exists.
  ///
  /// Called on every store write and once before the first read, because a list
  /// can vanish from under the page (deleted in the list manager, or merged
  /// away by a sync round) while the toolbar is open.
  void _reconcileList() {
    final List<WordList> lists = _store.data.lists;
    if (lists.isEmpty) return;
    final bool exists = lists.any((l) => l.id == _filters.listId);
    if (exists && _adoptedList) return;
    _adoptedList = true;
    _filters = _withList(lists.first.id);
  }

  /// Prepare the state the first read depends on: adopt a list, so the page
  /// does not draw an empty toolbar on the very first frame.
  void ensureReady() => _reconcileList();

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  /// The active list's language pair, for the editor's lookup direction.
  String get sourceLang => _activeList?.sourceLang ?? 'en';
  String get targetLang => _activeList?.targetLang ?? 'zh-CN';

  WordList? get _activeList {
    for (final WordList list in data.lists) {
      if (list.id == listId) return list;
    }
    return null;
  }

  /* ---- filter intents ---------------------------------------------- */

  /// Replace the atom, keeping every other field. The single write path for the
  /// toolbar, so no setter can silently drop a sibling field.
  WordQuery _with({
    String? listId,
    String? query,
    WordStatus? status,
    bool? favoriteOnly,
    SortKey? sort,
    bool clearStatus = false,
  }) =>
      WordQuery(
        listId: listId ?? _filters.listId,
        query: query ?? _filters.query,
        status: clearStatus ? null : (status ?? _filters.status),
        favoriteOnly: favoriteOnly ?? _filters.favoriteOnly,
        sort: sort ?? _filters.sort,
        lang: _filters.lang,
      );

  WordQuery _withList(String id) => WordQuery(
        listId: id,
        query: _filters.query,
        status: _filters.status,
        favoriteOnly: _filters.favoriteOnly,
        sort: _filters.sort,
        lang: _filters.lang,
      );

  void _setFilters(WordQuery next) => update(() => _filters = next);

  void setQuery(String query) => _setFilters(_with(query: query));

  /// `null` means "all statuses" — the atom has no third meaning to preserve.
  void setStatus(WordStatus? status) =>
      _setFilters(status == null ? _with(clearStatus: true) : _with(status: status));

  void setSort(SortKey sort) => _setFilters(_with(sort: sort));

  void toggleFavoriteOnly() =>
      _setFilters(_with(favoriteOnly: !_filters.favoriteOnly));

  void selectList(String id) => _setFilters(_withList(id));

  /// Clears the filters but keeps the list and the sort: "reset" means "show me
  /// this list again", not "forget where I was".
  void resetFilters() => _setFilters(
        WordQuery(listId: _filters.listId, sort: _filters.sort),
      );

  /* ---- select mode ------------------------------------------------- */

  void enterSelect() => update(() => _selectMode = true);

  void exitSelect() => update(() {
        _selectMode = false;
        _selected.clear();
      });

  void toggleSelectMode() => _selectMode ? exitSelect() : enterSelect();

  void toggleSelected(String id) => update(() {
        if (!_selected.remove(id)) _selected.add(id);
      });

  void selectAllVisible() =>
      update(() => _selected.addAll(filtered.map((w) => w.id)));

  /* ---- word actions ------------------------------------------------ */

  /// Speak a term and record the listen, through the injected port.
  ///
  /// Counted even when the engine is silent: the user pressed 发音, and the
  /// count is a usage tally rather than an audio diagnostic.
  Future<void> play(Word word) async => _speak?.call(word);

  /// Handle what the editor returned.
  ///
  /// The editor writes through the store itself, so this only acts on the two
  /// things a caller must own: a delete request for an existing word, and the
  /// toast for a create. [original] is the word that was opened, `null` in
  /// create mode — the same distinction the page used to make by comparing ids.
  Future<void> applyEditorResult(Word? requested, {Word? original}) async {
    if (requested == null) return;
    final AppData snapshot = _store.data;

    if (original == null) {
      // Create mode: the editor's own Save already inserted the word.
      _feedback.toast(_feedback.t('words.wordAdded'), kind: ToastKind.ok);
      return;
    }

    // The editor returns the word the user asked to delete, or the saved word.
    // A delete confirmation must not be raised from inside a dialog that is
    // still closing, so the caller checks first.
    final bool stillExists = snapshot.words.any((w) => w.id == requested.id);
    if (requested.id == original.id && !stillExists) return;

    final bool confirmed = await _feedback.confirm(
      title: _feedback.t('words.deleteConfirm'),
      subtitle: _feedback.t('words.deleteConfirmBody', {'term': original.term}),
      confirmLabel: _feedback.t('common.delete'),
      danger: true,
    );
    if (!confirmed || isDisposed) return;

    final List<ReviewLog> logs =
        snapshot.logs.where((l) => l.wordId == original.id).toList();
    _store.deleteWord(original.id);
    _feedback.toast(
      _feedback.t('words.wordDeleted'),
      kind: ToastKind.ok,
      actionLabel: _feedback.t('common.undo'),
      onAction: () => _store.restoreWord(original, logs),
    );
  }

  /// Delete one word, with the undo toast that restores its review schedule too.
  Future<void> deleteWord(Word word) async {
    final AppData snapshot = _store.data;
    final bool confirmed = await _feedback.confirm(
      title: _feedback.t('words.deleteConfirm'),
      subtitle: _feedback.t('words.deleteConfirmBody', {'term': word.term}),
      confirmLabel: _feedback.t('common.delete'),
      danger: true,
    );
    if (!confirmed || isDisposed) return;

    // Snapshot the review logs too, so undo restores the schedule rather than
    // just the bare term.
    final List<ReviewLog> logs =
        snapshot.logs.where((l) => l.wordId == word.id).toList();
    _store.deleteWord(word.id);
    _feedback.toast(
      _feedback.t('words.wordDeleted'),
      kind: ToastKind.ok,
      actionLabel: _feedback.t('common.undo'),
      onAction: () => _store.restoreWord(word, logs),
    );
  }

  /// Delete every ticked word in one write, with one undo that restores all of
  /// them and their schedules.
  Future<void> deleteSelected() async {
    final List<Word> victims = selectedWords;
    if (victims.isEmpty) return;
    final bool confirmed = await _feedback.confirm(
      title: _feedback.t('words.bulkDeleteConfirm', {'n': victims.length}),
      subtitle: _feedback.t('words.bulkDeleteBody'),
      confirmLabel: _feedback.t('words.deleteSelected'),
      danger: true,
    );
    if (!confirmed || isDisposed) return;

    final AppData snapshot = _store.data;
    final List<(Word, List<ReviewLog>)> saved = <(Word, List<ReviewLog>)>[
      for (final Word w in victims)
        (w, snapshot.logs.where((l) => l.wordId == w.id).toList()),
    ];
    _store.deleteWords(victims.map((w) => w.id));
    update(() {
      _selectMode = false;
      _selected.clear();
    });
    _feedback.toast(
      _feedback.t('words.bulkDeleted', {'n': saved.length}),
      kind: ToastKind.ok,
      actionLabel: _feedback.t('common.undo'),
      onAction: () {
        for (final (Word word, List<ReviewLog> logs) in saved) {
          _store.restoreWord(word, logs);
        }
      },
    );
  }

  /// Mark every ticked word a favourite. Already-favourited rows are skipped so
  /// the write count matches what actually changed.
  void favoriteSelected() {
    final List<Word> words = selectedWords;
    for (final Word w in words) {
      if (!w.favorite) {
        _store.updateWord(w.id, (cur) => cur.copyWith(favorite: true));
      }
    }
    _feedback.toast(
      _feedback.t('words.favoritedCount', {'n': words.length}),
      kind: ToastKind.ok,
    );
  }

  /* ---- list actions ------------------------------------------------ */

  /// Create a list and switch to it — the new list is what the user wants to
  /// see next, so the tab follows.
  WordList createList({
    required String name,
    required String sourceLang,
    required String targetLang,
  }) {
    final WordList created = _store.createList(
      name: name,
      sourceLang: sourceLang,
      targetLang: targetLang,
    );
    selectList(created.id);
    _feedback.toast(_feedback.t('words.newList'), kind: ToastKind.ok);
    return created;
  }

  /// Rename a list in place.
  void renameList(String id, String name) =>
      _store.renameList(id, name);

  /// Delete a list and everything in it, after confirming. The last list cannot
  /// be deleted, so the caller hides the control rather than this refusing.
  Future<void> deleteList(WordList list) async {
    final int count =
        _store.data.words.where((w) => w.listId == list.id).length;
    final bool confirmed = await _feedback.confirm(
      title: _feedback.t('common.delete'),
      subtitle: _feedback.t('words.deleteListConfirm', {
        'name': list.name,
        'n': count,
      }),
      confirmLabel: _feedback.t('common.delete'),
      danger: true,
    );
    if (!confirmed || isDisposed) return;
    _store.deleteList(list.id);
    _feedback.toast(_feedback.t('words.wordDeleted'), kind: ToastKind.ok);
  }

  /// The wire ids of every page a cross-page call to action can reach, so the
  /// view can ask [Feedback] instead of hard-coding strings.
  bool get canNavigate => _feedback.canNavigate;

  void goTo(String pageId) => _feedback.goTo(pageId);
}
