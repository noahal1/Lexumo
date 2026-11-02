/// Shared UI primitives, ported from `src/components/ui.tsx`.
///
/// The web build had one file of small building blocks that every page used so
/// headers, empty states and progress read the same everywhere. The Flutter
/// port keeps that arrangement, with the Material widgets that already match a
/// primitive (Switch, Slider) left out — those come from the `ThemeData` in
/// `design/theme.dart` instead of being rebuilt here.
library;

import 'package:flutter/material.dart';

import '../tokens.dart';
import 'density.dart';
import 'entrance.dart';
import 'lex_icon.dart';

/// The page shell every screen uses: one scrolling body, nothing above it.
///
/// It used to open every page with a sticky bar carrying a 30dp serif title and
/// a one-line subtitle. Both are gone. The shell's own navigation already names
/// the page — the sidebar's active row, the phone tab bar's selected tab — so a
/// title repeated the one thing the screen had just told you, and on a phone it
/// spent the first ~77dp of an 866dp screen doing it. The subtitle was worse: it
/// counted things the body counts again one block below.
///
/// What survives is the body, which still expands rather than scrolls the whole
/// page, so the phone tab bar can sit underneath without anyone measuring.
class PageShell extends StatelessWidget {
  const PageShell({
    super.key,
    this.actions,
    required this.children,
    this.wide = false,
    this.controller,
    this.fab,
    this.bleed = false,
  });

  /// A page-level action, drawn at the top of the body and aligned to its end.
  ///
  /// It lives inside the scroll view, not in chrome above it: an action belongs
  /// to the content it acts on, and a button pinned above a list scrolls away
  /// from the list's own idea of where it is. Only the pages that genuinely
  /// have one page-wide action pass this — a button that duplicates something
  /// already in the body is not an action, it is a second copy.
  final Widget? actions;
  final List<Widget> children;

  /// `wide` widens the content column from [Layout.contentMax] to 1360.
  final bool wide;
  final ScrollController? controller;

  /// A [FloatingAction] to hang over the bottom-right corner.
  final Widget? fab;

  /// Drop the body's horizontal padding so a [HairlineList] can run from the
  /// window edge to the window edge, which is what the reference does. The
  /// header keeps its own padding either way.
  final bool bleed;

