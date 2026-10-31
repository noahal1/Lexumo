/// The word library.
///
/// Ports `src/pages/words/WordsPage.tsx`. One page owns five things the web
/// build spread across a component and three dialogs: the list tabs, the query
/// bar (search + status filter + sort + tools), the table itself, select mode's
/// bulk bar, and the list manager.
///
/// Three decisions carried over deliberately:
///
///   * **one [WordQuery] atom.** List, status, sort, favourite-only and the
///     search text live in a single value, so switching a list and resetting
///     the filters cannot disagree about what the others are.
///   * **the index is built once per snapshot**, not once per build — the
///     header counts, the status segmented control and the table all read the
///     same buckets, so a plain repaint can never shift a count under the user.
///   * **the view shape is remembered, the query is not.** Reopening the page
///     with a stale search would look like the library had lost its words.
///
/// The row's 发音 button speaks the term through [speakWord], which also
/// records the listen — the same pair the web build did inline.
library;

import 'dart:math' as math;

// `Card` is ours (ui/widgets.dart), not Material's.
import 'package:flutter/material.dart' hide Card;
import 'package:flutter/services.dart';

import '../app/scope.dart';
import '../design/tokens.dart';
import '../domain/languages.dart';
import '../domain/srs.dart';
import '../domain/types.dart';
import '../domain/utils.dart';
import '../domain/word_index.dart';
import '../platform/speak_word.dart';
import '../ui/controls.dart';
import '../ui/density.dart';
import '../ui/keyboard_hints.dart';
import '../ui/lex_icon.dart';
import '../ui/widgets.dart';
import 'word_editor.dart';

/// Status tallies for a list the index has no bucket for yet.
const Map<String, int> _kEmptyCounts = <String, int>{
  'all': 0,
  'new': 0,
  'reviewing': 0,
  'learning': 0,
  'mastered': 0,
};

/// i18n key per status, mirroring `STATUS_LABEL_KEY` in `types.ts`.
const Map<WordStatus, String> _kStatusLabelKey = <WordStatus, String>{
  WordStatus.new_: 'status.new',
  WordStatus.reviewing: 'status.reviewing',
  WordStatus.learning: 'status.learning',
  WordStatus.mastered: 'status.mastered',
};

/// Sort options in menu order, with their labels.
const List<(SortKey, String)> _kSortOptions = <(SortKey, String)>[
  (SortKey.recent, 'words.sortRecent'),
  (SortKey.alpha, 'words.sortAlpha'),
  (SortKey.due, 'words.sortDue'),
  (SortKey.status, 'words.sortStatus'),
];

/// Statuses offered by the filter, in ladder order after "all".
const List<WordStatus> _kStatusFilters = STATUS_ORDER;

class WordsPage extends StatefulWidget {
  const WordsPage({super.key, this.controller});

  /// Owned by the shell, so the page's scroll position survives a switch.
  final ScrollController? controller;

  @override
  State<WordsPage> createState() => _WordsPageState();
}

class _WordsPageState extends State<WordsPage> {
  /// The single filter atom for the whole toolbar.
  ///
  /// `listId` starts empty and is filled on the first build, because the
  /// snapshot is not readable in [initState] — the store may still be loading.
  WordQuery _filters = const WordQuery(listId: '');

  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  bool _selectMode = false;
  final Set<String> _selected = <String>{};

  /// Guards the one-time "adopt the first list" step so a user who deliberately
  /// ends up with no list selected is not overruled on every rebuild.
  bool _adoptedList = false;

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /* ---- filter plumbing --------------------------------------------- */

  void _setFilters(WordQuery next) => setState(() => _filters = next);

  void _setQuery(String query) =>
      _setFilters(WordQuery(
        listId: _filters.listId,
        query: query,
        status: _filters.status,
        favoriteOnly: _filters.favoriteOnly,
        sort: _filters.sort,
        lang: _filters.lang,
      ));

  void _setStatus(WordStatus? status) =>
      _setFilters(WordQuery(
        listId: _filters.listId,
        query: _filters.query,
        status: status,
        favoriteOnly: _filters.favoriteOnly,
        sort: _filters.sort,
        lang: _filters.lang,
      ));

  void _setSort(SortKey sort) =>
      _setFilters(WordQuery(
        listId: _filters.listId,
        query: _filters.query,
        status: _filters.status,
        favoriteOnly: _filters.favoriteOnly,
        sort: sort,
        lang: _filters.lang,
      ));

  void _toggleFavoriteOnly() =>
      _setFilters(WordQuery(
        listId: _filters.listId,
        query: _filters.query,
        status: _filters.status,
        favoriteOnly: !_filters.favoriteOnly,
        sort: _filters.sort,
        lang: _filters.lang,
      ));

  void _selectList(String id) =>
      _setFilters(WordQuery(
        listId: id,
        query: _filters.query,
        status: _filters.status,
        favoriteOnly: _filters.favoriteOnly,
        sort: _filters.sort,
        lang: _filters.lang,
      ));

  /// Clears the filters but keeps the list and the sort: "reset" means "show me
  /// this list again", not "forget where I was".
  void _resetFilters() {
    _search.clear();
    _setFilters(WordQuery(listId: _filters.listId, sort: _filters.sort));
  }

  /* ---- select mode ------------------------------------------------- */

  void _enterSelect() => setState(() => _selectMode = true);

  void _exitSelect() => setState(() {
        _selectMode = false;
        _selected.clear();
      });

  void _toggleSelected(String id) => setState(() {
        if (!_selected.remove(id)) _selected.add(id);
      });

  void _selectAll(List<Word> visible) =>
      setState(() => _selected.addAll(visible.map((w) => w.id)));

  /* ---- actions ----------------------------------------------------- */

  Future<void> _openEditor({Word? word, required String listId}) async {
    final store = context.store;
    final data = context.data;
    final requested = await showWordEditor(
      context,
      word: word,
      defaultListId: listId,
    );
    if (requested == null || !mounted) return;

    // The editor returns the word the user asked to delete, or the saved word.
    // Distinguishing them is the caller's job: a delete confirmation must not
    // be raised from inside a dialog that is still closing.
    if (word != null && requested.id == word.id && !_stillExists(data, requested.id)) {
      return;
    }
    if (word != null) {
      // Existing word: the editor already wrote through the store; only a
      // delete request needs acting on.
      final logs = data.logs.where((l) => l.wordId == word.id).toList();
      final confirmDelete = await confirmLex(
        context,
        title: context.t('words.deleteConfirm'),
        subtitle: context.t('words.deleteConfirmBody', {'term': word.term}),
        confirmLabel: context.t('common.delete'),
        danger: true,
      );
      if (!confirmDelete || !mounted) return;
      store.deleteWord(word.id);
      context.toast(
        context.t('words.wordDeleted'),
        ToastKind.ok,
        context.t('common.undo'),
        () => store.restoreWord(word, logs),
      );
      return;
    }

    // Create mode: the editor's own Save already inserted the word.
    context.toast(context.t('words.wordAdded'), ToastKind.ok);
  }

