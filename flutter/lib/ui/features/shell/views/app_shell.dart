/// The app shell: navigation rail, page switching, theme, global shortcuts.
///
/// Mirrors `src/App.tsx`. Three layout modes, chosen by width exactly as the CSS
/// media queries did:
///
///   · wide (>1000px)   — stone sidebar with labels,
///   · rail (≤1000px)   — the same destinations collapsed into a floating
///                        capsule: a pill-shaped stone lozenge that hovers in
///                        the rail's slot instead of filling it top to bottom,
///   · mobile (≤720px)  — no sidebar at all; a stone tab bar at the bottom.
///
/// The collapsed/expanded choice is remembered for the session (in
/// [ShellViewModel]) so a resize does not overrule an explicit choice.
///
/// ## The view/model split
///
/// [ShellViewModel] owns the current destination, the rail preference and every
/// number the chrome prints (the due badge, the streak, today's reviews, the
/// theme). This file owns the widgets and the two things a view model cannot
/// have:
///
///   * **the scroll controllers.** A [ScrollController] only means something
///     inside a mounted tree, so they stay here, created per destination on
///     demand and disposed with the `State`.
///   * **the icon for a destination.** [PageId] carries identity, order and an
///     i18n key; the icon name is an `Ic` constant that only [LexIcon]
///     understands, so the mapping lives here in [_iconFor]. That split is why
///     `PageId` can live in a file that never imports `material`.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../app/scope.dart';
import '../../../core/context_feedback.dart';
import '../../../core/system_ui.dart';
import '../../../core/tokens.dart';
import '../../../core/widgets/density.dart';
import '../../../core/widgets/keyboard_hints.dart';
import '../../../core/widgets/lex_icon.dart';
import '../../../core/widgets/widgets.dart';
import '../../home/views/home_page.dart';
import '../../practice/views/practice_page.dart';
import '../../profile/views/profile_page.dart';
import '../../stats/views/stats_page.dart';
import '../../words/views/words_page.dart';
import '../view_models/shell_view_model.dart';

export '../view_models/shell_view_model.dart' show PageId;

/// Identity for the sidebar box itself.
///
/// Public so a test can measure the sidebar and prove the rail keeps its 64dp
/// width rather than growing to fit its contents — widening the rail would
/// "fix" an overflow by breaking the layout of the page beside it.
const Key kSidebarKey = ValueKey<String>('app-sidebar');

/// Identity for the collapsed capsule inside the rail.
///
/// Separate from [kSidebarKey] because the two are different objects now: the
/// sidebar *slot* keeps the rail width, and the capsule floats inside it with
/// a margin on each side. A test that wants the shape has to address the
/// capsule, and a test that wants the layout budget has to address the slot.
const Key kRailCapsuleKey = ValueKey<String>('app-rail-capsule');

/// Identity for the phone tab bar's slot: the full-width box that owns the
/// bottom edge, before the bar collapses.
///
/// Same split as [kSidebarKey] / [kRailCapsuleKey], for the same reason. The
/// slot animates its colour and its margins; the capsule inside it animates its
/// shape. A test that wants "how wide is the bar" measures the slot's child,
/// and a test that wants "is it floating" measures the capsule.
const Key kTabBarKey = ValueKey<String>('app-tab-bar');

/// Identity for the capsule the phone tab bar shrinks into.
const Key kTabBarCapsuleKey = ValueKey<String>('app-tab-bar-capsule');

/// How far the page has to have been scrolled before the bar is allowed to
/// collapse. A few pixels in the first frame are noise — an overscroll bounce
/// or a keyboard inset would otherwise fold the bar away on its own.
const double _barCollapseAfter = 24.0;

/// The smallest scroll movement that counts as a direction. Below this the two
/// events are jitter, and a hand resting on a touchpad produces exactly that.
const double _barCollapseDelta = 6.0;

/// The icon for a destination.
///
/// Kept out of [PageId] on purpose: `PageId` lives in the view-model layer,
/// which may not import `widgets`, and an icon name is only meaningful to
/// [LexIcon]. The switch is exhaustive, so a new destination cannot be added
/// without giving it an icon.
String _iconFor(PageId page) => switch (page) {
      PageId.home => Ic.home,
      PageId.words => Ic.words,
      PageId.practice => Ic.cards,
      PageId.stats => Ic.stats,
      PageId.profile => Ic.person,
    };

/// One row of the shortcut help sheet.
class ShortcutHelp {
  const ShortcutHelp(this.keys, this.labelKey);
  final List<String> keys;
  final String labelKey;
}

/// The sheet's contents, in declaration order — the same list the web build
/// rendered from `SHORTCUT_HELP`.
const List<ShortcutHelp> kShortcutHelp = <ShortcutHelp>[
  ShortcutHelp(<String>['Ctrl', '1…5'], 'shortcuts.pageSwitch'),
  ShortcutHelp(<String>['?'], 'shortcuts.help'),
  ShortcutHelp(<String>['/'], 'settings.shortcutSearch'),
  ShortcutHelp(<String>['n'], 'settings.shortcutAdd'),
  ShortcutHelp(<String>['空格'], 'settings.shortcutFlip'),
  ShortcutHelp(<String>['1', '2', '3'], 'shortcuts.grade'),
  ShortcutHelp(<String>['Ctrl', 'Z'], 'shortcuts.undo'),
  ShortcutHelp(<String>['←', '→'], 'shortcuts.skip'),
  ShortcutHelp(<String>['Esc'], 'shortcuts.closeModal'),
];

