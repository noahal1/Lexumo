/// App-wide plumbing: the store adapter, the toast queue and the shell scope.
///
/// The web build used three React contexts (`useAppData`, `useT`, `useToast`).
/// Flutter's equivalent is an [InheritedNotifier] for the store — it rebuilds
/// exactly the widgets that depend on a snapshot — plus two small
/// [InheritedWidget]s for the localisation and the toast sink. Keeping them in
/// one file means a new page imports `app/scope.dart` and gets all three.
library;

import 'package:flutter/widgets.dart';

import '../data/repositories/store.dart';
import '../data/repositories/sync_engine.dart';
import '../domain/models/types.dart';
import '../ui/core/i18n/i18n.dart';
// [ToastKind] is declared in `ui/core/view_model.dart`: the view-model layer
// has to name it and must not import `app/`. Imported for this file's own use
// and re-exported so every existing `import '.../app/scope.dart'` keeps
// resolving it.
export '../ui/core/view_model.dart' show ToastKind;
import '../ui/core/view_model.dart' show ToastKind;

/// Bridges [Store]'s listener list to [ChangeNotifier], so `InheritedNotifier`
/// can drive rebuilds without the store having to know about Flutter.
class StoreNotifier extends ChangeNotifier {
  StoreNotifier(this._store) {
    _detach = _store.addListener(notifyListeners);
  }

  final Store _store;
  late final void Function() _detach;

  Store get store => _store;
  AppData get data => _store.data;

  @override
  void dispose() {
    _detach();
    super.dispose();
  }
}

/// Provides the snapshot; every screen reads it through [AppScope.dataOf].
class StoreScope extends InheritedNotifier<StoreNotifier> {
  const StoreScope({
    super.key,
    required StoreNotifier notifier,
    required super.child,
  }) : super(notifier: notifier);

  static StoreNotifier of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<StoreScope>();
    assert(scope?.notifier != null, 'StoreScope is missing above this widget');
    return scope!.notifier!;
  }

  /// The current snapshot. Depends on the scope, so the caller rebuilds on
  /// every store write — which is what a page wants.
  static AppData dataOf(BuildContext context) => of(context).data;

  /// The store itself, for its operations. Does *not* subscribe: an action
  /// handler that only writes should not rebuild.
  static Store storeOf(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<StoreScope>();
    assert(scope?.notifier != null, 'StoreScope is missing above this widget');
    return scope!.notifier!.store;
  }
}

/// Provides the active [I18n]. Depends on the language only, so a snapshot
/// write does not rebuild every label.
class I18nScope extends InheritedWidget {
  const I18nScope({super.key, required this.i18n, required super.child});

  final I18n i18n;

  static I18n of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<I18nScope>();
    return scope?.i18n ?? const I18n(UiLang.zhCN);
  }

  @override
  bool updateShouldNotify(I18nScope old) => old.i18n.lang != i18n.lang;
}

/// Hands the shell a way to raise a toast without threading a callback through
/// every page.
class ToastScope extends InheritedWidget {
  const ToastScope({super.key, required this.show, required super.child});

  final void Function(String text, ToastKind kind, {String? actionLabel, VoidCallback? onAction, int? durationMs}) show;

  static ToastScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ToastScope>();

  @override
  bool updateShouldNotify(ToastScope old) => old.show != show;
}

/// Lets a page ask the shell to switch pages — the Flutter equivalent of the
/// web build's `router.navigate('quiz')`.
///
/// It is deliberately keyed by the page's wire id (`'words'`, `'quiz'`, …) and
/// not by [PageId]: `PageId` lives in `shell.dart`, which imports every page,
/// so a page that imported it back would close an import cycle. The shell owns
/// the id→PageId mapping; a page only names a destination.
///
/// Pages read it with `context.goTo('quiz')`, which is a no-op when no shell is
/// above them (a page pumped bare in a test, say) — the CTA then simply stays
/// hidden rather than becoming a button that does nothing.
class NavScope extends InheritedWidget {
  const NavScope({super.key, required this.onNavigate, required super.child});

  /// Receives a page id such as `'quiz'`. Unknown ids are ignored by the shell.
  final ValueChanged<String> onNavigate;

  static ValueChanged<String>? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<NavScope>()?.onNavigate;

  @override
  bool updateShouldNotify(NavScope old) => old.onNavigate != onNavigate;
}

/// Provides the sync engine and republishes its status changes.
///
/// [SyncScope] is an [InheritedNotifier] over a [Listenable] that forwards the
/// engine's own listener list, so the settings page rebuilds when a round
/// changes state while nothing in the snapshot did. It is optional: a page
/// pumped without one (a widget test) sees `null` and draws the signed-out
/// state rather than throwing.
class SyncScope extends InheritedNotifier<SyncStatusNotifier> {
  const SyncScope({super.key, required SyncStatusNotifier notifier, required super.child})
      : super(notifier: notifier);

  static SyncEngine? engineOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SyncScope>()?.notifier?.engine;

  /// Depends on the scope, so the caller rebuilds on every status change.
  static SyncStatus? statusOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SyncScope>()?.notifier?.engine.status;

  /// The engine without subscribing — for action handlers.
  static SyncEngine? engineWithoutDeps(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SyncScope>()?.notifier?.engine;
}

/// Bridges the engine's plain listener list to [ChangeNotifier].
class SyncStatusNotifier extends ChangeNotifier {
  SyncStatusNotifier(this.engine) {
    _detach = engine.addListener(notifyListeners);
  }

  final SyncEngine engine;
  late final void Function() _detach;

  @override
  void dispose() {
    _detach();
    super.dispose();
  }
}

/// Convenience: `context.t('nav.words')`.
extension AppScope on BuildContext {
  I18n get i18n => I18nScope.of(this);
  String t(String key, [Map<String, Object>? vars]) => i18n.t(key, vars);
  AppData get data => StoreScope.dataOf(this);
  Store get store => StoreScope.storeOf(this);

  /// The sync engine, subscribing the caller to status changes. Null when the
  /// tree has no [SyncScope].
  SyncEngine? get sync => SyncScope.engineOf(this);

  /// The sync status, subscribing the caller. Null when the tree has no
  /// [SyncScope].
  SyncStatus? get syncStatus => SyncScope.statusOf(this);

  /// The engine without subscribing — for a button's `onPressed`.
  SyncEngine? get syncEngine => SyncScope.engineWithoutDeps(this);

  void toast(String text, [ToastKind kind = ToastKind.info, String? actionLabel, VoidCallback? onAction]) {
    ToastScope.maybeOf(this)?.show(text, kind, actionLabel: actionLabel, onAction: onAction);
  }

  /// True when a shell is above this page, i.e. when cross-page links can work.
  bool get canNavigate => NavScope.maybeOf(this) != null;

  /// Switch to the page named by its wire id. No-op without a [NavScope].
  void goTo(String pageId) => NavScope.maybeOf(this)?.call(pageId);
}