  @override
  Widget build(BuildContext context) {
    final maxWidth = wide ? 1360.0 : Layout.contentMax;
    // The action row sits inside the scroll view so it scrolls with the content
    // it acts on. `bleed` pages draw their lists edge to edge, so the row keeps
    // its own gutter rather than inheriting the body's (absent) padding.
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Scrollbar(
            controller: controller,
            child: SingleChildScrollView(
              controller: controller,
              padding: EdgeInsets.zero,
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: Padding(
                    padding: EdgeInsetsDirectional.only(
                      start: bleed ? 0 : Sp.x6,
                      end: bleed ? 0 : Sp.x6,
                      top: Sp.x6,
                      // Room for the phone tab bar so the last card can scroll
                      // clear of it. With a FAB the tail has to clear the
                      // button too, or the last row hides under it.
                      bottom: (fab != null ? Layout.fab + Layout.fabInset : Sp.x6) +
                          (context.isTouch ? Layout.tap : 0),
                    ),
                    // Every page fades in on navigation. Opacity only — no
                    // travel — for the same reason the web build restricted
                    // `.page-inner` to `fade-in`: a transform here would become
                    // the containing block for anything positioned inside the
                    // page, and the shell draws its own layers above this one.
                    child: FadeRise(
                      offset: 0,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (actions != null) ...[
                            Padding(
                              padding: EdgeInsetsDirectional.only(
                                start: bleed ? Sp.x6 : 0,
                                end: bleed ? Sp.x6 : 0,
                              ),
                              child: Align(
                                alignment: AlignmentDirectional.centerEnd,
                                child: actions,
                              ),
                            ),
                            const SizedBox(height: Sp.x4),
                          ],
                          ...children,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );

    if (fab == null) return body;
    return Stack(
      children: [
        Positioned.fill(child: body),
        Positioned(
          right: Layout.fabInset,
          // Clear the phone tab bar. The shell reserves its own strip there and
          // a button sitting on it would be under the user's thumb.
          bottom: Layout.fabInset + (context.isTouch ? Layout.tap + Sp.x2 : 0),
          child: fab!,
        ),
      ],
    );
  }
}

/// One option in a [Segmented] control.
class SegOption<T> {
  const SegOption({required this.value, required this.label, this.count});

  final T value;
  final String label;
  final int? count;
}

/// The segmented control: a row of tab-like buttons where one is selected.
class Segmented<T> extends StatelessWidget {
  const Segmented({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final T value;
  final List<SegOption<T>> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      // The 2dp inset keeps the selected pill's tint off the track's outline.
      // On touch the buttons grow to the 44dp floor and the inset has to give
      // way, or the strip would stand 4dp taller than the row that holds it.
      padding: EdgeInsets.all(context.isTouch ? 0 : 2),
      decoration: BoxDecoration(color: p.surfaceSunken, borderRadius: R.borderPill),
      // The track outline is painted *over* the children rather than as part of
      // the box decoration, because a border consumes layout space: with a real
      // 1dp border the tallest a chip could be inside a 44dp track is 42. Drawn
      // as a foreground decoration the chips get the whole 44.
      foregroundDecoration: BoxDecoration(
        borderRadius: R.borderPill,
        border: Border.all(color: p.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final o in options)
            _SegButton<T>(
              option: o,
              selected: o.value == value,
              onTap: () => onChanged(o.value),
            ),
        ],
      ),
    );
  }
}

class _SegButton<T> extends StatefulWidget {
  const _SegButton({required this.option, required this.selected, required this.onTap});

  final SegOption<T> option;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SegButton<T>> createState() => _SegButtonState<T>();
}

class _SegButtonState<T> extends State<_SegButton<T>> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final selected = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: Motion.dur1,
          curve: Motion.ease,
          // One chip is a filter you tap repeatedly while reading a list, so it
          // is a real target rather than a label: it grows with the density the
          // same way a button does, but only in height — the sideways padding
          // is where the chips earn their fit on a phone.
          height: context.controlH,
          alignment: Alignment.center,
          // Sideways air is where a phone pays for its chips. The five status
          // labels measure 172dp; at 12dp a side the row is 292dp against the
          // 236dp the query bar can spare once the search field and the select
          // button have theirs, and the last chip was cut off at the card edge.
          // At 4dp the labels fit, but "全部" then measures 36.5dp across — so
          // the floor is enforced as a width too, not just a height. Both ends
          // of the trade are real: a chip narrower than a fingertip is not a
          // target, and a chip wider than the row is not a control.
          padding: EdgeInsets.symmetric(
            horizontal: context.isTouch ? Sp.x1 : Sp.x3,
            vertical: context.isTouch ? 0 : Sp.x2 - 2,
          ),
          constraints: context.isTouch
              ? const BoxConstraints(minWidth: Layout.tap)
              : null,
          decoration: BoxDecoration(
            // The selected chip is a *tinted* chip, not a white one. A white
            // chip on a near-white track is a 1.04:1 difference and a hairline
            // — the state was legible only to whoever already knew which chip
            // they had tapped. The accent tint says "this one" from across the
            // room, which is the only job a filter has, and it is the one place
            // besides the primary action the accent is allowed to appear.
            color: selected
                ? p.accentSoft
                : _hover
                    ? p.surfaceHover
                    : const Color(0x00000000),
            borderRadius: R.borderPill,
            // No per-chip outline. The track draws its own 1dp outline as a
            // *foreground* decoration, so an outlined selected chip sat 2dp
            // inside that line and read as a double border — the same defect
            // class as the two-border text fields of 0.2.5. The tint plus the
            // heavier label is the whole selection signal, which is also what
            // the reference does with its selected tab.
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.option.label,
                style: TextStyle(
                  fontSize: Fs.sm,
                  height: Lh.tight,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? p.accentInk : p.ink2,
                ),
              ),
              // The count is a wide-screen affordance. Five chips with a number
              // apiece measure 396dp on a 411dp phone, so the last one was cut
              // in half at the card's edge — the one thing a segmented control
              // must never do, since the cut is indistinguishable from a chip
              // that does not exist. The label alone measures 252dp and fits,
              // and the number is still where it matters: the list below shows
              // every word's status, and the footer counts the list.
              if (widget.option.count != null && !context.isTouch) ...[
                const SizedBox(width: Sp.x1),
                Text(
                  '${widget.option.count}',
                  style: TextStyle(
                    fontSize: Fs.xs,
                    height: Lh.tight,
                    fontWeight: FontWeight.w500,
                    color: selected ? p.accent : p.ink4,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// An empty state: icon, one line of what is missing, an optional action.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    this.icon = Ic.sparkles,
    required this.title,
    this.text,
    this.action,
  });

  final String icon;
  final String title;
  final String? text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.x12, horizontal: Sp.x6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: p.surface2,
              shape: BoxShape.circle,
              border: Border.all(color: p.line),
            ),
            child: Center(child: LexIcon(icon, size: 22, color: p.ink3)),
          ),
          const SizedBox(height: Sp.x4),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: Fonts.display,
              fontSize: Fs.md,
              height: Lh.title,
              fontWeight: FontWeight.w600,
              color: p.ink,
            ),
          ),
          if (text != null) ...[
            const SizedBox(height: Sp.x2),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Text(
                text!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: Fs.sm, color: p.ink3, height: Lh.body),
              ),
            ),
          ],
          if (action != null) ...[
            const SizedBox(height: Sp.x5),
            action!,
          ],
        ],
      ),
    );
  }
}

