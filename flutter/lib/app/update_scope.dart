/// The update service in the widget tree, shaped exactly like [SyncScope].
///
/// [UpdateService] is plain Dart on purpose — it can be tested without a
/// framework, and it does not know what a widget is. This file is the bridge:
/// an [InheritedNotifier] over a [ChangeNotifier] that forwards the service's
/// own `ValueNotifier`, so the settings row and the update sheet rebuild when a
/// phase changes while nothing in the snapshot did.
///
/// It is optional, like [SyncScope]: a page pumped without one (a widget test)
/// sees `null` and draws the version it was built with rather than throwing.
library;

import 'package:flutter/widgets.dart';

import '../data/update_service.dart';

/// Bridges [UpdateService.state] to [ChangeNotifier].
class UpdateNotifier extends ChangeNotifier {
  UpdateNotifier(this.service) {
    service.state.addListener(notifyListeners);
  }

  final UpdateService service;

  UpdateState get state => service.state.value;

  @override
  void dispose() {
    service.state.removeListener(notifyListeners);
    super.dispose();
  }
}

/// Provides the update service and republishes its state changes.
class UpdateScope extends InheritedNotifier<UpdateNotifier> {
  const UpdateScope({
    super.key,
    required UpdateNotifier notifier,
    required super.child,
  }) : super(notifier: notifier);

  /// The service without subscribing — for a button's `onPressed`.
  static UpdateService? serviceOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<UpdateScope>()?.notifier?.service;

  /// The current update state, subscribing the caller.
  static UpdateState? stateOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UpdateScope>()?.notifier?.state;
}

/// Convenience: `context.update` / `context.updateState`.
extension UpdateScopeAccess on BuildContext {
  /// The service, without subscribing. Null when the tree has no [UpdateScope].
  UpdateService? get update => UpdateScope.serviceOf(this);

  /// The update state, subscribing the caller. Null without an [UpdateScope].
  UpdateState? get updateState => UpdateScope.stateOf(this);
}
