/// The one place the MVVM vocabulary is defined: what a view model is, what it
/// is allowed to touch, and how a view talks to it.
///
/// The split this file encodes:
///
///   * **a [ViewModel] owns a screen's mutable state and every derivation from
///     the data layer.** Filters, selection, the session in progress, the index
///     built from the snapshot — all of it lives here, and none of it lives in
///     a `State`.
///   * **a view owns widgets.** It builds from the view model's getters and
///     calls its intent methods. It holds no logic of its own beyond layout.
///   * **a view model never imports `package:flutter/material.dart`.** It may
///     use `foundation` (for [ChangeNotifier]) and nothing above it. That rule
///     is what keeps a view model unit-testable without a widget tree.
///
/// The things a view model genuinely cannot do — raise a dialog, show a toast,
/// switch pages — arrive through [Feedback]. That is a port, not a widget: a
/// test passes a fake and asserts on what the screen *asked for*.
library;

import 'package:flutter/foundation.dart';

/// The three toast severities, mirroring the web build's `ToastKind`.
///
/// Defined here rather than beside [Feedback]'s production implementation so
/// that both the view-model layer and `app/scope.dart` can name it without
/// either importing the other. `app/scope.dart` re-exports it, so every
/// existing `import '.../app/scope.dart'` keeps working.
enum ToastKind { ok, err, info }

/// Base class for the per-feature view models.
///
/// Extends [ChangeNotifier], so a view rebuilds from one [ListenableBuilder]
/// instead of scattering `setState` through the tree.
abstract class ViewModel extends ChangeNotifier {
  bool _disposed = false;

  /// True once [dispose] has run. A view model that started an async operation
  /// (a store write, a lookup) must check this before notifying.
  bool get isDisposed => _disposed;

  /// Publish a state change, unless the screen is already gone.
  ///
  /// Every mutation in every subclass goes through here rather than calling
  /// [notifyListeners] directly: a store write that lands after the page was
  /// popped would otherwise throw `A ChangeNotifier was used after being
  /// disposed`.
  @protected
  void update(VoidCallback mutate) {
    if (_disposed) return;
    mutate();
    notifyListeners();
  }

  /// Rebuild the view without a state change — for a view model that derives
  /// everything from the store and only needs to re-read it.
  @protected
  void refresh() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// The view model's window onto the UI: the four things it cannot do itself.
///
/// **Naming note.** `package:flutter/widgets.dart` exports its own `Feedback`
/// (the haptic / sound platform-feedback helper). This class has the same name
/// on purpose — it is the view model's feedback to the user — so a widget-layer
/// file that imports `widgets.dart` *and* names this type must write
/// `hide Feedback` on the Flutter import. Files that merely pass a
/// `ContextFeedback` into a view-model constructor never mention the name and
/// need nothing.
///
/// Implemented for production by [ContextFeedback] (`ui/core/context_feedback.dart`,
/// which needs a `BuildContext`) and in tests by a fake that records the calls.
/// Keeping this an interface is what lets a view model be tested with no widget
/// tree at all — see `test/support/fake_feedback.dart`.
abstract class Feedback {
  /// Translate a key, so a view model can compose a message without importing
  /// the widget layer.
  String t(String key, [Map<String, Object>? vars]);

  /// Show a transient message, optionally with an action ("撤销").
  void toast(
    String text, {
    ToastKind kind = ToastKind.info,
    String? actionLabel,
    VoidCallback? onAction,
  });

  /// Ask the user to confirm a destructive action. Returns false when the user
  /// dismisses the dialog, so a caller can `if (!await …) return;`.
  Future<bool> confirm({
    required String title,
    String? subtitle,
    required String confirmLabel,
    bool danger = false,
  });

  /// Switch to the page named by its wire id; a no-op without a shell.
  void goTo(String pageId);

  /// True when a shell is above this screen, i.e. when [goTo] would work.
  bool get canNavigate;
}
