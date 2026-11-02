/// The one entrance animation in the app.
///
/// The design system asks for exactly one motion recipe: opacity plus a few
/// pixels of travel, decelerating, nothing overshooting (`docs/design.md`: "Only
/// transform and opacity animate"). The web build spells that recipe out as
/// keyframes in `src/styles/global.css` — `fade-in` for a page, `pop-in` for a
/// panel, `row-in`/`tile-in`/`bar-rise` for content arriving in sequence — and
/// this widget is their shared Flutter shape.
///
/// Four properties are deliberate, and each exists because the obvious
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
///   · **The widget tree never changes shape.** This is the one the first three
///     versions got wrong, and it is worth spelling out because the mistake is
///     invisible in a widget test and obvious to the person using the app.
///
/// ## Why the tree must not change shape
///
/// The natural way to write "fade in, then get out of the way" is:
///
/// ```dart
/// if (t >= 1) return child;                       // settled: no wrapper
/// return Opacity(opacity: t, child: Transform...); // animating
/// ```
///
/// That is a *structural* change, and Flutter answers it by throwing away the
/// element subtree under the wrapper and inflating a new one. Every `State`
/// below is destroyed and recreated — which means every nested [FadeRise]
/// restarts from zero, every hover state resets, and every scroll offset inside
/// it is lost. The visible result is a page that fades in, settles, and then
/// jerks back to the start and fades in *again*; the reported symptom was
/// "每次进首页、词库、统计页 动画会跳动一下".
///
/// So this widget keeps exactly one shape for its whole life: a [FadeRiseBody]
/// wrapping the child, whose render object decides every frame whether it needs
/// a layer at all. Settling costs a repaint and nothing else — no element is
/// rebuilt, no state is thrown away, and the settled frame paints the child
/// straight through with no `OpacityLayer` and no `TransformLayer` left behind.
library;

import 'package:flutter/rendering.dart';
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
    // One shape, always. [FadeRiseBody] is what listens to [_progress] and
    // repaints; nothing here is conditional, because a conditional wrapper is
    // what used to remount the whole subtree the moment the entrance finished.
    return FadeRiseBody(
      animation: _progress,
      travel: widget.offset,
      child: widget.child,
    );
  }
}

/// The paint layer of [FadeRise]: fades and travels [child] without ever
/// changing the widget tree around it.
///
/// Public so a test can read the current [RenderFadeRise.progress] instead of
/// counting `Opacity` widgets — there is no longer an `Opacity` widget to count.
class FadeRiseBody extends SingleChildRenderObjectWidget {
  const FadeRiseBody({
    super.key,
    required this.animation,
    required this.travel,
    required super.child,
  });

  /// Runs from 0 (nothing painted) to 1 (child painted straight through).
  final Animation<double> animation;

  /// How far below its final position the child starts, in logical pixels.
  final double travel;

  @override
  RenderFadeRise createRenderObject(BuildContext context) =>
      RenderFadeRise(animation: animation, travel: travel);

  @override
  void updateRenderObject(BuildContext context, RenderFadeRise renderObject) {
    renderObject
      ..animation = animation
      ..travel = travel;
  }
}

/// Paints [child] at [progress], and paints it bare once the entrance is over.
///
/// Doing this in a render object rather than with `Opacity`/`Transform` widgets
/// is the whole point: a widget cannot decide to stop wrapping its child
/// without changing the tree, and a tree that changes shape loses the state
/// below it. This one keeps its element for the page's lifetime and only ever
/// schedules repaints.
class RenderFadeRise extends RenderProxyBox {
  RenderFadeRise({required Animation<double> animation, required double travel})
      // A named parameter cannot start with an underscore, so these two cannot
      // be initializing formals even though each is assigned exactly once.
      // ignore: prefer_initializing_formals
      : _animation = animation,
        // ignore: prefer_initializing_formals
        _travel = travel {
    _animation.addListener(_onProgress);
  }

  Animation<double> _animation;

  set animation(Animation<double> value) {
    if (identical(value, _animation)) return;
    _animation.removeListener(_onProgress);
    _animation = value;
    _animation.addListener(_onProgress);
    markNeedsPaint();
  }

  double _travel;

  set travel(double value) {
    if (value == _travel) return;
    _travel = value;
    markNeedsPaint();
  }

  /// Where the entrance is, 0 to 1. `1` means settled: no layer, no travel.
  double get progress => _animation.value.clamp(0.0, 1.0);

  /// How far below its laid-out position the child is currently painted.
  ///
  /// Read off the same curve the painter uses, so a test asserting "it travelled
  /// 12px and never overshot" measures the animation rather than the layout.
  double get paintedOffset => (1 - progress) * _travel;

  void _onProgress() => markNeedsPaint();

  @override
  void paint(PaintingContext context, Offset offset) {
    final double t = progress;
    // Settled, or the reduce-motion switch jumped us here: paint the child as
    // if this widget were not in the tree at all. This is the frame that used to
    // cost a structural swap.
    if (t >= 1) {
      super.paint(context, offset);
      return;
    }
    final int alpha = (t * 255).round();
    // Fully transparent: painting nothing is both cheaper and semantically
    // right — a child that is not drawn cannot be seen, whatever its alpha.
    if (alpha <= 0) return;
    context.pushOpacity(
      offset.translate(0, paintedOffset),
      alpha,
      (PaintingContext ctx, Offset off) => super.paint(ctx, off),
    );
  }

  @override
  bool paintsChild(RenderBox child) => progress > 0;

  @override
  void dispose() {
    _animation.removeListener(_onProgress);
    super.dispose();
  }
}
