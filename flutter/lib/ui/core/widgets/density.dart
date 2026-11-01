/// Control sizing that answers the pointer, not the window width.
///
/// The design system's control heights ([Layout.controlH] 36, [Layout.controlHSm]
/// 32) were measured against a mouse: a cursor can hit a 32px box, and a dense
/// row of icon buttons is worth the accuracy it costs. A fingertip cannot. On a
/// phone the same row is a 32px target surrounded by other 32px targets, and
/// missing one by four pixels opens the wrong entry — or deletes a word.
///
/// So on touch platforms an interactive box grows to [Layout.tap] (44). Two
/// different recipes follow from that, and the difference is deliberate:
///
///   · a **button with a label** (`LexButton`) grows whole — the border and fill
///     are the affordance, and a 44px button is simply a normal phone button;
///   · an **icon-only button** keeps its drawn square and grows only the hit
///     box, because a 44px outlined square in a table row reads as a hole in the
///     row rather than as a control. That is the rule `docs/design.md` records
///     for the web build — extend the target, not the shape.
///
/// The rule is platform-based rather than width-based, for the same reason
/// `showKeyboardHints` is: a narrowed desktop window is still a mouse, and a
/// tablet in landscape is wide but still a fingertip. Window width answers
/// neither question.
///
/// [platform] exists so a test can pin the answer instead of inheriting the
/// host's — `flutter test` reports `TargetPlatform.android` by default, which
/// would otherwise mean the desktop branch is never exercised.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../tokens.dart';

/// Whether the ambient platform is driven by a fingertip rather than a pointer.
bool isTouchPlatform({TargetPlatform? platform}) {
  final TargetPlatform p = platform ?? defaultTargetPlatform;
  return switch (p) {
    TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.fuchsia => true,
    TargetPlatform.windows || TargetPlatform.macOS || TargetPlatform.linux => false,
  };
}

extension TouchDensity on BuildContext {
  /// True on a phone or tablet.
  bool get isTouch => isTouchPlatform();

  /// Height for a default control: 44 on touch, 36 with a mouse.
  double get controlH => isTouch ? Layout.tap : Layout.controlH;

  /// Height for a compact control: 44 on touch, 32 with a mouse.
  double get controlHSm => isTouch ? Layout.tap : Layout.controlHSm;

  /// Hit box for an icon-only button: 44 on touch, 32 with a mouse.
  double get iconTarget => isTouch ? Layout.tap : Layout.controlHSm;
}

/// Grows the tap area to [Layout.tap] on touch while drawing [child] at its own
/// size in the middle.
///
/// It must sit INSIDE the `GestureDetector`, not outside it: a gesture recogniser
/// only receives events within its own box, so wrapping the detector in a larger
/// box would move the pixels and not the target. Inside, the detector's box
/// becomes the padded one while the decorated box the user sees stays at its
/// design size — the hover fill is still 32px, the target is 44.
///
/// The detector above must also carry `HitTestBehavior.opaque`, because a bare
/// [SizedBox] is not itself hit-testable and the 6px ring around the child would
/// stay dead. That requirement is asserted, not assumed: `density_test.dart` taps
/// a corner of the ring and fails if the tap misses.
///
/// With a mouse this is a no-op, so every desktop measurement is unchanged.
class TapTarget extends StatelessWidget {
  const TapTarget({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!context.isTouch) return child;
    return SizedBox(
      width: Layout.tap,
      height: Layout.tap,
      child: Center(child: child),
    );
  }
}
