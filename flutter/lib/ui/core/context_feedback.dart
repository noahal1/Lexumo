/// The production [Feedback]: a view model's four outward-facing verbs,
/// implemented over a [BuildContext].
///
/// Every lookup here goes through `getInheritedWidgetOfExactType` rather than
/// `dependOnInheritedWidgetOfExactType`: a view model asks for a translation or
/// raises a toast from an event handler, and registering a dependency there
/// would make the *view model* rebuild the widget it was created for — exactly
/// the loop the MVVM split exists to avoid. The widgets subscribe to the view
/// model; the view model subscribes to nobody but the store.
library;

// `package:flutter/widgets.dart` exports its own `Feedback` (the haptic /
// sound platform-feedback helper, `Feedback.forTap`), which collides with the
// view-model port of the same name. Hide it so `implements Feedback` below
// binds to `ui/core/view_model.dart`'s. Any widget-layer file that needs to
// *name* the port has to do the same; a file that only passes a
// `ContextFeedback` to a view model never mentions it and needs nothing.
import 'package:flutter/widgets.dart' hide Feedback;

import '../../app/scope.dart' show I18nScope, NavScope, ToastScope;
import '../../domain/models/types.dart' show UiLang;
import '../core/i18n/i18n.dart';
import '../core/view_model.dart';
import '../core/widgets/controls.dart' show confirmLex;

/// A [Feedback] bound to a live [BuildContext].
///
/// Construct one per view model, from the `State` that owns it. The context is
/// only dereferenced inside the four methods, all of which the view calls while
/// it is mounted, so a disposed page cannot reach it.
class ContextFeedback implements Feedback {
  ContextFeedback(this._context);

  final BuildContext _context;

  I18n get _i18n =>
      _context.getInheritedWidgetOfExactType<I18nScope>()?.i18n ??
      const I18n(UiLang.zhCN);

  @override
  String t(String key, [Map<String, Object>? vars]) => _i18n.t(key, vars);

  @override
  void toast(
    String text, {
    ToastKind kind = ToastKind.info,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    ToastScope.maybeOf(_context)?.show(
      text,
      kind,
      actionLabel: actionLabel,
      onAction: onAction,
    );
  }

  @override
  Future<bool> confirm({
    required String title,
    String? subtitle,
    required String confirmLabel,
    bool danger = false,
  }) =>
      confirmLex(
        _context,
        title: title,
        subtitle: subtitle,
        confirmLabel: confirmLabel,
        danger: danger,
      );

  @override
  void goTo(String pageId) => NavScope.maybeOf(_context)?.call(pageId);

  @override
  bool get canNavigate => NavScope.maybeOf(_context) != null;
}
