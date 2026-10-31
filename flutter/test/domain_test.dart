/// Port of the vitest suites in `src/lib/*.test.ts`.
///
/// One Dart test per vitest `it`, with the same fixtures, the same expected
/// values and the same Chinese descriptions, so the two builds can be diffed
/// case by case. The only tests dropped are the ones that exercised React or
/// the DOM; every pure assertion is here.
///
/// Deferred until the Flutter port needs it: `previewIntervals` (the old
/// `intervalLabel` helper) has no counterpart in `src/lib/srs.ts`, so its
/// assertions do not exist in the TS suite either.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/domain/day_stats.dart';
import 'package:lexumo/domain/languages.dart';
import 'package:lexumo/domain/quiz.dart';
import 'package:lexumo/domain/seed.dart';
import 'package:lexumo/domain/session.dart';
import 'package:lexumo/domain/srs.dart';
import 'package:lexumo/domain/types.dart';
import 'package:lexumo/domain/utils.dart';
import 'package:lexumo/domain/word_index.dart';

/* ------------------------------------------------------------------ */
/* Shared fixtures — the same ones the vitest suites use               */
/* ------------------------------------------------------------------ */

final int NOW = DateTime(2024, 6, 10, 12).millisecondsSinceEpoch;
final int TODAY_START = DateTime(2024, 6, 10).millisecondsSinceEpoch;
const int DAY = DAY_MS;

List<Grade> grades = [Grade.easy, Grade.good, Grade.hard];

/// A card that has already been reviewed at least once.
SrsState reviewed(
  int intervalDays,
  double ease, {
  int? reviewCount,
  int? correctCount,
}) =>
    SrsState(
      ease: ease,
      intervalDays: intervalDays,
      dueAt: NOW + intervalDays * DAY_MS,
      reviewCount: reviewCount ?? 1,
      correctCount: correctCount ?? 1,
      lastReviewedAt: NOW - DAY_MS,
    );

WordList list(String id) => WordList(
      id: id,
      name: id,
      sourceLang: 'en',
      targetLang: 'zh-CN',
      createdAt: 0,
      updatedAt: 0,
    );

Word word(String id, [Map<String, Object?> over = const {}]) {
  return Word.fromJson({
    'id': id,
    'term': over.containsKey('term') ? over['term'] as String : id,
    'definition': over['definition'] as String? ?? '',
    'definition2': over['definition2'] as String? ?? '',
    'example': '',
    'note': over['note'] as String? ?? '',
    'status': (over['status'] as WordStatus?)?.wire ?? 'new',
    'favorite': over['favorite'] as bool? ?? false,
    'listId': over['listId'] as String? ?? 'a',
    'sourceLang': 'en',
    'targetLang': 'zh-CN',
    'listenCount': 0,
    'srs': (over['srs'] as SrsState?)?.toJson(),
    'createdAt': over['createdAt'] as int? ?? 0,
    'updatedAt': 0,
    if (over.containsKey('pos')) 'pos': over['pos'] as String,
  });
}

SrsState srs(Map<String, Object?> over) => SrsState(
      ease: over['ease'] as double? ?? 2.5,
      intervalDays: over['intervalDays'] as int? ?? 1,
      dueAt: over['dueAt'] as int? ?? NOW,
      reviewCount: over['reviewCount'] as int? ?? 1,
      correctCount: over['correctCount'] as int? ?? 1,
      lastReviewedAt: NOW,
    );

ReviewLog log(int at, [Grade grade = Grade.good]) => ReviewLog(
      id: 'log_$at',
      wordId: 'w',
      grade: grade,
      at: at,
      intervalBefore: 1,
      intervalAfter: 2,
    );

AppData appData(
  List<Word> words, {
  List<WordList>? lists,
  List<ReviewLog> logs = const [],
  int dailyGoal = 20,
}) {
  return AppData(
    version: 2,
    lists: lists ?? [list('a'), list('b')],
    words: words,
    logs: logs,
    settings: Settings(dailyGoal: dailyGoal),
  );
}

/// Local midnight `n` days before today's.
int daysAgo(int n) => DateTime(2024, 6, 10 - n).millisecondsSinceEpoch;

/// Stands in for `vi.spyOn(Math, "random")`: every draw is the same value.
class _FixedRandom implements Random {
  _FixedRandom(this._nextInt);

  final int Function(int max) _nextInt;

  @override
  int nextInt(int max) => _nextInt(max);

  @override
  double nextDouble() => 0;

  @override
  bool nextBool() => false;
}

