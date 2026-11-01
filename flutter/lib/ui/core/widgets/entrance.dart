/// The one entrance animation in the app.
///
/// The design system asks for exactly one motion recipe: opacity plus a few
/// pixels of travel, decelerating, nothing overshooting (`docs/design.md`: "Only
/// transform and opacity animate"). The web build spells that recipe out as
/// keyframes in `src/styles/global.css` — `fade-in` for a page, `pop-in` for a
/// panel, `row-in`/`tile-in`/`bar-rise` for content arriving in sequence — and
/// this widget is their shared Flutter shape.
///
/// Three properties are deliberate, and each exists because the obvious
/// alternative breaks something:
///
///   · **Transform and opacity only.** Neither changes the size or position of
///     anything in the layout. A `Padding` tween or an animated `SizedBox` would
///     glide the content around while rows are still being measured, which is
///     how a list ends up with a hit box that does not match the row.
///   · **One controller, no timers.** A stagger delay is expressed as an
///     `Interval` on a single `AnimationController` whose duration is
///     `delay + duration`, so nothing schedules a `Timer`. A test that pumps a
///     screen and then asserts on it settles; a test that forgot to settle does
///     not fail with "A Timer is still pending".
///   · **`disableAnimations` is honoured.** The OS reduced-motion switch turns
///     the controller straight to its end value, so the finished state is
///     identical and the animation simply never plays.
///
/// The child is built once and handed to the builder, so an entrance never
/// rebuilds the subtree it is animating.
library;

import 'package:flutter/widgets.dart';

import '../tokens.dart';

class FadeRise extends StatefulWidget {
  const FadeRise({
    super.key,
    required this.child,
    this.duration = Motion.dur3,
    this.delay = Duration.zero,
    this.offset = 10,
    this.curve = Motion.easeOut,
  });

  final Widget child;

  /// How long the fade-travel takes. Capped at [Motion.dur3] by convention:
  /// anything longer starts to feel like the interface is thinking.
  final Duration duration;

  /// When this item enters, relative to its siblings' first frame. The design
  /// system's stagger step is [Motion.stagger]; a list should cap the total so a
  /// long page costs the same as a short one.
  final Duration delay;

  /// Vertical travel in logical pixels. `0` for a full page, where the web
  /// build deliberately uses opacity alone: a transform on the page container
  /// would become the containing block for anything positioned inside it.
  final double offset;

  final Curve curve;

  @override
  State<FadeRise> createState() => _FadeRiseState();
}

class _FadeRiseState extends State<FadeRise> with SingleTickerProviderStateMixin {
  late final Duration _total = widget.delay + widget.duration;
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _total,
  );
  late final CurvedAnimation _progress = CurvedAnimation(
    parent: _controller,
    curve: _interval(),
  );

  /// The delay as a slice of the single timeline, so the stagger costs no timer.
  Curve _interval() {
    final int total = _total.inMilliseconds;
    if (total <= 0 || widget.delay == Duration.zero) return widget.curve;
    return Interval(widget.delay.inMilliseconds / total, 1, curve: widget.curve);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Read once: the OS switch does not change under a mounted screen in any
    // way worth chasing, and re-reading it every frame would subscribe this
    // widget to a media query it otherwise does not care about.
    final bool reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduced) {
      _controller.value = 1;
    } else if (_controller.isDismissed) {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_total == Duration.zero) return widget.child;
    return AnimatedBuilder(
      animation: _progress,
      // The subtree is built once here, outside the builder: an entrance must
      // not rebuild what it is animating on every frame.
      child: widget.child,
      builder: (BuildContext context, Widget? child) {
        final double t = _progress.value;
        if (t >= 1) return child!;
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * widget.offset),
            child: child,
          ),
        );
      },
    );
  }
}