  bool _stillExists(AppData data, String id) =>
      data.words.any((w) => w.id == id);

  Future<void> _deleteWord(Word word, AppData data) async {
    final ok = await confirmLex(
      context,
      title: context.t('words.deleteConfirm'),
      subtitle: context.t('words.deleteConfirmBody', {'term': word.term}),
      confirmLabel: context.t('common.delete'),
      danger: true,
    );
    if (!ok || !mounted) return;

    final store = context.store;
    // Snapshot the review logs too, so undo restores the schedule rather than
    // just the bare term.
    final logs = data.logs.where((l) => l.wordId == word.id).toList();
    store.deleteWord(word.id);
    context.toast(
      context.t('words.wordDeleted'),
      ToastKind.ok,
      context.t('common.undo'),
      () => store.restoreWord(word, logs),
    );
  }

  Future<void> _confirmBulkDelete(List<Word> victims, AppData data) async {
    final ok = await confirmLex(
      context,
      title: context.t('words.bulkDeleteConfirm', {'n': victims.length}),
      subtitle: context.t('words.bulkDeleteBody'),
      confirmLabel: context.t('words.deleteSelected'),
      danger: true,
    );
    if (!ok || !mounted) return;

    final store = context.store;
    final snapshot = <(Word, List<ReviewLog>)>[
      for (final w in victims)
        (w, data.logs.where((l) => l.wordId == w.id).toList()),
    ];
    store.deleteWords(victims.map((w) => w.id));
    _exitSelect();
    context.toast(
      context.t('words.bulkDeleted', {'n': snapshot.length}),
      ToastKind.ok,
      context.t('common.undo'),
      () {
        for (final (word, logs) in snapshot) {
          store.restoreWord(word, logs);
        }
      },
    );
  }

  void _favoriteSelected(List<Word> selectedWords) {
    final store = context.store;
    for (final w in selectedWords) {
      if (!w.favorite) store.updateWord(w.id, (cur) => cur.copyWith(favorite: true));
    }
    context.toast(
      context.t('words.favoritedCount', {'n': selectedWords.length}),
      ToastKind.ok,
    );
  }

  /* ---- build ------------------------------------------------------- */

