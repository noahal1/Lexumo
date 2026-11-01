import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Whether keycap affordances should be drawn.
///
/// A keycap is the little `Ctrl`, `Enter`, `空格` or `1` badge that advertises a
/// keyboard shortcut. On a phone or tablet there is no hardware keyboard, so
/// these are pure noise: they cannot be pressed, they eat horizontal space on
/// cards that are already tight, and on the study screens they compete with the
/// word itself for attention.
///
/// The rule is deliberately **platform-based rather than width-based**. A
/// narrowed desktop window is still driven by a keyboard, and a tablet held in
/// landscape is wide but still has none — so window width answers the wrong
/// question. Desktop (Windows/macOS/Linux) keeps the hints; they are the reason
/// a keyboard-first workflow is discoverable at all.
///
/// [platform] exists so a test can pin the answer instead of inheriting the
/// host's: `flutter test` reports `TargetPlatform.android` by default, which
/// would otherwise mean the desktop branch is never exercised.
bool showKeyboardHints({TargetPlatform? platform}) {
  final TargetPlatform p = platform ?? defaultTargetPlatform;
  return switch (p) {
    TargetPlatform.windows || TargetPlatform.macOS || TargetPlatform.linux => true,
    TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.fuchsia => false,
  };
}

extension KeyboardHintScope on BuildContext {
  /// [showKeyboardHints] bound to the ambient platform.
  bool get showsKeyHints => showKeyboardHints();
}
