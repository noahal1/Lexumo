/// The shell's destination, its order, the selected index and the rail state,
/// with no widgets in them.
///
/// The shell used to keep four things in one `State`: which page was current,
/// whether the sidebar was collapsed, the scroll controller per page, and the
/// numbers the sidebar prints. Three of the four live here now; the scroll
/// controllers stay in the view because a [ScrollController] is a widget-layer
/// object and has no meaning outside a mounted tree.
///
/// ## The `PageId` / icon split
///
/// [PageId] used to be declared beside the view and carried three fields:
/// the wire id, the icon name and the label key. The icon name is an `Ic`
/// constant — a string only `LexIcon` understands, declared in a file that
/// imports `package:flutter/widgets.dart` — so it is widget-layer and stays in
/// the view (`_iconFor` in `views/app_shell.dart`).
///
/// What moves here is everything that is *identity* rather than *paint*:
///
///   * **order** — [values] is the tab-bar order, and the Ctrl/Cmd+1…6 table
///     is indexed by it,
///   * **the wire id** — `'words'`, `'quiz'`, …, which is what a page sends
///     back through `NavScope` and what [PageId.fromId] resolves,
///   * **the label key** — a plain `String` key, not a translation; the view
///     still calls `context.t` on it, so no language lives in this file,
///   * **the selected index** — [page], the one piece of mutable state the
///     shell owns.
///
/// ## What it derives
///
/// The due badge, the streak card and the theme icon are all read off the
/// snapshot, so they are derivations from the data layer and belong here rather
/// than in `build`. The view model subscribes to the store and republishes, so
/// a snapshot write redraws the sidebar without the view reading the store at
/// all.
library;

// The constructor's parameter names (`store:`, `feedback:`) read better than
// the private field names — the same trade-off `words_view_model.dart` and
// `data/repositories/store.dart` make.
// ignore_for_file: prefer_initializing_formals

import '../../../../data/repositories/store.dart';
import '../../../../domain/models/types.dart';
import '../../../../domain/use_cases/day_stats.dart';
import '../../../core/view_model.dart';

/// The six destinations, in tab-bar order.
///
/// Identity, order and the i18n key — not the icon. See this file's header for
/// why the icon mapping is the view's.
///
/// [home] leads because it is the screen the app opens on: a landing page that
/// says what is waiting today. It was added after the other five, and it went
/// in at the front rather than the back because tab-bar order is reading order
/// — a summary belongs before the thing it summarises.
enum PageId {
  home('home', 'nav.home'),
  words('words', 'nav.words'),
  flashcards('flashcards', 'nav.flashcards'),
  quiz('quiz', 'nav.quiz'),
  stats('stats', 'nav.stats'),
  settings('settings', 'nav.settings');

  const PageId(this.id, this.labelKey);

  /// The wire id a page sends through `NavScope` — `'words'`, `'quiz'`, ….
  final String id;

  /// The i18n key for the destination's label. The view translates it.
  final String labelKey;

  /// The destination named by [id], or null when the shell does not know it.
  ///
  /// Forgiving on purpose: a page can ask for a destination this build does
  /// not have, and that must be ignored rather than throw out of a button
  /// callback.
  static PageId? fromId(String id) {
    for (final PageId page in values) {
      if (page.id == id) return page;
    }
    return null;
  }
}

/// Owns the shell's screen state.
///
/// The rail preference is in-memory only, exactly as it was in the view: the
/// snapshot schema belongs to the sync protocol, and a UI preference is not a
/// record worth migrating a snapshot for.
class ShellViewModel extends ViewModel {
  ShellViewModel({
    required Store store,
    required this.feedback,
    PageId initialPage = PageId.home,
    int Function()? clock,
  })  : _store = store,
        _page = initialPage,
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _detach = _store.addListener(refresh);
  }

  final Store _store;

  final int Function() _clock;

  /// The store outlives the shell, so a closure left behind would keep this
  /// view model alive for the rest of the session.
  late final void Function() _detach;

  /// The shell's window onto dialogs and toasts.
  ///
  /// The shell raises neither today — every label it draws is a `context.t` in
  /// the view, and its only navigation is its own — but the port is part of the
  /// view-model contract and is kept here so the constructor matches every
  /// other screen's and a shell-level action added later has somewhere to
  /// report without changing this class's shape.
  final Feedback feedback;

  /* ---- selection ---------------------------------------------------- */

  PageId _page;

  /// The destination currently on screen.
  PageId get page => _page;

  /// Move to [page]. Returns false when it was already the current one, which
  /// is the case the view must not re-scroll.
  bool navigate(PageId page) {
    if (page == _page) return false;
    update(() => _page = page);
    return true;
  }

  /// Move to the destination a page named by wire id.
  ///
  /// Returns the destination actually entered, or null when the id is unknown
  /// or names the page already on screen — the two cases the view must not
  /// re-scroll. This is the only place the id→[PageId] lookup lives, so a page
  /// asking for a destination this build lacks is ignored in exactly one spot.
  PageId? navigateToId(String id) {
    final PageId? target = PageId.fromId(id);
    if (target == null || !navigate(target)) return null;
    return target;
  }

  /* ---- sidebar rail ------------------------------------------------- */

  /// The user's explicit collapse choice, or null to follow the window width.
  bool? _railPref;

  /// The explicit choice, if the user has made one.
  bool? get railPref => _railPref;

  /// Whether the sidebar is collapsed to icons, for a window that is [narrow].
  ///
  /// [narrow] is the view's layout mode (`width <= Layout.railBreakpoint`),
  /// passed in because a view model has no `MediaQuery` — the breakpoint is a
  /// property of the window, not of the screen's state.
  bool railFor(bool narrow) => _railPref ?? narrow;

  /// Flip the rail and remember the result, so an explicit choice survives a
  /// resize while the default keeps following the window.
  void toggleRail(bool narrow) => update(() => _railPref = !railFor(narrow));

  /* ---- derived from the snapshot ------------------------------------ */

  /// The snapshot's theme, for the sidebar's sun/moon button.
  bool get isDark => _store.data.settings.theme == ThemeMode_.dark;

  /// How many cards are waiting, for the flashcard badge.
  int get dueCount => dueWords(_store.data).length;

  /// The streak card's two numbers, read from one clock reading.
  ///
  /// A record rather than two getters because both must describe the same
  /// moment: two `now` calls straddling midnight would print yesterday's
  /// reviews beside today's streak.
  ({int streak, int today}) get studyStats {
    final int now = _clock();
    final AppData data = _store.data;
    return (
      streak: streakDays(data, now),
      today: reviewsToday(data, now),
    );
  }

  /* ---- intents ------------------------------------------------------ */

  /// Flip the theme between light and dark, in the snapshot.
  void toggleTheme() {
    final bool dark = isDark;
    _store.updateSettings(
      (Settings s) =>
          s.copyWith(theme: dark ? ThemeMode_.light : ThemeMode_.dark),
    );
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }
}
