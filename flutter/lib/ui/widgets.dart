/// Shared UI primitives, ported from `src/components/ui.tsx`.
///
/// The web build had one file of small building blocks that every page used so
/// headers, empty states and progress read the same everywhere. The Flutter
/// port keeps that arrangement, with the Material widgets that already match a
/// primitive (Switch, Slider) left out — those come from the `ThemeData` in
/// `design/theme.dart` instead of being rebuilt here.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import 'density.dart';
import 'lex_icon.dart';

/// The page shell every screen uses: a sticky header over a scrolling body.
///
/// The web version drew `.topbar` + `.page`; on Flutter the header is a
/// [Column] child and the body expands, which keeps one scroll view per page
/// and lets the phone layout put its tab bar underneath without measuring.
class PageShell extends StatelessWidget {
  const PageShell({
    super.key,
    required this.title,
    this.subtitle,
    this.actions,
    required this.children,
    this.wide = false,
    this.controller,
  });

  final String title;
  final String? subtitle;
  final Widget? actions;
  final List<Widget> children;

  /// `wide` widens the content column from [Layout.contentMax] to 1360.
  final bool wide;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final maxWidth = wide ? 1360.0 : Layout.contentMax;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TopBar(title: title, subtitle: subtitle, actions: actions, maxWidth: maxWidth),
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
                    padding: EdgeInsets.fromLTRB(
                      Sp.x6,
                      Sp.x6,
                      Sp.x6,
                      // Room for the phone tab bar so the last card can scroll
                      // clear of it.
                      Layout.tap + Sp.x6,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: children,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.subtitle,
    required this.actions,
    required this.maxWidth,
  });

  final String title;
  final String? subtitle;
  final Widget? actions;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      decoration: BoxDecoration(
        color: p.bg,
        border: Border(bottom: BorderSide(color: p.line)),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Padding(
            // A phone spends 87dp of an 866dp screen on this bar. The type
            // stays — a page title is not something to shrink — but the air
            // around it can go: 20/16 of vertical padding is a desktop
            // measurement, and dropping it to 16/12 buys back 8dp on every
            // page without moving anything the eye reads.
            padding: EdgeInsets.fromLTRB(
              Sp.x6,
              context.isTouch ? Sp.x4 : Sp.x5,
              Sp.x6,
              context.isTouch ? Sp.x3 : Sp.x4,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontFamily: Fonts.display,
                          fontSize: Fs.xl,
                          height: Lh.title,
                          fontWeight: FontWeight.w600,
                          color: p.ink,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: Sp.x1),
                        Text(
                          subtitle!,
                          style: TextStyle(fontSize: Fs.sm, color: p.ink3, height: Lh.snug),
                        ),
                      ],
                    ],
                  ),
                ),
                if (actions != null) ...[
                  const SizedBox(width: Sp.x4),
                  actions!,
                ],
              ],
            ),
          ),
        ),
      ),
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
      // The 2dp inset around the selected pill exists to keep its own border
      // from touching the track's. On touch the buttons grow to the 44dp floor
      // and the inset has to give way, or the strip would stand 4dp taller
      // than the row that holds it.
      padding: EdgeInsets.all(context.isTouch ? 0 : 2),
      decoration: BoxDecoration(color: p.surface2, borderRadius: R.borderMd),
      // The track outline is painted *over* the children rather than as part of
      // the box decoration, because a border consumes layout space: with a real
      // 1dp border the tallest a chip could be inside a 44dp track is 42. Drawn
      // as a foreground decoration the chips get the whole 44.
      foregroundDecoration: BoxDecoration(
        borderRadius: R.borderMd,
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
            color: selected
                ? p.surface
                : _hover
                    ? p.surfaceHover
                    : const Color(0x00000000),
            borderRadius: R.borderSm,
            border: Border.all(color: selected ? p.line : const Color(0x00000000)),
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
                  color: selected ? p.ink : p.ink2,
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
    return SizedBox(
      width: size,
      height: size,
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
    return Container(
      padding: const EdgeInsets.all(Sp.x4),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: R.borderLg,
        border: Border.all(color: p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                LexIcon(icon!, size: 14, color: accent ?? p.ink3),
                const SizedBox(width: Sp.x2),
              ],
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(fontSize: Fs.xs, color: p.ink3, height: Lh.tight),
                ),
              ),
            ],
          ),
          const SizedBox(height: Sp.x2),
          Text(
            value,
            style: TextStyle(
              fontFamily: Fonts.display,
              fontSize: Fs.xl,
              height: Lh.title,
              fontWeight: FontWeight.w600,
              color: accent ?? p.ink,
            ),
          ),
          if (sub != null) ...[
            const SizedBox(height: Sp.x1),
            Text(sub!, style: TextStyle(fontSize: Fs.xs, color: p.ink4, height: Lh.tight)),
          ],
        ],
      ),
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