  @override
  Widget build(BuildContext context) {
    final data = context.data;
    final now = DateTime.now().millisecondsSinceEpoch;
    final lang = context.i18n.lang.wire;

    // Adopt the first list once, when there is one and nothing is selected.
    if (!_adoptedList && data.lists.isNotEmpty) {
      _adoptedList = true;
      final saved = _filters.listId;
      final exists = data.lists.any((l) => l.id == saved);
      if (!exists) {
        _filters = WordQuery(
          listId: data.lists.first.id,
          query: _filters.query,
          status: _filters.status,
          favoriteOnly: _filters.favoriteOnly,
          sort: _filters.sort,
          lang: _filters.lang,
        );
      }
    }
    // If the active list vanished (deleted elsewhere), fall back to the first.
    if (data.lists.isNotEmpty && !data.lists.any((l) => l.id == _filters.listId)) {
      _filters = WordQuery(
        listId: data.lists.first.id,
        query: _filters.query,
        status: _filters.status,
        favoriteOnly: _filters.favoriteOnly,
        sort: _filters.sort,
        lang: _filters.lang,
      );
    }

    final index = buildWordIndex(data, now);
    final listId = _filters.listId;
    final listCount = index.byList[listId]?.length ?? 0;
    final counts = index.countsByList[listId] ?? _kEmptyCounts;
    final dueCount = index.dueByList[listId]?.length ?? 0;

    final trimmed = (_filters.query ?? '').trim();
    final filtered = queryWords(
      index,
      WordQuery(
        listId: listId,
        query: _filters.query,
        status: _filters.status,
        favoriteOnly: _filters.favoriteOnly,
        sort: _filters.sort,
        lang: lang,
      ),
    );

    final selectedWords = data.words.where((w) => _selected.contains(w.id)).toList();

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.slash): () {
          if (_selectMode) return;
          _searchFocus.requestFocus();
        },
        const SingleActivator(LogicalKeyboardKey.keyN): () {
          if (_selectMode) return;
          _openEditor(listId: listId);
        },
        const SingleActivator(LogicalKeyboardKey.keyA, control: true): () {
          if (_selectMode) _selectAll(filtered);
        },
        const SingleActivator(LogicalKeyboardKey.keyA, meta: true): () {
          if (_selectMode) _selectAll(filtered);
        },
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_selectMode) {
            _exitSelect();
          } else if (trimmed.isNotEmpty) {
            _search.clear();
            _setQuery('');
          }
        },
      },
      child: Focus(
        autofocus: true,
        child: PageShell(
          title: context.t('words.title'),
          subtitle: context.t('words.pageSubtitle', {
            'words': listCount,
            'due': dueCount,
          }),
          controller: widget.controller,
          actions: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              LexButton(
                label: context.t('common.list'),
                icon: Ic.layers,
                size: BtnSize.sm,
                kind: BtnKind.ghost,
                onPressed: () => _openListManager(context, listId),
              ),
              const SizedBox(width: Sp.x2),
              LexButton(
                label: context.t('words.addWord'),
                icon: Ic.plus,
                kind: BtnKind.primary,
                onPressed: () => _openEditor(listId: listId),
              ),
            ],
          ),
          children: [
            _ListTabs(
              lists: data.lists,
              activeId: listId,
              counts: index.byList,
              onSelect: _selectList,
              onManage: () => _openListManager(context, listId),
            ),
            const SizedBox(height: Sp.x4),
            _QueryBar(
              controller: _search,
              focusNode: _searchFocus,
              query: _filters.query ?? '',
              status: _filters.status,
              sort: _filters.sort ?? SortKey.recent,
              favoriteOnly: _filters.favoriteOnly,
              counts: counts,
              matchCount: filtered.length,
              selectMode: _selectMode,
              onQuery: _setQuery,
              onStatus: _setStatus,
              onSort: _setSort,
              onToggleFavorite: _toggleFavoriteOnly,
              onToggleSelect: () => _selectMode ? _exitSelect() : _enterSelect(),
              onReset: _resetFilters,
            ),
            const SizedBox(height: Sp.x4),
            if (data.lists.isEmpty || listCount == 0)
              Card(
                child: EmptyState(
                  icon: Ic.words,
                  title: context.t('words.noWords'),
                  text: context.t('words.noWordsHint'),
                  action: LexButton(
                    label: context.t('words.addFirst'),
                    icon: Ic.plus,
                    kind: BtnKind.primary,
                    onPressed: () => _openEditor(listId: listId),
                  ),
                ),
              )
            else if (filtered.isEmpty)
              Card(
                child: EmptyState(
                  icon: Ic.search,
                  title: context.t('words.noResults'),
                  text: context.t('words.noResultsHint'),
                  action: LexButton(
                    label: context.t('common.reset'),
                    onPressed: _resetFilters,
                  ),
                ),
              )
            else
              _WordTable(
                words: filtered,
                query: trimmed,
                lang: lang,
                now: now,
                selectMode: _selectMode,
                selected: _selected,
                onToggleSelected: _toggleSelected,
                onOpen: (w) => _openEditor(word: w, listId: listId),
                onFavorite: (w) => context.store.toggleFavorite(w.id),
                onPlay: (w) => speakWord(context, w),
                onDelete: (w) => _deleteWord(w, data),
              ),
            if (_selectMode) ...[
              const SizedBox(height: Sp.x4),
              _BulkBar(
                count: _selected.length,
                allSelected: _selected.length == filtered.length && filtered.isNotEmpty,
                onSelectAll: () => _selectAll(filtered),
                onFavorite: () => _favoriteSelected(selectedWords),
                onDelete: () => _confirmBulkDelete(selectedWords, data),
                onCancel: _exitSelect,
              ),
            ],
            if (filtered.isNotEmpty && !_selectMode) ...[
              const SizedBox(height: Sp.x4),
              _FooterHint(
                shown: filtered.length,
                total: listCount,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _openListManager(BuildContext context, String activeId) async {
    await showLexModal<void>(
      context: context,
      title: context.t('common.list'),
      subtitle: context.t('words.listsSubtitle', {'n': context.data.lists.length}),
      width: 560,
      body: _ListManagerBody(activeId: activeId, onSelect: _selectList),
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          LexButton(
            label: context.t('common.close'),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

/* ------------------------------------------------------------------ */
/* List tabs                                                           */
/* ------------------------------------------------------------------ */

class _ListTabs extends StatelessWidget {
  const _ListTabs({
    required this.lists,
    required this.activeId,
    required this.counts,
    required this.onSelect,
    required this.onManage,
  });

  final List<WordList> lists;
  final String activeId;
  final Map<String, List<Word>> counts;
  final ValueChanged<String> onSelect;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: Sp.x2,
      runSpacing: Sp.x2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final l in lists)
          _ListTab(
            label: l.name,
            count: counts[l.id]?.length ?? 0,
            active: l.id == activeId,
            onTap: () => onSelect(l.id),
          ),
        _AddTabButton(onTap: onManage, tooltip: context.t('words.newList')),
      ],
    );
  }
}

class _ListTab extends StatefulWidget {
  const _ListTab({
    required this.label,
    required this.count,
    required this.active,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_ListTab> createState() => _ListTabState();
}

class _ListTabState extends State<_ListTab> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final bg = widget.active
        ? p.accentSoft
        : _hover
            ? p.surfaceHover
            : Colors.transparent;
    final fg = widget.active ? p.accentInk : p.ink2;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: Motion.dur1,
          curve: Motion.ease,
          // The list strip is the first thing on the page and the only way to
          // switch lists, so each tab is a target, not a caption. It grows with
          // the density like a button does. No `alignment:` here — setting one
          // makes the box claim every pixel the Wrap offers, which turned one
          // tab into a full-width bar.
          height: context.controlH,
          padding: EdgeInsets.symmetric(
            horizontal: Sp.x3,
            vertical: context.isTouch ? 0 : Sp.x2,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: R.borderSm,
            border: Border.all(
              color: widget.active ? Colors.transparent : p.line,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: Fs.sm,
                  height: Lh.snug,
                  fontWeight: widget.active ? FontWeight.w500 : FontWeight.w400,
                  color: fg,
                ),
              ),
              const SizedBox(width: Sp.x2),
              Text(
                '${widget.count}',
                style: TextStyle(
                  fontFamily: Fonts.mono,
                  fontSize: Fs.xs,
                  height: Lh.none,
                  color: widget.active ? p.accentInk : p.ink3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddTabButton extends StatefulWidget {
  const _AddTabButton({required this.onTap, required this.tooltip});

  final VoidCallback onTap;
  final String tooltip;

  @override
  State<_AddTabButton> createState() => _AddTabButtonState();
}

class _AddTabButtonState extends State<_AddTabButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          // The detector has to be `opaque` for the ring `TapTarget` adds to be
          // part of the target; a bare SizedBox is not hit-testable itself.
          behavior: HitTestBehavior.opaque,
          child: TapTarget(
            child: Container(
              width: Layout.controlHSm,
              height: Layout.controlHSm,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _hover ? p.surfaceHover : Colors.transparent,
                borderRadius: R.borderSm,
                border: Border.all(color: p.line),
              ),
              child: LexIcon(Ic.plus, size: 14, color: p.ink3),
            ),
          ),
        ),
      ),
    );
  }
}

/* ------------------------------------------------------------------ */
/* Query bar                                                           */
/* ------------------------------------------------------------------ */

