/// The profile destination — 「我的」.
///
/// Laid out from the reference design: an identity block, three centred
/// figures, the two bulk actions, and a card that points at the desktop build.
///
/// Two deliberate departures from the reference, both to keep the product one
/// design rather than two:
///
///  * The reference sits on a warmer cream and prints its numerals in cobalt.
///    This page wears the app's own paper and azurite instead. Copying the
///    reference's colours would make one screen a different product from the
///    four beside it in the same tab bar; the *structure* is what carries the
///    design, and that is copied faithfully.
///  * The reference's 设置 is a destination of its own. Here settings is
///    already a page, so it is a row that pushes it — the same route the
///    account sheet already uses.
///
/// Everything the screen reads comes from [ProfileViewModel]; this file spells
/// labels and lays out widgets.
library;

import 'dart:async';
import 'dart:io';

// `Card` is ours (ui/widgets.dart), not Material's.
import 'package:flutter/material.dart' hide Card;
import 'package:flutter/services.dart';

import '../../../../app/scope.dart';
import '../../../../app/update_scope.dart';
import '../../../../data/repositories/onboarding_store.dart';
import '../../../../data/services/app_dir.dart';
import '../../../../data/services/transfer.dart';
import '../../../core/context_feedback.dart';
import '../../../core/tokens.dart';
import '../../../core/widgets/controls.dart';
import '../../../core/widgets/entrance.dart';
import '../../../core/widgets/lex_icon.dart';
import '../../../core/widgets/widgets.dart';
import '../../onboarding/views/onboarding_page.dart';
import '../../settings/views/settings_page.dart';
import '../view_models/profile_view_model.dart';