void main() {
  /* ================================================================ */
  /* srs.test.ts                                                       */
  /* ================================================================ */

  group('freshSrs', () {
    test('返回全新卡片的初始状态', () {
      final s = freshSrs(NOW);
      expect(s.ease, 2.5);
      expect(s.intervalDays, 0);
      expect(s.dueAt, NOW);
      expect(s.reviewCount, 0);
      expect(s.correctCount, 0);
      expect(s.lastReviewedAt, isNull);
    });
  });

  group('applyGrade — 首次评分', () {
    for (final grade in grades) {
      test('${grade.wire} 首次评分 → 间隔 1 天、复习次数 1', () {
        final next = applyGrade(null, grade, NOW);
        expect(next.intervalDays, 1);
        expect(next.reviewCount, 1);
        expect(next.ease, 2.5);
        expect(next.lastReviewedAt, NOW);
        expect(next.dueAt, NOW + DAY);
      });
    }

    test('reviewCount 为 0 的 freshSrs 同样按首次评分处理', () {
      final next = applyGrade(freshSrs(NOW), Grade.easy, NOW);
      expect(next.intervalDays, 1);
      expect(next.reviewCount, 1);
    });

    test('easy / good 计入 correctCount，hard 不计入', () {
      expect(applyGrade(null, Grade.easy, NOW).correctCount, 1);
      expect(applyGrade(null, Grade.good, NOW).correctCount, 1);
      expect(applyGrade(null, Grade.hard, NOW).correctCount, 0);
    });
  });

  group('applyGrade — good', () {
    test('good 连续两次：1 → 2（trunc(1 × 2.5)）', () {
      final first = applyGrade(null, Grade.good, NOW);
      final second = applyGrade(first, Grade.good, NOW);
      expect(first.intervalDays, 1);
      expect(second.intervalDays, 2);
      expect(second.reviewCount, 2);
      expect(second.dueAt, NOW + 2 * DAY);
    });

    test('good 第三次：2 → 5', () {
      var s = applyGrade(null, Grade.good, NOW);
      s = applyGrade(s, Grade.good, NOW);
      s = applyGrade(s, Grade.good, NOW);
      expect(s.intervalDays, 5);
    });

    // 回归：曾因 `correct = difficulty <= 2` 把 good 误判为 lapse，
    // 导致间隔恒为 1、correctCount 不增长。
    test('good 递增 correctCount', () {
      final first = applyGrade(null, Grade.good, NOW);
      expect(first.correctCount, 1);
      final second = applyGrade(first, Grade.good, NOW);
      expect(second.correctCount, 2);
    });

    test('good 在 ease 未封顶时 +0.1', () {
      final next = applyGrade(reviewed(5, 2.0), Grade.good, NOW);
      expect(next.intervalDays, 10);
      expect(next.ease, 2.1);
    });

    test('good 的 ease 不超过上限', () {
      expect(applyGrade(reviewed(1, 2.5), Grade.good, NOW).ease, MAX_EASE);
    });
  });

  group('applyGrade — easy', () {
    test('easy 第二次：1 → 3，比 good 长', () {
      final first = applyGrade(null, Grade.easy, NOW);
      final second = applyGrade(first, Grade.easy, NOW);
      expect(first.intervalDays, 1);
      expect(second.intervalDays, 3);
    });

    test('同一状态下 easy 的间隔大于 good', () {
      final small = reviewed(1, 2.5);
      expect(applyGrade(small, Grade.easy, NOW).intervalDays,
          greaterThan(applyGrade(small, Grade.good, NOW).intervalDays));
      final big = reviewed(10, 2.5);
      expect(applyGrade(big, Grade.easy, NOW).intervalDays, 37);
      expect(applyGrade(big, Grade.good, NOW).intervalDays, 25);
    });

    test('easy 在 ease 未封顶时 +0.15', () {
      final next = applyGrade(reviewed(5, 2.0), Grade.easy, NOW);
      expect(next.intervalDays, 15);
      expect(next.ease, 2.15);
    });

    test('easy 的 ease 不超过上限', () {
      expect(applyGrade(reviewed(1, 2.5), Grade.easy, NOW).ease, MAX_EASE);
    });
  });

  group('applyGrade — hard', () {
    test('hard 把间隔重置为 1', () {
      expect(applyGrade(reviewed(10, 2.5), Grade.hard, NOW).intervalDays, 1);
    });

    test('hard 使 ease 下降 0.2', () {
      expect(applyGrade(reviewed(10, 2.5), Grade.hard, NOW).ease, 2.3);
    });

    test('hard 的 ease 不低于下限 1.3', () {
      expect(applyGrade(reviewed(10, 1.4), Grade.hard, NOW).ease, MIN_EASE);
      expect(applyGrade(reviewed(10, 1.3), Grade.hard, NOW).ease, MIN_EASE);
    });

    test('hard 不增加 correctCount', () {
      expect(applyGrade(reviewed(10, 2.5, correctCount: 4), Grade.hard, NOW)
          .correctCount, 4);
    });

    test('连续 hard 后 ease 停在 1.3', () {
      var s = reviewed(10, 2.5);
      for (var i = 0; i < 10; i++) {
        s = applyGrade(s, Grade.hard, NOW);
      }
      expect(s.ease, MIN_EASE);
    });
  });

  group('applyGrade — 边界', () {
    test('反复 easy 时 ease 恰好封顶在 2.5', () {
      var s = freshSrs(NOW);
      for (var i = 0; i < 50; i++) {
        s = applyGrade(s, Grade.easy, NOW);
      }
      expect(s.ease, MAX_EASE);
      expect(s.ease, lessThanOrEqualTo(MAX_EASE));
    });

    test('间隔不超过 3650 天', () {
      expect(applyGrade(reviewed(3000, 2.5), Grade.easy, NOW).intervalDays,
          MAX_INTERVAL_DAYS);
      expect(applyGrade(reviewed(3000, 2.5), Grade.good, NOW).intervalDays,
          MAX_INTERVAL_DAYS);
    });

    test('hard 之后间隔至少为 1 天', () {
      expect(applyGrade(reviewed(0, 2.5), Grade.hard, NOW).intervalDays, 1);
    });

    test('不修改传入的状态对象', () {
      final current = reviewed(4, 2.0);
      final snapshot = current.toJson();
      final next = applyGrade(current, Grade.good, NOW);
      expect(current.toJson(), snapshot);
      expect(identical(next, current), isFalse);
    });
  });

  group('statusRank / nextStatus', () {
    test('等级与 STATUS_ORDER 一致', () {
      expect(statusRank(WordStatus.new_), 0);
      expect(statusRank(WordStatus.reviewing), 1);
      expect(statusRank(WordStatus.learning), 2);
      expect(statusRank(WordStatus.mastered), 3);
    });

    test('nextStatus 提升到更高的等级', () {
      expect(nextStatus(WordStatus.learning, WordStatus.reviewing),
          WordStatus.learning);
      expect(nextStatus(WordStatus.reviewing, WordStatus.new_),
          WordStatus.reviewing);
    });

    test('nextStatus 永不降级：earned 更低时保留当前状态', () {
      expect(nextStatus(WordStatus.reviewing, WordStatus.mastered),
          WordStatus.mastered);
      expect(nextStatus(WordStatus.new_, WordStatus.learning),
          WordStatus.learning);
      expect(nextStatus(WordStatus.learning, WordStatus.mastered),
          WordStatus.mastered);
    });

    test('nextStatus 同级时保持当前状态', () {
      expect(nextStatus(WordStatus.reviewing, WordStatus.reviewing),
          WordStatus.reviewing);
      expect(nextStatus(WordStatus.mastered, WordStatus.mastered),
          WordStatus.mastered);
    });
  });

  group('reviewCard', () {
    const ids = (wordId: 'w1', logId: 'r1');

    test('新卡评分：间隔 1 天、复习次数 1、状态提升为 reviewing', () {
      final result = reviewCard(
        const CardState(srs: null, status: WordStatus.new_),
        Grade.good,
        NOW,
        wordId: ids.wordId,
        logId: ids.logId,
      );
      expect(result.srs.intervalDays, 1);
      expect(result.srs.reviewCount, 1);
      expect(result.srs.lastReviewedAt, NOW);
      expect(result.status, WordStatus.reviewing);
    });

    test('新卡的 intervalBefore 记为 0', () {
      final result = reviewCard(
        const CardState(srs: null, status: WordStatus.new_),
        Grade.easy,
        NOW,
        wordId: ids.wordId,
        logId: ids.logId,
      );
      expect(result.log.intervalBefore, 0);
      expect(result.log.intervalAfter, 1);
    });

    test('记录复习日志的每个字段', () {
      final result = reviewCard(
        CardState(srs: reviewed(5, 2.0), status: WordStatus.reviewing),
        Grade.good,
        NOW,
        wordId: ids.wordId,
        logId: ids.logId,
      );
      expect(result.srs.intervalDays, 10);
      final l = result.log;
      expect(l.id, 'r1');
      expect(l.wordId, 'w1');
      expect(l.grade, Grade.good);
      expect(l.at, NOW);
      expect(l.intervalBefore, 5);
      expect(l.intervalAfter, 10);
    });

    test('把状态提升到新间隔对应的等级', () {
      // 5 天 × 2.5 = 12 天 → learning
      final result = reviewCard(
        CardState(srs: reviewed(5, 2.5), status: WordStatus.reviewing),
        Grade.good,
        NOW,
        wordId: ids.wordId,
        logId: ids.logId,
      );
      expect(result.srs.intervalDays, 12);
      expect(result.status, WordStatus.learning);
    });

    test('earned 状态更低时保留原状态（永不降级）', () {
      // 已掌握的卡片答 hard：间隔重置为 1 天，earned 状态只有 reviewing。
      final result = reviewCard(
        CardState(srs: reviewed(30, 2.5), status: WordStatus.mastered),
        Grade.hard,
        NOW,
        wordId: ids.wordId,
        logId: ids.logId,
      );
      expect(result.srs.intervalDays, 1);
      expect(statusForInterval(result.srs.intervalDays), WordStatus.reviewing);
      // 返回的是提升后的最终状态，而不是 earned 状态。
      expect(result.status, WordStatus.mastered);
    });

    test('不修改传入的卡片状态对象', () {
      final cardSrs = reviewed(4, 2.0);
      final card = CardState(srs: cardSrs, status: WordStatus.reviewing);
      final snapshot = cardSrs.toJson();
      reviewCard(card, Grade.easy, NOW, wordId: ids.wordId, logId: ids.logId);
      expect(card.srs!.toJson(), snapshot);
      expect(card.status, WordStatus.reviewing);
    });
  });

  group('undoGrade', () {
    const ids = (wordId: 'w1', logId: 'r1');

    test('恢复评分前的卡片并返回要删除的日志 id', () {
      final prevSrs = reviewed(5, 2.0);
      final prev = CardState(srs: prevSrs, status: WordStatus.reviewing);
      final graded =
          reviewCard(prev, Grade.good, NOW, wordId: ids.wordId, logId: ids.logId);
      final undone = undoGrade(prev, graded.log.id);
      expect(identical(undone.srs, prevSrs), isTrue);
      expect(undone.status, prev.status);
      expect(undone.removedLogId, 'r1');
    });

    test('srs 为 null 的卡片同样精确还原', () {
      const prev = CardState(srs: null, status: WordStatus.new_);
      final graded =
          reviewCard(prev, Grade.good, NOW, wordId: ids.wordId, logId: ids.logId);
      final undone = undoGrade(prev, graded.log.id);
      expect(undone.srs, isNull);
      expect(undone.status, WordStatus.new_);
      expect(undone.removedLogId, graded.log.id);
    });

    test('是 reviewCard 的精确逆操作（遍历评分与状态）', () {
      for (final grade in grades) {
        for (final status in STATUS_ORDER) {
          final prevSrs = reviewed(4, 2.0);
          final prev = CardState(srs: prevSrs, status: status);
          final graded = reviewCard(prev, grade, NOW,
              wordId: ids.wordId, logId: ids.logId);
          final undone = undoGrade(prev, graded.log.id);
          expect(identical(undone.srs, prevSrs), isTrue);
          expect(undone.status, status);
          expect(undone.removedLogId, graded.log.id);
        }
      }
    });

    test('不重新计算调度：mastered 卡片 hard 后撤销仍恢复 mastered', () {
      final prevSrs = reviewed(30, 2.5);
      final prev = CardState(srs: prevSrs, status: WordStatus.mastered);
      final graded =
          reviewCard(prev, Grade.hard, NOW, wordId: ids.wordId, logId: ids.logId);
      // 若撤销时按评分后的间隔重算，会得到 reviewing —— 这正是不能重算的原因。
      expect(statusForInterval(graded.srs.intervalDays), WordStatus.reviewing);
      expect(undoGrade(prev, graded.log.id).status, WordStatus.mastered);
    });
  });

  group('previewGrades', () {
    test('新卡三个评分都预览 1 天，并预览提升后的状态', () {
      final p = previewGrades(
          const CardState(srs: null, status: WordStatus.new_), NOW);
      expect(p[Grade.hard], (intervalDays: 1, status: WordStatus.reviewing));
      expect(p[Grade.good], (intervalDays: 1, status: WordStatus.reviewing));
      expect(p[Grade.easy], (intervalDays: 1, status: WordStatus.reviewing));
    });

    test('已复习卡片按真实调度预览', () {
      final p = previewGrades(
          CardState(srs: reviewed(1, 2.5), status: WordStatus.reviewing), NOW);
      expect(p[Grade.hard], (intervalDays: 1, status: WordStatus.reviewing));
      expect(p[Grade.good], (intervalDays: 2, status: WordStatus.reviewing));
      expect(p[Grade.easy], (intervalDays: 3, status: WordStatus.reviewing));
    });

    test('预览的状态与 reviewCard 实际应用的状态一致', () {
      final card = CardState(srs: reviewed(5, 2.0), status: WordStatus.reviewing);
      final preview = previewGrades(card, NOW);
      for (final grade in grades) {
        final applied = reviewCard(card, grade, NOW, wordId: 'w1', logId: 'r1');
        expect(
          preview[grade],
          (intervalDays: applied.srs.intervalDays, status: applied.status),
        );
      }
    });

    test('已掌握的卡片预览仍保持 mastered（永不降级）', () {
      final p = previewGrades(
          CardState(srs: reviewed(30, 2.5), status: WordStatus.mastered), NOW);
      expect(p[Grade.hard],
          (intervalDays: 1, status: WordStatus.mastered));
    });
  });

  group('statusForInterval', () {
    final cases = <(int, WordStatus)>[
      (0, WordStatus.new_),
      (-3, WordStatus.new_),
      (1, WordStatus.reviewing),
      (LEARNING_INTERVAL_DAYS - 1, WordStatus.reviewing),
      (LEARNING_INTERVAL_DAYS, WordStatus.learning),
      (MASTERED_INTERVAL_DAYS - 1, WordStatus.learning),
      (MASTERED_INTERVAL_DAYS, WordStatus.mastered),
      (MAX_INTERVAL_DAYS, WordStatus.mastered),
    ];
    for (final (days, status) in cases) {
      test('$days 天 → ${status.wire}', () {
        expect(statusForInterval(days), status);
      });
    }
  });

  group('formatInterval', () {
    final cases = <(int, String)>[
      (0, '<1天'),
      (-5, '<1天'),
      (1, '1天'),
      (6, '6天'),
      (29, '29天'),
      (30, '1月'),
      (45, '2月'),
      (364, '12月'),
      (365, '1年'),
      (547, '1.5年'),
      (730, '2年'),
      (3650, '10年'),
      (4015, '11年'),
    ];
    for (final (days, label) in cases) {
      test('$days 天 → $label', () {
        expect(formatInterval(days), label);
      });
    }
  });

  group('isNew', () {
    test('null 视为新卡', () {
      expect(isNew(null), isTrue);
    });

    test('复习过的卡片不再是新卡', () {
      expect(isNew(freshSrs(NOW)), isTrue);
      expect(isNew(reviewed(1, 2.5)), isFalse);
    });
  });

  /* ================================================================ */
  /* dayStats.test.ts                                                  */
  /* ================================================================ */

  group('reviewsToday', () {
    test('counts only reviews since local midnight', () {
      final data = appData([], logs: [
        log(daysAgo(1) + 12 * 3600000),
        log(daysAgo(0)),
        log(NOW),
      ]);
      expect(reviewsToday(data, NOW), 2);
    });

    test('counts a review at exactly midnight as today', () {
      expect(reviewsToday(appData([], logs: [log(daysAgo(0))]), NOW), 1);
    });

    test('is zero without logs', () {
      expect(reviewsToday(appData([]), NOW), 0);
    });
  });

  group('streakDays', () {
    test('counts consecutive days ending today', () {
      final data = appData([], logs: [
        log(daysAgo(0)),
        log(daysAgo(1)),
        log(daysAgo(2)),
      ]);
      expect(streakDays(data, NOW), 3);
    });

    test('does not break the streak when today is still empty', () {
      // Yesterday and the day before, nothing yet today: the streak is still 2.
      final data = appData([], logs: [log(daysAgo(1)), log(daysAgo(2))]);
      expect(streakDays(data, NOW), 2);
    });

    test('stops at the first missing day', () {
      final data = appData([], logs: [
        log(daysAgo(0)),
        log(daysAgo(1)),
        log(daysAgo(3)),
      ]);
      expect(streakDays(data, NOW), 2);
    });

    test('counts several reviews on one day once', () {
      final data = appData([], logs: [log(daysAgo(0) + 3600000), log(NOW)]);
      expect(streakDays(data, NOW), 1);
    });

    test('is zero with no logs, and zero when the last review is older than yesterday',
        () {
      expect(streakDays(appData([]), NOW), 0);
      expect(streakDays(appData([], logs: [log(daysAgo(3))]), NOW), 0);
    });

    test('keeps month and day apart (0-based months must not collide)', () {
      // Jan 31 → Feb 1 is a real consecutive pair; a key that concatenated the
      // unpadded numbers would still work here, but a padded one must too.
      final jan31 = DateTime(2024, 1, 31, 12).millisecondsSinceEpoch;
      final feb01 = DateTime(2024, 2, 1, 12).millisecondsSinceEpoch;
      expect(streakDays(appData([], logs: [log(jan31), log(feb01)]), feb01), 2);
    });
  });

  /* ================================================================ */
  /* session.test.ts                                                   */
  /* ================================================================ */

  const ids = ['a', 'b', 'c'];

  /// Answer once and hand back the resulting progress for before/after checks.
  SessionProgress answer(Session session, bool correct) {
    session.record(correct: correct);
    return session.progress();
  }

  group('createSession', () {
    test('空卡组没有当前卡，进度归零且直接算完成', () {
      final session = createSession(ids: []);

      expect(session.current(), isNull);
      expect(
        session.progress(),
        const SessionProgress(
          index: 0,
          total: 0,
          reviewed: 0,
          correct: 0,
          skipped: 0,
          accuracy: 0,
          done: true,
        ),
      );
      expect(session.canUndo(), isFalse);
      expect(session.undo(), isNull);
    });

    test('新会话停在第一张卡，正确率是 0 而不是 NaN', () {
      final session = createSession(ids: ids);

      expect(session.current(), 'a');
      expect(
        session.progress(),
        const SessionProgress(
          index: 0,
          total: 3,
          reviewed: 0,
          correct: 0,
          skipped: 0,
          accuracy: 0,
          done: false,
        ),
      );
    });

    test('record 推进卡片并累计复习张数与正确数', () {
      final session = createSession(ids: ids);

      final first = answer(session, true);
      expect(first.index, 1);
      expect(first.reviewed, 1);
      expect(first.correct, 1);
      expect(first.done, isFalse);
      expect(session.current(), 'b');

      final afterWrong = answer(session, false);
      expect(afterWrong.index, 2);
      expect(afterWrong.reviewed, 2);
      expect(afterWrong.correct, 1);
      expect(afterWrong.accuracy, closeTo(0.5, 1e-9));

      final afterLast = answer(session, true);
      expect(afterLast.index, 3);
      expect(afterLast.reviewed, 3);
      expect(afterLast.correct, 2);
      expect(afterLast.done, isTrue);
      expect(afterLast.accuracy, closeTo(2 / 3, 1e-9));
      expect(session.current(), isNull);
    });

    test('skip 只计入 skipped，不算复习，也不影响正确率', () {
      final session = createSession(ids: ids);

      session.skip();
      var p = session.progress();
      expect(p.index, 1);
      expect(p.reviewed, 0);
      expect(p.skipped, 1);
      expect(p.accuracy, 0);
      expect(p.done, isFalse);
      expect(session.current(), 'b');

      session.skip();
      session.skip();
      p = session.progress();
      expect(p.index, 3);
      expect(p.reviewed, 0);
      expect(p.skipped, 3);
      expect(p.accuracy, 0);
      expect(p.done, isTrue);
      expect(session.current(), isNull);
    });

    test('完成后 record / skip 不再改变进度', () {
      final session = createSession(ids: ['a']);
      answer(session, true);
      final finished = session.progress();

      session.record(correct: false);
      session.skip();

      expect(session.progress(), finished);
      expect(session.current(), isNull);
    });
  });

  group('gradeCountsAsCorrect', () {
    final cases = <(Grade, bool)>[
      (Grade.hard, false),
      (Grade.good, true),
      (Grade.easy, true),
    ];
    for (final (grade, expected) in cases) {
      test('${grade.wire} → $expected', () {
        expect(gradeCountsAsCorrect(grade), expected);
      });
    }

    test('只答困难时复习张数增加，但正确数不增加', () {
      final session = createSession(ids: ['a']);

      session.record(correct: gradeCountsAsCorrect(Grade.hard));

      final p = session.progress();
      expect(p.reviewed, 1);
      expect(p.correct, 0);
      expect(p.accuracy, 0);
    });
  });

  group('undo', () {
    test('撤销一次答对，精确回到作答前的进度与卡片', () {
      final session = createSession(ids: ids);
      final before = session.progress();

      session.record(correct: true);
      final step = session.undo();

      expect(step, const RecordStep('a', correct: true));
      expect(session.progress(), before);
      expect(session.current(), 'a');
      expect(session.canUndo(), isFalse);
    });

    test('撤销一次答错，精确回到作答前的进度', () {
      final session = createSession(ids: ids);
      answer(session, true);
      final before = session.progress();

      session.record(correct: false);
      session.undo();

      expect(session.progress(), before);
      expect(session.current(), 'b');
    });

    test('撤销 skip 精确还原 skipped 与卡片位置', () {
      final session = createSession(ids: ids);
      final before = session.progress();

      session.skip();
      final step = session.undo();

      expect(step, const SkipStep('a'));
      expect(session.progress(), before);
      expect(session.current(), 'a');
    });

    test('连续撤销按后进先出回到每一个中间状态', () {
      final session = createSession(ids: ids);
      final states = [session.progress()];

      states.add(answer(session, true));
      session.skip();
      states.add(session.progress());

      expect(session.undo(), const SkipStep('b'));
      expect(session.progress(), states[1]);

      expect(session.undo(), const RecordStep('a', correct: true));
      expect(session.progress(), states[0]);

      expect(session.undo(), isNull);
    });

    test('撤销在完成后也能回到未完成状态', () {
      final session = createSession(ids: ['a']);
      answer(session, true);
      expect(session.progress().done, isTrue);

      session.undo();

      expect(session.progress().index, 0);
      expect(session.progress().done, isFalse);
      expect(session.current(), 'a');
    });
  });

  group('reset', () {
    test('reset 回到第一张卡并清空历史', () {
      final session = createSession(ids: ids);
      answer(session, true);
      session.skip();

      session.reset();

      expect(
        session.progress(),
        const SessionProgress(
          index: 0,
          total: 3,
          reviewed: 0,
          correct: 0,
          skipped: 0,
          accuracy: 0,
          done: false,
        ),
      );
      expect(session.current(), 'a');
      expect(session.canUndo(), isFalse);
    });
  });

  group('formatAccuracy', () {
    final cases = <(double, String)>[
      (0, '0%'),
      (0.5, '50%'),
      (1, '100%'),
      (2 / 3, '67%'),
    ];
    for (final (accuracy, expected) in cases) {
      test('$accuracy → $expected', () {
        expect(formatAccuracy(accuracy), expected);
      });
    }
  });

  /* ================================================================ */
  /* quiz.test.ts                                                      */
  /* ================================================================ */

  /// A deck whose terms and definitions are all distinct, so every question
  /// can find its distractors.
  List<Word> deck(int n) =>
      [for (var i = 0; i < n; i++) word('w$i', {'term': 'term$i', 'definition': 'def$i'})];

  group('quizEligibleWords', () {
    test('只保留词形与释义都非空的词', () {
      final words = [
        word('w1', {'term': 'apple', 'definition': '苹果'}),
        word('w2', {'term': 'banana', 'definition': ''}),
        word('w3', {'term': '', 'definition': '樱桃'}),
        word('w4', {'term': '   ', 'definition': '   '}),
        word('w5', {'term': ' date ', 'definition': '枣 '}),
      ];

      expect(quizEligibleWords(words).map((w) => w.id).toList(), ['w1', 'w5']);
    });

    test('全空的词表得到空数组', () {
      expect(quizEligibleWords([]), isEmpty);
    });
  });

  group('buildQuiz', () {
    test('每题给出 4 个互不相同的选项，正确答案恰好出现一次', () {
      final questions = buildQuiz(deck(10), QuizDirection.termToDef);

      expect(questions.length, greaterThan(0));
      for (final q in questions) {
        expect(q.options.length, QUIZ_CHOICES);
        expect(q.options.toSet().length, QUIZ_CHOICES);
        expect(q.options.where((o) => o == q.answer).length, 1);
      }
    });

    test('answerIndex 正好指向正确答案', () {
      for (final q in buildQuiz(deck(10), QuizDirection.defToTerm)) {
        expect(q.answerIndex, greaterThanOrEqualTo(0));
        expect(q.answerIndex, lessThan(q.options.length));
        expect(q.options[q.answerIndex], q.answer);
      }
    });

    test('看词选义：题干是词形，答案是释义', () {
      final words = deck(6);
      final byId = {for (final w in words) w.id: w};

      for (final q in buildQuiz(words, QuizDirection.termToDef)) {
        final source = byId[q.wordId]!;
        expect(q.prompt, source.term);
        expect(q.answer, source.definition);
      }
    });

    test('看义选词：题干是释义，答案是词形', () {
      final words = deck(6);
      final byId = {for (final w in words) w.id: w};

      for (final q in buildQuiz(words, QuizDirection.defToTerm)) {
        final source = byId[q.wordId]!;
        expect(q.prompt, source.definition);
        expect(q.answer, source.term);
      }
    });

    test('同一轮里每个词最多出现一次', () {
      final questions = buildQuiz(deck(20), QuizDirection.termToDef);
      final questionIds = questions.map((q) => q.wordId).toList();

      expect(questionIds.length, QUIZ_ROUND);
      expect(questionIds.toSet().length, questionIds.length);
    });

    test('轮次大小受 count 限制', () {
      expect(buildQuiz(deck(15), QuizDirection.termToDef).length, QUIZ_ROUND);
      expect(buildQuiz(deck(15), QuizDirection.termToDef, count: 3).length, 3);
    });

    test('释义相同的词不会成为同一题的重复选项', () {
      // 两个词共用一个释义：互相不能当对方的干扰项，选项文本仍然唯一。
      final words = [
        word('w0', {'term': 'a', 'definition': 'same'}),
        word('w1', {'term': 'b', 'definition': 'same'}),
        word('w2', {'term': 'c', 'definition': 'x'}),
        word('w3', {'term': 'd', 'definition': 'y'}),
        word('w4', {'term': 'e', 'definition': 'z'}),
      ];

      for (final q in buildQuiz(words, QuizDirection.termToDef)) {
        expect(q.options.toSet().length, q.options.length);
      }
    });

    test('可用词不足 4 个时返回空数组', () {
      expect(buildQuiz(deck(3), QuizDirection.termToDef), isEmpty);
    });

    test('count 不为正时返回空数组', () {
      expect(buildQuiz(deck(10), QuizDirection.termToDef, count: 0), isEmpty);
      expect(buildQuiz(deck(10), QuizDirection.termToDef, count: -1), isEmpty);
    });

    test('没有可用词时返回空数组', () {
      final words = [
        word('w0', {'term': 'a', 'definition': ''}),
        word('w1', {'term': 'b', 'definition': '  '}),
        word('w2', {'term': '', 'definition': 'c'}),
      ];
      expect(buildQuiz(words, QuizDirection.termToDef), isEmpty);
    });
  });

  group('quizShortfall', () {
    test('能出题时返回 null', () {
      expect(quizShortfall(deck(10), QuizDirection.termToDef), isNull);
    });

    test('一个可用词都没有时说明是 no-eligible-words', () {
      expect(quizShortfall(deck(0), QuizDirection.termToDef),
          QuizShortfall.noEligibleWords);
      expect(
        quizShortfall([
          word('w0', {'term': 'a', 'definition': ''}),
          word('w1', {'term': '', 'definition': 'b'}),
        ], QuizDirection.termToDef),
        QuizShortfall.noEligibleWords,
      );
    });

    test('可用词不足 4 个时说明是 not-enough-words', () {
      expect(quizShortfall(deck(3), QuizDirection.termToDef),
          QuizShortfall.notEnoughWords);
      // 有词但释义缺失，原因仍应是"词不够"而不是"一个都没有"。
      expect(
        quizShortfall([...deck(3), word('w9', {'term': 'term9', 'definition': ''})],
            QuizDirection.termToDef),
        QuizShortfall.notEnoughWords,
      );
    });

    test('这一轮没有意义时说明是 empty-round', () {
      expect(quizShortfall(deck(10), QuizDirection.termToDef, count: 0),
          QuizShortfall.emptyRound);
    });

    test('词够多但干扰项文本全都重复时说明是 not-enough-distractors', () {
      // 四个可用词，却只有三个不同的释义：每个词都凑不齐三个干扰项。
      final words = [
        word('w0', {'term': 'a', 'definition': 'same'}),
        word('w1', {'term': 'b', 'definition': 'same'}),
        word('w2', {'term': 'c', 'definition': 'same'}),
        word('w3', {'term': 'd', 'definition': 'same'}),
      ];

      expect(quizShortfall(words, QuizDirection.termToDef),
          QuizShortfall.notEnoughDistractors);
      expect(buildQuiz(words, QuizDirection.termToDef), isEmpty);
    });

    test('空结果与 shortfall 判断始终一致', () {
      final cases = <(List<Word>, int)>[
        (deck(10), QUIZ_ROUND),
        (deck(3), QUIZ_ROUND),
        (deck(0), QUIZ_ROUND),
        (deck(10), 0),
        (deck(4), QUIZ_ROUND),
      ];

      for (final (words, count) in cases) {
        final questions =
            buildQuiz(words, QuizDirection.termToDef, count: count);
        expect(
          questions.isEmpty,
          quizShortfall(words, QuizDirection.termToDef, count: count) != null,
        );
      }
    });
  });

  /* ================================================================ */
  /* wordIndex.test.ts                                                 */
  /* ================================================================ */

  group('statusRank', () {
    test('四种状态只有一个顺序：new < reviewing < learning < mastered', () {
      const order = [
        WordStatus.new_,
        WordStatus.reviewing,
        WordStatus.learning,
        WordStatus.mastered,
      ];
      expect(order.map(statusRank).toList(), [0, 1, 2, 3]);
    });
  });

  group('buildWordIndex — 分库计数', () {
    test('每个词库都有 all 与四种状态的计数，空词库也在', () {
      final words = [
        word('a1', {'listId': 'a', 'status': WordStatus.new_}),
        word('a2', {'listId': 'a', 'status': WordStatus.reviewing}),
        word('a3', {'listId': 'a', 'status': WordStatus.mastered}),
        word('b1', {'listId': 'b', 'status': WordStatus.learning}),
      ];
      final index = buildWordIndex(
        appData(words, lists: [list('a'), list('b'), list('c')]),
        NOW,
      );

      expect(index.countsByList['a'],
          {'all': 3, 'new': 1, 'reviewing': 1, 'learning': 0, 'mastered': 1});
      expect(index.countsByList['b'],
          {'all': 1, 'new': 0, 'reviewing': 0, 'learning': 1, 'mastered': 0});
      // A declared but empty list still gets a zeroed bucket.
      expect(index.countsByList['c'],
          {'all': 0, 'new': 0, 'reviewing': 0, 'learning': 0, 'mastered': 0});
      expect(index.byList['a']!.map((w) => w.id).toList(), ['a1', 'a2', 'a3']);
      expect(index.byList['c'], isEmpty);
    });
  });

  group('buildWordIndex — 分桶不依赖标签', () {
    test('同一个词库的多个词各自入桶；跨库互不干扰', () {
      final words = [
        word('w1', {'listId': 'a'}),
        word('w2', {'listId': 'a'}),
        word('w3', {'listId': 'b'}),
      ];
      final index = buildWordIndex(appData(words), NOW);

      expect(index.byList['a']!.map((w) => w.id).toList(), ['w1', 'w2']);
      expect(index.byList['b']!.map((w) => w.id).toList(), ['w3']);
    });
  });

  group('buildWordIndex — 到期判定', () {
    test('已掌握排除；无 srs 计入；未来到期排除；到期边界含等于', () {
      final words = [
        word('masteredPast', {
          'status': WordStatus.mastered,
          'srs': srs({'dueAt': NOW - DAY}),
        }),
        word('nullSrs', {'srs': null}),
        word('dueNow', {
          'status': WordStatus.reviewing,
          'srs': srs({'dueAt': NOW}),
        }),
        word('future', {
          'status': WordStatus.reviewing,
          'srs': srs({'dueAt': NOW + DAY}),
        }),
        word('past', {'status': WordStatus.learning, 'srs': srs({'dueAt': NOW - DAY})}),
        word('masteredNull', {'listId': 'b', 'status': WordStatus.mastered}),
      ];
      final index = buildWordIndex(appData(words), NOW);

      // Snapshot order is preserved; mastered words are never due, even with a
      // past dueAt or a missing srs.
      expect(index.due.map((w) => w.id).toList(), ['nullSrs', 'dueNow', 'past']);
      expect(index.dueByList['a']!.map((w) => w.id).toList(),
          ['nullSrs', 'dueNow', 'past']);
      expect(index.dueByList.containsKey('b'), isFalse);
    });
  });

  List<Word> queryFixture() => [
        word('zebra', {'term': 'zebra', 'definition': 'striped equine', 'createdAt': 100}),
        word('apple', {
          'term': 'apple',
          'definition2': 'a hidden meaning',
          'favorite': true,
          'createdAt': 400,
        }),
        word('boat', {
          'term': 'boat',
          'note': 'sails on water',
          'status': WordStatus.reviewing,
          'createdAt': 300,
        }),
        word('cat', {
          'term': 'cat',
          'definition': 'small animal',
          'pos': 'n.',
          'status': WordStatus.mastered,
          'createdAt': 200,
        }),
      ];

  group('queryWords — 搜索', () {
    final index = buildWordIndex(appData(queryFixture()), NOW);
    List<String> queryIds(String q) =>
        queryWords(index, WordQuery(listId: 'a', query: q))
            .map((w) => w.id)
            .toList();

    test('大小写不敏感地匹配 term', () {
      expect(queryIds('ZEBRA'), ['zebra']);
    });

    test('匹配 definition / definition2 / note', () {
      expect(queryIds('striped'), ['zebra']);
      expect(queryIds('HIDDEN'), ['apple']);
      expect(queryIds('sails'), ['boat']);
    });

    test('只搜 term / definition / definition2 / note —— 词性与音标不进搜索', () {
      // `cat` carries pos "n.", `zebra` nothing extra: searching the tag must
      // not light up every noun, because the tag is a label the user did not
      // type.
      expect(queryIds('n.'), isEmpty);
    });

    test('忽略首尾空白；无匹配返回空', () {
      expect(queryIds('  zebra  '), ['zebra']);
      expect(queryIds('nope'), isEmpty);
      expect(queryIds('   ').length, 4);
    });
  });

  group('queryWords — 筛选', () {
    final index = buildWordIndex(appData(queryFixture()), NOW);

    test('按状态筛选', () {
      expect(
        queryWords(index, WordQuery(listId: 'a', status: WordStatus.reviewing))
            .map((w) => w.id)
            .toList(),
        ['boat'],
      );
      expect(
        queryWords(index, WordQuery(listId: 'a', status: WordStatus.mastered))
            .map((w) => w.id)
            .toList(),
        ['cat'],
      );
      expect(queryWords(index, const WordQuery(listId: 'a')).length, 4);
    });

    test('只看收藏', () {
      expect(
        queryWords(index, const WordQuery(listId: 'a', favoriteOnly: true))
            .map((w) => w.id)
            .toList(),
        ['apple'],
      );
    });

    test('未知词库返回空数组', () {
      expect(queryWords(index, const WordQuery(listId: 'nope')), isEmpty);
    });
  });

  group('queryWords — 排序', () {
    test('recent：createdAt 降序，且是默认排序', () {
      final index = buildWordIndex(appData(queryFixture()), NOW);
      expect(
        queryWords(index, const WordQuery(listId: 'a', sort: SortKey.recent))
            .map((w) => w.id)
            .toList(),
        ['apple', 'boat', 'cat', 'zebra'],
      );
      expect(
        queryWords(index, const WordQuery(listId: 'a'))
            .map((w) => w.id)
            .toList(),
        ['apple', 'boat', 'cat', 'zebra'],
      );
    });

    test('alpha：term 按 lang 排序', () {
      final index = buildWordIndex(appData(queryFixture()), NOW);
      expect(
        queryWords(
                index,
                const WordQuery(listId: 'a', sort: SortKey.alpha, lang: 'en'))
            .map((w) => w.id)
            .toList(),
        ['apple', 'boat', 'cat', 'zebra'],
      );
    });

    test('status：先状态序，再 term 兜底', () {
      final words = [
        word('s1', {'term': 'cat', 'status': WordStatus.reviewing}),
        word('s2', {'term': 'zebra', 'status': WordStatus.new_}),
        word('s3', {'term': 'ant', 'status': WordStatus.reviewing}),
      ];
      final index = buildWordIndex(appData(words), NOW);
      // new (rank 0) first, then the two reviewing words by term: ant < cat.
      expect(
        queryWords(
                index,
                const WordQuery(listId: 'a', sort: SortKey.status, lang: 'en'))
            .map((w) => w.id)
            .toList(),
        ['s2', 's3', 's1'],
      );
    });

    test('due：dueAt 升序，同到期时间用状态序兜底', () {
      final words = [
        word('d1', {
          'status': WordStatus.mastered,
          'srs': srs({'dueAt': NOW + 2 * DAY}),
        }),
        word('d2', {'status': WordStatus.mastered, 'srs': srs({'dueAt': NOW})}),
        word('d3', {'status': WordStatus.new_, 'srs': srs({'dueAt': NOW})}),
        word('d4', {'status': WordStatus.reviewing, 'srs': null}),
      ];
      final index = buildWordIndex(appData(words), NOW);
      // d4 has no srs → dueAt 0 → first. d2/d3 tie on dueAt; new ranks before
      // mastered, so d3 comes first even though d2 was inserted first.
      expect(
        queryWords(index, const WordQuery(listId: 'a', sort: SortKey.due))
            .map((w) => w.id)
            .toList(),
        ['d4', 'd3', 'd2', 'd1'],
      );
    });
  });

  group('summarize — 统计头条', () {
    test('一次算出全部头条数字，且沿用旧 StatsPage 的算法', () {
      final words = [
        word('w1', {'status': WordStatus.new_}),
        word('w2', {
          'status': WordStatus.reviewing,
          'srs': srs({
            'dueAt': TODAY_START - 1,
            'reviewCount': 3,
            'correctCount': 2,
            'intervalDays': 5,
          }),
        }),
        word('w3', {
          'status': WordStatus.learning,
          // Due exactly at midnight: due today, but NOT overdue.
          'srs': srs({
            'dueAt': TODAY_START,
            'reviewCount': 2,
            'correctCount': 2,
            'intervalDays': 7,
          }),
        }),
        word('w4', {
          'status': WordStatus.mastered,
          'srs': srs({
            'dueAt': TODAY_START - DAY,
            'reviewCount': 10,
            'correctCount': 9,
            'intervalDays': 30,
          }),
        }),
        word('w5', {'status': WordStatus.mastered}),
        word('w6', {'status': WordStatus.new_}),
      ];
      final logs = [
        log(NOW),
        log(NOW - DAY),
        log(NOW - 2 * DAY),
        log(NOW - 4 * DAY),
      ];
      final summary = summarize(appData(words, logs: logs, dailyGoal: 2), NOW);

      expect(summary.total, 6);
      expect(summary.statusCounts,
          {'new': 2, 'reviewing': 1, 'learning': 1, 'mastered': 2});
      expect(summary.mastered, 2);
      expect(summary.masteryPct, 33); // 2/6 = 33.33 → 33
      expect(summary.overdue, 1); // only w2 is strictly before midnight
      expect(summary.dueToday, 4); // w1, w2, w3 (midnight), w6
      expect(summary.today, 1);
      expect(summary.streak, 3); // today, yesterday, day before
      expect(summary.goal, 2);
      expect(summary.goalPct, 0.5);
      expect(summary.reached, isFalse);
      expect(summary.remaining, 1);
      expect(summary.reviewSum, 15);
      expect(summary.correctSum, 13);
      expect(summary.reviewedWords, 3);
      expect(summary.scheduled, 3);
      expect(summary.retention, 87); // 13/15 = 86.66 → 87
      expect(summary.avgInterval, 14); // (5 + 7 + 30) / 3
    });

    test('没有可计算的复习时 retention 为 null，avgInterval 为 0', () {
      final summary = summarize(appData([word('w1')]), NOW);
      expect(summary.retention, isNull);
      expect(summary.avgInterval, 0);
      expect(summary.today, 0);
      expect(summary.streak, 0);
      expect(summary.reviewedWords, 0);
      expect(summary.dueToday, 1);
      expect(summary.goal, 20); // DEFAULT_SETTINGS.dailyGoal
    });

    test('有 srs 但 reviewCount 为 0 时同样不计入留存率', () {
      final summary = summarize(
        appData([
          word('w1', {
            'srs': srs({'reviewCount': 0, 'correctCount': 0}),
          })
        ]),
        NOW,
      );
      expect(summary.retention, isNull);
      expect(summary.avgInterval, 0);
      expect(summary.reviewedWords, 0);
      expect(summary.dueToday, 1);
    });

    test('overdue 用严格小于今天零点：零点整不算逾期', () {
      expect(
        summarize(appData([word('w1', {'srs': srs({'dueAt': TODAY_START})})]), NOW)
            .overdue,
        0,
      );
      expect(
        summarize(
                appData([word('w1', {'srs': srs({'dueAt': TODAY_START - 1})})]), NOW)
            .overdue,
        1,
      );
    });

    test('masteryPct 四舍五入（12.5% → 13%）', () {
      final words = [
        word('m', {'status': WordStatus.mastered}),
        for (var i = 0; i < 7; i++) word('n$i', {'status': WordStatus.new_}),
      ];
      expect(summarize(appData(words), NOW).masteryPct, 13);
    });

    test('goal 至少为 1，goalPct 封顶 1', () {
      final summary = summarize(
        appData([word('w1')], dailyGoal: 0, logs: [log(NOW)]),
        NOW,
      );
      expect(summary.goal, 1);
      expect(summary.goalPct, 1);
      expect(summary.reached, isTrue);
      expect(summary.remaining, 0);
    });
  });

  /* ================================================================ */
  /* utils / languages / seed — smoke coverage for the rest of the port */
  /* ================================================================ */

  group('utils', () {
    /// Local-time timestamp helper (month is 1-based, like `utils.test.ts`).
    int at(int year, int month, int day, [int hour = 12]) =>
        DateTime(year, month, day, hour).millisecondsSinceEpoch;

    // --- normalizeTerm -------------------------------------------------
    test('去除首尾空白并转小写', () {
      expect(normalizeTerm('  Hello  '), 'hello');
      expect(normalizeTerm('Café'), 'café');
      expect(normalizeTerm('ÄBC'), 'äbc');
    });

    test('空字符串与纯空白返回空串', () {
      expect(normalizeTerm(''), '');
      expect(normalizeTerm('   '), '');
    });

    // --- clamp ---------------------------------------------------------
    test('区间内原样返回', () {
      expect(clamp(5, 0, 10), 5);
      expect(clamp(0, 0, 10), 0);
      expect(clamp(10, 0, 10), 10);
    });

    test('低于下限取下限，高于上限取上限', () {
      expect(clamp(-1, 0, 10), 0);
      expect(clamp(11, 0, 10), 10);
      expect(clamp(-0.5, -1, 1), -0.5);
    });

    test('min > max 时取 min（Math.max(min, Math.min(max, n)) 的原样结果）', () {
      expect(clamp(5, 0, 3), 3);
      expect(clamp(5, 10, 3), 10);
    });

    // --- shuffle -------------------------------------------------------
    test('返回新数组，长度与元素集合不变，且不修改原数组', () {
      final input = [1, 2, 3, 4, 5];
      final out = shuffle(input);
      expect(identical(out, input), isFalse);
      expect(out.length, input.length);
      expect([...out]..sort(), [...input]..sort());
      expect(input, [1, 2, 3, 4, 5]);
    });

    test('空数组返回空数组', () {
      expect(shuffle(<int>[]), isEmpty);
    });

    test('固定随机数时产生确定的排列', () {
      // Math.random() === 0 → j 始终为 0：[1,2,3,4] → [2,3,4,1]
      expect(shuffle([1, 2, 3, 4], _FixedRandom((max) => 0)), [2, 3, 4, 1]);
      // Math.random() === 0.9999 → j 始终等于 i：排列保持不变
      expect(
        shuffle([1, 2, 3, 4], _FixedRandom((max) => max - 1)),
        [1, 2, 3, 4],
      );
    });

    // --- daysBetween / startOfDay --------------------------------------
    test('同一天内不同时刻相差 0 天', () {
      expect(daysBetween(at(2024, 3, 5, 1), at(2024, 3, 5, 23)), 0);
    });

    test('相邻日期相差 ±1 天', () {
      expect(daysBetween(at(2024, 3, 5), at(2024, 3, 6)), 1);
      expect(daysBetween(at(2024, 3, 6), at(2024, 3, 5)), -1);
    });

    test('跨月、跨年、闰日都按自然日计算', () {
      expect(daysBetween(at(2024, 1, 31), at(2024, 2, 1)), 1);
      expect(daysBetween(at(2023, 12, 31), at(2024, 1, 1)), 1);
      expect(daysBetween(at(2024, 2, 28), at(2024, 2, 29)), 1);
      expect(daysBetween(at(2024, 3, 5), at(2024, 3, 15)), 10);
    });

    test('startOfDay 归零到当天 00:00:00.000', () {
      final t = startOfDay(at(2024, 3, 5, 23));
      final d = DateTime.fromMillisecondsSinceEpoch(t);
      expect([d.hour, d.minute, d.second, d.millisecond], [0, 0, 0, 0]);
      expect(t, at(2024, 3, 5, 0));
      expect(startOfDay(NOW), TODAY_START);
    });

    // --- dayKey --------------------------------------------------------
    test('输出 YYYY-MM-DD 并补零', () {
      expect(dayKeyOfTs(at(2024, 3, 5)), '2024-03-05');
      expect(dayKeyOfTs(at(2024, 3, 9)), '2024-03-09');
      expect(dayKeyOfTs(at(2024, 1, 1)), '2024-01-01');
      expect(dayKeyOfTs(at(2024, 12, 31)), '2024-12-31');
      expect(dayKeyOfTs(DateTime(2024, 1, 5, 23, 30).millisecondsSinceEpoch),
          '2024-01-05');
    });

    // --- cx ------------------------------------------------------------
    test('过滤假值后用空格拼接', () {
      expect(cx(['a', false, null, null, 'b', '']), 'a b');
    });

    test('没有有效类名时返回空串', () {
      expect(cx([]), '');
      expect(cx([false, null, '', null]), '');
    });

    test('单个类名原样返回', () {
      expect(cx(['only']), 'only');
    });

    // --- uid -----------------------------------------------------------
    test('默认生成 12 位唯一 id', () {
      final ids = {for (var i = 0; i < 1000; i++) uid()};
      expect(ids.length, 1000);
      for (final id in ids) {
        expect(RegExp(r'^[0-9a-z]{12}$').hasMatch(id), isTrue, reason: id);
      }
    });

    test('带前缀时以 前缀_ 开头', () {
      expect(RegExp(r'^w_[0-9a-z]{12}$').hasMatch(uid('w')), isTrue);
      expect(RegExp(r'^list_[0-9a-z]{12}$').hasMatch(uid('list')), isTrue);
      expect(uid(), isNot(contains('_')));
    });

    test('带前缀的 id 同样唯一', () {
      final ids = {for (var i = 0; i < 500; i++) uid('r')};
      expect(ids.length, 500);
    });

    // --- relativeDay ---------------------------------------------------
    test('中文文案', () {
      expect(relativeDay(NOW, 'zh-CN', NOW), '今天');
      expect(relativeDay(NOW + DAY, 'zh-CN', NOW), '明天');
      expect(relativeDay(NOW - DAY, 'zh-CN', NOW), '昨天');
      expect(relativeDay(NOW + 5 * DAY, 'zh-CN', NOW), '5 天后');
      expect(relativeDay(NOW - 5 * DAY, 'zh-CN', NOW), '5 天前');
    });

    test('英文文案', () {
      expect(relativeDay(NOW, 'en', NOW), 'today');
      expect(relativeDay(NOW + DAY, 'en', NOW), 'tomorrow');
      expect(relativeDay(NOW - DAY, 'en', NOW), 'yesterday');
      expect(relativeDay(NOW + 5 * DAY, 'en', NOW), 'in 5 days');
      expect(relativeDay(NOW - 5 * DAY, 'en', NOW), '5 days ago');
    });

    // --- stableSort (Dart-only: List.sort is not stable) ----------------
    test('stableSort 在相等时保留输入顺序', () {
      final items = [3, 1, 2];
      final keys = {3: 0, 1: 0, 2: 0};
      stableSort(items, (a, b) => keys[a]!.compareTo(keys[b]!));
      expect(items, [3, 1, 2]);
    });
  });

  group('languages', () {
    test('langName 按 UI 语言给出标签，未知代码回退为代码', () {
      expect(langName('en', 'zh-CN'), '英语');
      expect(langName('en', 'en'), 'English');
      expect(langName('zh-TW', 'zh-CN'), '中文（繁体）');
      expect(langName('xx', 'zh-CN'), 'xx');
    });

    test('langShort 去掉中/繁区域后缀', () {
      expect(langShort('en'), 'EN');
      expect(langShort('zh-CN'), 'ZH');
      expect(langShort('zh-TW'), 'ZH');
      expect(langShort('ja'), 'JA');
    });

    test('代码唯一', () {
      final codes = LANGUAGES.map((l) => l.code).toList();
      expect(codes.toSet().length, codes.length);
      expect(LANGUAGES.length, 70);
    });
  });

  group('seedData', () {
    final data = seedData(NOW);

    test('只有一个示例词库，词库 id 是 DEFAULT_LIST_ID', () {
      expect(data.lists.length, 1);
      expect(data.lists.single.id, DEFAULT_LIST_ID);
      expect(data.lists.single.name, '示例词库 · 英语');
      expect(data.words.every((w) => w.listId == DEFAULT_LIST_ID), isTrue);
    });

    test('词是 TS 里的那 14 个，id 按顺序', () {
      expect(data.words.length, 14);
      expect(data.words.map((w) => w.id).toList(),
          [for (var i = 0; i < 14; i++) 'seed_$i']);
      expect(data.words.first.term, 'serendipity');
      expect(data.words.last.term, 'inevitable');
      expect(data.words.first.definition, '意外发现美好事物的运气');
      expect(data.words.first.example, 'Finding that little bookshop was pure serendipity.');
      expect(data.words.first.exampleZh, '发现那家小书店纯属机缘巧合。');
    });

    test('状态与 SRS 与 TS 的种子一致', () {
      final byTerm = {for (final w in data.words) w.term: w};

      expect(byTerm['serendipity']!.status, WordStatus.learning);
      expect(byTerm['serendipity']!.favorite, isTrue);
      expect(byTerm['serendipity']!.srs!.ease, 2.35);
      expect(byTerm['serendipity']!.srs!.intervalDays, 9);
      expect(byTerm['serendipity']!.srs!.dueAt, NOW + 2 * DAY_MS);
      expect(byTerm['serendipity']!.srs!.lastReviewedAt, NOW - 9 * DAY_MS);

      expect(byTerm['ubiquitous']!.status, WordStatus.mastered);
      expect(byTerm['ubiquitous']!.listenCount, 120);
      expect(byTerm['meticulous']!.listenCount, 30);
      expect(byTerm['ephemeral']!.status, WordStatus.new_);
      expect(byTerm['ephemeral']!.srs, isNull);
      expect(byTerm['ephemeral']!.listenCount, 0);
      expect(byTerm['tenacious']!.favorite, isTrue);
    });

    test('合成复习历史按时间升序，且每条都挂在存在的词上', () {
      final wordIds = data.words.map((w) => w.id).toSet();
      expect(data.logs, isNotEmpty);
      for (var i = 1; i < data.logs.length; i++) {
        expect(data.logs[i].at >= data.logs[i - 1].at, isTrue);
      }
      expect(data.logs.every((l) => wordIds.contains(l.wordId)), isTrue);
      // 没有 srs 或 reviewCount 为 0 的词不产生日志。
      expect(data.logs.any((l) => l.id == 'seedlog_4_0'), isFalse);
    });

    test('每一条记录都在 pending 里（种子是离线创建的）', () {
      expect(data.pending.words, data.words.map((w) => w.id).toList());
      expect(data.pending.lists, [DEFAULT_LIST_ID]);
      expect(data.pending.logs, data.logs.map((l) => l.id).toList());
      expect(data.pending.settings, isFalse);
      expect(data.tombstones.words, isEmpty);
    });

    test('version 是当前 DATA_VERSION，设置是默认值', () {
      expect(data.version, DATA_VERSION);
      expect(data.settings.dailyGoal, 20);
      expect(data.settings.uiLang, UiLang.zhCN);
      expect(data.settingsUpdatedAt, NOW - 7 * DAY_MS);
    });  });
}