class _QueryBar extends StatelessWidget {
  const _QueryBar({
    required this.controller,
    required this.focusNode,
    required this.query,
    required this.status,
    required this.sort,
    required this.favoriteOnly,
    required this.counts,
    required this.matchCount,
    required this.selectMode,
    required this.onQuery,
    required this.onStatus,
    required this.onSort,
    required this.onToggleFavorite,
    required this.onToggleSelect,
    required this.onReset,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String query;
  final WordStatus? status;
  final SortKey sort;
  final bool favoriteOnly;
  final Map<String, int> counts;
  final int matchCount;
  final bool selectMode;
  final ValueChanged<String> onQuery;
  final ValueChanged<WordStatus?> onStatus;
  final ValueChanged<SortKey> onSort;
  final VoidCallback onToggleFavorite;
  final VoidCallback onToggleSelect;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final trimmed = query.trim();
    final filtersActive =
        trimmed.isNotEmpty || status != null || favoriteOnly;

    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: R.borderMd,
        border: Border.all(color: p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildToolbarRow(context, trimmed),
          if (filtersActive)
            Container(
              padding: const EdgeInsets.fromLTRB(Sp.x3, 0, Sp.x3, Sp.x3),
              child: Wrap(
                spacing: Sp.x2,
                runSpacing: Sp.x2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (trimmed.isNotEmpty)
                    Text(
                      context.t('words.matches', {'n': matchCount}),
                      style: TextStyle(
                        fontFamily: Fonts.mono,
                        fontSize: Fs.xs,
                        height: Lh.none,
                        color: p.ink3,
                      ),
                    ),
                  if (status != null)
                    _FilterToken(
                      label: context.t(_kStatusLabelKey[status!]!),
                      onRemove: () => onStatus(null),
                    ),
                  if (favoriteOnly)
                    _FilterToken(
                      label: context.t('words.filterFavorites'),
                      onRemove: onToggleFavorite,
                    ),
                  _ResetButton(onTap: onReset),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// The search field, the status chips and the three tool buttons.
  ///
  /// On a desktop all of it fits on one line. On a phone it cannot: the five
  /// status chips alone need more width than the screen has, and squeezing
  /// them into an `Expanded` made the whole row overflow. Below
  /// [_kCompactBreakpoint] the bar folds into two stacked rows and the chip
  /// strip scrolls sideways instead of clipping a filter the user cannot tap.
  ///
  /// It used to be three: search, chips, tools. That cost 164dp of the 401dp a
  /// phone has above the fold — and the middle row held nothing but five chips,
  /// leaving the row's full width to one scrolling strip. Pairing search with
  /// the two icon tools (which are 44dp each) and the chip strip with the
  /// select toggle gives both rows something to share, and the bar drops to
  /// 108dp. What is kept, deliberately: the sort menu still shows its current
  /// label rather than collapsing to an icon, because "sorted by which column"
  /// is the one thing in this bar a user cannot recover by tapping.
  Widget _buildToolbarRow(BuildContext context, String trimmed) {
    final search = _SearchField(
      controller: controller,
      focusNode: focusNode,
      placeholder: context.t('words.searchPlaceholder'),
      onChanged: onQuery,
      onClear: () {
        controller.clear();
        onQuery('');
        focusNode.requestFocus();
      },
    );
    final statuses = Segmented<String>(
      value: status?.wire ?? 'all',
      options: <SegOption<String>>[
        SegOption(
          value: 'all',
          label: context.t('common.all'),
          count: counts['all'] ?? 0,
        ),
        for (final s in _kStatusFilters)
          SegOption(
            value: s.wire,
            label: context.t(_kStatusLabelKey[s]!),
            count: counts[s.wire] ?? 0,
          ),
      ],
      onChanged: (value) =>
          onStatus(value == 'all' ? null : WordStatus.fromWire(value)),
    );
    final sortMenu = _SortMenu(value: sort, onChanged: onSort);
    final favoriteButton = _QbarIconButton(
      icon: favoriteOnly ? Ic.starFilled : Ic.star,
      active: favoriteOnly,
      tooltip: context.t('words.filterFavorites'),
      onTap: onToggleFavorite,
    );
    final selectButton = LexButton(
      label: selectMode ? context.t('common.done') : context.t('words.select'),
      icon: selectMode ? Ic.check : Ic.list,
      size: BtnSize.sm,
      kind: selectMode ? BtnKind.primary : BtnKind.quiet,
      onPressed: onToggleSelect,
    );

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth >= _kCompactBreakpoint) {
          return Padding(
            padding: const EdgeInsets.all(Sp.x3),
            child: Row(
              children: [
                Expanded(flex: 3, child: search),
                const SizedBox(width: Sp.x3),
                Expanded(flex: 4, child: statuses),
                const SizedBox(width: Sp.x3),
                sortMenu,
                const SizedBox(width: Sp.x1),
                favoriteButton,
                const SizedBox(width: Sp.x1),
                selectButton,
              ],
            ),
          );
        }
        // The two rows keep their height fixed so the card does not jump as
        // the search field gains focus and the chips change count.
        return Padding(
          padding: const EdgeInsets.all(Sp.x3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: context.controlH,
                child: Row(
                  children: [
                    Expanded(child: search),
                    const SizedBox(width: Sp.x2),
                    sortMenu,
                    const SizedBox(width: Sp.x1),
                    favoriteButton,
                  ],
                ),
              ),
              const SizedBox(height: Sp.x3),
              SizedBox(
                height: context.controlH,
                child: Row(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: statuses,
                      ),
                    ),
                    const SizedBox(width: Sp.x2),
                    selectButton,
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SearchField extends StatefulWidget {
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.placeholder,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String placeholder;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocus);
  }

  void _onFocus() => setState(() => _focused = widget.focusNode.hasFocus);

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocus);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final hasText = widget.controller.text.isNotEmpty;

    return AnimatedContainer(
      duration: Motion.dur1,
      curve: Motion.ease,
      height: context.controlH,
      decoration: BoxDecoration(
        color: p.surface2,
        borderRadius: R.borderSm,
        border: Border.all(
          color: _focused ? p.accent : p.lineControl,
        ),
      ),
      child: Row(
        children: [
          const SizedBox(width: Sp.x3),
          LexIcon(Ic.search, size: 15, color: p.ink3),
          const SizedBox(width: Sp.x2),
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: widget.focusNode,
              onChanged: widget.onChanged,
              style: TextStyle(fontSize: Fs.sm, height: Lh.snug, color: p.ink),
              cursorColor: p.accent,
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: widget.placeholder,
                hintStyle: TextStyle(
                  fontSize: Fs.sm,
                  height: Lh.snug,
                  color: p.ink4,
                ),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          if (hasText)
            _QbarIconButton(
              icon: Ic.x,
              tooltip: context.t('common.clear'),
              size: 13,
              onTap: widget.onClear,
            )
          else
            const SizedBox(width: Sp.x2),
        ],
      ),
    );
  }
}

class _SortMenu extends StatelessWidget {
  const _SortMenu({required this.value, required this.onChanged});

  final SortKey value;
  final ValueChanged<SortKey> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return PopupMenuButton<SortKey>(
      tooltip: context.t('common.sort'),
      initialValue: value,
      onSelected: onChanged,
      position: PopupMenuPosition.under,
      color: p.surface,
      itemBuilder: (context) => <PopupMenuEntry<SortKey>>[
        for (final (key, labelKey) in _kSortOptions)
          PopupMenuItem<SortKey>(
            value: key,
            height: context.controlH,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    context.t(labelKey),
                    style: TextStyle(fontSize: Fs.sm, height: Lh.snug, color: p.ink),
                  ),
                ),
                if (key == value)
                  LexIcon(Ic.check, size: 14, color: p.accent),
              ],
            ),
          ),
      ],
      child: Container(
        height: context.controlH,
        padding: const EdgeInsets.symmetric(horizontal: Sp.x3),
        decoration: BoxDecoration(
          borderRadius: R.borderSm,
          border: Border.all(color: p.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.t(
                _kSortOptions.firstWhere((o) => o.$1 == value).$2,
              ),
              style: TextStyle(fontSize: Fs.sm, height: Lh.snug, color: p.ink2),
            ),
            const SizedBox(width: Sp.x2),
            LexIcon(Ic.chevronDown, size: 12, color: p.ink3),
          ],
        ),
      ),
    );
  }
}

