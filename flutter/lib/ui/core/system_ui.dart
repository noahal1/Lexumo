/// Edge-to-edge window chrome: the status bar and the navigation bar.
///
/// ## What was wrong
///
/// The app never talked to the system UI at all. Android therefore drew the
/// default opaque status bar above a `Theme.Light` window, and the Flutter view
/// started *below* it. The shell then wrapped its body in
/// `SafeArea(bottom: false)`, which reserved that height again. The visible
/// result was a dead band at the top of the screen that belonged to the OS, in a
/// colour that matched neither material in the design system: not the stone
/// frame, not the paper. On a notched device it was worse, because
/// `Theme.Light.NoTitleBar` declares no `windowLayoutInDisplayCutoutMode`, so
/// the notch cut into the letterbox rather than into the app.
///
/// ## What this does
///
/// Two halves that have to agree, or the result is worse than doing nothing:
///
///   1. **[enableEdgeToEdge]** makes the Flutter view draw *under* both system
///      bars and makes both of them transparent. This is the immersion — the
///      app's own colour reaches the top and bottom edges of the glass.
///   2. **An [AnnotatedRegion]** tells the OS what to paint the *glyphs* in.
///      Transparent bars with dark icons over a dark frame are invisible; the
///      icons have to follow the material behind them.
///
/// ## Why the two edges are not the same decision
///
/// The status bar is easy: the shell's `Scaffold` background is the stone frame,
/// its `SafeArea` insets only the content, so the strip behind the status bar is
/// stone. Stone is dark in **both** themes — that is the whole point of it
/// (`docs/design.md`: "the frame never changes colour with the theme") — so the
/// status-bar glyphs are **always light**, in light mode and dark mode alike.
///
/// The navigation bar is not. It used to be argued the other way: a phone's tab
/// bar was stone too, so both edges were stone and took light glyphs. That bar
/// is paper now — it belongs to the paper material and only the *frame* around
/// it is stone — so every layout ends with paper at the bottom edge, and the
/// glyphs follow the theme. This is no longer a question about layout, which is
/// why [shellOverlayStyle] takes only `isDark`; it used to take the layout mode
/// and got the phone case wrong the moment the bar changed material.
///
/// ## Why an `AnnotatedRegion` and not a global call
///
/// `SystemChrome.setSystemUIOverlayStyle` sets a process-wide value that the
/// engine applies on the next frame regardless of which widget asked. An
/// `AnnotatedRegion` is resolved per-frame from the layer tree, so a dialog or a
/// pushed route can override it locally and the shell gets its own value back
/// when the route pops. It is the difference between "what the app wants" and
/// "what is on screen right now".
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The overlay style for the shell, given which material is under each edge.
///
/// [isDark] decides the bottom edge only. The paper follows the theme and the
/// paper is always what the bottom edge lands on: the phone tab bar is paper,
/// and a tablet or desktop window has no bar at all, so the page's paper runs
/// there. The status bar over the stone frame does not consult it.
SystemUiOverlayStyle shellOverlayStyle({required bool isDark}) {
  // The top edge is stone in every layout, so it never consults `isDark`.
  const Brightness statusIcons = Brightness.light;
  // The bottom edge is paper in every layout, so it always does.
  final Brightness navIcons = isDark ? Brightness.light : Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: statusIcons,
    // iOS reads this one inverted: `dark` means "draw light content".
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: navIcons,
    systemNavigationBarDividerColor: Colors.transparent,
    // Both bars are drawn by the app. The OS scrim would tint them a colour the
    // design system does not own, and on Android 10+ it is on by default for the
    // navigation bar whenever it is transparent.
    systemStatusBarContrastEnforced: false,
    systemNavigationBarContrastEnforced: false,
  );
}

/// Put the window into edge-to-edge mode and keep it there.
///
/// Call once, from `main()`, **after** `WidgetsFlutterBinding.ensureInitialized()`
/// and before `runApp`. Calling it later works, but the first frame is then
/// drawn letterboxed and the transition is visible as a jump.
///
/// Returns a `Future` the caller should await, so the first frame is already
/// edge-to-edge rather than becoming so one frame later.
Future<void> enableEdgeToEdge() async {
  // `edgeToEdge` is the mode that actually gives the app the whole screen: both
  // bars become transparent overlays and the view is laid out behind them.
  // `leanBack` / `immersive` hide the bars entirely, which is wrong for a tool —
  // a user needs their clock and battery without performing a gesture.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  // A provisional style for the very first frame, before the shell has built and
  // had a chance to publish its own. The shell's region wins from frame two on.
  SystemChrome.setSystemUIOverlayStyle(shellOverlayStyle(isDark: false));
}
