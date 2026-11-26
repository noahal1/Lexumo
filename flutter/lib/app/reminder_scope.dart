/// The reminder service in the widget tree, shaped exactly like [UpdateScope].
///
/// [ReminderService] is plain Dart — no widget knowledge, testable without a
/// framework. This file is the bridge: the service is plain-field state (prefs
/// change rarely, through explicit user actions), so a bare [ChangeNotifier]
/// with an explicit [notify] from the settings view model is enough; there is
/// no stream to relay.
///
/// Optional like [SyncScope]: a page pumped without one (a widget test) sees
/// `null` and renders no reminder group rather than throwing.
library;

import 'package:flutter/widgets.dart';

import '../data/repositories/reminder_service.dart';

/// Provides the reminder service.
class ReminderScope extends InheritedWidget {
  const ReminderScope({
    super.key,
    required this.service,
    required super.child,
  }) : super();

  final ReminderService service;

  @override
  bool updateShouldNotify(ReminderScope oldWidget) =>
      service != oldWidget.service;

  /// The service without subscribing. Null when the tree has no scope.
  static ReminderService? serviceOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ReminderScope>()?.service;
}

/// Convenience: `context.reminder`.
extension ReminderScopeAccess on BuildContext {
  /// The service, without subscribing. Null without a [ReminderScope].
  ReminderService? get reminder => ReminderScope.serviceOf(this);
}