class _QbarIconButton extends StatefulWidget {
  const _QbarIconButton({
    required this.icon,
    required this.onTap,
    this.active = false,
    this.tooltip,
    this.size = 16,
  });

  final String icon;
  final VoidCallback onTap;
  final bool active;
  final String? tooltip;
  final double size;

  @override
  State<_QbarIconButton> createState() => _QbarIconButtonState();
}

class _QbarIconButtonState extends State<_QbarIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final bg = widget.active
        ? p.accentSoft
        : _hover
            ? p.surfaceHover
            : Colors.transparent;
    final fg = widget.active ? p.accentInk : p.ink3;

    final button = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: TapTarget(
          child: AnimatedContainer(
            duration: Motion.dur1,
            curve: Motion.ease,
            width: Layout.controlHSm,
            height: Layout.controlHSm,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: bg, borderRadius: R.borderSm),
            child: LexIcon(widget.icon, size: widget.size, color: fg),
          ),
        ),
      ),
    );

    final tip = widget.tooltip;
    if (tip == null) return button;
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 500),
      child: button,
    );
  }
}

class _FilterToken extends StatelessWidget {
  const _FilterToken({required this.label, required this.onRemove});

  final String label;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return GestureDetector(
      onTap: onRemove,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Sp.x2, vertical: Sp.x1),
          decoration: BoxDecoration(
            color: p.surface2,
            borderRadius: R.borderXs,
            border: Border.all(color: p.line),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(fontSize: Fs.xs, height: Lh.snug, color: p.ink2),
              ),
              const SizedBox(width: Sp.x1),
              LexIcon(Ic.x, size: 11, color: p.ink3),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResetButton extends StatefulWidget {
  const _ResetButton({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_ResetButton> createState() => _ResetButtonState();
}

class _ResetButtonState extends State<_ResetButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Text(
          context.t('common.reset'),
          style: TextStyle(
            fontSize: Fs.xs,
            height: Lh.snug,
            color: _hover ? p.accent : p.ink3,
          ),
        ),
      ),
    );
  }
}

/* ------------------------------------------------------------------ */
/* Table                                                               */
/* ------------------------------------------------------------------ */

class _WordTable extends StatelessWidget {
  const _WordTable({
    required this.words,
    required this.query,
    required this.lang,
    required this.now,
    required this.selectMode,
    required this.selected,
    required this.onToggleSelected,
    required this.onOpen,
    required this.onFavorite,
    required this.onPlay,
    required this.onDelete,
  });

  final List<Word> words;
  final String query;
  final String lang;
  final int now;
  final bool selectMode;
  final Set<String> selected;
  final ValueChanged<String> onToggleSelected;
  final ValueChanged<Word> onOpen;
  final ValueChanged<Word> onFavorite;
  final ValueChanged<Word> onPlay;
  final ValueChanged<Word> onDelete;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    // The term and its gloss share one column (term on top, definition
    // underneath) instead of sitting side by side. Side-by-side split the
    // available width two ways, so a long English term and a long Chinese
    // gloss both ended up ellipsised on a phone. Stacking gives each one the
    // full column width, which is what "show the whole entry" needs.
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < _kCompactBreakpoint;
        return Card(
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // A phone row already reads as two stacked lines, so a header
              // would just eat vertical space and repeat itself.
              if (!compact)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Sp.x4,
                    vertical: Sp.x3,
                  ),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: p.line)),
                  ),
                  child: Row(
                    children: [
                      if (selectMode) const SizedBox(width: Sp.x6),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _HeadCell(label: context.t('words.term')),
                            _HeadCell(label: context.t('common.definition')),
                          ],
                        ),
                      ),
                      SizedBox(
                        width: _kStatusColW,
                        child: _HeadCell(label: context.t('common.status')),
                      ),
                      SizedBox(
                        width: selectMode ? 0 : _actionsColW(context),
                        child: _HeadCell(
                          label: context.t('common.actions'),
                          align: TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                ),
              for (var i = 0; i < words.length; i++)
                _WordRow(
                  key: ValueKey<String>(words[i].id),
                  word: words[i],
                  query: query,
                  lang: lang,
                  now: now,
                  selectMode: selectMode,
                  compact: compact,
                  picked: selected.contains(words[i].id),
                  last: i == words.length - 1,
                  index: i,
                  onTap: () => selectMode
                      ? onToggleSelected(words[i].id)
                      : onOpen(words[i]),
                  onFavorite: () => onFavorite(words[i]),
                  onPlay: () => onPlay(words[i]),
                  onEdit: () => onOpen(words[i]),
                  onDelete: () => onDelete(words[i]),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Below this content width the row folds into a phone-shaped two-liner.
const double _kCompactBreakpoint = 640;
const double _kStatusColW = 128;

/// The actions column holds four icon buttons, so its width is not a constant —
/// it is however wide four targets are. Hard-coding 140 was a mouse
/// measurement: once the buttons grow to [Layout.tap] on a touch platform the
/// column needed 176 and the row overflowed by exactly 36.
double _actionsColW(BuildContext context) =>
    math.max(140.0, 4 * context.iconTarget);

class _HeadCell extends StatelessWidget {
  const _HeadCell({required this.label, this.align = TextAlign.left});

  final String label;
  final TextAlign align;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Text(
      label,
      textAlign: align,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: Fs.xs,
        height: Lh.snug,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.02,
        color: p.ink3,
      ),
    );
  }
}

