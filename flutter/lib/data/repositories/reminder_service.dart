/// The daily review reminder: preferences in a local sidecar, one scheduled
/// notification, nothing in sync.
///
/// Why a sidecar and not [Settings]: settings travel as one document and merge
/// by last-write-wins, so a phone's reminder choice would overwrite every other
/// device's — including desktops that cannot show a notification at all. A
/// reminder is a fact about *this device's* attention, the same reason
/// `UpdateStateStore` keeps its dismissed release out of settings. The sidecar
/// lives beside `lexumo.json`, is written with write-then-rename so a crash
/// cannot truncate it, and falls back to defaults when unreadable — the worst
/// outcome of a lost file is toggling the switch again.
///
/// Why the due count is computed, not stored: a cached count goes stale the
/// moment the user adds words, and recomputing is one pass over an in-memory
/// list. The service reschedules (same id, cancel-then-schedule) whenever the
/// count it would announce could have moved — after boot, after a preference
/// change, after a sync round.
///
/// The notification text comes in through [ReminderService.text] rather than
/// being built here: the body is UI language, and this class holds no widget.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../domain/models/srs.dart' as srs;
import '../services/notifications.dart';
import 'store.dart';

/// The id of the one daily reminder. Fixed so a reschedule replaces rather
/// than accumulates.
const int kReminderNotificationId = 1;

/// The reminder time of day: minutes since midnight, local.
class ReminderTime {
  const ReminderTime({required this.hour, required this.minute});

  static const ReminderTime evening = ReminderTime(hour: 20, minute: 0);

  final int hour;
  final int minute;

  @override
  bool operator ==(Object other) =>
      other is ReminderTime && other.hour == hour && other.minute == minute;

  @override
  int get hashCode => Object.hash(hour, minute);
}

/// What survives between launches. Not synced — see the library doc.
class ReminderPrefs {
  const ReminderPrefs({
    this.enabled = false,
    this.time = ReminderTime.evening,
  });

  final bool enabled;
  final ReminderTime time;

  ReminderPrefs copyWith({bool? enabled, ReminderTime? time}) => ReminderPrefs(
        enabled: enabled ?? this.enabled,
        time: time ?? this.time,
      );

  Map<String, dynamic> toJson() =>
      {'enabled': enabled, 'hour': time.hour, 'minute': time.minute};

  /// Unreadable or absent fields fall back to the defaults rather than
  /// throwing: a corrupt sidecar costs one re-toggle, not a broken boot.
  static ReminderPrefs fromJson(Map<String, dynamic>? m) {
    if (m == null) return const ReminderPrefs();
    final hour = (m['hour'] as num?)?.toInt();
    final minute = (m['minute'] as num?)?.toInt();
    return ReminderPrefs(
      enabled: m['enabled'] == true,
      time: hour != null && minute != null && _valid(hour, minute)
          ? ReminderTime(hour: hour, minute: minute)
          : ReminderTime.evening,
    );
  }

  static bool _valid(int hour, int minute) =>
      hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59;
}

/// Where the preferences live. Same shape as `UpdateStateStore`'s sidecar.
abstract class ReminderPrefsStore {
  Future<ReminderPrefs> read();
  Future<void> write(ReminderPrefs prefs);
}

/// The JSON sidecar beside `lexumo.json`.
class FileReminderPrefsStore implements ReminderPrefsStore {
  FileReminderPrefsStore(this.path);

  final String path;

  File get _file => File(path);

  @override
  Future<ReminderPrefs> read() async {
    try {
      if (!await _file.exists()) return const ReminderPrefs();
      final raw = jsonDecode(await _file.readAsString());
      return ReminderPrefs.fromJson(raw is Map ? raw.cast<String, dynamic>() : null);
    } on FormatException {
      return const ReminderPrefs();
    } on FileSystemException {
      return const ReminderPrefs();
    }
  }

  @override
  Future<void> write(ReminderPrefs prefs) async {
    try {
      await _file.parent.create(recursive: true);
      // Write beside then rename: a crash mid-write would otherwise leave a
      // truncated sidecar. Same pattern as `FileUpdateStateStore`.
      final temp = File('$path.tmp');
      await temp.writeAsString(jsonEncode(prefs.toJson()), flush: true);
      await temp.rename(path);
    } on FileSystemException {
      // Losing this file costs one redundant toggle; it must not break boot.
    }
  }
}

/// In-memory store for tests.
class MemoryReminderPrefsStore implements ReminderPrefsStore {
  MemoryReminderPrefsStore([ReminderPrefs? initial]) : prefs = initial ?? const ReminderPrefs();

  ReminderPrefs prefs;

  @override
  Future<ReminderPrefs> read() async => prefs;

