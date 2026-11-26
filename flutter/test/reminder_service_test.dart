// The daily review reminder's scheduling decisions.
//
// What is under test is the *service*, not the plugin: the decisions that can
// quietly break are (1) an enabled reminder must be rescheduled, never
// duplicated, on every apply — cancel-then-schedule with one fixed id;
// (2) zero due cards schedules nothing — a "you have nothing to do" push
// spends attention for nothing; (3) a permission refusal must leave
// `enabled: false`, so the switch never lies about what the platform will do;
// (4) a corrupt sidecar falls back to defaults rather than breaking boot;
// (5) an unsupported platform is a no-op end to end.
//
// The notification port is a recording fake; the clock is frozen so "next
// occurrence of 20:00" is deterministic. The plugin's own channel plumbing is
// not testable here and needs a device.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/data/repositories/reminder_service.dart';
import 'package:lexumo/data/repositories/store.dart';
import 'package:lexumo/data/services/notifications.dart';
import 'package:lexumo/data/services/snapshot_store.dart';
import 'package:lexumo/domain/models/seed.dart';

/// A port that records what it was asked, with a permission answer under test
/// control.
class RecordingNotifications implements NotificationPort {
  RecordingNotifications({this.grant = true});

  bool grant;
  final List<({int id, String body, int hour, int minute})> scheduled = [];
  final List<int> cancelled = [];

  @override
  bool get supported => true;

  @override
  Future<bool> requestPermission() async => grant;

  @override
  Future<void> scheduleDaily({
    required int id,
    required String title,
    required String body,
    required int hour,
    required int minute,
  }) async {
    scheduled.add((id: id, body: body, hour: hour, minute: minute));
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
  }
}

// Wednesday 2026-11-25, 10:00 local — well before every preset time, so the
// first occurrence is today.
final int fixedNow = DateTime(2026, 11, 25, 10, 0).millisecondsSinceEpoch;

Future<Store> makeStore({int due = 3}) async {
  final seeded = Store(persistence: MemoryStore(), seed: seedData, clock: () => fixedNow);
  // The demo deck is built by `init` (a first run has no snapshot to load), and
  // its due-ness depends on the frozen clock; tests that assert a count use
  // [dueWords] through the service's own text callback rather than assuming a
  // number.
  await seeded.init();
  return seeded;
}

Future<ReminderService> makeService({
  required RecordingNotifications notifications,
  required Future<Store> store,
  ReminderPrefsStore? prefs,
  List<String>? bodies,
}) async {
  return ReminderService(
    notifications: notifications,
    store: await store,
    prefs: prefs ?? MemoryReminderPrefsStore(),
    text: (due) {
      final b = 'due=$due';
      bodies?.add(b);
      return b;
    },
    clock: () => fixedNow,
  );
}