/// A thin progress rule. `thick` is the daily-goal variant.
class ProgressBar extends StatelessWidget {
  const ProgressBar({
    super.key,
    required this.value,
    this.max = 1,
    this.thick = false,
    this.color,
  });

  final double value;
  final double max;
  final bool thick;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final pct = max <= 0 ? 0.0 : (value / max).clamp(0.0, 1.0);
    final h = thick ? 8.0 : 4.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(h),
      child: SizedBox(
        height: h,
        child: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: p.surfaceSunken)),
            AnimatedFractionallySizedBox(
              duration: Motion.dur3,
              curve: Motion.easeOut,
              widthFactor: pct,
              alignment: Alignment.centerLeft,
              child: ColoredBox(color: color ?? p.accent),
            ),
          ],
        ),
      ),
    );
  }
}

/// The accuracy ring shared by both study modes and the stats page.
class Ring extends StatelessWidget {
  const Ring({
    super.key,
    required this.value,
    this.max = 1,
    this.size = 96,
    this.stroke = 8,
    this.children = const [],
  });

  final double value;
  final double max;
  final double size;
  final double stroke;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final pct = max <= 0 ? 0.0 : (value / max).clamp(0.0, 1.0);
    // The ring holds text, so its diameter has to answer to the text scale the
    // same way a padded box does. A fixed 84dp circle that fits 「0 / 20」 at 1.0x
    // overflows by 20dp at 2.0x — the numerals are what is inside it, not
    // decoration painted next to it. Capped at 1.6x so a large-text ring does
    // not swallow the card it sits in; past that the figures are simply bigger
    // than the ring and the ring yields by overlap-free growth only up to here.
    final double scale = MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.6);
    final double side = size * scale;
    return SizedBox(
      width: side,
      height: side,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: pct),
        duration: Motion.dur4,
        curve: Motion.easeOut,
        builder: (context, animated, _) => CustomPaint(
          painter: _RingPainter(pct: animated, stroke: stroke, track: p.surfaceSunken, fill: p.accent),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.pct,
    required this.stroke,
    required this.track,
    required this.fill,
  });

  final double pct;
  final double stroke;
  final Color track;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset(stroke / 2, stroke / 2) &
        Size(size.width - stroke, size.height - stroke);
    canvas.drawArc(
      rect,
      0,
      6.283185307179586,
      false,
      Paint()
        ..color = track
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );
    if (pct <= 0) return;
    canvas.drawArc(
      rect,
      -1.5707963267948966,
      6.283185307179586 * pct,
      false,
      Paint()
        ..color = fill
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.pct != pct || old.stroke != stroke || old.track != track || old.fill != fill;
}

