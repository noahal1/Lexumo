/// The notification seam: what the reminder service may ask the platform for.
///
/// The shape mirrors `app_installer.dart`: one small interface, one plugin-backed
/// implementation, one fake for tests. The reminder service must not know that
/// `flutter_local_notifications` exists — a platform without notification support
/// is a constructor argument, not an `if` sprinkled through the service.
///
/// `supported == false` means every method is a no-op and the settings page
/// hides the reminder group entirely, exactly as `speechSupported` hides the
/// voice picker before TTS has answered.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// The platform's daily-notification ability, behind one seam.
abstract class NotificationPort {
  /// Whether this platform can show notifications at all. Checked once; a
  /// false answer must not come and go mid-session.
  bool get supported;

  /// Ask for the Android 13+ runtime permission. Returns whether the user
  /// granted it. Desktop implementations return true without asking; a port
  /// whose [supported] is false is never asked.
  Future<bool> requestPermission();

  /// (Re)schedule the single daily reminder. Any previously scheduled
  /// reminder with [id] is replaced. Scheduled for the next occurrence of
  /// [hour]:[minute] local time, then daily.
  Future<void> scheduleDaily({
    required int id,
    required String title,
    required String body,
    required int hour,
    required int minute,
  });

  /// Remove the scheduled reminder, if any.
  Future<void> cancel(int id);
}

/// A port that cannot notify: Windows (until verified), tests that want the
/// reminder feature invisible, any future platform without a plugin.
class NoNotifications implements NotificationPort {
  const NoNotifications();

  @override
  bool get supported => false;

  @override
  Future<bool> requestPermission() async => false;

  @override
  Future<void> scheduleDaily({
    required int id,
    required String title,
    required String body,
    required int hour,
    required int minute,
  }) async {}

  @override
  Future<void> cancel(int id) async {}
}

/// Builds the platform-backed port. Windows is deliberately served
/// [NoNotifications] until the plugin's Windows support is verified against
/// this app's manifests — see `docs/reminder-plan.md` §3.
NotificationPort buildNotifications() {
  if (Platform.isAndroid) return PluginNotifications();
  return const NoNotifications();
}

/// The plugin-backed port. Guarded behind [buildNotifications] so importing
/// the plugin happens only where it exists; every call is a best-effort — a
/// missed notification is a missed reminder, never a crash in a sync round.
class PluginNotifications implements NotificationPort {
  PluginNotifications() {
    tzdata.initializeTimeZones();
    _initLocalLocation();
    final plugin = FlutterLocalNotificationsPlugin();
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: android);
    plugin.initialize(settings: settings);
    _plugin = plugin;
  }

  /// A `tz.Location` for this device's current offset, built rather than
  /// looked up.
  ///
  /// `DateTime.timeZoneName` returns an *abbreviation* ("CST", "GMT+8") which
  /// is almost never a name in the tz database, so `getLocation(name)` throws
  /// `LocationNotFoundException` — and this constructor runs in `main`, where
  /// an exception is a white screen, not a missing reminder. The offset itself
  /// always exists, so the fallback is a location that is merely at UTC when
  /// the abbreviation lookup fails; a reminder then fires at UTC-shifted local
  /// time until the next launch picks up a resolvable zone, which is still a
  /// reminder rather than a crash.
  static void _initLocalLocation() {
    try {
      tz.setLocalLocation(tz.getLocation(DateTime.now().timeZoneName));
    } on Exception {
      final offset = DateTime.now().timeZoneOffset;
      final name = 'lexumo-local${offset.isNegative ? '-' : '+'}'
          '${offset.inHours.abs()}h${offset.inMinutes.abs() % 60}m';
      // One zone with one transition in the far past: a fixed-offset location
      // that never throws, whatever the platform reports as its zone name.
      tz.setLocalLocation(tz.Location(
        name,
        [tz.TZDateTime.minMillisecondsSinceEpoch],
        [0],
        [
          tz.TimeZone(
            offset,
            isDst: false,
            abbreviation: name,
          ),
        ],
      ));
    }
  }

  late final FlutterLocalNotificationsPlugin _plugin;

  // The one reminder. Fixed channel: low importance would hide it on Android
  // 8+ (channels are decided at first use and never renegotiable), so it is a
  // default-importance channel with sound — a reminder the user asked for.
  static const _androidDetails = AndroidNotificationDetails(
    'lexumo_reminder',
    'Review reminder',
    channelDescription: 'Daily reminder with the number of cards due',
    importance: Importance.defaultImportance,
    priority: Priority.defaultPriority,
  );

  @override
  bool get supported => true;

  @override
  Future<bool> requestPermission() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final granted = await android?.requestNotificationsPermission();
    return granted ?? true;
  }

  @override
  Future<void> scheduleDaily({
    required int id,
    required String title,
    required String body,
    required int hour,
    required int minute,
  }) async {
    // TZDateTime requires the timezone database; for a daily local-time
    // reminder the plugin's `zonedSchedule` needs an initialised tz database.
    // `DateTimeComponents.time` makes it repeat daily at the same local time.
    final now = DateTime.now();
    var next = DateTime(now.year, now.month, now.day, hour, minute);
    if (!next.isAfter(now)) {
      next = next.add(const Duration(days: 1));
    }
    await _plugin.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: tz.TZDateTime.from(next, tz.local),
      notificationDetails: const NotificationDetails(android: _androidDetails),
      // Android 14+ demands a schedule mode; inexact is right for a daily
      // study nudge and spares the user the exact-alarm permission dialog.
      androidScheduleMode: AndroidScheduleMode.inexact,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }

  @override
  Future<void> cancel(int id) => _plugin.cancel(id: id);
}
