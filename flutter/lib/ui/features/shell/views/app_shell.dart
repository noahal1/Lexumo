/// The app shell: navigation rail, page switching, theme, global shortcuts.
///
/// Mirrors `src/App.tsx`. Three layout modes, chosen by width exactly as the CSS
/// media queries did:
///
///   · wide (>1000px)   — stone sidebar with labels,
///   · rail (≤1000px)   — the same sidebar collapsed to icons,
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

import '../../../core/tokens.dart';
import '../../../core/widgets/density.dart';
import '../../../core/widgets/keyboard_hints.dart';
import '../../../core/widgets/lex_icon.dart';
import '../../../core/widgets/widgets.dart';
import '../../../../app/scope.dart';
import '../../../core/context_feedback.dart';
import '../../flashcards/views/flashcards_page.dart';
import '../../quiz/views/quiz_page.dart';
import '../../settings/views/settings_page.dart';
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

/// The icon for a destination.
///
/// Kept out of [PageId] on purpose: `PageId` lives in the view-model layer,
/// which may not import `widgets`, and an icon name is only meaningful to
/// [LexIcon]. The switch is exhaustive, so a new destination cannot be added
/// without giving it an icon.
String _iconFor(PageId page) => switch (page) {
      PageId.words => Ic.words,
      PageId.flashcards => Ic.cards,
      PageId.quiz => Ic.quiz,
      PageId.stats => Ic.stats,
      PageId.settings => Ic.settings,
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

/// The five digit keys behind Ctrl/Cmd+1…5, in page order. Spelled out because
/// `LogicalKeyboardKey.digit1 + i` is not arithmetic the type allows.
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

  ScrollController _scrollerFor(PageId page) =>
      _scrollers.putIfAbsent(page, ScrollController.new);

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
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final mobile = width <= Layout.mobileBreakpoint;
    final narrow = width <= Layout.railBreakpoint;

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
            child: Scaffold(
              backgroundColor: Palette.of(context).frame,
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
                      child: Container(
                        // The paper.
                        color: Palette.of(context).bg,
                        child: _pageFor(page),
                      ),
                    ),
                  ],
                ),
              ),
              bottomNavigationBar:
                  mobile ? _TabBar(vm: _vm, onNavigate: _navigate) : null,
              floatingActionButton: null,
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
        PageId.words => WordsPage(controller: controller),
        PageId.flashcards => FlashcardsPage(controller: controller),
        PageId.quiz => QuizPage(controller: controller),
        PageId.stats => StatsPage(controller: controller),
        PageId.settings => SettingsPage(controller: controller),
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
        icon: rail ? Ic.chevronRight : Ic.chevronLeft,
        tooltip: rail ? context.t('shell.expandRail') : context.t('shell.collapseRail'),
        onTap: () => vm.toggleRail(narrow),
      ),
    ];

    return AnimatedContainer(
      // Named so a test can measure the sidebar itself rather than whichever
      // AnimatedContainer happens to come first in the tree.
      key: kSidebarKey,
      duration: const Duration(milliseconds: 160),
      width: rail ? Layout.sidebarRailW : Layout.sidebarW,
      decoration: BoxDecoration(
        color: p.frame,
        border: Border(right: BorderSide(color: p.frameLine)),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: Sp.x5, horizontal: rail ? Sp.x2 : Sp.x3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final item in PageId.values)
              _NavItem(
                item: item,
                active: vm.page == item,
                rail: rail,
                badge: item == PageId.flashcards && vm.dueCount > 0
                    ? vm.dueCount
                    : null,
                onTap: () => onNavigate(item),
              ),
            const Spacer(),
            if (!rail) ...[
              _StreakCard(streak: stats.streak, today: stats.today),
              const SizedBox(height: Sp.x2),
            ],
            // The footer buttons cannot sit side by side in the 64dp rail:
            // the rail's inner width is 64 - 2*8 padding - 1 border = 47dp,
            // while three 44dp touch targets need 132 — an 85dp overflow that
            // only appears on touch platforms, which is why the desktop-width
            // tests never saw it. Stacked, each button gets the full width and
            // the footer's axis becomes the only thing that changes. The web
            // build made the same call for the same reason (global.css: "The
            // footer buttons cannot sit side by side in a 64px rail — stack
            // them"). One list, two axes, so the buttons cannot drift apart.
            rail
                ? Column(mainAxisSize: MainAxisSize.min, children: footerButtons)
                : Row(children: footerButtons),
            if (!rail) ...[
              const SizedBox(height: Sp.x2),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Sp.x2),
                child: Text(
                  context.t('common.appTagline'),
                  style: TextStyle(fontSize: Fs.xs, height: Lh.body, color: p.frameInk3),
                ),
              ),
            ],
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

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final active = widget.active;
    final bg = active || _hover ? (active ? p.frame3 : p.frame2) : Colors.transparent;
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
                fontSize: Fs.md,
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
              height: Layout.controlH,
              padding: EdgeInsets.symmetric(horizontal: Sp.x2),
              decoration: BoxDecoration(color: bg, borderRadius: R.borderSm),
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  row,
                  // The azurite hairline that marks the current page.
                  if (active)
                    Positioned(
                      left: -Sp.x2,
                      child: Container(
                        width: 2,
                        height: 16,
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
  const _SidebarButton({required this.icon, required this.tooltip, required this.onTap});

  final String icon;
  final String tooltip;
  final VoidCallback onTap;

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
            child: Container(
              width: Layout.controlHSm,
              height: Layout.controlHSm,
              margin: const EdgeInsets.only(right: 2),
              decoration: BoxDecoration(
                color: _hover ? p.frame3 : Colors.transparent,
                borderRadius: R.borderSm,
              ),
              child: Center(
                child: LexIcon(
                  widget.icon,
                  size: 16,
                  color: _hover ? p.frameInk : p.frameInk3,
                ),
              ),
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
      decoration: BoxDecoration(
        color: p.frame2,
        borderRadius: R.borderMd,
        border: Border.all(color: p.frameLine),
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
                        fontSize: Fs.lg,
                        height: Lh.title,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.1,
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
  const _TabBar({required this.vm, required this.onNavigate});

  final ShellViewModel vm;
  final ValueChanged<PageId> onNavigate;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      decoration: BoxDecoration(
        color: p.frame,
        border: Border(top: BorderSide(color: p.frameLine)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Sp.x2, vertical: Sp.x1),
          child: Row(
            children: [
              for (final item in PageId.values)
                Expanded(
                  child: _TabItem(
                    item: item,
                    active: vm.page == item,
                    badge: item == PageId.flashcards && vm.dueCount > 0
                        ? vm.dueCount
                        : null,
                    onTap: () => onNavigate(item),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  const _TabItem({required this.item, required this.active, required this.badge, required this.onTap});

  final PageId item;
  final bool active;
  final int? badge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final color = active ? p.frameAccent : p.frameInk3;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsets.symmetric(vertical: Sp.x1, horizontal: Sp.x2),
        decoration: BoxDecoration(
          color: active ? p.frame3 : Colors.transparent,
          borderRadius: R.borderMd,
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
                  LexIcon(_iconFor(item), size: 21, color: color),
                  if (badge != null)
                    Positioned(
                      top: -5,
                      right: -8,
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 17),
                        height: 17,
                        padding: const EdgeInsets.symmetric(horizontal: Sp.x1),
                        decoration: BoxDecoration(
                          color: p.frameAccent,
                          borderRadius: BorderRadius.circular(R.full),
                        ),
                        child: Center(
                          child: Text(
                            badge! > 99 ? '99+' : '$badge',
                            style: TextStyle(
                              fontSize: Fs.xs,
                              height: 1,
                              fontWeight: FontWeight.w600,
                              color: p.frame2,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: Sp.x1),
            Text(
              context.t(item.labelKey),
              style: TextStyle(
                fontSize: Fs.xs,
                height: Lh.title,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
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