/// A status pill. [tone] names the semantic colour: ok / warn / danger / idle.
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.label, required this.tone});

  final String label;

  /// `new` / `learning` / `review` / `mastered` map to the word statuses; the
  /// rest are the generic tones.
  final String tone;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final (bg, fg) = switch (tone) {
      'ok' || 'mastered' => (p.okSoft, p.ok),
      'warn' || 'learning' => (p.warnSoft, p.warn),
      'danger' => (p.dangerSoft, p.danger),
      'accent' || 'review' => (p.accentSoft, p.accentInk),
      _ => (p.surface2, p.ink3),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x2, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: R.borderSm),
      child: Text(
        label,
        style: TextStyle(
          fontSize: Fs.xs,
          height: Lh.tight,
          fontWeight: FontWeight.w500,
          color: fg,
        ),
      ),
    );
  }
}

/// A labelled figure — the stats page is a grid of these.
///
/// The order is label, figure, note — not icon, figure, note. A figure is the
/// thing this app is made of (words counted, days counted, percentages), and it
/// was being set one step smaller than the serif page furniture around it while
/// an icon carried the colour. The figure now leads in the display face so two
/// tiles side by side read as two statements rather than two readouts, and the
/// icon — where a caller still passes one — is a 13dp muted mark inside the
/// label row rather than a tinted badge above the number.
///
/// The icon trails its label rather than leading it. Leading it pushed the
/// label 19dp to the right of the figure underneath, so the two left edges of a
/// tile disagreed and a row of tiles read as ragged — the live build measured
/// 「连续学习」 starting at x1156 above a figure starting at x1129. A mark that
/// sits ahead of the words it describes moves the words; a mark that follows
/// them perturbs nothing that has to line up.
///
/// There is no box here. A tile is a figure on the page and the page is already
/// the container; the grid that lays these out draws the hairlines between them,
/// which is the only separation four numbers need.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.sub,
    this.accent,
    this.icon,
  });

  final String label;
  final String value;
  final String? sub;
  final Color? accent;
  final String? icon;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: Fs.xs,
                    color: p.ink3,
                    height: Lh.tight,
                    letterSpacing: 0.04,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (icon != null) ...[
                const SizedBox(width: Sp.x1 + 2),
                LexIcon(icon!, size: 13, color: p.ink4),
              ],
            ],
          ),
          const SizedBox(height: Sp.x1 + 2),
          Text(
            value,
            maxLines: 1,
            style: TextStyle(
              fontFamily: Fonts.display,
              fontSize: Fs.x2xl,
              height: Lh.tight,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.02,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              color: accent ?? p.ink,
            ),
          ),
          if (sub != null) ...[
            const SizedBox(height: Sp.x1),
            Text(
              sub!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: Fs.xs, color: p.ink4, height: Lh.tight),
            ),
          ],
        ],
      ),
    );
  }
}

/// A section heading over a block of related content.
///
/// The dashboard had no such thing: every band sat directly on the page and the
/// only hierarchy came from card borders, so the eye could not tell where one
/// idea ended and the next began. A heading is 15dp of serif over a 12dp muted
/// count — the same relationship the page header uses, one level down, so the
/// page reads as a table of contents rather than a stack.
class SectionHeading extends StatelessWidget {
  const SectionHeading({super.key, required this.title, this.note, this.action});

  final String title;
  final String? note;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(
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
        if (note != null) ...[
          const SizedBox(width: Sp.x3),
          Flexible(
            child: Text(
              note!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: Fonts.mono,
                fontSize: Fs.xs,
                height: Lh.tight,
                color: p.ink4,
              ),
            ),
          ),
        ],
        if (action != null) ...[const SizedBox(width: Sp.x3), action!],
      ],
    );
  }
}

/// One row of the keyboard-shortcut sheet: label on the left, keycaps right.
class ShortcutRow extends StatelessWidget {
  const ShortcutRow({super.key, required this.keys, required this.label});

  final List<String> keys;
  final String label;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.x2),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: TextStyle(fontSize: Fs.base, color: p.ink2)),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final k in keys)
                Padding(
                  padding: const EdgeInsets.only(left: Sp.x1),
                  child: Kbd(k),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A keycap.
class Kbd extends StatelessWidget {
  const Kbd(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x2 - 2, vertical: 2),
      decoration: BoxDecoration(
        color: p.surface2,
        borderRadius: R.borderXs,
        border: Border.all(color: p.lineStrong),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: Fonts.mono,
          fontSize: Fs.xs - 1,
          height: Lh.tight,
          color: p.ink2,
        ),
      ),
    );
  }
}