/// Where the desktop build is published.
///
/// The same repository the update manifest already points at
/// (`UpdateService.manifestUrl`), so there is one address for "another build of
/// this app" rather than two that can drift.
const String _kReleasesUrl = 'https://github.com/noahal1/Lexumo/releases';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key, this.controller});

  /// Owned by the shell, so the scroll offset survives a page switch.
  final ScrollController? controller;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late final ProfileViewModel _vm;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _vm = ProfileViewModel(
      store: context.store,
      feedback: ContextFeedback(context),
      importPrompt: _previewImport,
    );
  }

  @override
  void dispose() {
    _vm.dispose();
    super.dispose();
  }

  /// Shows what an import would add before it is committed.
  ///
  /// Same shape as the settings sheet: the chips say what was recognised, which
  /// is the one thing the user cannot otherwise check — a CSV parsed as Anki
  /// looks identical once it is in the library.
  Future<bool> _previewImport(ProfileImportRequest request) async {
    final confirmed = await showLexModal<bool>(
      context: context,
      title: context.t('settings.importPreviewTitle'),
      subtitle: '${request.fileName} · ${request.formatLabel}',
      width: 520,
      body: _ImportPreview(result: request.result),
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
          LexButton(
            label: context.t('common.cancel'),
            kind: BtnKind.ghost,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          const SizedBox(width: Sp.x2),
          LexButton(
            label: '${context.t('common.import')} · ${request.result.words.length}',
            kind: BtnKind.primary,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _import() async {
    if (_busy) return;
    setState(() => _busy = true);
    await _vm.pickImport();
    if (mounted) setState(() => _busy = false);
  }

  /// Pushes the settings page over the shell.
  ///
  /// [SettingsPage] has no chrome of its own — it is a shell destination, not a
  /// route — so the route supplies a bar with a way back. This mirrors
  /// `SettingsPage._openSignIn`, which pushes the onboarding page the same way.
  Future<void> _openSettings() {
    final p = Palette.of(context);
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => Scaffold(
          backgroundColor: p.bg,
          body: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _PushBar(
                  title: context.t('nav.settings'),
                  onBack: () => Navigator.of(routeContext).pop(),
                ),
                const Expanded(child: SettingsPage()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Opens the first-run gate again, so a device set up as local can change
  /// its mind without the reader having to know the button lives in settings.
  ///
  /// Same route [SettingsPage._openSignIn] uses: the sidecar store is rebuilt
  /// here (one small file read), and [OnboardingPage.onConfigured] only pops —
  /// the shell is already underneath and the identity row rebuilds through the
  /// sync scope's subscription.
  Future<void> _openSignIn() async {
    final engine = SyncScope.engineWithoutDeps(context);
    if (engine == null) return;
    final store = FileOnboardingStore(
      '${AppDir.dataDir}${Platform.pathSeparator}onboarding.json',
    );
    unawaited(store.load());
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => OnboardingPage(
          engine: engine,
          onboarding: store,
          onConfigured: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _vm,
      builder: (BuildContext context, Widget? _) {
        final vm = _vm;
        return PageShell(
          controller: widget.controller,
          children: _stacked(<Widget>[
            _Identity(
              email: context.syncStatus?.email ?? '',
              listCount: vm.listCount,
              onSignIn: _openSignIn,
            ),
            _FigureRow(
              today: vm.today,
              streak: vm.streak,
              total: vm.total,
            ),
            _ActionList(
              onImport: _import,
              onSettings: _openSettings,
              importBusy: _busy,
            ),
            // "About" is a flat row like the two above it — keeping the three
            // together lets them read as one run of destinations. The desktop
            // notice is an aside in a box, not a destination; last, so it
            // cannot split that run the way it did between the rows and here.
            _AboutRow(
              version: context.updateState?.current?.name.toString() ?? '—',
              onTap: _showAbout,
            ),
            _DesktopCard(onTap: () => _showReleases()),
          ]),
        );
      },
    );
  }

  /// Copies the releases address.
  ///
  /// Guarded by `mounted` on the State rather than on a captured context: the
  /// await is a platform round trip, and this State is the only thing that
  /// knows whether the sheet is still up.
  Future<void> _copyLink() async {
    await Clipboard.setData(const ClipboardData(text: _kReleasesUrl));
    if (!mounted) return;
    context.toast(context.t('profile.linkCopied'), ToastKind.ok);
  }

  /// The desktop card is a promise this build cannot keep by itself — there is
  /// no URL launcher in the dependency set — so it hands over the address
  /// instead of pretending to navigate.
  void _showReleases() {
    showLexModal<void>(
      context: context,
      title: context.t('profile.desktopAction'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            context.t('profile.desktopBody'),
            style: TextStyle(
              fontSize: Fs.base,
              height: Lh.body,
              color: Palette.of(context).ink2,
            ),
          ),
          const SizedBox(height: Sp.x4),
          _LinkBox(url: _kReleasesUrl),
        ],
      ),
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
          LexButton(
            label: context.t('profile.copyLink'),
            icon: Ic.layers,
            onPressed: _copyLink,
          ),
          const SizedBox(width: Sp.x2),
          LexButton(
            label: context.t('common.close'),
            kind: BtnKind.primary,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  void _showAbout() {
    final p = Palette.of(context);
    final version = context.updateState?.current?.name.toString() ?? '—';
    showLexModal<void>(
      context: context,
      title: context.t('profile.about', {'app': context.t('common.appName')}),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _AboutLine(
            label: context.t('settings.version'),
            value: version,
          ),
          const SizedBox(height: Sp.x4),
          Text(
            context.t('profile.releases'),
            style: TextStyle(
              fontSize: Fs.sm,
              height: Lh.snug,
              fontWeight: FontWeight.w600,
              color: p.ink2,
            ),
          ),
          const SizedBox(height: Sp.x2),
          _LinkBox(url: _kReleasesUrl),
        ],
      ),
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
          LexButton(
            label: context.t('profile.copyLink'),
            icon: Ic.layers,
            onPressed: _copyLink,
          ),
          const SizedBox(width: Sp.x2),
          LexButton(
            label: context.t('common.close'),
            kind: BtnKind.primary,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

/// Join [blocks] with the page's vertical rhythm, and stagger them in.
///
/// Same helper shape as the home dashboard: one controller per block rather
/// than a timer, so `pumpAndSettle` still returns.
List<Widget> _stacked(List<Widget> blocks) {
  final out = <Widget>[];
  for (var i = 0; i < blocks.length; i++) {
    if (i > 0) out.add(const SizedBox(height: Sp.x5));
    out.add(
      FadeRise(
        offset: 8,
        delay: Motion.stagger * (i < 6 ? i : 6),
        child: blocks[i],
      ),
    );
  }
  return out;
}

/* ------------------------------------------------------------------ */
/* Identity                                                            */
/* ------------------------------------------------------------------ */

/// Who this library belongs to.
///
/// The reference shows a name and an email. This app has no profile model —
/// the only identity it owns is the sync session's address — so the name is
/// derived from the address's local part, and a signed-out build says so
/// rather than inventing a person.
class _Identity extends StatelessWidget {
  const _Identity({
    required this.email,
    required this.listCount,
    required this.onSignIn,
  });

  final String email;
  final int listCount;
  final VoidCallback onSignIn;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final bool signedIn = email.isNotEmpty;
    final String title =
        signedIn ? _localPart(email) : context.t('common.appName');
    final String subtitle = signedIn
        ? email
        : context.t('settings.syncStatusSignedOut');

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        _Avatar(
          initial: title.characters.first.toUpperCase(),
          signedIn: signedIn,
        ),
        const SizedBox(width: Sp.x4),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: Fonts.ui,
                  fontSize: Fs.xl,
                  height: Lh.tight,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.01,
                  color: p.ink,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: Fonts.ui,
                  fontSize: Fs.sm,
                  height: Lh.snug,
                  color: p.ink3,
                ),
              ),
              // Signed out used to say only "未登录" and leave the way back in
              // a settings section two taps away. The first-run gate already
              // owns that flow; a small primary button here puts it where the
              // identity itself is, which is where a reader looks for it.
              if (!signedIn) ...<Widget>[
                const SizedBox(height: Sp.x3),
                LexButton(
                  label: context.t('settings.syncSignIn'),
                  kind: BtnKind.primary,
                  size: BtnSize.sm,
                  onPressed: onSignIn,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// `coolzhaobo@gmail.com` → `coolzhaobo`.
  static String _localPart(String email) {
    final at = email.indexOf('@');
    return at <= 0 ? email : email.substring(0, at);
  }
}

/// The circle at the top left: an initial, or a bare person glyph when there is
/// no address to initial.
class _Avatar extends StatelessWidget {
  const _Avatar({required this.initial, required this.signedIn});

  final String initial;
  final bool signedIn;

  static const double _size = 64;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        color: p.accentSoft,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: signedIn
          // Serif on purpose: it is the one glyph on the page that stands for a
          // person, not for data.
          ? Text(
              initial,
              style: TextStyle(
                fontFamily: Fonts.display,
                fontSize: 28,
                height: Lh.none,
                fontWeight: FontWeight.w600,
                color: p.accentInk,
              ),
            )
          : LexIcon(Ic.person, size: 26, color: p.accentInk),
    );
  }
}

/* ------------------------------------------------------------------ */
/* Figures                                                             */
/* ------------------------------------------------------------------ */

/// Three figures, centred in equal columns, with no rules between them.
///
/// The reference separates them with whitespace alone and prints the numbers in
/// the display face at a size the page has nowhere else — that contrast is what
/// makes them read as the page's headline rather than as three more labels.
class _FigureRow extends StatelessWidget {
  const _FigureRow({
    required this.today,
    required this.streak,
    required this.total,
  });

  final int today;
  final int streak;
  final int total;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final figures = <(String, String)>[
      (context.t('stats.reviewsToday'), '$today'),
      (context.t('stats.streak'), '$streak'),
      (context.t('stats.totalWords'), '$total'),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(vertical: Sp.x5, horizontal: Sp.x3),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: R.borderLg,
        border: Border.all(color: p.line),
      ),
      child: Row(
        children: <Widget>[
          for (final (label, value) in figures)
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    value,
                    style: TextStyle(
                      fontFamily: Fonts.display,
                      fontSize: Fs.x2xl,
                      height: Lh.none,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.02,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                      color: p.accent,
                    ),
                  ),
                  const SizedBox(height: Sp.x2),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: Fonts.ui,
                      fontSize: Fs.xs,
                      height: Lh.snug,
                      color: p.ink3,
                    ),
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
/* Rows                                                                */
/* ------------------------------------------------------------------ */

/// A flat, tappable row: bare glyph, two lines of text, a chevron.
///
/// No card and no divider, as in the reference — the rows read as a list
/// because of their height and their shared left edge, not because something
/// draws a box around them.
class _ActionRow extends StatefulWidget {
  const _ActionRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.busy = false,
  });

  final String icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  /// An import is a file picker plus a parse, with no visible progress today.
  /// While it runs the row stays named but shows a spinner and stops answering
  /// taps, so a second tap cannot open a second picker over the first.
  final bool busy;

  @override
  State<_ActionRow> createState() => _ActionRowState();
}

class _ActionRowState extends State<_ActionRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return KeyFocus(
      label: widget.title,
      enabled: !widget.busy,
      onActivate: widget.onTap,
      builder: (bool focused) => MouseRegion(
        cursor: widget.busy ? SystemMouseCursors.basic : SystemMouseCursors.click,
        onEnter: widget.busy ? null : (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.busy ? null : widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            constraints: const BoxConstraints(minHeight: Layout.tap),
            padding: const EdgeInsets.symmetric(horizontal: Sp.x2, vertical: Sp.x3),
            decoration: BoxDecoration(
              color: _hover && !widget.busy ? p.surfaceHover : fadeFrom(p.surfaceHover),
              borderRadius: R.borderMd,
              // At rest these rows are flat: the design forbids any box edge
              // around them. A focus ring is drawn only while the row actually
              // holds keyboard focus, and `Border.all` strokes inside so the
              // row's height does not change when the ring appears.
              border: focused
                  ? Border.all(color: p.accent, width: 2)
                  : null,
            ),
          child: Row(
            children: <Widget>[
              LexIcon(widget.icon, size: 21, color: p.ink),
              const SizedBox(width: Sp.x4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: Fonts.ui,
                        fontSize: Fs.base,
                        height: Lh.snug,
                        fontWeight: FontWeight.w600,
                        color: p.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: Fonts.ui,
                        fontSize: Fs.sm,
                        height: Lh.snug,
                        color: p.ink3,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Sp.x1),
              if (widget.busy)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: p.accent),
                )
              else
                LexIcon(Ic.chevronRight, size: 16, color: p.ink4),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

/// The two bulk actions, and the way into settings.
class _ActionList extends StatelessWidget {
  const _ActionList({
    required this.onImport,
    required this.onSettings,
    this.importBusy = false,
  });

  final VoidCallback onImport;
  final VoidCallback onSettings;
  final bool importBusy;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _ActionRow(
          icon: Ic.upload,
          title: context.t('profile.importTitle'),
          subtitle: context.t('profile.importHint'),
          onTap: onImport,
          busy: importBusy,
        ),
        _ActionRow(
          icon: Ic.settings,
          title: context.t('nav.settings'),
          subtitle: context.t('profile.settingsHint'),
          onTap: onSettings,
        ),
      ],
    );
  }
}

/* ------------------------------------------------------------------ */
/* Desktop card                                                        */
/* ------------------------------------------------------------------ */

/// The one card on the page that is not a figure.
///
/// The reference makes the whole card the tap target and lets the chevron be
/// the only affordance; there is no button inside it, so nothing here competes
/// with the rows above for "the thing to press".
class _DesktopCard extends StatefulWidget {
  const _DesktopCard({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_DesktopCard> createState() => _DesktopCardState();
}

class _DesktopCardState extends State<_DesktopCard> {
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
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x4),
          decoration: BoxDecoration(
            color: _hover ? p.surfaceHover : p.surface,
            borderRadius: R.borderLg,
            border: Border.all(color: p.line),
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: p.accentSoft,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: LexIcon(Ic.monitor, size: 22, color: p.accentInk),
              ),
              const SizedBox(width: Sp.x4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      context.t('profile.desktopTitle'),
                      style: TextStyle(
                        fontFamily: Fonts.ui,
                        fontSize: Fs.base,
                        height: Lh.snug,
                        fontWeight: FontWeight.w600,
                        color: p.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      context.t('profile.desktopBody'),
                      style: TextStyle(
                        fontFamily: Fonts.ui,
                        fontSize: Fs.sm,
                        height: Lh.snug,
                        color: p.ink3,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Sp.x3),
              LexIcon(Ic.chevronRight, size: 16, color: p.ink4),
            ],
          ),
        ),
      ),
    );
  }
}

/* ------------------------------------------------------------------ */
/* About                                                               */
/* ------------------------------------------------------------------ */

/// The footer row. Quiet by design: it is the last thing on the page and says
/// so with muted type and no box.
class _AboutRow extends StatelessWidget {
  const _AboutRow({required this.version, required this.onTap});

  final String version;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _ActionRow(
      icon: Ic.info,
      title: context.t('profile.about', {'app': context.t('common.appName')}),
      // The subtitle *is* the version number. The trailing "版本" label used to
      // print the word a second time next to the very number it names — one
      // figure, one place. The about sheet still spells out the label/value
      // pair for anyone who wants it.
      subtitle: version,
      onTap: onTap,
    );
  }
}

/// A read-only line of text in the about sheet.
class _AboutLine extends StatelessWidget {
  const _AboutLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Row(
      children: <Widget>[
        Text(
          label,
          style: TextStyle(fontSize: Fs.sm, color: p.ink3),
        ),
        const SizedBox(width: Sp.x3),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: TextStyle(
              fontFamily: Fonts.mono,
              fontSize: Fs.sm,
              height: Lh.tight,
              color: p.ink2,
            ),
          ),
        ),
      ],
    );
  }
}