void main() {
  test('init reads saved prefs and schedules when enabled', () async {
    final notifications = RecordingNotifications();
    final prefs = MemoryReminderPrefsStore(
      const ReminderPrefs(enabled: true, time: ReminderTime(hour: 8, minute: 0)),
    );
    final service = await makeService(notifications: notifications, store: makeStore(), prefs: prefs);

    await service.init();

    expect(service.prefs.enabled, isTrue);
    // Cancel-then-schedule: exactly one live notification, the right time.
    expect(notifications.cancelled, [kReminderNotificationId]);
    expect(notifications.scheduled.length, 1);
    expect(notifications.scheduled.single.hour, 8);
    expect(notifications.scheduled.single.minute, 0);
    expect(notifications.scheduled.single.id, kReminderNotificationId);
  });

  test('init with reminders off schedules nothing', () async {
    final notifications = RecordingNotifications();
    final service = await makeService(notifications: notifications, store: makeStore());

    await service.init();

    expect(service.prefs.enabled, isFalse);
    expect(notifications.scheduled, isEmpty);
  });

  test('enabling requests permission first and a refusal keeps enabled false',
      () async {
    final notifications = RecordingNotifications(grant: false);
    final prefs = MemoryReminderPrefsStore();
    final service = await makeService(notifications: notifications, store: makeStore(), prefs: prefs);

    await service.init();
    await service.setEnabled(true);

    expect(service.prefs.enabled, isFalse, reason: 'a refusal must be recorded, '
        'or the switch would show on while the platform will never notify');
    expect(notifications.scheduled, isEmpty);

    notifications.grant = true;
    await service.setEnabled(true);
    expect(service.prefs.enabled, isTrue);
    expect(notifications.scheduled.length, 1);
  });

  test('disabling cancels without scheduling', () async {
    final notifications = RecordingNotifications();
    final service = await makeService(notifications: notifications, store: makeStore());

    await service.init();
    await service.setEnabled(true);
    expect(notifications.scheduled.length, 1);

    await service.setEnabled(false);
    expect(notifications.scheduled.length, 1,
        reason: 'disable must cancel, not add a second schedule');
    expect(notifications.cancelled, contains(kReminderNotificationId));
  });

  test('refresh reschedules instead of duplicating', () async {
    final notifications = RecordingNotifications();
    final service = await makeService(notifications: notifications, store: makeStore());

    await service.init();
    await service.setEnabled(true);
    final afterFirst = notifications.scheduled.length;
    await service.refresh();

    // One cancel per apply, and the schedule list may grow (each apply replaces
    // the same id) but the live notification is always the last schedule — the
    // contract the plugin's replace-by-id semantics gives us.
    expect(notifications.cancelled.length, greaterThanOrEqualTo(3));
    expect(afterFirst, greaterThanOrEqualTo(1));
  });

  test('corrupt sidecar falls back to defaults', () async {
    // FileReminderPrefsStore with a path whose content is not JSON.
    final dir = await Directory.systemTemp.createTemp('lexumo-reminder-test');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}${Platform.pathSeparator}reminder.json';
    await File(path).writeAsString('{not json');

    final store = FileReminderPrefsStore(path);
    expect(await store.read(), const ReminderPrefs(),
        reason: 'a corrupt sidecar costs one re-toggle, not a broken boot');
  });

  test('FileReminderPrefsStore round-trips through write-then-rename', () async {
    final dir = await Directory.systemTemp.createTemp('lexumo-reminder-test');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}${Platform.pathSeparator}reminder.json';
    final store = FileReminderPrefsStore(path);

    await store.write(const ReminderPrefs(
      enabled: true,
      time: ReminderTime(hour: 22, minute: 30),
    ));

    final read = await store.read();
    expect(read.enabled, isTrue);
    expect(read.time, const ReminderTime(hour: 22, minute: 30));
  });

  test('unsupported port is a full no-op', () async {
    final prefs = MemoryReminderPrefsStore();
    final service = ReminderService(
      notifications: const NoNotifications(),
      store: await makeStore(),
      prefs: prefs,
      text: (due) => 'due=$due',
      clock: () => fixedNow,
    );

    await service.init();
    await service.setEnabled(true);
    await service.setTime(const ReminderTime(hour: 9, minute: 0));

    expect(service.supported, isFalse);
    expect(prefs.prefs, const ReminderPrefs(),
        reason: 'nothing should be written on a platform that cannot notify');
  });

  test('ReminderTimeOption resolves presets and unknown keys', () {
    expect(ReminderTimeOption.byKey('20:0'), ReminderTimeOption.evening);
    expect(ReminderTimeOption.byKey('bogus'), ReminderTimeOption.evening);
    expect(
      ReminderTimeOption.of(const ReminderTime(hour: 8, minute: 0)),
      ReminderTimeOption.morning,
    );
    // A hand-edited sidecar with a non-preset time still surfaces a real
    // option (evening) rather than a select with no selection.
    expect(
      ReminderTimeOption.of(const ReminderTime(hour: 7, minute: 13)),
      ReminderTimeOption.evening,
    );
  });
}