/// A hairline card — the app's one surface for grouping content.
class Card extends StatelessWidget {
  const Card({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Sp.x5),
    this.tight = false,
  });

  final Widget child;
  final EdgeInsets padding;
  final bool tight;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: tight ? R.borderMd : R.borderLg,
        border: Border.all(color: p.line),
      ),
      child: child,
    );
  }
}

/// ---------------------------------------------------------------------------
/// The hairline list — the app's content surface.
///
/// The design system used to group everything into a [Card]: a bordered rounded
/// rectangle per block, so a page was a stack of boxes. The reference draws no
/// boxes at all. Its word list is one full-width column divided by hairlines,
/// with a single accent rule down the left edge, and the effect is that the
/// page reads as a page rather than as a dashboard of widgets.
///
/// So a list is [HairlineList] holding [HairlineRow]s. The row paints the rule
/// and the divider itself; the list only decides which row is last.
/// ---------------------------------------------------------------------------

/// A column of [HairlineRow]s: full-width, separated by hairlines, with the
/// accent rule running down the left edge of the whole list.
///
/// The rule is painted once for the list rather than per row: the reference's
/// rule is a single unbroken line from the first entry to the last, and a
/// per-row segment would show a 1dp gap at every hairline.
class HairlineList extends StatelessWidget {
  const HairlineList({
    super.key,
    required this.children,
    this.rule = true,
    this.padded = true,
  });

  final List<Widget> children;

  /// Whether the list draws the accent rule down its left edge.
  final bool rule;

  /// Whether the list contributes the outer horizontal padding. A page that
  /// already pads its body leaves this on so the rule is inset from the window
  /// edge; a list that must bleed edge to edge turns it off.
  final bool padded;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
    final body = rule
        ? Stack(
            children: [
              column,
              // Drawn last so a row's hover fill cannot paint over it: the rule
              // is the list's edge, not part of whichever row the pointer is on.
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: Container(width: Layout.listRuleW, color: p.accent),
              ),
            ],
          )
        : column;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: padded ? Sp.x6 : 0),
      child: body,
    );
  }
}

/// One entry in a [HairlineList]: airy, full-width, hairline underneath.
///
/// There is no box, no radius and no fill — [onTap] adds hover and press
/// feedback and nothing else. Row height comes from its content, with
/// [Layout.listRowMin] as the floor so a one-line entry still breathes.
class HairlineRow extends StatefulWidget {
  const HairlineRow({
    super.key,
    required this.child,
    this.onTap,
    this.last = false,
    this.padding,
    this.trailing,
  });

  final Widget child;
  final VoidCallback? onTap;

  /// The final row draws no divider; the list ends there.
  final bool last;
  final EdgeInsets? padding;

  /// Anything pinned to the right of the row — a star, a speaker, a chevron.
  /// It is laid out beside [child], which gets the remaining width.
  final Widget? trailing;

  @override
  State<HairlineRow> createState() => _HairlineRowState();
}

class _HairlineRowState extends State<HairlineRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final content = Container(
      constraints: const BoxConstraints(minHeight: Layout.listRowMin),
      padding: widget.padding ??
          const EdgeInsets.symmetric(vertical: Sp.x4, horizontal: Sp.x4),
      decoration: BoxDecoration(
        color: _hover ? p.surfaceHover : Colors.transparent,
        border: widget.last ? null : Border(bottom: BorderSide(color: p.line)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: widget.child),
          if (widget.trailing != null) ...[
            const SizedBox(width: Sp.x3),
            widget.trailing!,
          ],
        ],
      ),
    );

    if (widget.onTap == null) return content;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(onTap: widget.onTap, child: content),
    );
  }
}

/// A section heading inside a page: a small label, optionally with a count and
/// a trailing action, sitting directly on the page above its list.
///
/// This replaces the "card with a title" pattern. A section title is one line
/// of small caps-ish text; the content under it owns the width.
class SectionTitle extends StatelessWidget {
  const SectionTitle({
    super.key,
    required this.label,
    this.trailing,
    this.padded = true,
  });