/// An address the user has to retype or copy, set in the mono face so it cannot
/// be mistaken for prose.
class _LinkBox extends StatelessWidget {
  const _LinkBox({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: Sp.x3),
      decoration: BoxDecoration(
        color: p.surface2,
        borderRadius: R.borderMd,
        border: Border.all(color: p.line),
      ),
      child: SelectableText(
        url,
        style: TextStyle(
          fontFamily: Fonts.mono,
          fontSize: Fs.sm,
          height: Lh.snug,
          color: p.ink2,
        ),
      ),
    );
  }
}

/// The bar over a pushed page: a way back and the page's name.
///
/// [SettingsPage] is a shell destination and has no header of its own, so the
/// route supplies one.
class _PushBar extends StatelessWidget {
  const _PushBar({required this.title, required this.onBack});

  /// Lets a test (and a future tour) name the way back.
  static const Key backKey = ValueKey<String>('profile-push-back');

  final String title;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        border: Border(bottom: BorderSide(color: p.line)),
      ),
      padding: const EdgeInsetsDirectional.only(
        start: Sp.x2,
        end: Sp.x6,
        top: Sp.x2,
        bottom: Sp.x2,
      ),
      child: Row(
        children: <Widget>[
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              key: _PushBar.backKey,
              onTap: onBack,
              behavior: HitTestBehavior.opaque,
              child: SizedBox(
                width: Layout.tap,
                height: Layout.tap,
                child: Center(
                  child: LexIcon(Ic.chevronLeft, size: 20, color: p.ink2),
                ),
              ),
            ),
          ),
          const SizedBox(width: Sp.x1),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: Fonts.display,
                fontSize: Fs.md,
                height: Lh.tight,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.005,
                color: p.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What an import would add, shown before it is committed.
