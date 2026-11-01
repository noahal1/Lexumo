/// A [Feedback] that records instead of asking, for view-model unit tests.
///
/// A view model is testable with no widget tree precisely because everything it
/// cannot do itself arrives through [Feedback]. This fake is the other half of
/// that bargain: it answers [confirm] from a script and keeps every toast and
/// navigation so a test can assert on what the screen *asked for* rather than on
/// what pixels appeared.
library;

import 'package:flutter/foundation.dart' show VoidCallback, immutable;
import 'package:lexumo/domain/models/types.dart' show UiLang;
import 'package:lexumo/ui/core/i18n/i18n.dart';
import 'package:lexumo/ui/core/view_model.dart';

/// One recorded [Feedback.toast] call.
@immutable
class ToastRecord {
  const ToastRecord({
    required this.text,
    required this.kind,
    this.actionLabel,
    this.onAction,
  });

  final String text;
  final ToastKind kind;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  String toString() => 'ToastRecord($kind, $text)';
}

/// Records every call; answers [confirm] from [confirmAnswer].
class FakeFeedback implements Feedback {
  FakeFeedback({this.confirmAnswer = true, UiLang lang = UiLang.zhCN})
      : _i18n = I18n(lang);

  final I18n _i18n;

  /// What the next [confirm] returns. Flip it to model the user dismissing the
  /// dialog — the branch that must write nothing.
  bool confirmAnswer;

  final List<ToastRecord> toasts = <ToastRecord>[];
  final List<String> navigations = <String>[];

  /// Every confirmation raised, so a test can assert the wording and that the
  /// dialog was asked for at all.
  final List<({String title, String? subtitle, String confirmLabel, bool danger})>
      confirmations = [];

  @override
  String t(String key, [Map<String, Object>? vars]) => _i18n.t(key, vars);

  @override
  void toast(
    String text, {
    ToastKind kind = ToastKind.info,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    toasts.add(ToastRecord(
      text: text,
      kind: kind,
      actionLabel: actionLabel,
      onAction: onAction,
    ));
  }

  @override
  Future<bool> confirm({
    required String title,
    String? subtitle,
    required String confirmLabel,
    bool danger = false,
  }) async {
    confirmations.add((
      title: title,
      subtitle: subtitle,
      confirmLabel: confirmLabel,
      danger: danger,
    ));
    return confirmAnswer;
  }

  @override
  void goTo(String pageId) => navigations.add(pageId);

  @override
  bool get canNavigate => true;
}
