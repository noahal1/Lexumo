/// Per-day activity helpers: how much was reviewed today, and how many days in
/// a row the user has studied.
///
/// Ported from `src/lib/dayStats.ts`. Two very different consumers need the
/// same numbers — the sidebar and the stats headline — so there is exactly one
/// definition here, as in the TS.
///
/// Pure: domain types and date helpers only.
library;

import 'types.dart';
import 'utils.dart';

/// Reviews recorded since local midnight.
///
/// `now` defaults to the wall clock like the TS's `now = Date.now()`; pass it
/// explicitly in tests and in anything that renders a fixed moment.
int reviewsToday(AppData data, [int? now]) {
  final t0 = startOfDay(now ?? DateTime.now().millisecondsSinceEpoch);
  return data.logs.where((l) => l.at >= t0).length;
}

/// Consecutive days with at least one review, counting back from today.
///
/// Today being empty does not break the streak — it just starts the count from
/// yesterday, so an unfinished day never looks like a lost streak.
///
/// The TS walked a `Date` with `setDate(d - 1)`; this walks calendar days with
/// `DateTime(year, month, day - n)`, which is the same arithmetic across
/// month boundaries and DST.
int streakDays(AppData data, [int? now]) {
  final nowTs = now ?? DateTime.now().millisecondsSinceEpoch;
  final days = <String>{};
  for (final log in data.logs) {
    days.add(dayKeyOfTs(log.at));
  }

  var cursor = DateTime.fromMillisecondsSinceEpoch(nowTs);
  if (!days.contains(dayKeyOfTs(cursor.millisecondsSinceEpoch))) {
    cursor = DateTime(cursor.year, cursor.month, cursor.day - 1);
  }
  var streak = 0;
  for (;;) {
    if (!days.contains(dayKeyOfTs(cursor.millisecondsSinceEpoch))) break;
    streak += 1;
    cursor = DateTime(cursor.year, cursor.month, cursor.day - 1);
  }
  return streak;
}