/// The digit keys behind Ctrl/Cmd+1…5, in page order. Spelled out because
/// `LogicalKeyboardKey.digit1 + i` is not arithmetic the type allows.
///
/// Five entries for five destinations. The list is indexed by
/// [PageId.values], so adding a destination without extending it would throw
/// a range error on the first Ctrl+5 rather than silently doing nothing.
const List<LogicalKeyboardKey> _digitKeys = <LogicalKeyboardKey>[
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
];

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final ShellViewModel _vm;

  /// The page each destination was last scrolled to, so switching back feels
  /// like returning rather than restarting. Keyed by page, created on demand.
  ///
  /// Widget-layer on purpose: a scroll offset is a property of the mounted
  /// list, not of the screen's state, and the view model must not import the
  /// framework that defines it.
  final Map<PageId, ScrollController> _scrollers = <PageId, ScrollController>{};

  ScrollController _scrollerFor(PageId page) => _scrollers.putIfAbsent(
    page,
    () => ScrollController()..addListener(_onPageScroll),
  );

  /// Re-read the active page's offset every time it scrolls.
  ///
  /// The controller is the shell's own, so this is the one place that sees a
  /// page's movement without each page having to report it. The bar is phone
  /// chrome only; a wide window has no bar to fold, so it is not tracked there
  /// and `_barCollapsed` is held open for whenever the window narrows again.
  void _onPageScroll() {
    if (!_isMobile) return;
    final controller = _scrollers[_vm.page];
    if (controller == null || !controller.hasClients) return;
    _onScrollPixels(controller.position.pixels);
  }

  /// Set on every build so a scroll callback knows whether the bar exists.
  bool _isMobile = true;

  /// Whether the phone tab bar has folded itself into its capsule.
  ///
  /// The bar reads a page's scroll direction and gets out of the way while the
  /// reader is moving down the page, then comes back the moment they move up
  /// or reach the top. It is shell state rather than bar state because the
  /// system navigation glyphs have to flip with it: collapsed, the bottom edge
  /// is paper and the glyphs must go dark in a light theme.
  bool _barCollapsed = false;

  /// The last scroll offset the bar reacted to, so a direction can be derived
  /// from the difference between two events rather than from a velocity.
  double _lastPixels = 0;

  void _setBarCollapsed(bool value) {
    if (_barCollapsed == value) return;
    // Called from a scroll notification, which arrives outside the frame's
    // build phase, so this is a legal place to rebuild.
    setState(() => _barCollapsed = value);
  }

  /// Fold or unfold the bar from the page's scroll offset.
  ///
  /// Deliberately hysteretic in both directions: a collapse needs the page to
  /// be past [_barCollapseAfter] and to have moved down by [_barCollapseDelta],
  /// and an expand needs the same distance back. Without the dead zone the
  /// bar would flutter open and shut on the jitter of a finger resting on the
  /// glass.
  void _onScrollPixels(double pixels) {
    final delta = pixels - _lastPixels;
    _lastPixels = pixels;
    if (pixels <= _barCollapseAfter) {
      _setBarCollapsed(false);
      return;
    }
    if (delta > _barCollapseDelta) {
      _setBarCollapsed(true);
    } else if (delta < -_barCollapseDelta) {
      _setBarCollapsed(false);
    }
  }

  @override
  void initState() {
    super.initState();
    // `context.store` is a non-depending lookup, so reading it here is safe and
    // does not subscribe the shell to every write before its first build.
    _vm = ShellViewModel(
      store: context.store,
      feedback: ContextFeedback(context),
    );
  }

  @override
  void dispose() {
    _vm.dispose();
    for (final c in _scrollers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _navigate(PageId page) {
    if (!_vm.navigate(page)) return;
    // A fresh page starts at the top; the scroll offset of the page we left is
    // dropped deliberately (the web build reset it too).
    final controller = _scrollers[page];
    if (controller != null && controller.hasClients) controller.jumpTo(0);
    // A destination starts at its own top, so its bar starts unfolded. The
    // last offset the bar reacted to belonged to the page we are leaving, and
    // keeping it would read the new page's first event as a jump.
    _lastPixels = 0;
    _setBarCollapsed(false);
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final mobile = width <= Layout.mobileBreakpoint;
    final narrow = width <= Layout.railBreakpoint;
    // A scroll callback has no context of its own; this is what tells it
    // whether the bar it would fold actually exists right now.
    _isMobile = mobile;

    return ListenableBuilder(
      listenable: _vm,
      builder: (context, _) {
        final page = _vm.page;
        // Explicit preference wins; otherwise the window decides.
        final rail = _vm.railFor(narrow);

        return CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            // Ctrl/Cmd + 1…5. The digits are not contiguous logical key codes,
            // so the table is spelled out rather than computed.
            for (var i = 0; i < PageId.values.length; i++) ...{
              SingleActivator(_digitKeys[i], control: true): () =>
                  _navigate(PageId.values[i]),
              SingleActivator(_digitKeys[i], meta: true): () =>
                  _navigate(PageId.values[i]),
            },
            // "?" — Shift+/ on a US layout.
            const SingleActivator(LogicalKeyboardKey.slash, shift: true): () {
              showShortcutSheet(context);
            },
          },
          child: Focus(
            autofocus: true,
            // The window is edge-to-edge (`enableEdgeToEdge` in `main.dart`),
            // so both system bars float over this widget and their glyph
            // colours have to be republished from here. The edges are not the
            // same decision: a phone has no frame beside the paper, so the
            // paper runs to the top of the glass and the status glyphs follow
            // the theme; a tablet or desktop window wraps the paper in the
            // stone frame, which is dark in both themes, so over stone the
            // glyphs stay light. The bottom edge lands on paper in every
            // layout, so its glyphs always follow the theme. See
            // `ui/core/system_ui.dart`.
            child: AnnotatedRegion<SystemUiOverlayStyle>(
              value: shellOverlayStyle(
                isDark: _vm.isDark,
                statusOnPaper: mobile,
              ),
              child: Scaffold(
                // A phone keeps nothing stone on screen — the tab bar is a
                // paper dock and nothing owns a strip at the top — so the
                // window's background is the paper itself, and the status bar
                // floats over it. The wider layouts show the stone frame
                // around the paper, as the desktop always has.
                backgroundColor:
                    mobile ? Palette.of(context).bg : Palette.of(context).frame,
                // The bar owns no strip of its own on a phone: the page's paper
                // runs to the bottom edge and the capsule floats over it. That
                // is the difference between "the bar folded away" and "the bar
                // turned see-through" — the first is a page you can scroll to
                // the end of, the second is a hole in the chrome. Without this,
                // a transparent slot would reveal the stone `Scaffold` behind
                // it instead of the page.
                extendBody: mobile,
                body: SafeArea(
                  bottom: false,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!mobile)
                        _Sidebar(
                          vm: _vm,
                          rail: rail,
                          narrow: narrow,
                          onNavigate: _navigate,
                          onHelp: () => showShortcutSheet(context),
                        ),
                      Expanded(
                        child: _Paper(mobile: mobile, child: _pageFor(page)),
                      ),
                    ],
                  ),
                ),
                bottomNavigationBar: mobile
                    ? _TabBar(
                        vm: _vm,
                        onNavigate: _navigate,
                        collapsed: _barCollapsed,
                      )
                    : null,
                floatingActionButton: null,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _pageFor(PageId page) {
    final controller = _scrollerFor(page);
    // A page can ask for a different destination by wire id — "go to quiz" from
    // a finished flashcard session, "add word" from an empty one. The lookup is
    // forgiving on purpose: an id the shell does not know is ignored rather than
    // throwing out of a page's button callback. [ShellViewModel.navigateToId]
    // owns that rule.
    return NavScope(
      onNavigate: (id) => _navigateToId(id),
      child: switch (page) {
        PageId.home => HomePage(controller: controller),
        PageId.words => WordsPage(controller: controller),
        PageId.practice => PracticePage(controller: controller),
        PageId.stats => StatsPage(controller: controller),
        PageId.profile => ProfilePage(controller: controller),
      },
    );
  }

  /// Navigate by wire id, honouring the same scroll reset as a rail tap.
  void _navigateToId(String id) {
    final PageId? target = PageId.fromId(id);
    if (target == null) return;
    _navigate(target);
  }
}

/* ------------------------------------------------------------------ */
/* Sidebar                                                             */
/* ------------------------------------------------------------------ */

/// The paper, with the lit edge that separates it from the stone frame.
///
/// In light theme the two materials are far apart in luminance and the boundary
/// needs nothing. In dark theme both are near-black, so the step between them is
/// almost invisible and the seam has to be drawn rather than implied: a 2dp
/// highlight on the paper's frame side, [Palette.edge]. This is the web build's
/// `:root[data-theme="dark"] .app:not(.mobile) .main { box-shadow: inset 2px 0 0
/// var(--edge) }` — the token existed in the port, nothing painted it, so on a
/// dark desktop the sidebar floated against an edge you could not see.
///
/// A phone has no frame beside the paper — the tab bar sits below, not to the
/// left — so there is no seam to draw.
class _Paper extends StatelessWidget {
  const _Paper({required this.mobile, required this.child});

  final bool mobile;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      color: p.bg,
      foregroundDecoration: p.isDark && !mobile
          ? BoxDecoration(
              border: Border(left: BorderSide(color: p.edge, width: 2)),
            )
          : null,
      child: child,
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.vm,
    required this.rail,
    required this.narrow,
    required this.onNavigate,
    required this.onHelp,
  });

  final ShellViewModel vm;
  final bool rail;

  /// The window's layout mode, passed to the view model so a rail toggle can
  /// remember the *inverse* of what is on screen.
  final bool narrow;

  final ValueChanged<PageId> onNavigate;
  final VoidCallback onHelp;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final stats = vm.studyStats;
    final dark = vm.isDark;
    // Declared once and laid out on whichever axis the current mode uses, so
    // the rail and the full sidebar can never disagree about which buttons
    // exist or what they do.
    final List<Widget> footerButtons = <Widget>[
      _SidebarButton(
        icon: Ic.keyboard,
        tooltip: context.t('settings.shortcuts'),
        onTap: onHelp,
      ),
      _SidebarButton(
        icon: dark ? Ic.sun : Ic.moon,
        tooltip: dark ? context.t('shell.themeToLight') : context.t('shell.themeToDark'),
        onTap: vm.toggleTheme,
      ),
      _SidebarButton(
        icon: Ic.chevronLeft,
        quarterTurns: rail ? 2 : 0,
        tooltip: rail ? context.t('shell.expandRail') : context.t('shell.collapseRail'),
        onTap: () => vm.toggleRail(narrow),
      ),
    ];

    final List<Widget> navItems = <Widget>[
      for (final item in PageId.values)
        _NavItem(
          item: item,
          active: vm.page == item,
          rail: rail,
          badge:
              item == PageId.practice && vm.dueCount > 0 ? vm.dueCount : null,
          onTap: () => onNavigate(item),
        ),
    ];

    // ---- collapsed: a floating capsule -------------------------------
    // The rail used to be the full-height slab narrowed to 64dp: the same
    // stone wall, with the labels removed. That reads as "the sidebar is
    // still there, it just went quiet" — which is what the web build drew,
    // and it is why the collapsed state felt like a strip of a slab rather
    // than a menu in its own right.
    //
    // Collapsed, the menu becomes one object: a capsule. It keeps the slot
    // width (the page beside it must not move when the rail is toggled), but
    // stops being the slot — it is a lozenge floating inside it.
    //
    // The slot gives up the stone for the same reason. A pill drawn in
    // `p.frame` *on* `p.frame` is invisible: the first pass shipped exactly
    // that, and the vision read on the running build returned "a tall, narrow
    // dark rectangular slab ... no obvious rounded outline, border, or drop
    // shadow" — the rounded ends, the outline and the pop shadow were all
    // there and none of them could be seen. Shape and lift only read against
    // a different field, so the rail's field becomes paper and the capsule
    // keeps the stone. The contrast is then the same one the paper already
    // has against the slab (roughly 12:1 in light, still clear in dark), and
    // every colour inside a nav row — the azurite-soft fill that marks the
    // current page, the `frame2` hover, the `frameInk` labels — keeps working
    // against the face it was tuned on.
    if (rail) {
      return AnimatedContainer(
        key: kSidebarKey,
        duration: const Duration(milliseconds: 160),
        width: Layout.sidebarRailW,
        color: p.bg,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: Sp.x4),
            // The margin lives on its own Padding, not on the keyed container:
            // `Container(margin:)` builds a Padding *around* itself, so a key
            // on such a container measures the margin plus the shape, and a
            // test asking "is the capsule narrower than its slot" would be
            // told no. Keyed, the container is the capsule.
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Sp.x1),
              child: Container(
                key: kRailCapsuleKey,
                padding:
                    const EdgeInsets.symmetric(horizontal: Sp.x1, vertical: Sp.x3),
                decoration: BoxDecoration(
                  color: p.frame,
                  borderRadius: R.borderPill,
                  border: Border.all(color: p.frameLine),
                  boxShadow: Shadows.popFor(p.isDark),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    ...navItems,
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Sp.x2,
                        vertical: Sp.x2,
                      ),
                      child: Container(height: 1, color: p.frameLine),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: footerButtons,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    // ---- expanded: the full stone slab -------------------------------
    return AnimatedContainer(
      // Named so a test can measure the sidebar itself rather than whichever
      // AnimatedContainer happens to come first in the tree.
      key: kSidebarKey,
      duration: const Duration(milliseconds: 160),
      width: Layout.sidebarW,
      decoration: BoxDecoration(
        color: p.frame,
        border: Border(right: BorderSide(color: p.frameLine)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.x4, horizontal: Sp.x3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The product's own name, once, at the top of its own chrome. The
            // sidebar used to begin with the first destination and end with the
            // tagline, which meant the stone slab identified itself only at the
            // bottom, under a streak counter — the two least consequential
            // things in the column. Wordmark first, destinations under it.
            Padding(
              padding: const EdgeInsets.fromLTRB(Sp.x3, 0, Sp.x3, Sp.x4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // The app mark: the same drawing as public/icon.svg — a
                  // stone frame holding a paper sheet, an azurite spine and
                  // one ink dot. It is the one mark in the chrome that is
                  // neither text nor an icon, and it is what makes the slab
                  // read as a cover rather than a menu.
                  const LexMark(size: 20, semanticLabel: 'Lexumo'),
                  const SizedBox(width: Sp.x2),
                  Expanded(
                    child: Text(
                      context.t('common.appName'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: Fonts.display,
                        fontSize: Fs.md,
                        height: Lh.tight,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.02,
                        color: p.frameInk,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            ...navItems,
            const Spacer(),
            _StreakCard(streak: stats.streak, today: stats.today),
            const SizedBox(height: Sp.x2),
            // Expanded, the three footer buttons share one row: the slab is
            // 232dp wide and each button is a 32dp tile, so they fit with room
            // to spare. (The collapsed capsule stacks them instead — see the
            // rail branch above, where 44dp touch targets cannot share a 64dp
            // slot.) One list, two axes, so the buttons cannot drift apart.
            Row(children: footerButtons),
            const SizedBox(height: Sp.x2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Sp.x2),
              child: Text(
                context.t('common.appTagline'),
                style: TextStyle(fontSize: Fs.xs, height: Lh.body, color: p.frameInk3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.item,
    required this.active,
    required this.rail,
    required this.badge,
    required this.onTap,
  });

  final PageId item;
  final bool active;
  final bool rail;
  final int? badge;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hover = false;

  /// A labelled destination is taller than a control. 36dp is the height of a
  /// button you press once; a sidebar row is a piece of a list you scan, and at
  /// 36dp with a 15dp label the five of them read as a strip of tiles rather than
  /// as a list. The rail keeps 36 because it wears no label and because a
  /// landscape phone (866×411) has 379dp of column to fit five rows, the streak
  /// card and three footer buttons into — 40dp rows overflow it by 5.
  double get _rowH => widget.rail ? Layout.controlH : 40;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final active = widget.active;
    // The active destination is tinted, not merely a shade lighter than the
    // stone. `frame3` on `frame` is #313935 on #252C28 — a 1.2:1 step that reads
    // as a smudge rather than as "you are here", and the vision pass on the
    // running build confirmed it disappears. The azurite-soft fill is the same
    // move the segmented control and the list tabs already make, so the shell
    // marks a selection the way the rest of the app does.
    final bg = active ? p.frameAccentSoft : (_hover ? p.frame2 : Colors.transparent);
    final fg = active ? p.frameInk : (_hover ? p.frameInk : p.frameInk2);
    final iconColor = active || _hover ? p.frameAccent : p.frameInk3;

    final row = Row(
      mainAxisAlignment: widget.rail ? MainAxisAlignment.center : MainAxisAlignment.start,
      children: [
        LexIcon(_iconFor(widget.item), size: 18, color: iconColor),
        if (!widget.rail) ...[
          const SizedBox(width: Sp.x3),
          Expanded(
            child: Text(
              context.t(widget.item.labelKey),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: Fs.base,
                letterSpacing: 0.01,
                color: fg,
                fontWeight: active ? FontWeight.w500 : FontWeight.w400,
              ),
            ),
          ),
          if (widget.badge != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: Sp.x1, vertical: 1),
              decoration: BoxDecoration(color: p.frame3, borderRadius: R.border2xs),
              child: Text(
                '${widget.badge}',
                style: TextStyle(
                  fontSize: Fs.xs,
                  color: p.frameInk2,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
        ],
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Tooltip(
            message: widget.rail && context.showsKeyHints
                ? '${context.t(widget.item.labelKey)}  (Ctrl+${widget.item.index + 1})'
                : '',
            waitDuration: const Duration(milliseconds: 600),
            child: Container(
              height: _rowH,
              padding: EdgeInsets.symmetric(horizontal: Sp.x3),
              // A capsule, like every other selected thing in the app. The
              // pill is the system's word for "this one", so the sidebar's
              // current page wears one rather than a soft-cornered tile.
              decoration: BoxDecoration(color: bg, borderRadius: R.borderPill),
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  row,
                  // The azurite hairline that marks the current page. It hangs
                  // in the row's own left padding rather than over the row's
                  // fill, so the mark and the fill do not read as one shape.
                  if (active)
                    Positioned(
                      left: -Sp.x3,
                      child: Container(
                        width: 2,
                        height: 18,
                        decoration: BoxDecoration(
                          color: p.frameAccent,
                          borderRadius: const BorderRadius.horizontal(right: Radius.circular(R.x2xs)),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarButton extends StatefulWidget {
  const _SidebarButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.quarterTurns = 0,
  });

  final String icon;
  final String tooltip;
  final VoidCallback onTap;

  /// How far to turn the icon, in quarter turns. The rail toggle uses two so the
  /// same chevron points the other way: the web build rotates one glyph
  /// (`.app.rail .rail-toggle svg { transform: rotate(180deg) }`) rather than
  /// swapping icons, and the difference is that the turn is visible — the
  /// chevron swings instead of being replaced, which is what tells you the two
  /// states are the same control.
  final int quarterTurns;

  @override
  State<_SidebarButton> createState() => _SidebarButtonState();
}

class _SidebarButtonState extends State<_SidebarButton> {
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
          behavior: HitTestBehavior.opaque,
          child: TapTarget(
            // The hover tint fades in over `dur-2` rather than snapping. On a
            // strip of three unlabelled icons a sudden fill reads as a state
            // change; a fade reads as the pointer arriving.
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: _hover ? 1 : 0),
              duration: Motion.dur2,
              curve: Motion.ease,
              builder: (BuildContext context, double t, Widget? child) {
                return Container(
                  width: Layout.controlHSm,
                  height: Layout.controlHSm,
                  margin: const EdgeInsets.only(right: 2),
                  decoration: BoxDecoration(
                    color: Color.lerp(fadeFrom(p.frame3), p.frame3, t),
                    borderRadius: R.borderSm,
                  ),
                  child: Center(
                    child: AnimatedRotation(
                      turns: widget.quarterTurns / 4,
                      duration: Motion.dur3,
                      curve: Motion.ease,
                      child: LexIcon(
                        widget.icon,
                        size: 16,
                        color: Color.lerp(p.frameInk3, p.frameInk, t)!,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _StreakCard extends StatelessWidget {
  const _StreakCard({required this.streak, required this.today});

  final int streak;
  final int today;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.all(Sp.x3),
      // A filled block, no outline: on the stone frame a hairline border read
      // as a second edge next to the sidebar's own right edge. The figure is
      // the only thing here that needs weight, and it carries the display face
      // like every other figure in the app.
      decoration: BoxDecoration(
        color: p.frame2,
        borderRadius: R.borderLg,
      ),
      child: Row(
        children: [
          LexIcon(Ic.flame, size: 18, color: p.frameWarm),
          const SizedBox(width: Sp.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      '$streak',
                      style: TextStyle(
                        fontFamily: Fonts.display,
                        fontSize: Fs.xl,
                        height: Lh.title,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.02,
                        color: p.frameInk,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: Sp.x1),
                    Text(
                      context.t('stats.streakUnit'),
                      style: TextStyle(fontSize: Fs.xs, color: p.frameInk3),
                    ),
                  ],
                ),
                Text(
                  '${context.t('stats.reviewsToday')} $today',
                  style: TextStyle(fontSize: Fs.xs, height: Lh.snug, color: p.frameInk3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/* ------------------------------------------------------------------ */
/* Phone tab bar                                                       */
/* ------------------------------------------------------------------ */

class _TabBar extends StatelessWidget {
  const _TabBar({
    required this.vm,
    required this.onNavigate,
    required this.collapsed,
  });

  final ShellViewModel vm;
  final ValueChanged<PageId> onNavigate;

  /// Whether the page is scrolling down, in which case the bar folds itself
  /// into a floating capsule of icons and gives the page its bottom edge back.
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    // One number drives the whole fold, and it is a *number*, not a boolean.
    //
    // The first pass switched a `collapsed` flag and swapped subtrees on it:
    // the bar's surface jumped colour, the row's children traded `Expanded`
    // for fixed boxes, and a capsule appeared in place of the row on the same
    // frame. Everything that was "animating" was the two colours the slot
    // tweened; the object the user is supposed to watch — the bar becoming a
    // pill — was never actually drawn mid-way, so folding read as a cut, not
    // as motion. A boolean cannot express a shape that is halfway between a
    // bar and a capsule. `t` can: every property below is a lerp on it.
    //
    // The choreography is a single idea: the bar's surface *lifts off* the
    // bottom edge. At t = 0 the capsule is exactly as wide as the slot and
    // exactly the slot's colour, so it is invisible — it is the bar. As t
    // rises, the slot recedes to the page colour while the capsule keeps the
    // surface colour, narrows to five slots, and grows its shadow. A capsule
    // that starts as the bar itself cannot pop into existence, and there is no
    // frame where the user sees "the old bar with rounded ends".
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: collapsed ? 1 : 0),
      duration: Motion.dur4,
      curve: Motion.easeTurn,
      builder: (BuildContext context, double t, Widget? _) {
        final List<Widget> items = <Widget>[
          for (final item in PageId.values)
            _TabItem(
              item: item,
              active: vm.page == item,
              badge: item == PageId.practice && vm.dueCount > 0
                  ? vm.dueCount
                  : null,
              fold: t,
              onTap: () => onNavigate(item),
            ),
        ];

        // The five destinations are `Expanded` at every point of the fold. The
        // capsule's *own* width is what shrinks (below), so each expanded child
        // narrows with it and lands on exactly 48dp when the capsule is five
        // slots wide plus its padding. Nothing trades places mid-animation.
        final Widget row = Row(
          children: <Widget>[
            for (final Widget item in items) Expanded(child: item),
          ],
        );

        return Container(
          key: kTabBarKey,
          decoration: BoxDecoration(
            // A surface while it is a bar, and nothing at all once it has
            // lifted off. Folding to a *paper-coloured* strip is what the first
            // pass did, and it is why the result looked transparent: paper over
            // paper is indistinguishable from a hole, so the reader cannot tell
            // whether the page continues under the bar or stops at it. Going to
            // zero alpha settles that question — with `extendBody` the page
            // really does continue, and the capsule really is floating on it.
            //
            // `fadeFrom` and not `Colors.transparent`: lerping towards
            // transparent black drags the mid-points through grey, which on a
            // light theme is a stain the concept does not have.
            color: Color.lerp(p.surface, fadeFrom(p.surface), t),
            // A paper seam, fading out as the slot hands the bottom edge back.
            //
            // This replaces the stone `Border(top:)` the bar used to wear. It
            // exists to define the edge against a same-coloured page; a seam
            // drawn in stone under a paper bar is a dark line the design system
            // does not have.
            border: Border(
              top: BorderSide(color: Color.lerp(p.line, fadeFrom(p.line), t)!),
            ),
            boxShadow: _fadedShadows(Shadows.tabbarFor(p.isDark), 1 - t),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              // The capsule needs air under it, or it is not floating — it is a
              // pill glued to the bottom of the window. The margin opens up as
              // it folds rather than snapping on at the end.
              padding: EdgeInsets.only(
                left: Sp.x2,
                right: Sp.x2,
                top: _fold(Sp.x1, Sp.x2, t),
                bottom: _fold(Sp.x1, Sp.x2, t),
              ),
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  // Full width is whatever the slot offers; compact is five
                  // slots plus the capsule's own horizontal padding.
                  final double width = _fold(
                    constraints.maxWidth,
                    PageId.values.length * _barCapsuleItemW + 2 * Sp.x1,
                    t,
                  );
                  return Center(
                    // `heightFactor: 1` is load-bearing. A bare `Center`
                    // expands to the loose constraints the Scaffold hands its
                    // bottom bar — the full window height — which collapses the
                    // page's scroll viewport to 0 and takes the bar's whole
                    // strip out of the page. Sizing to the child keeps the bar
                    // as tall as the capsule and no taller.
                    heightFactor: 1.0,
                    child: Container(
                      key: kTabBarCapsuleKey,
                      width: width,
                      padding: EdgeInsets.symmetric(
                        horizontal: _fold(0, Sp.x1, t),
                        vertical: _fold(0, Sp.x1, t),
                      ),
                      decoration: BoxDecoration(
                        color: p.surface,
                        // Zero radius and a surface-coloured edge at t = 0:
                        // the capsule has no outline of its own until it has
                        // something to be outlined against.
                        borderRadius: BorderRadius.circular(_fold(0, R.pill, t)),
                        border: Border.all(
                          color: Color.lerp(p.surface, p.line, t)!,
                        ),
                        boxShadow: _fadedShadows(Shadows.popFor(p.isDark), t),
                      ),
                      child: row,
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Linear interpolation, the one primitive the tab bar's fold is built on.
double _fold(double from, double to, double t) => from + (to - from) * t;

/// A child that shrinks and fades as [fold] rises from 0 to 1, taking no space
/// once it is folded.
///
/// `heightFactor` on an [Align] is what makes "no space" continuous: the label
/// gives up its height a fraction at a time instead of being removed on a
/// frame. Without it the item's height would jump, and the bar's total height
/// is exactly what must not jump — it is the one piece of chrome whose size the
/// page below depends on.
Widget _folded({required double fold, required Widget child}) {
  final double t = fold.clamp(0.0, 1.0);
  return ClipRect(
    child: Align(
      alignment: Alignment.topCenter,
      heightFactor: 1 - t,
      child: Opacity(
        opacity: 1 - t,
        // Folded, the label is off the layout but still hit-testable through a
        // zero-height box; excluding it keeps taps on the gap from landing on a
        // text nobody can see.
        child: IgnorePointer(ignoring: t > 0.999, child: child),
      ),
    ),
  );
}

/// The same shadows, scaled towards invisible.
///
/// `BoxShadow` has no alpha knob and `scale` only touches geometry, so the
/// colour is rebuilt. Used to fade a shadow in with the fold instead of
/// switching it on at the last frame — a capsule that gains its shadow in one
/// frame has not finished folding, it has been replaced.
List<BoxShadow> _fadedShadows(List<BoxShadow> shadows, double alpha) {
  final double a = alpha.clamp(0.0, 1.0);
  return <BoxShadow>[
    for (final BoxShadow s in shadows)
      BoxShadow(
        color: s.color.withValues(alpha: s.color.a * a),
        offset: s.offset,
        blurRadius: s.blurRadius,
        spreadRadius: s.spreadRadius,
        blurStyle: s.blurStyle,
      ),
  ];
}

/// Width of one destination inside the collapsed capsule.
///
/// Fixed rather than intrinsic: five equal 48dp slots keep the icons on the
/// same rhythm as the expanded bar, and a fixed width is what lets the capsule
/// be narrower than the window without measuring text that is no longer drawn.
const double _barCapsuleItemW = 48.0;

class _TabItem extends StatelessWidget {
  const _TabItem({
    required this.item,
    required this.active,
    required this.badge,
    required this.fold,
    required this.onTap,
  });

  final PageId item;
  final bool active;
  final int? badge;

  /// How far the bar has folded into a capsule, 0 (bar) … 1 (capsule).
  ///
  /// A double rather than a flag because this widget has to be *midway* — its
  /// label half-folded, its icon part-way between 48dp and a full share of the
  /// width. The parent already tweens this value, so nothing here may run an
  /// implicit animation of its own: two clocks for one gesture is how a fold
  /// ends up with a part that arrives late.
  final double fold;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    // Paper ink now, not frame ink. The bar is part of the paper material in
    // both themes; `frameInk` was for the stone slab that used to sit here, and
    // on paper it is white-on-white.
    final Color color = active ? p.accent : p.ink3;
    // The current tab wears a capsule of accent-soft, exactly like the sidebar's
    // current row and the segmented control. A tint plus a 2dp rule was the
    // previous vocabulary — a third one, since nothing else in the app marked a
    // selection with a line under it — and at phone size the rule read as an
    // underline belonging to the label rather than as "you are here".
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        constraints: BoxConstraints(
          minHeight: _fold(52, Layout.tap, fold),
        ),
        margin: EdgeInsets.symmetric(
          horizontal: 2 * (1 - fold),
          vertical: Sp.x1 * (1 - fold),
        ),
        // The folded capsule is 48dp wide with 8dp of its own padding, so the
        // item has to give up its horizontal padding or the 30dp icon box would
        // not fit inside it.
        padding: EdgeInsets.symmetric(
          vertical: Sp.x1,
          horizontal: _fold(Sp.x2, Sp.x1, fold),
        ),
        decoration: BoxDecoration(
          color: active ? p.accentSoft : fadeFrom(p.accentSoft),
          borderRadius: R.borderPill,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 30,
              height: 24,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  AnimatedScale(
                    // A 4% lift on selection. Small enough that it reads as
                    // "this one" rather than as a bounce, which the design
                    // system forbids — nothing overshoots.
                    scale: active ? 1.04 : 1.0,
                    duration: Motion.dur2,
                    curve: Motion.easeOut,
                    child: LexIcon(_iconFor(item), size: 21, color: color),
                  ),
                  if (badge != null)
                    Positioned(
                      // A count is a footnote, not an alarm. It used to sit at
                      // top -5 / right -8 of a 30×24 box, parked half outside the
                      // icon and filled with the accent, so on an inactive tab it
                      // was the loudest thing on the bar. It now sits inside the
                      // icon's own box at a size the eye reaches only after the
                      // destination, and it picks up the accent only when its tab
                      // is the current one.
                      top: -4,
                      right: -6,
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 15),
                        height: 15,
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: BoxDecoration(
                          // Paper palette: the count is a quiet footnote filled
                          // with the accent when its tab is current, and a
                          // sunken chip otherwise. `frame3` was the stone
                          // version of that chip and is a black dot here.
                          color: active ? p.accent : p.surface2,
                          borderRadius: BorderRadius.circular(R.full),
                        ),
                        child: Center(
                          child: Text(
                            badge! > 99 ? '99+' : '$badge',
                            style: TextStyle(
                              fontSize: 10,
                              height: 1,
                              fontWeight: FontWeight.w600,
                              color: active ? p.onAccent : p.ink3,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // Folded, the capsule is icons only — a 48dp column cannot hold a
            // label, and five stacked labels are what made the collapsed state
            // look like the old bar wearing a border radius.
            //
            // It folds rather than switching off. The label's height and its
            // opacity are both lerps on `fold`, so the bar loses its second
            // line over the same 420ms as everything else. Cutting it on the
            // frame the flag flipped was half of why folding read as a cut:
            // five labels vanished while the surface was still mid-tween.
            //
            // At rest it is dropped from the tree entirely, which is what makes
            // "folded" mean folded: an invisible label still occupies a text
            // layout box and still answers `find.text`.
            if (fold < 1)
              _folded(
                fold: fold,
                child: Padding(
                  padding: const EdgeInsets.only(top: Sp.x1),
                  child: Text(
                    context.t(item.labelKey),
                    // Five destinations on a 320dp phone leave ~34dp of text
                    // column once the pill's padding is taken. A CJK label is
                    // two glyphs and fits; a longer Latin one has to ellipsize
                    // rather than wrap, because a wrapped label would grow the
                    // bar and the bar is the one piece of chrome that must not
                    // change height with language.
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: Fs.xs,
                      height: Lh.title,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                      letterSpacing: 0.01,
                      color: color,
                    ),
                  ),
                ),
              ),
            // The capsule behind the whole tab is the selection mark now, so the
            // 2dp rule that used to sit under the label is gone: two marks for
            // one state is how a bar starts looking decorated.
          ],
        ),
      ),
    );
  }
}

/* ------------------------------------------------------------------ */
/* Shortcut sheet                                                      */
/* ------------------------------------------------------------------ */

/// The `?` sheet. Public so a page can open it (the settings page links here).
class ShortcutSheet extends StatelessWidget {
  const ShortcutSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final row in kShortcutHelp)
          ShortcutRow(keys: row.keys, label: context.t(row.labelKey)),
        const SizedBox(height: Sp.x4),
        Container(
          padding: const EdgeInsets.all(Sp.x3),
          decoration: BoxDecoration(
            color: p.surface2,
            borderRadius: R.borderSm,
            border: Border.all(color: p.line),
          ),
          child: Row(
            children: [
              LexIcon(Ic.info, size: 15, color: p.ink3),
              const SizedBox(width: Sp.x2),
              Expanded(
                child: Text(
                  context.t('shell.shortcutsTypingHint'),
                  style: TextStyle(fontSize: Fs.sm, height: Lh.snug, color: p.ink2),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Shown once on the first frame of the shell so the help sheet is reachable
/// from the keyboard alone.
Future<void> showShortcutSheet(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      final p = Palette.of(ctx);
      return Dialog(
        backgroundColor: p.surface,
        shape: const RoundedRectangleBorder(borderRadius: R.borderLg),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(Sp.x6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  ctx.t('settings.shortcuts'),
                  style: TextStyle(
                    fontFamily: Fonts.display,
                    fontSize: Fs.lg,
                    height: Lh.title,
                    fontWeight: FontWeight.w600,
                    color: p.ink,
                  ),
                ),
                const SizedBox(height: Sp.x1),
                Text(
                  ctx.t('shell.shortcutsSub'),
                  style: TextStyle(fontSize: Fs.sm, color: p.ink3, height: Lh.snug),
                ),
                const SizedBox(height: Sp.x4),
                const ShortcutSheet(),
                const SizedBox(height: Sp.x5),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _PrimaryButton(
                      label: ctx.t('common.gotIt'),
                      onTap: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          height: Layout.controlH,
          padding: const EdgeInsets.symmetric(horizontal: Sp.x4),
          decoration: BoxDecoration(color: p.accent, borderRadius: R.borderMd),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: Fs.base,
                fontWeight: FontWeight.w500,
                color: p.onAccent,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