class _WordRow extends StatefulWidget {
  const _WordRow({
    super.key,
    required this.word,
    required this.query,
    required this.lang,
    required this.now,
    required this.selectMode,
    required this.compact,
    required this.picked,
    required this.last,
    required this.index,
    required this.onTap,
    required this.onFavorite,
    required this.onPlay,
    required this.onEdit,
    required this.onDelete,
  });

  final Word word;
  final String query;
  final String lang;
  final int now;
  final bool selectMode;
  final bool compact;
  final bool picked;
  final bool last;
  final int index;
  final VoidCallback onTap;
  final VoidCallback onFavorite;
  final VoidCallback onPlay;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  State<_WordRow> createState() => _WordRowState();
}

class _WordRowState extends State<_WordRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final w = widget.word;

    final bg = widget.picked
        ? p.accentSoft
        : _hover
            ? p.surfaceHover
            : Colors.transparent;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: Motion.dur1,
          curve: Motion.ease,
          decoration: BoxDecoration(
            color: bg,
            border: widget.last
                ? null
                : Border(bottom: BorderSide(color: p.line)),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: Sp.x4,
            vertical: Sp.x3,
          ),
          child: widget.compact
              ? _buildCompact(context, p, w)
              : _buildWide(context, p, w),
        ),
      ),
    );
  }

  /// Phone / narrow: term on the first line, gloss underneath, and the
  /// status + actions folded into a quiet third line. Every text gets the
  /// full row width instead of a fraction of it.
  Widget _buildCompact(BuildContext context, Palette p, Word w) {
    final due = w.srs == null
        ? context.t('words.neverReviewed')
        : relativeDay(w.srs!.dueAt, widget.lang, widget.now);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.selectMode) ...[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: _CheckBox(on: widget.picked),
          ),
          const SizedBox(width: Sp.x3),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _TermLine(word: w, query: widget.query, maxLines: 2),
              const SizedBox(height: 2),
              _DefinitionLine(word: w, query: widget.query, maxLines: 3),
              const SizedBox(height: Sp.x2),
              Row(
                children: [
                  StatusChip(
                    label: context.t(_kStatusLabelKey[w.status]!),
                    tone: w.status.wire,
                  ),
                  const SizedBox(width: Sp.x2),
                  Expanded(
                    child: Text(
                      due,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: Fs.xs,
                        height: Lh.snug,
                        color: p.ink3,
                      ),
                    ),
                  ),
                  if (!widget.selectMode) ...[
                    _RowAction(
                      icon: w.favorite ? Ic.starFilled : Ic.star,
                      tooltip: context.t('common.favorite'),
                      onTap: widget.onFavorite,
                      active: w.favorite,
                    ),
                    _RowAction(
                      icon: Ic.volume,
                      tooltip: context.t('words.listens', {'n': w.listenCount}),
                      onTap: widget.onPlay,
                    ),
                    _RowAction(
                      icon: Ic.trash,
                      tooltip: context.t('common.delete'),
                      onTap: widget.onDelete,
                      danger: true,
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Desktop / wide: the term column holds the term *and* its gloss stacked,
  /// then fixed-width status and action columns.
  Widget _buildWide(BuildContext context, Palette p, Word w) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.selectMode) ...[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: _CheckBox(on: widget.picked),
          ),
          const SizedBox(width: Sp.x3),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _TermLine(word: w, query: widget.query, maxLines: 1),
              const SizedBox(height: 2),
              _DefinitionLine(word: w, query: widget.query, maxLines: 2),
            ],
          ),
        ),
        const SizedBox(width: Sp.x4),
        SizedBox(
          width: _kStatusColW,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              StatusChip(
                label: context.t(_kStatusLabelKey[w.status]!),
                tone: w.status.wire,
              ),
              const SizedBox(height: Sp.x1),
              Text(
                w.srs == null
                    ? context.t('words.neverReviewed')
                    : relativeDay(w.srs!.dueAt, widget.lang, widget.now),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: Fs.xs,
                  height: Lh.snug,
                  color: p.ink3,
                ),
              ),
            ],
          ),
        ),
        if (!widget.selectMode)
          SizedBox(
            width: _actionsColW(context),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _RowAction(
                  icon: w.favorite ? Ic.starFilled : Ic.star,
                  tooltip: context.t('common.favorite'),
                  onTap: widget.onFavorite,
                  active: w.favorite,
                ),
                _RowAction(
                  icon: Ic.volume,
                  tooltip: context.t('words.listens', {'n': w.listenCount}),
                  onTap: widget.onPlay,
                ),
                _RowAction(
                  icon: Ic.edit,
                  tooltip: context.t('common.edit'),
                  onTap: widget.onEdit,
                ),
                _RowAction(
                  icon: Ic.trash,
                  tooltip: context.t('common.delete'),
                  onTap: widget.onDelete,
                  danger: true,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The headword, with the favourite star inline. Kept separate from the gloss
/// so both can own a full line.
class _TermLine extends StatelessWidget {
  const _TermLine({
    required this.word,
    required this.query,
    required this.maxLines,
  });

  final Word word;
  final String query;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        if (word.favorite) ...[
          LexIcon(Ic.starFilled, size: 13, color: p.accent),
          const SizedBox(width: Sp.x2),
        ],
        Expanded(
          child: _Highlighted(
            text: word.term,
            query: query,
            maxLines: maxLines,
            style: TextStyle(
              fontFamily: Fonts.display,
              fontSize: Fs.md,
              height: Lh.title,
              fontWeight: FontWeight.w500,
              color: p.ink,
            ),
          ),
        ),
      ],
    );
  }
}

/// The gloss, with the part-of-speech tag kept outside the highlight (a search
/// for the meaning marks the meaning; typing "adj." must not light up every
/// adjective in the list).
class _DefinitionLine extends StatelessWidget {
  const _DefinitionLine({
    required this.word,
    required this.query,
    required this.maxLines,
  });

