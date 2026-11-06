/// The word library.
///
/// Ports the web build's `WordsPage.tsx`. One page owns five things the web build
/// spread across a component and three dialogs: the list tabs, the query bar
/// (search + status filter + sort + tools), the table itself, select mode's
/// bulk bar, and the list manager.
///
/// This file is layout and wiring only. The filter atom, the selection set, the
/// "adopt the first list" latch, the index and every store write live in
/// [WordsViewModel]; the page builds from its getters and calls its intents.
/// What stays here is exactly what needs a `BuildContext` or a widget identity:
/// the text controller and focus node (a search field's buffer is view state —
/// it must survive a rebuild that the view model did not cause), and the
/// dialogs.
///
/// The three decisions the view model documents — one `WordQuery` atom, one
/// index per snapshot, the query forgotten on reopen — are unchanged; they just
/// moved one layer down.
///
/// The row's 发音 button speaks the term through [speakWord], which also
/// records the listen — the same pair the web build did inline.
library;


import 'package:flutter/gestures.dart'
    show PointerDeviceKind, PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart' hide Card;
import 'package:flutter/services.dart';

import '../../../../app/scope.dart';
import '../../../../data/services/speech.dart';
import '../../../../domain/models/languages.dart';
import '../../../../domain/models/srs.dart';
import '../../../../domain/models/types.dart';
import '../../../../domain/use_cases/deck_templates.dart';
import '../../../../domain/use_cases/word_query.dart';
import '../../../core/context_feedback.dart';
import '../../../core/tokens.dart';
import '../../../core/widgets/controls.dart';
import '../../../core/widgets/entrance.dart';
import '../../../core/widgets/density.dart';
import '../../../core/widgets/keyboard_hints.dart';
import '../../../core/widgets/lex_icon.dart';
import '../../../core/widgets/widgets.dart';
import '../view_models/words_view_model.dart';
import 'word_editor.dart';

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
  late final WordsViewModel _vm;

  /// The search field's buffer. Kept in the view because it is a text editing
  /// surface, not screen state: the field must not be reset by a rebuild the
  /// view model did not ask for.
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    // `context.store` is a non-depending lookup, so reading it here is safe and
    // does not subscribe the page to every write before its first build.
    _vm = WordsViewModel(
      store: context.store,
      feedback: ContextFeedback(context),
      speak: (Word word) => speakWord(context, word),
    );
  }

  @override
  void dispose() {
    _vm.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /* ---- dialog plumbing --------------------------------------------- */

  Future<void> _openEditor({Word? word}) async {
    final requested = await showWordEditor(
      context,
      word: word,
      defaultListId: _vm.listId,
    );
    if (!mounted) return;
    await _vm.applyEditorResult(requested, original: word);
  }

  Future<void> _openListManager() async {
    final String listId = _vm.listId;
    await showLexModal<void>(
      context: context,
      title: context.t('common.list'),
      subtitle: context.t('words.listsSubtitle', {'n': context.data.lists.length}),
      width: 560,
      body: _ListManagerBody(vm: _vm, activeId: listId),
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

  /* ---- build ------------------------------------------------------- */

  @override
  Widget build(BuildContext context) {
    final String lang = context.i18n.lang.wire;
    // Idempotent, and must precede the first `filtered` read so collation and
    // the adopted list are settled before the table is measured.
    _vm
      ..setUiLang(lang)
      ..ensureReady();

    return ListenableBuilder(
      listenable: _vm,
      builder: (BuildContext context, Widget? _) {
        final List<Word> filtered = _vm.filtered;
        final String trimmed = _vm.trimmedQuery;

        return CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.slash): () {
              if (_vm.selectMode) return;
              _searchFocus.requestFocus();
            },
            const SingleActivator(LogicalKeyboardKey.keyN): () {
              if (_vm.selectMode) return;
              _openEditor();
            },
            const SingleActivator(LogicalKeyboardKey.keyA, control: true): () {
              if (_vm.selectMode) _vm.selectAllVisible();
            },
            const SingleActivator(LogicalKeyboardKey.keyA, meta: true): () {
              if (_vm.selectMode) _vm.selectAllVisible();
            },
            const SingleActivator(LogicalKeyboardKey.escape): () {
              if (_vm.selectMode) {
                _vm.exitSelect();
              } else if (trimmed.isNotEmpty) {
                _search.clear();
                _vm.setQuery('');
              }
            },
          },
          child: Focus(
            autofocus: true,
            child: PageShell(
              controller: widget.controller,
              // The list runs edge to edge and wears each word's status stripe
              // on the page's own left margin, so the shell stops padding the
              // body and every other block here adds its own gutter. That is
              // what makes the stripes read as the list's spine rather than as
              // a border on a floating box, which is what it was before.
              bleed: true,
              // Adding a word is the page's one action, so it gets the corner
              // where a thumb already is instead of a button in the header that
              // competes with the title.
              fab: FloatingAction(
                icon: Ic.plus,
                tooltip: context.t('words.addWord'),
                onPressed: () => _openEditor(),
              ),
              // No page-level action row: the list manager is already reachable
              // from the tabs strip below (`_AddTabButton`), and a second button
              // for the same dialog in the chrome above it was the page saying
              // the same thing twice.
              // The two controls that decide what the list shows — which
              // wordbook, and the query/filter — stay at the top while the rows
              // scroll under them. A filtered list whose filter has scrolled
              // out of sight is a list you cannot trust, and changing wordbook
              // meant scrolling to the top first.
              pinned: <Widget>[
                // Not wrapped in [_gutter]: the tab strip supplies its own
                // leading gutter so that tabs can scroll off the window's edge
                // instead of vanishing at an inner margin.
                _ListTabs(
                  lists: context.data.lists,
                  activeId: _vm.listId,
                  counts: _vm.index.byList,
                  onSelect: _vm.selectList,
                  onManage: _openListManager,
                ),
                const SizedBox(height: Sp.x4),
                _gutter(
                  _QueryBar(
                    controller: _search,
                    focusNode: _searchFocus,
                    query: _vm.filters.query ?? '',
                    status: _vm.filters.status,
                    sort: _vm.filters.sort ?? SortKey.recent,
                    favoriteOnly: _vm.filters.favoriteOnly,
                    counts: _vm.counts,
                    selectMode: _vm.selectMode,
                    onQuery: _vm.setQuery,
                    onStatus: _vm.setStatus,
                    onSort: _vm.setSort,
                    onToggleFavorite: _vm.toggleFavoriteOnly,
                    onToggleSelect: _vm.toggleSelectMode,
                    onReset: () {
                      _search.clear();
                      _vm.resetFilters();
                    },
                  ),
                ),
              ],
              children: [
                if (_vm.isListEmpty)
                  _gutter(
                    EmptyState(
                      icon: Ic.words,
                      title: context.t('words.noWords'),
                      text: context.t('words.noWordsHint'),
                      action: LexButton(
                        label: context.t('words.addFirst'),
                        icon: Ic.plus,
                        kind: BtnKind.primary,
                        onPressed: () => _openEditor(),
                      ),
                    ),
                  )
                else if (!_vm.hasResults)
                  _gutter(
                    EmptyState(
                      icon: Ic.search,
                      title: context.t('words.noResults'),
                      text: context.t('words.noResultsHint'),
                      action: LexButton(
                        label: context.t('common.reset'),
                        onPressed: () {
                          _search.clear();
                          _vm.resetFilters();
                        },
                      ),
                    ),
                  )
                else
                  _WordTable(
                    words: filtered,
                    query: trimmed,
                    selectMode: _vm.selectMode,
                    selected: _vm.selected,
                    onToggleSelected: _vm.toggleSelected,
                    onOpen: (Word w) => _openEditor(word: w),
                    onFavorite: (Word w) => context.store.toggleFavorite(w.id),
                    onPlay: _vm.play,
                  ),
                if (_vm.selectMode) ...[
                  const SizedBox(height: Sp.x4),
                  // The web's `bar-rise`, and the largest travel of any
                  // entrance: the bar appears where the footer hint was, so a
                  // long rise makes the swap read as one thing rather than as
                  // two unrelated footers trading places.
                  _gutter(
                    FadeRise(
                      offset: 14,
                      child: _BulkBar(
                        count: _vm.selectedCount,
                        allSelected: _vm.allVisibleSelected,
                        onSelectAll: _vm.selectAllVisible,
                        onFavorite: _vm.favoriteSelected,
                        onDelete: _vm.deleteSelected,
                        onCancel: _vm.exitSelect,
                      ),
                    ),
                  ),
                ],
                if (_vm.hasResults && !_vm.selectMode) ...[
                  const SizedBox(height: Sp.x4),
                  _gutter(
                    _FooterHint(
                      shown: filtered.length,
                      total: _vm.listCount,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/* ------------------------------------------------------------------ */
/* List tabs                                                           */
/* ------------------------------------------------------------------ */

/// The wordbook strip: one fixed row — the current wordbook on the left, every
/// other one scrolling beside it.
///
/// It used to be a `Wrap`, which was wrong in both directions. Three lists fit
/// on a phone and five did not: the surplus wrapped onto a second and then a
/// third line inside the pinned strip, so the strip grew downwards and took the
/// room from the words — the control that chooses what you read was eating what
/// you read. Wrapping also re-flowed whenever a list was renamed, which moved
/// every tab out from under the pointer.
///
/// Now the strip is exactly one row high no matter how many wordbooks exist.
/// The tabs scroll horizontally; the + does not scroll with them, because a +
/// that can be pushed off the edge is the same bug as a + that wraps off it.
///
/// The current wordbook is not a tab any more. It sits pinned at the left as a
/// dropdown listing the other wordbooks *in the same learning language*, so
/// jumping between 日语 N2 and 五十音 stays one click even when the strip holds
/// thirty books across six languages: the strip answers "everything I have",
/// the dropdown answers "the ones this one is comparable to". The strip keeps
/// every other wordbook whatever its language, because the cross-language
/// switch has to stay one click as well — the dropdown is a shortcut, not the
/// only door.
///
/// Two things are needed to make that row usable with a mouse, and both are
/// done here rather than left to the platform: Flutter's scrollables ignore the
/// mouse wheel on a horizontal axis (it is a vertical input) and ignore mouse
/// dragging entirely, so on the desktop build the strip would scroll only if
/// the user happened to have a trackpad. The wheel is mapped onto the axis and
/// the mouse joins the drag devices.
class _ListTabs extends StatefulWidget {
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
  State<_ListTabs> createState() => _ListTabsState();
}

class _ListTabsState extends State<_ListTabs> {
  final ScrollController _scroll = ScrollController();

  @override
  void didUpdateWidget(_ListTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeId == widget.activeId) return;
    // The strip leads with the active book's same-language siblings, so a
    // strip left scrolled to some later book would hide exactly those siblings
    // off its left edge after a switch. The reader would see only books in
    // other languages and conclude the same-language ones had vanished —
    // with the dropdown the only place still showing them. Rewind on switch.
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(0);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Turns a vertical wheel notch into horizontal travel.
  ///
  /// Only a pure vertical notch is remapped: a horizontal wheel (or shift+wheel,
  /// which the engine reports as `dx`) is already understood by the scrollable,
  /// and handling it here as well would scroll twice for one notch.
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final double dy = event.scrollDelta.dy;
    if (dy == 0 || !_scroll.hasClients) return;
    final ScrollPosition position = _scroll.position;
    final double next = (position.pixels + dy).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (next == position.pixels) return;
    _scroll.jumpTo(next);
  }

  @override
  Widget build(BuildContext context) {
    WordList? active;
    for (final WordList list in widget.lists) {
      if (list.id == widget.activeId) {
        active = list;
        break;
      }
    }

    // Two different cuts of the same collection, on purpose. `siblings` feeds
    // the dropdown and is narrowed to the active book's learning language;
    // the strip is NOT narrowed — a book in another language is still one tap
    // away. But it is ordered: the active book's siblings come first.
    //
    // Creation order used to put the cross-language books (the kana decks are
    // often added later) in front of the same-language ones. On a phone the
    // strip's viewport is barely one tab wide, so the books a reader most
    // wants to switch to sat off-screen behind a scroll and looked like they
    // had vanished — the dropdown was the only place still showing them.
    final List<WordList> siblings = active == null
        ? const <WordList>[]
        : <WordList>[
            for (final WordList list in widget.lists)
              if (list.id != active.id && list.sourceLang == active.sourceLang)
                list,
          ];
    final List<WordList> strip = <WordList>[
      ...siblings,
      for (final WordList list in widget.lists)
        if (list.id != widget.activeId &&
            (active == null || list.sourceLang != active.sourceLang))
          list,
    ];

    return Row(
      children: <Widget>[
        Padding(
          padding: const EdgeInsetsDirectional.only(start: Sp.x6),
          child: active == null
              ? const SizedBox.shrink()
              : _ActiveListButton(
                  active: active,
                  siblings: siblings,
                  counts: widget.counts,
                  onSelect: widget.onSelect,
                ),
        ),
        const SizedBox(width: Sp.x2),
        Expanded(
          child: ScrollConfiguration(
            // A mouse cannot drag a scrollable by default; on the desktop build
            // that leaves the wheel as the only input, and the wheel is what
            // [_onPointerSignal] has to translate.
            behavior: ScrollConfiguration.of(context).copyWith(
              dragDevices: <PointerDeviceKind>{
                ...ScrollConfiguration.of(context).dragDevices,
                PointerDeviceKind.mouse,
              },
            ),
            child: Listener(
              onPointerSignal: _onPointerSignal,
              child: SingleChildScrollView(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                // No leading gutter here: the active wordbook already supplies
                // it, and a second inset would leave a gap between the pill and
                // the first tab that reads as a broken row.
                padding: const EdgeInsetsDirectional.only(end: Sp.x2),
                child: Row(
                  children: <Widget>[
                    for (int i = 0; i < strip.length; i++)
                      Padding(
                        padding: EdgeInsetsDirectional.only(
                          end: i == strip.length - 1 ? 0 : Sp.x2,
                        ),
                        child: _ListTab(
                          label: strip[i].name,
                          count: widget.counts[strip[i].id]?.length ?? 0,
                          onTap: () => widget.onSelect(strip[i].id),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: Sp.x2),
        Padding(
          padding: const EdgeInsetsDirectional.only(end: Sp.x6),
          child: _AddTabButton(
            onTap: widget.onManage,
            tooltip: context.t('words.newList'),
          ),
        ),
      ],
    );
  }
}

/// The current wordbook, pinned at the left of the strip.
///
/// It is a menu only when there is something to switch to. A book that is the
/// only one in its language gets a plain label: a chevron over an empty menu
/// teaches the user that the control lies, and the strip beside it already
/// offers every other book anyway.
///
/// The menu lists the same-language siblings and nothing else — that is the
/// whole point of it. It deliberately has no "manage wordbooks" entry: the +
/// at the right end of the same row opens that dialog, and a second door to one
/// room is the page saying the same thing twice.
class _ActiveListButton extends StatefulWidget {
  const _ActiveListButton({
    required this.active,
    required this.siblings,
    required this.counts,
    required this.onSelect,
  });

  final WordList active;
  final List<WordList> siblings;
  final Map<String, List<Word>> counts;
  final ValueChanged<String> onSelect;

  @override
  State<_ActiveListButton> createState() => _ActiveListButtonState();
}

class _ActiveListButtonState extends State<_ActiveListButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final bool canSwitch = widget.siblings.isNotEmpty;

    // The pill is the same shape and tint the active tab used to wear, so the
    // strip still reads as "this one, then the others" at a glance.
    final Widget pill = MouseRegion(
      cursor: canSwitch ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        height: context.controlH,
        // The pill sits in the same row as an `Expanded` strip, so it has to be
        // bounded: a long wordbook name would otherwise take the width the tabs
        // need and push the + off the right edge — the very bug this row was
        // rebuilt to remove, arriving from the other side.
        constraints: BoxConstraints(
          minWidth: context.isTouch ? Layout.tap : 0,
          maxWidth: 220,
        ),
        padding: EdgeInsets.symmetric(
          horizontal: Sp.x3,
          vertical: context.isTouch ? 0 : Sp.x2,
        ),
        decoration: BoxDecoration(
          color: p.accentSoft,
          borderRadius: R.borderPill,
          // Hover is a ring, not a darker fill: there is no "one step past
          // accentSoft" in the palette, and inventing one here would be the
          // third tint of azurite in the app. A ring also says "this opens
          // something" rather than "this is selected", which the fill already
          // says.
          border: Border.all(
            color: _hover && canSwitch ? p.accent : fadeFrom(p.accent),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Flexible(
              child: Text(
                widget.active.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: Fs.sm,
                  height: Lh.snug,
                  fontWeight: FontWeight.w500,
                  color: p.accentInk,
                ),
              ),
            ),
            const SizedBox(width: Sp.x2),
            Text(
              '${widget.counts[widget.active.id]?.length ?? 0}',
              style: TextStyle(
                fontFamily: Fonts.mono,
                fontSize: Fs.xs,
                height: Lh.none,
                color: p.accentInk,
              ),
            ),
            if (canSwitch) ...<Widget>[
              const SizedBox(width: Sp.x1),
              LexIcon(Ic.chevronDown, size: 13, color: p.accentInk),
            ],
          ],
        ),
      ),
    );

    if (!canSwitch) {
      return KeyedSubtree(
        key: const Key('active-list-button'),
        child: pill,
      );
    }

    return MenuAnchor(
      builder: (BuildContext ctx, MenuController controller, Widget? _) =>
          Tooltip(
        message: context.t('words.switchList'),
        waitDuration: const Duration(milliseconds: 500),
        child: GestureDetector(
          onTap: () =>
              controller.isOpen ? controller.close() : controller.open(),
          child: KeyedSubtree(
            key: const Key('active-list-button'),
            child: pill,
          ),
        ),
      ),
      menuChildren: <Widget>[
        for (final WordList sibling in widget.siblings)
          MenuItemButton(
            // A stable key: the name alone is not unique enough for a test to
            // say "this menu does not offer the Japanese books", because the
            // same names are printed in the strip right next to the menu.
            key: ValueKey<String>('switch-list-${sibling.id}'),
            onPressed: () => widget.onSelect(sibling.id),
            style: ButtonStyle(
              backgroundColor: WidgetStatePropertyAll<Color>(p.surface),
              shape: WidgetStatePropertyAll<OutlinedBorder>(
                RoundedRectangleBorder(borderRadius: R.borderXs),
              ),
              minimumSize: const WidgetStatePropertyAll<Size>(Size(200, 40)),
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 200),
                    child: Text(
                      sibling.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: Fs.sm, color: p.ink),
                    ),
                  ),
                  const SizedBox(width: Sp.x3),
                  Text(
                    '${widget.counts[sibling.id]?.length ?? 0}',
                    style: TextStyle(
                      fontFamily: Fonts.mono,
                      fontSize: Fs.xs,
                      color: p.ink4,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// One wordbook in the strip, other than the active one.
///
/// No active state here any more: the current book lives in
/// [_ActiveListButton], and a tab in this row can never be it. So a tab is
/// always plain text that darkens under the pointer — it changes which rows are
/// shown, it does not hold data, and a row of outlined boxes above the search
/// field read like a form.
class _ListTab extends StatefulWidget {
  const _ListTab({
    required this.label,
    required this.count,
    required this.onTap,
  });

  final String label;
  final int count;
  final VoidCallback onTap;

  @override
  State<_ListTab> createState() => _ListTabState();
}

class _ListTabState extends State<_ListTab> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final bg = _hover ? p.surfaceHover : fadeFrom(p.surfaceHover);
    final fg = _hover ? p.ink : p.ink2;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: Motion.dur1,
          curve: Motion.ease,
          // The list strip is the only way to switch lists, so each tab is a
          // target, not a caption. It grows with the density like a button does.
          height: context.controlH,
          // A one-character list name would otherwise be a target narrower than
          // a finger; the floor is on the box, so the shape does not grow with
          // it on a mouse.
          constraints: BoxConstraints(minWidth: context.isTouch ? Layout.tap : 0),
          padding: EdgeInsets.symmetric(
            horizontal: Sp.x3,
            vertical: context.isTouch ? 0 : Sp.x2,
          ),
          decoration: BoxDecoration(color: bg, borderRadius: R.borderPill),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: Fs.sm,
                  height: Lh.snug,
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
                  color: p.ink4,
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
                // A filled chip rather than an outlined square: the outline was
                // the only 1px rectangle left in a row of pills, so it read as
                // an empty slot. The fill is the same `surface2` the search
                // capsule wears, which says "this is a control" without a border.
                color: _hover ? p.surfaceHover : p.surface2,
                borderRadius: R.borderPill,
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
  final bool selectMode;
  final ValueChanged<String> onQuery;
  final ValueChanged<WordStatus?> onStatus;
  final ValueChanged<SortKey> onSort;
  final VoidCallback onToggleFavorite;
  final VoidCallback onToggleSelect;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    // Two things, one row, at every width.
    //
    // The bar used to be five controls in two rows — the search capsule, a
    // strip of six status segments, a sort menu, a favourites toggle and a
    // select button — plus a third row of removable tokens that appeared once
    // anything was filtered and restated the same three facts. On a phone that
    // was 124dp of chrome above the list before a single word was visible, and
    // on any width it asked the reader to learn five separate things that all
    // answer one question: which words am I looking at?
    //
    // So everything that is not search went behind one capsule that reports its
    // own state. The row cannot grow a second line any more, which is the point
    // — there is nothing left to fold, and no token row to reflow.
    return Row(
      children: [
        Expanded(
          child: _SearchField(
            controller: controller,
            focusNode: focusNode,
            // On a phone the field shares its row with the filter capsule,
            // which leaves ~120dp for the hint — the full sentence needs more
            // than that and was being cut off mid-character. A hint that is
            // ellipsised is worse than a shorter hint: the cut reads as a
            // broken field, and the words it lost are the ones explaining what
            // can be searched. The full sentence is kept wherever it fits.
            placeholder: context.isTouch
                ? context.t('words.searchPlaceholderShort')
                : context.t('words.searchPlaceholder'),
            onChanged: onQuery,
            onClear: () {
              controller.clear();
              onQuery('');
              focusNode.requestFocus();
            },
          ),
        ),
        const SizedBox(width: Sp.x2),
        _FilterMenu(
          status: status,
          sort: sort,
          favoriteOnly: favoriteOnly,
          counts: counts,
          selectMode: selectMode,
          canClear: status != null || favoriteOnly || query.trim().isNotEmpty,
          onStatus: onStatus,
          onSort: onSort,
          onToggleFavorite: onToggleFavorite,
          onSelectMode: onToggleSelect,
          onClear: onReset,
        ),
      ],
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

    // A capsule, like the filter beside it and the control that adds a word.
    // The field used to be a rounded rectangle with a full outline in the
    // idle state, which made the query bar — the one thing on the page that is
    // *not* a container — look like the most boxed thing on it.
    return PillField(
      focused: _focused,
      icon: Ic.search,
      child: Row(
        children: [
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
            ),
        ],
      ),
    );
  }
}

/// What a pick in [_FilterMenu] means.
///
/// A sealed hierarchy rather than an enum: three of the five carry a payload,
/// and the payloads are different types, so `switch` over these is exhaustive
/// without a default branch that could silently swallow a new case.
sealed class _FilterAction {
  const _FilterAction();
}

class _PickStatus extends _FilterAction {
  const _PickStatus(this.status);

  /// Null is "all statuses".
  final WordStatus? status;
}

class _PickSort extends _FilterAction {
  const _PickSort(this.sort);

  final SortKey sort;
}

class _ToggleFavorites extends _FilterAction {
  const _ToggleFavorites();
}

class _StartSelect extends _FilterAction {
  const _StartSelect();
}

class _ClearFilters extends _FilterAction {
  const _ClearFilters();
}

/// Every control that is not search, behind one capsule.
///
/// The capsule carries its own state in its label — the status it is filtered
/// to, or a star when only favourites are showing — and turns accent-filled
/// while any of it is on. That label is what let the removable filter tokens
/// below the bar go: a filter you can read off the control that set it does not
/// need a chip underneath reminding you it is set.
class _FilterMenu extends StatelessWidget {
  const _FilterMenu({
    required this.status,
    required this.sort,
    required this.favoriteOnly,
    required this.counts,
    required this.selectMode,
    required this.canClear,
    required this.onStatus,
    required this.onSort,
    required this.onToggleFavorite,
    required this.onSelectMode,
    required this.onClear,
  });

  final WordStatus? status;
  final SortKey sort;
  final bool favoriteOnly;
  final Map<String, int> counts;
  final bool selectMode;
  final bool canClear;
  final ValueChanged<WordStatus?> onStatus;
  final ValueChanged<SortKey> onSort;
  final VoidCallback onToggleFavorite;
  final VoidCallback onSelectMode;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final List<String> parts = <String>[
      if (status != null) context.t(_kStatusLabelKey[status!]!),
      if (favoriteOnly) '★',
    ];
    final bool active = parts.isNotEmpty;
    final String label =
        active ? parts.join(' · ') : context.t('words.filter');
    final Color fg = active ? p.accentInk : p.ink2;

    return PopupMenuButton<_FilterAction>(
      tooltip: context.t('words.filter'),
      position: PopupMenuPosition.under,
      color: p.surface,
      onSelected: (_FilterAction action) {
        switch (action) {
          case _PickStatus(status: final WordStatus? picked):
            onStatus(picked);
          case _PickSort(sort: final SortKey picked):
            onSort(picked);
          case _ToggleFavorites():
            onToggleFavorite();
          case _StartSelect():
            onSelectMode();
          case _ClearFilters():
            onClear();
        }
      },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<_FilterAction>>[
        _section(context.t('words.filter')),
        for (final (WordStatus? s, String labelKey) in <(WordStatus?, String)>[
          (null, 'common.all'),
          for (final WordStatus s in _kStatusFilters) (s, _kStatusLabelKey[s]!),
        ])
          PopupMenuItem<_FilterAction>(
            value: _PickStatus(s),
            height: context.controlH,
            child: _MenuRow(
              label: context.t(labelKey),
              count: counts[s?.wire ?? 'all'],
              selected: status == s,
              // The four status rows carry the same swatch as the word rows'
              // left stripe, so the stripe can be read without a legend. The
              // "all" row has no single status, hence no dot.
              status: s,
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<_FilterAction>(
          value: const _ToggleFavorites(),
          height: context.controlH,
          child: _MenuRow(
            label: context.t('words.filterFavorites'),
            selected: favoriteOnly,
          ),
        ),
        // Entering select mode from here rather than from a button of its own:
        // it is a once-in-a-session action, and a permanently visible button
        // for it cost a third of the bar's width every other time.
        if (!selectMode)
          PopupMenuItem<_FilterAction>(
            value: const _StartSelect(),
            height: context.controlH,
            child: _MenuRow(label: context.t('words.select')),
          ),
        const PopupMenuDivider(),
        _section(context.t('common.sort')),
        for (final (SortKey key, String labelKey) in _kSortOptions)
          PopupMenuItem<_FilterAction>(
            value: _PickSort(key),
            height: context.controlH,
            child: _MenuRow(label: context.t(labelKey), selected: sort == key),
          ),
        if (canClear) ...[
          const PopupMenuDivider(),
          PopupMenuItem<_FilterAction>(
            value: const _ClearFilters(),
            height: context.controlH,
            child: _MenuRow(label: context.t('common.reset')),
          ),
        ],
      ],
      child: Container(
        height: context.controlH,
        padding: const EdgeInsets.symmetric(horizontal: Sp.x3),
        decoration: BoxDecoration(
          // Filled, not outlined — the same capsule the search field and the
          // add button wear, so the row reads as one family of controls.
          color: active ? p.accentSoft : p.surface2,
          borderRadius: R.borderPill,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            LexIcon(Ic.filter, size: 15, color: active ? p.accentInk : p.ink3),
            const SizedBox(width: Sp.x2),
            Text(
              label,
              style: TextStyle(fontSize: Fs.sm, height: Lh.snug, color: fg),
            ),
            const SizedBox(width: Sp.x1),
            LexIcon(Ic.chevronDown, size: 12, color: active ? p.accentInk : p.ink3),
          ],
        ),
      ),
    );
  }

  /// A group heading. Disabled so it cannot be picked, short so it does not
  /// read as a row of the menu.
  PopupMenuEntry<_FilterAction> _section(String text) => PopupMenuItem<_FilterAction>(
        enabled: false,
        height: 28,
        child: _MenuSection(label: text),
      );
}

/// One pickable row: label, an optional count, a check when it is the choice.
class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.label,
    this.count,
    this.selected = false,
    this.status,
  });

  final String label;
  final int? count;
  final bool selected;
  final WordStatus? status;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Row(
      children: [
        if (status != null) ...[
          Container(
            key: ValueKey<String>('status-dot-${status!.wire}'),
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: p.statusColor(status!),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: Sp.x2),
        ],
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: Fs.sm,
              height: Lh.snug,
              color: selected ? p.accent : p.ink,
            ),
          ),
        ),
        if (count != null) ...[
          const SizedBox(width: Sp.x3),
          Text(
            '$count',
            style: TextStyle(
              fontFamily: Fonts.mono,
              fontSize: Fs.xs,
              height: Lh.none,
              color: p.ink3,
            ),
          ),
        ],
        if (selected) ...[
          const SizedBox(width: Sp.x2),
          LexIcon(Ic.check, size: 14, color: p.accent),
        ],
      ],
    );
  }
}

class _MenuSection extends StatelessWidget {
  const _MenuSection({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Text(
      label,
      style: TextStyle(
        fontSize: Fs.xs,
        height: Lh.snug,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.04,
        color: p.ink3,
      ),
    );
  }
}

class _QbarIconButton extends StatefulWidget {
  const _QbarIconButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.size = 16,
  });

  final String icon;
  final VoidCallback onTap;
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
    final bg = _hover ? p.surfaceHover : fadeFrom(p.surfaceHover);
    final fg = p.ink3;

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
            decoration: BoxDecoration(color: bg, borderRadius: R.borderPill),
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

/* ------------------------------------------------------------------ */
/* Table                                                               */
/* ------------------------------------------------------------------ */

class _WordTable extends StatelessWidget {
  const _WordTable({
    required this.words,
    required this.query,
    required this.selectMode,
    required this.selected,
    required this.onToggleSelected,
    required this.onOpen,
    required this.onFavorite,
    required this.onPlay,
  });

  final List<Word> words;
  final String query;
  final bool selectMode;
  final Set<String> selected;
  final ValueChanged<String> onToggleSelected;
  final ValueChanged<Word> onOpen;
  final ValueChanged<Word> onFavorite;
  final ValueChanged<Word> onPlay;

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
        // No card. A library is a list, and a list is hairlines on the page —
        // the card wrapper put 400 rows inside a rounded rectangle that said
        // nothing except "a component lives here", and its inset edges fought
        // the left stripe that now runs down the page's own margin.
        //
        // The list's own accent rule is switched off: each row paints a stripe
        // in its study-status colour instead, so the left edge reports where
        // every word is in the review cycle rather than drawing one unbroken
        // line for the whole list.
        return HairlineList(
          padded: false,
          rule: false,
          children: [
            // A phone row already reads as two stacked lines, so a header
            // would just eat vertical space and repeat itself.
            if (!compact)
              Container(
                padding: const EdgeInsets.only(
                  left: Sp.x4 + Layout.listRuleGap,
                  right: Sp.x4,
                  top: Sp.x3,
                  bottom: Sp.x3,
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
                  ],
                ),
              ),
            for (var i = 0; i < words.length; i++)
              FadeRise(
                // The key moves to the wrapper: it is what lets a row that
                // survives a filter keep its finished entrance instead of
                // replaying it, and what lets a genuinely new row play one.
                key: ValueKey<String>(words[i].id),
                offset: 6,
                delay: Motion.stagger * (i < _kStaggerRows ? i : _kStaggerRows),
                child: _WordRow(
                  word: words[i],
                  query: query,
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
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Below this content width the row folds into a phone-shaped two-liner.
const double _kCompactBreakpoint = 640;

/// The page's horizontal gutter.
///
/// The shell runs `bleed: true` so that each word's status stripe can sit on
/// the page's own left margin; every block that is *not* the list re-adds the
/// gutter here rather than each one inventing its own padding.
Widget _gutter(Widget child) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x6),
      child: child,
    );

/// How many rows keep a growing entrance delay before it stops increasing.
///
/// The web build caps the inline `animationDelay` at `Math.min(index, 8) * 16ms`
/// so a 400-word library costs the same third of a second as a ten-word one.
/// Without the cap the last row of a long list would wait six seconds for its
/// turn, which reads as the page being broken rather than as a stagger.
const int _kStaggerRows = 8;
class _HeadCell extends StatelessWidget {
  const _HeadCell({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Text(
      label,
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
  // No `key`: the identity that matters belongs to the [FadeRise] wrapper above,
  // so that a row keeping its place keeps its finished entrance too.
  const _WordRow({
    required this.word,
    required this.query,
    required this.selectMode,
    required this.compact,
    required this.picked,
    required this.last,
    required this.index,
    required this.onTap,
    required this.onFavorite,
    required this.onPlay,
  });

  final Word word;
  final String query;
  final bool selectMode;
  final bool compact;
  final bool picked;
  final bool last;
  final int index;
  final VoidCallback onTap;
  final VoidCallback onFavorite;
  final VoidCallback onPlay;

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
            : fadeFrom(p.surfaceHover);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          children: [
            AnimatedContainer(
              duration: Motion.dur1,
              curve: Motion.ease,
              constraints: const BoxConstraints(minHeight: Layout.listRowMin),
              decoration: BoxDecoration(
                color: bg,
                border: widget.last
                    ? null
                    : Border(bottom: BorderSide(color: p.line)),
              ),
              // The left inset is the stripe's lane plus air. The row paints
              // its own stripe (see below), so text starting at x=0 would sit
              // on top of that colour instead of beside it.
              padding: const EdgeInsets.only(
                left: Sp.x4 + Layout.listRuleGap,
                right: Sp.x4,
                top: Sp.x4,
                bottom: Sp.x4,
              ),
              child: widget.compact
                  ? _buildCompact(context, p, w)
                  : _buildWide(context, p, w),
            ),
            // Painted last so a row's hover fill cannot wash it out: the
            // stripe is the row's state, not part of whatever the pointer is
            // over. Its colour is the word's place in the review ladder.
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Container(
                key: ValueKey<String>('status-stripe-${w.status.wire}'),
                width: Layout.listRuleW,
                color: p.statusColor(w.status),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Phone / narrow: the term, then its gloss. Nothing else.
  ///
  /// The row used to carry a third line — a status chip, a due date and three
  /// icon buttons — which made a five-line entry out of a two-line one. The
  /// status and the date are both answers to "what is this word's place in my
  /// study plan", and that is a question this page is not being asked: the
  /// flashcard and stats screens report on scheduling, and a list is for
  /// finding a word. They were also the two things that made a row's height
  /// vary, so a list of twenty words had no rhythm to read down.
  Widget _buildCompact(BuildContext context, Palette p, Word w) {
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
            ],
          ),
        ),
        if (!widget.selectMode) ...[
          const SizedBox(width: Sp.x2),
          _RowActions(word: w, onFavorite: widget.onFavorite, onPlay: widget.onPlay),
        ],
      ],
    );
  }

  /// Desktop / wide: the same two lines, with the actions held to the right by
  /// the row's own width rather than by a fixed column.
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
        if (!widget.selectMode)
          _RowActions(word: w, onFavorite: widget.onFavorite, onPlay: widget.onPlay),
      ],
    );
  }
}

/// The headword.
///
/// One row of a word table is read as "what is this word, and what does it
/// mean" — in that order, and at a glance. The headword therefore carries the
/// weight: serif, one step up from body, and the only thing in the row set in
/// the display face. Everything under it is a caption by comparison, which is
/// what makes a list of four hundred words scannable instead of uniform.
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
        // The favourite star is not drawn inline here: inline it pushed this
        // one headword ~20dp right of every other headword, so a single
        // starred word broke the left edge the whole list is read down. The
        // actions column already shows the same star in the same place for
        // every row, which is where a per-row state belongs.
        Expanded(
          child: _Highlighted(
            text: word.term,
            query: query,
            maxLines: maxLines,
            style: TextStyle(
              fontFamily: Fonts.display,
              // The headword is the largest thing on the page below the title.
              // At 19 it sat a single step above the gloss and a list of four
              // hundred entries read as uniform grey; at 24 the eye lands on the
              // word first and the meaning second, which is the order a
              // vocabulary list is scanned in.
              fontSize: Fs.xl,
              height: Lh.title,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.01,
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

/// The two things a row can do: star it, hear it.
///
/// There used to be four. Edit was a duplicate — tapping the row already opens
/// the editor — and delete is in that editor's footer, which is where a
/// destructive action belongs: behind a deliberate open, not one stray tap from
/// the row you were reading. What is left is what the reference puts on a row,
/// and it fits beside the gloss instead of claiming a column of its own.
class _RowActions extends StatelessWidget {
  const _RowActions({
    required this.word,
    required this.onFavorite,
    required this.onPlay,
  });

  final Word word;
  final VoidCallback onFavorite;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RowAction(
          icon: word.favorite ? Ic.starFilled : Ic.star,
          tooltip: context.t('common.favorite'),
          onTap: onFavorite,
          active: word.favorite,
        ),
        _RowAction(
          icon: Ic.volume,
          tooltip: context.t('words.listens', {'n': word.listenCount}),
          onTap: onPlay,
        ),
      ],
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
                color: _hover ? p.surface2 : fadeFrom(p.surface2),
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
  const _ListManagerBody({required this.vm, required this.activeId});

  /// The page's view model: the modal creates, renames and deletes lists
  /// through it so there is one write path and one set of toasts.
  final WordsViewModel vm;

  /// The list that was active when the modal opened, for the row highlight.
  final String activeId;

  @override
  State<_ListManagerBody> createState() => _ListManagerBodyState();
}

class _ListManagerBodyState extends State<_ListManagerBody>
    with WidgetsBindingObserver {
  bool _creating = false;
  final TextEditingController _name = TextEditingController();
  final FocusNode _nameFocus = FocusNode();

  /// Set when 创建 is pressed with a blank name; cleared on the next keystroke.
  ///
  /// The button stays enabled on purpose: a greyed-out 创建 explains nothing,
  /// and on a phone the tap is the one moment the user is looking for a reason.
  /// Silently returning is what made the button read as broken.
  String? _nameError;

  /// The create card's action row. Held in view when the keyboard opens: the
  /// name field autofocuses, the modal body shrinks under the keyboard, and
  /// that used to push 取消/创建 below the fold — an invisible create button is
  /// indistinguishable from one that does nothing.
  final GlobalKey _formActions = GlobalKey();

  String _sourceLang = 'en';
  String _targetLang = 'zh-CN';
  String? _renamingId;
  final TextEditingController _rename = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeMetrics() => _revealActions();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _nameFocus.dispose();
    _name.dispose();
    _rename.dispose();
    super.dispose();
  }

  /// Scrolls the create card's buttons into view after the frame that moved
  /// them. `Scrollable.ensureVisible` walks up to the modal body's scroll view
  /// on its own: `showLexModal` owns that view, so there is no controller here
  /// to ask, and asking the nearest scrollable is also what keeps this correct
  /// if the dialog gains another one.
  void _revealActions() {
    if (!_creating) return;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      final BuildContext? actions = _formActions.currentContext;
      if (!mounted || actions == null) return;
      Scrollable.ensureVisible(
        actions,
        alignment: 1,
        duration: Motion.dur2,
        curve: Motion.ease,
      );
    });
  }

  void _openCreate() {
    setState(() {
      _creating = true;
      _nameError = null;
    });
    _revealActions();
  }

  void _closeCreate() {
    _nameFocus.unfocus();
    setState(() {
      _creating = false;
      _nameError = null;
    });
  }

  void _create() {
    final String trimmed = _name.text.trim();
    if (trimmed.isEmpty) {
      setState(() => _nameError = context.t('words.listNameRequired'));
      _nameFocus.requestFocus();
      _revealActions();
      return;
    }
    // Creates, switches the page to the new list, and toasts — all in the view
    // model, so the tab and the modal cannot disagree about which list is new.
    widget.vm.createList(
      name: trimmed,
      sourceLang: _sourceLang,
      targetLang: _targetLang,
    );
    _name.clear();
    _nameFocus.unfocus();
    setState(() {
      _creating = false;
      _nameError = null;
    });
  }

  /// The create card: title, the required name, the language pair, the actions.
  ///
  /// Laid out for the width it actually gets rather than for a desktop dialog.
  /// A phone's modal body is ~340dp wide; two language selects side by side
  /// there leave each label ellipsised to "中文（简…", so under 420dp they stack
  /// and the buttons stretch to the card — also the width a thumb wants.
  Widget _buildCreateForm(BuildContext context) {
    final p = Palette.of(context);
    final String uiLang = context.i18n.lang.wire;

    // Only the decks written for the language the user just picked. Offering
    // 五十音 to somebody naming an English list is noise: the suggestion has to
    // arrive as an answer to a choice they made, not as a standing banner.
    final List<DeckTemplate> decks = deckTemplates()
        .where((DeckTemplate d) => d.sourceLang == _sourceLang)
        .toList();

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool compact = constraints.maxWidth < 420;
        final Widget source = LexField(
          label: context.t('words.sourceLang'),
          child: LexSelect<String>(
            value: _sourceLang,
            options: LANGUAGES.map((l) => l.code).toList(),
            labelOf: (code) => langName(code, uiLang),
            onChanged: (v) => setState(() => _sourceLang = v),
          ),
        );
        final Widget target = LexField(
          label: context.t('words.targetLang'),
          child: LexSelect<String>(
            value: _targetLang,
            options: LANGUAGES.map((l) => l.code).toList(),
            labelOf: (code) => langName(code, uiLang),
            onChanged: (v) => setState(() => _targetLang = v),
          ),
        );
        final Widget cancel = LexButton(
          label: context.t('common.cancel'),
          size: compact ? BtnSize.md : BtnSize.sm,
          kind: BtnKind.quiet,
          block: compact,
          onPressed: _closeCreate,
        );
        final Widget create = LexButton(
          label: context.t('common.create'),
          size: compact ? BtnSize.md : BtnSize.sm,
          kind: BtnKind.primary,
          block: compact,
          onPressed: _create,
        );

        return Container(
          padding: const EdgeInsets.all(Sp.x4),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: R.borderSm,
            border: Border.all(color: p.lineStrong),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  LexIcon(Ic.plus, size: 15, color: p.accent),
                  const SizedBox(width: Sp.x2),
                  Text(
                    context.t('words.newList'),
                    style: TextStyle(
                      fontSize: Fs.sm,
                      fontWeight: FontWeight.w600,
                      color: p.ink,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Sp.x3),
              LexField(
                label: context.t('words.listName'),
                error: _nameError,
                child: LexInput(
                  // A stable handle for the widget tests: the page behind the
                  // modal also owns a text field (the search capsule), so
                  // "the first TextField" would be a coin flip.
                  key: const Key('create-list-name'),
                  controller: _name,
                  focusNode: _nameFocus,
                  placeholder: context.t('words.listNameHint'),
                  autofocus: true,
                  onChanged: (_) {
                    if (_nameError != null) setState(() => _nameError = null);
                  },
                  onSubmitted: (_) => _create(),
                ),
              ),
              const SizedBox(height: Sp.x4),
              if (compact) ...<Widget>[
                source,
                const SizedBox(height: Sp.x3),
                target,
              ] else
                Row(
                  children: <Widget>[
                    Expanded(child: source),
                    const SizedBox(width: Sp.x3),
                    Expanded(child: target),
                  ],
                ),
              if (decks.isNotEmpty) ...<Widget>[
                const SizedBox(height: Sp.x4),
                _buildDeckPicker(context, decks),
              ],
              const SizedBox(height: Sp.x4),
              Row(
                key: _formActions,
                children: compact
                    ? <Widget>[
                        Expanded(child: cancel),
                        const SizedBox(width: Sp.x2),
                        Expanded(child: create),
                      ]
                    : <Widget>[
                        const Spacer(),
                        cancel,
                        const SizedBox(width: Sp.x2),
                        create,
                      ],
              ),
            ],
          ),
        );
      },
    );
  }

  /// The ready-made decks for [decks], as one hairline row each.
  ///
  /// Shown inside the create form, right under the language pair, and only when
  /// the chosen source language has decks. Someone naming a list in Japanese
  /// gets the offer where they made the choice; everyone else gets a blank form
  /// and nothing else. The row is the same shape as a list row so it reads as
  /// "a list you can have" rather than as an advertisement.
  Widget _buildDeckPicker(BuildContext context, List<DeckTemplate> decks) {
    final Palette p = Palette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          context.t('words.decks'),
          style: TextStyle(
            fontSize: Fs.xs,
            height: Lh.tight,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
            color: p.ink4,
          ),
        ),
        const SizedBox(height: Sp.x2),
        for (var i = 0; i < decks.length; i++)
          _DeckRow(
            deck: decks[i],
            label: context.t(
              decks[i].id == 'kana-hiragana'
                  ? 'words.deckKanaHiragana'
                  : 'words.deckKanaKatakana',
            ),
            hint: context.t('words.deckKanaHint'),
            last: i == decks.length - 1,
            onTap: () => _addDeck(decks[i]),
          ),
      ],
    );
  }

  /// Add [deck] and close: the page switches to the new list, so staying in the
  /// dialog would hide the thing that was just created.
  void _addDeck(DeckTemplate deck) {
    widget.vm.addDeck(deck, name: context.t(
      deck.id == 'kana-hiragana'
          ? 'words.deckKanaHiragana'
          : 'words.deckKanaKatakana',
    ));
    Navigator.of(context).pop();
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
              widget.vm.selectList(l.id);
              Navigator.of(context).pop();
            },
            onStartRename: () {
              _rename.text = l.name;
              setState(() => _renamingId = l.id);
            },
            onCommitRename: () {
              widget.vm.renameList(l.id, _rename.text);
              setState(() => _renamingId = null);
            },
            onCancelRename: () => setState(() => _renamingId = null),
            onDelete: () => widget.vm.deleteList(l),
          ),
        const SizedBox(height: Sp.x4),
        if (_creating)
          _buildCreateForm(context)
        else
          GestureDetector(
            onTap: _openCreate,
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

/// One ready-made deck: what it is, how big it is, and a plus.
class _DeckRow extends StatefulWidget {
  const _DeckRow({
    required this.deck,
    required this.label,
    required this.hint,
    required this.last,
    required this.onTap,
  });

  final DeckTemplate deck;
  final String label;
  final String hint;
  final bool last;
  final VoidCallback onTap;

  @override
  State<_DeckRow> createState() => _DeckRowState();
}

class _DeckRowState extends State<_DeckRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Sp.x2,
            vertical: Sp.x2,
          ),
          decoration: BoxDecoration(
            color: _hover ? p.surfaceHover : Colors.transparent,
            borderRadius: R.borderSm,
            border: widget.last
                ? null
                : Border(bottom: BorderSide(color: p.line)),
          ),
          child: Row(
            children: <Widget>[
              LexIcon(Ic.layers, size: 16, color: p.ink3),
              const SizedBox(width: Sp.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      widget.label,
                      style: TextStyle(
                        fontSize: Fs.sm,
                        height: Lh.snug,
                        fontWeight: FontWeight.w500,
                        color: p.ink,
                      ),
                    ),
                    Text(
                      widget.hint,
                      style: TextStyle(
                        fontSize: Fs.xs,
                        height: Lh.snug,
                        color: p.ink3,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Sp.x2),
              Text(
                '${widget.deck.count}',
                style: TextStyle(
                  fontFamily: Fonts.mono,
                  fontSize: Fs.xs,
                  height: Lh.none,
                  color: p.ink3,
                  fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: Sp.x3),
              LexIcon(Ic.plus, size: 15, color: p.accent),
            ],
          ),
        ),
      ),
    );
  }
}
