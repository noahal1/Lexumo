/// Small shared helpers: ids, dates, class names, text utils.
///
/// Ported from `src/lib/utils.ts`. Everything that read the clock or the DOM in
/// the TS version takes an explicit `now` here (`relativeDay`, `daysBetween`)
/// or is dropped (`downloadText` — that belonged to the browser build, the
/// Flutter shell saves files itself).
library;

import 'dart:math';

final Random _rng = _secureRandom();

Random _secureRandom() {
  try {
    return Random.secure();
  } on UnsupportedError {
    return Random();
  }
}

/// A 12-char random suffix, optionally prefixed. The TS version preferred
/// `crypto.randomUUID()` and fell back to `Math.random()`; both are random
/// tokens, so the Dart port goes straight to the secure source.
String uid([String prefix = '']) {
  final buffer = StringBuffer();
  for (var i = 0; i < 12; i++) {
    buffer.write(_rng.nextInt(16).toRadixString(16));
  }
  final rnd = buffer.toString();
  return prefix.isEmpty ? rnd : '${prefix}_$rnd';
}

/// Join the non-empty class-name parts. Every `null`, `false` and empty string
/// is dropped — the same filter as `parts.filter(Boolean)` in the TS.
String cx(List<Object?> parts) =>
    parts.where((p) => p != null && p != false && '$p'.isNotEmpty).join(' ');

/// Local midnight for the epoch-ms instant [ts].
int startOfDay(int ts) {
  final d = DateTime.fromMillisecondsSinceEpoch(ts);
  return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
}

/// `YYYY-MM-DD` in local time, from epoch ms.
///
/// Named `dayKeyOfTs` rather than `dayKey` on purpose: `domain/srs.dart`
/// already exports `dayKey(DateTime)`, and a second top-level `dayKey` would
/// make every file that imports both ambiguous. This is the same function,
/// keyed off epoch milliseconds (which is what `logs[].at` holds).
String dayKeyOfTs(int ts) {
  final d = DateTime.fromMillisecondsSinceEpoch(ts);
  final m = '${d.month}'.padLeft(2, '0');
  final day = '${d.day}'.padLeft(2, '0');
  return '${d.year}-$m-$day';
}

/// Whole local days from [a] to [b]; negative when [b] is earlier.
int daysBetween(int a, int b) =>
    ((startOfDay(b) - startOfDay(a)) / 86400000).round();

/// "today" / "tomorrow" / "in 3 days" / "2 days ago", in [lang].
///
/// The TS default was `Date.now()`; the port requires [now] so callers (and
/// tests) stay deterministic.
String relativeDay(int ts, String lang, int now) {
  final diff = daysBetween(now, ts);
  if (diff == 0) return lang == 'zh-CN' ? '今天' : 'today';
  if (diff == 1) return lang == 'zh-CN' ? '明天' : 'tomorrow';
  if (diff == -1) return lang == 'zh-CN' ? '昨天' : 'yesterday';
  if (diff > 1) return lang == 'zh-CN' ? '$diff 天后' : 'in $diff days';
  return lang == 'zh-CN' ? '${-diff} 天前' : '${-diff} days ago';
}

/// Trim and lower-case, for term identity comparisons.
///
/// The TS used `toLocaleLowerCase()`; Dart has no locale-sensitive case
/// mapping, so this is the locale-less `toLowerCase()`. For the languages in
/// the catalogue the two agree.
String normalizeTerm(String s) => s.trim().toLowerCase();

/// `Math.max(min, Math.min(max, n))`, including its behaviour when `min > max`
/// (which `num.clamp` would reject with an ArgumentError, so it is spelled out).
num clamp(num n, num min, num max) {
  final lower = n < max ? n : max;
  return lower > min ? lower : min;
}

/// A copy of [arr] in random order (Fisher–Yates, same direction as the TS).
List<T> shuffle<T>(List<T> arr, [Random? random]) {
  final rng = random ?? _rng;
  final out = arr.toList();
  for (var i = out.length - 1; i > 0; i--) {
    final j = rng.nextInt(i + 1);
    final tmp = out[i];
    out[i] = out[j];
    out[j] = tmp;
  }
  return out;
}

/// `Math.round`, i.e. floor(x + 0.5) — half rounds *up*, not away from zero.
///
/// Dart's `double.round()` sends -0.5 to -1 where JS sends it to -0, so the
/// two disagree on negative halves. Percentages are computed with this one to
/// keep the TS's rounding.
int jsRound(num x) => (x + 0.5).floor();

/// Sort [list] in place with [compare], preserving input order on ties.
///
/// `Array.prototype.sort` is stable; `List.sort` in Dart is not, so a tie in
/// the "recent" order would otherwise reorder the words at random.
void stableSort<T>(List<T> list, int Function(T a, T b) compare) {
  final indexed = List<int>.generate(list.length, (i) => i);
  final copy = list.toList();
  indexed.sort((a, b) {
    final c = compare(copy[a], copy[b]);
    return c != 0 ? c : a.compareTo(b);
  });
  for (var i = 0; i < list.length; i++) {
    list[i] = copy[indexed[i]];
  }
}