  final Word word;
  final String query;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final empty = word.definition.isEmpty;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if ((word.pos ?? '').isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Sp.x1,
                vertical: 1,
              ),
              decoration: BoxDecoration(
                color: p.surface2,
                borderRadius: R.borderXs,
              ),
              child: Text(
                word.pos!,
                style: TextStyle(
                  fontFamily: Fonts.mono,
                  // 10 was outside the type scale `Fs` declares, and the only
                  // size in the app below `Fs.xs`. On a phone it is not a
                  // caption, it is unreadable.
                  fontSize: Fs.xs,
                  height: Lh.snug,
                  color: p.ink3,
                ),
              ),
            ),
          ),
          const SizedBox(width: Sp.x2),
        ],
        Expanded(
          child: _Highlighted(
            text: empty ? context.t('words.noDefinition') : word.definition,
            query: query,
            maxLines: maxLines,
            style: TextStyle(
              fontSize: Fs.sm,
              height: Lh.snug,
              color: empty ? p.ink4 : p.ink2,
            ),
          ),
        ),
      ],
    );
  }
}

/// Wraps every case-insensitive match of [query] in an accent tint.
///
/// The web build used `<mark>`; here the highlight is a [TextSpan] background,
/// which is the same idea without an inline element.
class _Highlighted extends StatelessWidget {
  const _Highlighted({
    required this.text,
    required this.query,
    required this.style,
    this.maxLines = 1,
  });

  final String text;
  final String query;
  final TextStyle style;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) {
      return Text(
        text,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }

    final p = Palette.of(context);
    final lower = text.toLowerCase();
    final spans = <TextSpan>[];
    var from = 0;
    var at = lower.indexOf(needle);
    while (at != -1) {
      if (at > from) {
        spans.add(TextSpan(text: text.substring(from, at)));
      }
      spans.add(TextSpan(
        text: text.substring(at, at + needle.length),
        style: TextStyle(backgroundColor: p.accentSoft, color: p.accentInk),
      ));
      from = at + needle.length;
      at = lower.indexOf(needle, from);
    }
    if (from < text.length) spans.add(TextSpan(text: text.substring(from)));

    return Text.rich(
      TextSpan(style: style, children: spans),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _CheckBox extends StatelessWidget {
  const _CheckBox({required this.on});

  final bool on;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      width: 18,
      height: 18,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: on ? p.accent : Colors.transparent,
        borderRadius: R.borderXs,
        border: Border.all(color: on ? p.accent : p.lineControl),
      ),
      child: on ? LexIcon(Ic.check, size: 12, color: p.onAccent) : null,
    );
  }
}

class _RowAction extends StatefulWidget {
  const _RowAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.danger = false,
  });

  final String icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;
  final bool danger;

  @override
  State<_RowAction> createState() => _RowActionState();
}

class _RowActionState extends State<_RowAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final Color fg;
    if (widget.active) {
      fg = p.accent;
    } else if (_hover && widget.danger) {
      fg = p.danger;
    } else if (_hover) {
      fg = p.ink;
    } else {
      fg = p.ink3;
    }

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: TapTarget(
            child: Container(
              width: Layout.controlHSm,
              height: Layout.controlHSm,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _hover ? p.surface2 : Colors.transparent,
                borderRadius: R.borderXs,
              ),
              child: LexIcon(widget.icon, size: 15, color: fg),
            ),
          ),
        ),
      ),
    );
  }
}

/* ------------------------------------------------------------------ */
/* Bulk bar                                                            */
/* ------------------------------------------------------------------ */

class _BulkBar extends StatelessWidget {
  const _BulkBar({
    required this.count,
    required this.allSelected,
    required this.onSelectAll,
    required this.onFavorite,
    required this.onDelete,
    required this.onCancel,
  });

  final int count;
  final bool allSelected;
  final VoidCallback onSelectAll;
  final VoidCallback onFavorite;
  final VoidCallback onDelete;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x3),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: R.borderMd,
        border: Border.all(color: p.lineStrong),
        boxShadow: Shadows.popFor(p.isDark),
      ),
      child: Row(
        children: [
          Text(
            context.t('words.selected', {'n': count}),
            style: TextStyle(
              fontFamily: Fonts.mono,
              fontSize: Fs.sm,
              height: Lh.none,
              color: p.ink2,
            ),
          ),
          const SizedBox(width: Sp.x4),
          LexButton(
            label: context.t('words.selectAll'),
            icon: Ic.check,
            size: BtnSize.sm,
            kind: BtnKind.quiet,
            onPressed: allSelected ? null : onSelectAll,
          ),
          const SizedBox(width: Sp.x2),
          LexButton(
            label: context.t('words.favoriteSelected'),
            icon: Ic.star,
            size: BtnSize.sm,
            kind: BtnKind.quiet,
            onPressed: count == 0 ? null : onFavorite,
          ),
          const SizedBox(width: Sp.x2),
          LexButton(
            label: context.t('words.deleteSelected'),
            icon: Ic.trash,
            size: BtnSize.sm,
            kind: BtnKind.quiet,
            onPressed: count == 0 ? null : onDelete,
          ),
          const Spacer(),
          LexButton(
            label: context.t('common.cancel'),
            icon: Ic.x,
            size: BtnSize.sm,
            kind: BtnKind.quiet,
            onPressed: onCancel,
          ),
        ],
      ),
    );
  }
}

class _FooterHint extends StatelessWidget {
  const _FooterHint({required this.shown, required this.total});

  final int shown;
  final int total;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final style = TextStyle(fontSize: Fs.xs, height: Lh.snug, color: p.ink3);
    // The keycaps are a keyboard affordance; the labels beside them are only
    // meaningful as a pair, so both go together on touch devices.
    final bool hints = context.showsKeyHints;
    return Row(
      children: [
        Text(
          shown == total
              ? '${context.t('common.total')} $shown ${context.t('common.words')}'
              : '${context.t('common.total')} $shown / $total ${context.t('common.words')}',
          style: style,
        ),
        if (hints) ...[
          const SizedBox(width: Sp.x3),
          Kbd('/'),
          const SizedBox(width: Sp.x1),
          Text(context.t('common.search'), style: style),
          const SizedBox(width: Sp.x3),
          Kbd('n'),
          const SizedBox(width: Sp.x1),
          Text(context.t('words.addWord'), style: style),
        ],
      ],
    );
  }
}

/* ------------------------------------------------------------------ */
/* List manager                                                        */
/* ------------------------------------------------------------------ */

class _ListManagerBody extends StatefulWidget {
  const _ListManagerBody({required this.activeId, required this.onSelect});

  final String activeId;
  final ValueChanged<String> onSelect;

  @override
  State<_ListManagerBody> createState() => _ListManagerBodyState();
}