  @override
  Future<void> write(ReminderPrefs prefs) async => this.prefs = prefs;
}

/// The time-of-day choices the settings page offers, with their i18n keys.
///
/// Keys, not resolved strings: the page translates, the service never touches
/// a widget. A handful of sane options rather than a free time picker — a
/// reminder is set once and rarely moved, and presets are one tap each.
enum ReminderTimeOption {
  morning('reminder.morning', ReminderTime(hour: 8, minute: 0)),
  noon('reminder.noon', ReminderTime(hour: 12, minute: 0)),
  evening('reminder.evening', ReminderTime(hour: 20, minute: 0)),
  night('reminder.night', ReminderTime(hour: 22, minute: 0));

  const ReminderTimeOption(this.labelKey, this.time);

  final String labelKey;
  final ReminderTime time;

  /// The stable identity persisted between sessions: the time itself, so a
  /// re-labelled option or a dropped preset still resolves an old sidecar.
  String get key => '${time.hour}:${time.minute}';

  static ReminderTimeOption byKey(String key) {
    for (final o in ReminderTimeOption.values) {
      if (o.key == key) return o;
    }
    return ReminderTimeOption.evening;
  }

  /// The option matching [time], or evening when none does (a hand-edited
  /// sidecar, a future preset list change).
  static ReminderTimeOption of(ReminderTime time) {
    for (final o in ReminderTimeOption.values) {
      if (o.time == time) return o;
    }
    return ReminderTimeOption.evening;
  }

  static List<ReminderTimeOption> get all => ReminderTimeOption.values;
}

/// The reminder flow. One instance for the app's lifetime.
///
/// `text` produces the notification body for [dueCount] due cards; the service
/// itself never builds a sentence, so the i18n stays in the UI layer.
// The private fields below cannot be initializing formals: a named parameter
// may not start with an underscore, which is the whole point of the field.
// Same trade-off `store.dart` makes.
// ignore_for_file: prefer_initializing_formals
class ReminderService {
  ReminderService({
    required NotificationPort notifications,
    required Store store,
    required ReminderPrefsStore prefs,
    required String Function(int dueCount) text,
    int Function()? clock,
  })  : _notifications = notifications,
        _store = store,
        _prefs = prefs,
        _text = text,
        _clock = clock ?? _systemClock;

  final NotificationPort _notifications;
  final Store _store;
  final ReminderPrefsStore _prefs;
  final String Function(int dueCount) _text;
  final int Function() _clock;

  static int _systemClock() => DateTime.now().millisecondsSinceEpoch;

  ReminderPrefs _current = const ReminderPrefs();
  bool _detached = false;

  /// The saved preferences, for the settings page to render.
  ReminderPrefs get prefs => _current;

  /// Whether the reminder group should be rendered at all.
  bool get supported => _notifications.supported;

  /// Read the sidecar and schedule, if enabled. Called once at boot.
  Future<void> init() async {
    if (!supported) return;
    _current = await _prefs.read();
    await _apply(_current);
  }

  /// Called after a sync round: the due count may have moved, and the already
  /// scheduled notification's body is stale. Replaces, never duplicates.
  Future<void> refresh() => _apply(_current);

  /// Turn the reminder on or off. Requests the runtime permission first on
  /// platforms that have one; a refusal records `enabled: false` so the switch
  /// reflects what the platform will actually do.
  Future<void> setEnabled(bool enabled) async {
    if (!supported) return;
    if (enabled) {
      final granted = await _notifications.requestPermission();
      if (!granted) return;
    }
    final next = _current.copyWith(enabled: enabled);
    _current = next;
    await _prefs.write(next);
    await _apply(next);
  }

  /// Change the time of day. Turning the time picker on does not enable the
  /// reminder: the two are independent controls.
  Future<void> setTime(ReminderTime time) async {
    if (!supported) return;
    final next = _current.copyWith(time: time);
    _current = next;
    await _prefs.write(next);
    await _apply(next);
  }

  /// Called when the app is being torn down, so a late callback does nothing.
  void dispose() => _detached = true;

  /// Cancel-then-schedule, or cancel-only when disabled. Idempotent.
  Future<void> _apply(ReminderPrefs prefs) async {
    if (_detached) return;
    await _notifications.cancel(kReminderNotificationId);
    if (!prefs.enabled) return;
    final due = srs.dueWords(_store.data.words, _clock()).length;
    if (due == 0) {
      // Nothing to announce today. No notification is scheduled: a "you have
      // nothing to do" push spends the user's attention budget for nothing.
      return;
    }
    await _notifications.scheduleDaily(
      id: kReminderNotificationId,
      title: 'Lexumo',
      body: _text(due),
      hour: prefs.time.hour,
      minute: prefs.time.minute,
    );
  }
}