///
/// Caps the visible rows at [_previewRows] and counts the rest: a file with nine
/// hundred words should not push the confirm button off the screen, and the
/// exact number matters more than the tail of the list.
class _ImportPreview extends StatelessWidget {
  const _ImportPreview({required this.result});

  final ImportResult result;

  static const int _previewRows = 8;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final shown = result.words.take(_previewRows).toList();
    final remaining = result.words.length - shown.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Wrap(
          spacing: Sp.x2,
          runSpacing: Sp.x2,
          children: <Widget>[
            StatusChip(
              label: context.t('settings.importWordsCount', {'n': result.words.length}),
              tone: 'accent',
            ),
            if (result.skipped > 0)
              StatusChip(
                label: context.t('settings.importRowsSkipped', {'n': result.skipped}),
                tone: 'warn',
              ),
          ],
        ),
        const SizedBox(height: Sp.x4),
        for (final word in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: Sp.x2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  width: 180,
                  child: Text(
                    word.term,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: Fonts.ui,
                      fontSize: Fs.base,
                      height: Lh.snug,
                      fontWeight: FontWeight.w500,
                      color: p.ink,
                    ),
                  ),
                ),
                const SizedBox(width: Sp.x3),
                Expanded(
                  child: Text(
                    (word.definition ?? '').isEmpty ? '—' : word.definition!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: Fonts.ui,
                      fontSize: Fs.sm,
                      height: Lh.snug,
                      color: p.ink3,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (remaining > 0)
          Padding(
            padding: const EdgeInsets.only(top: Sp.x1),
            child: Text(
              context.t('settings.importMore', {'n': remaining}),
              style: TextStyle(
                fontFamily: Fonts.ui,
                fontSize: Fs.xs,
                height: Lh.snug,
                color: p.ink4,
              ),
            ),
          ),
      ],
    );
  }
}