class _ListManagerBodyState extends State<_ListManagerBody> {
  bool _creating = false;
  final TextEditingController _name = TextEditingController();
  String _sourceLang = 'en';
  String _targetLang = 'zh-CN';
  String? _renamingId;
  final TextEditingController _rename = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _rename.dispose();
    super.dispose();
  }

  void _create() {
    final trimmed = _name.text.trim();
    if (trimmed.isEmpty) return;
    final list = context.store.createList(
      name: trimmed,
      sourceLang: _sourceLang,
      targetLang: _targetLang,
    );
    widget.onSelect(list.id);
    _name.clear();
    setState(() => _creating = false);
    context.toast(context.t('words.newList'), ToastKind.ok);
  }

  Future<void> _deleteList(WordList list) async {
    final count = context.data.words.where((w) => w.listId == list.id).length;
    final ok = await confirmLex(
      context,
      title: context.t('common.delete'),
      subtitle: context.t('words.deleteListConfirm', {
        'name': list.name,
        'n': count,
      }),
      confirmLabel: context.t('common.delete'),
      danger: true,
    );
    if (!ok || !mounted) return;
    context.store.deleteList(list.id);
    context.toast(context.t('words.wordDeleted'), ToastKind.ok);
  }

  @override
  Widget build(BuildContext context) {
    final data = context.data;
    final p = Palette.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final l in data.lists)
          _ListRow(
            list: l,
            count: data.words.where((w) => w.listId == l.id).length,
            active: l.id == widget.activeId,
            canDelete: data.lists.length > 1,
            renaming: _renamingId == l.id,
            renameController: _rename,
            onTap: () {
              widget.onSelect(l.id);
              Navigator.of(context).pop();
            },
            onStartRename: () {
              _rename.text = l.name;
              setState(() => _renamingId = l.id);
            },
            onCommitRename: () {
              context.store.renameList(l.id, _rename.text);
              setState(() => _renamingId = null);
            },
            onCancelRename: () => setState(() => _renamingId = null),
            onDelete: () => _deleteList(l),
          ),
        const SizedBox(height: Sp.x4),
        if (_creating)
          Container(
            padding: const EdgeInsets.all(Sp.x4),
            decoration: BoxDecoration(
              color: p.surface2,
              borderRadius: R.borderSm,
              border: Border.all(color: p.line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LexField(
                  label: context.t('words.newList'),
                  hint: context.t('words.listName'),
                  child: LexInput(
                    controller: _name,
                    placeholder: context.t('words.listName'),
                    autofocus: true,
                    onSubmitted: (_) => _create(),
                  ),
                ),
                const SizedBox(height: Sp.x3),
                Row(
                  children: [
                    Expanded(
                      child: LexField(
                        label: context.t('words.sourceLang'),
                        child: LexSelect<String>(
                          value: _sourceLang,
                          options: LANGUAGES.map((l) => l.code).toList(),
                          labelOf: (code) => langName(code, 'zh-CN'),
                          onChanged: (v) => setState(() => _sourceLang = v),
                        ),
                      ),
                    ),
                    const SizedBox(width: Sp.x3),
                    Expanded(
                      child: LexField(
                        label: context.t('words.targetLang'),
                        child: LexSelect<String>(
                          value: _targetLang,
                          options: LANGUAGES.map((l) => l.code).toList(),
                          labelOf: (code) => langName(code, 'zh-CN'),
                          onChanged: (v) => setState(() => _targetLang = v),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Sp.x3),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    LexButton(
                      label: context.t('common.cancel'),
                      size: BtnSize.sm,
                      kind: BtnKind.quiet,
                      onPressed: () => setState(() => _creating = false),
                    ),
                    const SizedBox(width: Sp.x2),
                    LexButton(
                      label: context.t('common.create'),
                      size: BtnSize.sm,
                      kind: BtnKind.primary,
                      onPressed: _create,
                    ),
                  ],
                ),
              ],
            ),
          )
        else
          GestureDetector(
            onTap: () => setState(() => _creating = true),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: Sp.x4,
                  vertical: Sp.x3,
                ),
                decoration: BoxDecoration(
                  borderRadius: R.borderSm,
                  border: Border.all(color: p.line),
                ),
                child: Row(
                  children: [
                    LexIcon(Ic.plus, size: 15, color: p.accent),
                    const SizedBox(width: Sp.x2),
                    Text(
                      context.t('words.newList'),
                      style: TextStyle(
                        fontSize: Fs.sm,
                        height: Lh.snug,
                        color: p.accentInk,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ListRow extends StatelessWidget {
  const _ListRow({
    required this.list,
    required this.count,
    required this.active,
    required this.canDelete,
    required this.renaming,
    required this.renameController,
    required this.onTap,
    required this.onStartRename,
    required this.onCommitRename,
    required this.onCancelRename,
    required this.onDelete,
  });

  final WordList list;
  final int count;
  final bool active;
  final bool canDelete;
  final bool renaming;
  final TextEditingController renameController;
  final VoidCallback onTap;
  final VoidCallback onStartRename;
  final VoidCallback onCommitRename;
  final VoidCallback onCancelRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return GestureDetector(
      onTap: renaming ? null : onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Sp.x4,
            vertical: Sp.x3,
          ),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: p.line)),
          ),
          child: Row(
            children: [
              Expanded(
                child: renaming
                    ? LexInput(
                        controller: renameController,
                        autofocus: true,
                        onSubmitted: (_) => onCommitRename(),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            list.name,
                            style: TextStyle(
                              fontSize: Fs.md,
                              height: Lh.snug,
                              fontWeight: FontWeight.w500,
                              color: active ? p.accentInk : p.ink,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '$count ${context.t('common.words')} · '
                            '${langName(list.sourceLang, 'zh-CN')} → '
                            '${langName(list.targetLang, 'zh-CN')}',
                            style: TextStyle(
                              fontSize: Fs.xs,
                              height: Lh.snug,
                              color: p.ink3,
                            ),
                          ),
                        ],
                      ),
              ),
              if (!renaming) ...[
                _RowAction(
                  icon: Ic.edit,
                  tooltip: context.t('common.rename'),
                  onTap: onStartRename,
                ),
                _RowAction(
                  icon: Ic.trash,
                  tooltip: context.t('common.delete'),
                  onTap: canDelete ? onDelete : () {},
                  danger: true,
                ),
              ] else
                LexButton(
                  label: context.t('common.save'),
                  size: BtnSize.sm,
                  kind: BtnKind.primary,
                  onPressed: onCommitRename,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