  final String label;
  final Widget? trailing;
  final bool padded;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: padded ? Sp.x6 : 0,
        right: padded ? Sp.x6 : 0,
        top: Sp.x6,
        bottom: Sp.x2,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: Fs.sm,
                height: Lh.snug,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.04,
                color: p.ink3,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// A round filled field — the reference's search box.
///
/// A bare [TextField] wrapped in a pill, with its own focus ring. The fill is
/// [Palette.surface2] (the warm sunken tone) rather than a white card, so the
/// field reads as a place to type rather than as another block of content.
class PillField extends StatelessWidget {
  const PillField({
    super.key,
    required this.child,
    this.icon,
    this.focused = false,
    this.height,
    this.padding,
  });

  final Widget child;
  final String? icon;
  final bool focused;
  final double? height;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return AnimatedContainer(
      duration: Motion.dur2,
      curve: Motion.ease,
      height: height ?? context.controlH,
      padding: padding ??
          EdgeInsets.symmetric(horizontal: Sp.x4),
      decoration: BoxDecoration(
        color: p.surface2,
        borderRadius: R.borderPill,
        // The focused field keeps the accent outline. It is the one input the
        // user is in the middle of, and the reference's unfocused field has no
        // outline at all — so the transition is from "no line" to "accent line",
        // which is a stronger signal than the old grey-to-accent swap.
        border: Border.all(
          color: focused ? p.accent : Colors.transparent,
        ),
      ),
      child: Row(
        children: [
          if (icon != null) ...[
            LexIcon(icon!, size: 16, color: focused ? p.accent : p.ink3),
            const SizedBox(width: Sp.x2),
          ],
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// The floating action button: a round accent-filled pill with a mark inside.
///
/// It floats over the scroll view in the bottom-right of the page, above the
/// phone tab bar. [PageShell] positions it; a page supplies it via
/// `PageShell.fab`.
class FloatingAction extends StatefulWidget {
  const FloatingAction({
    super.key,
    required this.onPressed,
    this.icon = Ic.plus,
    this.label,
    this.tooltip,
  });

  final VoidCallback onPressed;

  /// The mark inside. When [label] is set the button is a stadium, not a circle.
  final String icon;
  final String? label;
  final String? tooltip;

  @override
  State<FloatingAction> createState() => _FloatingActionState();
}

class _FloatingActionState extends State<FloatingAction> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final hasLabel = widget.label != null;

    final button = AnimatedScale(
      scale: _pressed ? 0.96 : (_hover ? 1.03 : 1),
      duration: _pressed ? Motion.dur1 : Motion.dur2,
      curve: Motion.ease,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: AnimatedContainer(
            duration: Motion.dur2,
            curve: Motion.ease,
            height: Layout.fab,
            padding: hasLabel
                ? const EdgeInsets.symmetric(horizontal: Sp.x5)
                : EdgeInsets.zero,
            constraints: hasLabel
                ? null
                : const BoxConstraints(minWidth: Layout.fab),
            decoration: BoxDecoration(
              color: _hover ? p.accentHover : p.accent,
              borderRadius: R.borderPill,
              // Soft and diffuse, not a drop shadow with an edge. The reference's
              // button sits above the page rather than on it, and a tight shadow
              // read as a second border around an already-bordered shape.
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: p.accent.withValues(alpha: _hover ? 0.34 : 0.26),
                  offset: const Offset(0, 8),
                  blurRadius: 22,
                  spreadRadius: -6,
                ),
              ],
            ),
            child: Center(
              widthFactor: 1,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LexIcon(widget.icon, size: 22, color: p.onAccent),
                  if (hasLabel) ...[
                    const SizedBox(width: Sp.x2),
                    Text(
                      widget.label!,
                      style: TextStyle(
                        fontSize: Fs.base,
                        height: Lh.tight,
                        fontWeight: FontWeight.w600,
                        color: p.onAccent,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );

    return widget.tooltip == null
        ? button
        : Tooltip(message: widget.tooltip!, child: button);
  }
}
