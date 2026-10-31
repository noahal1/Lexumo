/// First-run demo content: a small, curated English → Chinese deck so the app
/// opens alive instead of empty. Users can wipe it in Settings.
///
/// Ported from `src/lib/seed.ts` — the words, definitions, examples, the list
/// id and the synthesised review history are the app's existing demo content
/// and must not be retranslated or retuned here.
library;

import 'srs.dart';
import 'types.dart';

class _SeedWord {
  const _SeedWord({
    required this.term,
    required this.definition,
    this.pos,
    this.definition2,
    this.example,
    this.exampleZh,
    required this.status,
    this.favorite = false,
    this.srs,
  });

  final String term;
  final String definition;
  final String? pos;
  final String? definition2;
  final String? example;

  /// Translation of [example]; the demo deck shows both faces of the card.
  final String? exampleZh;
  final WordStatus status;
  final bool favorite;

  /// `[ease, intervalDays, daysUntilDue, reviewCount, correctCount]`
  final List<num>? srs;
}

const List<_SeedWord> _seed = [
  _SeedWord(
    term: 'serendipity',
    pos: 'n.',
    definition: '意外发现美好事物的运气',
    definition2: '机缘巧合；不期而遇的惊喜',
    example: 'Finding that little bookshop was pure serendipity.',
    exampleZh: '发现那家小书店纯属机缘巧合。',
    status: WordStatus.learning,
    favorite: true,
    srs: [2.35, 9, 2, 5, 4],
  ),
  _SeedWord(
    term: 'resilient',
    pos: 'adj.',
    definition: '有韧性的；能迅速恢复的',
    definition2: '形容人或材料受挫后仍能复原',
    example: 'Children are remarkably resilient.',
    exampleZh: '孩子的恢复力强得惊人。',
    status: WordStatus.reviewing,
    srs: [2.5, 4, 0, 2, 2],
  ),
  _SeedWord(
    term: 'ubiquitous',
    pos: 'adj.',
    definition: '无处不在的；普遍存在的',
    example: 'Smartphones have become ubiquitous.',
    exampleZh: '智能手机已经无处不在。',
    status: WordStatus.mastered,
    srs: [2.5, 34, 12, 8, 8],
  ),
  _SeedWord(
    term: 'meticulous',
    pos: 'adj.',
    definition: '一丝不苟的；极其仔细的',
    definition2: '对细节近乎挑剔的认真',
    example: 'She kept meticulous notes.',
    exampleZh: '她的笔记做得一丝不苟。',
    status: WordStatus.learning,
    srs: [2.2, 11, 1, 4, 3],
  ),
  _SeedWord(
    term: 'ephemeral',
    pos: 'adj.',
    definition: '短暂的；转瞬即逝的',
    example: 'Fame can be ephemeral.',
    exampleZh: '名声可能是短暂的。',
    status: WordStatus.new_,
  ),
  _SeedWord(
    term: 'candid',
    pos: 'adj.',
    definition: '坦率的；直言不讳的',
    definition2: '不加修饰地说出真实想法',
    example: 'Thank you for your candid feedback.',
    exampleZh: '谢谢你坦率的反馈。',
    status: WordStatus.reviewing,
    srs: [2.5, 2, 0, 1, 1],
  ),
  _SeedWord(
    term: 'nuance',
    pos: 'n.',
    definition: '细微差别；微妙之处',
    example: 'The translation misses the nuance.',
    exampleZh: '这个翻译丢掉了原文的细微差别。',
    status: WordStatus.learning,
    srs: [2.3, 8, 3, 3, 3],
  ),
  _SeedWord(
    term: 'pragmatic',
    pos: 'adj.',
    definition: '务实的；讲求实际的',
    example: 'We need a pragmatic solution.',
    exampleZh: '我们需要一个务实的方案。',
    status: WordStatus.mastered,
    srs: [2.5, 26, 20, 6, 6],
  ),
  _SeedWord(
    term: 'ambiguous',
    pos: 'adj.',
    definition: '模棱两可的；含糊不清的',
    example: 'His answer was deliberately ambiguous.',
    exampleZh: '他的回答是故意含糊的。',
    status: WordStatus.new_,
  ),
  _SeedWord(
    term: 'diligent',
    pos: 'adj.',
    definition: '勤勉的；用功的',
    example: 'A diligent student reviews every day.',
    exampleZh: '勤勉的学生每天都会复习。',
    status: WordStatus.reviewing,
    srs: [2.5, 3, 0, 2, 1],
  ),
  _SeedWord(
    term: 'empathy',
    pos: 'n.',
    definition: '共情；同理心',
    definition2: '理解他人感受的能力',
    example: 'Good design starts with empathy.',
    exampleZh: '好的设计始于共情。',
    status: WordStatus.learning,
    srs: [2.1, 7, 0, 3, 2],
  ),
  _SeedWord(
    term: 'tenacious',
    pos: 'adj.',
    definition: '顽强的；坚持不懈的',
    example: 'A tenacious researcher rarely gives up.',
    exampleZh: '顽强的研究者很少放弃。',
    status: WordStatus.new_,
    favorite: true,
  ),
  _SeedWord(
    term: 'concise',
    pos: 'adj.',
    definition: '简洁的；简明的',
    example: 'Keep the summary concise.',
    exampleZh: '摘要保持简洁。',
    status: WordStatus.mastered,
    srs: [2.5, 40, 25, 9, 9],
  ),
  _SeedWord(
    term: 'inevitable',
    pos: 'adj.',
    definition: '不可避免的；必然发生的',
    example: 'Change is inevitable.',
    exampleZh: '变化是不可避免的。',
    status: WordStatus.reviewing,
    srs: [2.5, 5, 4, 2, 2],
  ),
];

SrsState? _makeSrs(List<num>? spec, int now) {
  if (spec == null) return null;
  final ease = spec[0].toDouble();
  final intervalDays = spec[1].toInt();
  final daysUntilDue = spec[2].toInt();
  final reviewCount = spec[3].toInt();
  final correctCount = spec[4].toInt();
  return SrsState(
    ease: ease,
    intervalDays: intervalDays,
    dueAt: now + daysUntilDue * DAY_MS,
    reviewCount: reviewCount,
    correctCount: correctCount,
    lastReviewedAt: now - (intervalDays > 1 ? intervalDays : 1) * DAY_MS,
  );
}

/// Synthesise a believable review history so the statistics page has something
/// to show on the very first launch (instead of an empty chart).
List<ReviewLog> _makeLogs(List<Word> words, int now) {
  final logs = <ReviewLog>[];
  final midnight = DateTime.fromMillisecondsSinceEpoch(now);
  final todayStart =
      DateTime(midnight.year, midnight.month, midnight.day).millisecondsSinceEpoch;

  for (var wi = 0; wi < words.length; wi++) {
    final word = words[wi];
    final srs = word.srs;
    if (srs == null || srs.reviewCount == 0) continue;
    final total = srs.reviewCount < 9 ? srs.reviewCount : 9;
    final rightRatio =
        srs.reviewCount > 0 ? srs.correctCount / srs.reviewCount : 0.0;
    for (var k = 0; k < total; k++) {
      // Older reviews land further back; the newest few are within the last days.
      final dayOffset = (((total - k) / total) * 22).round();
      final at = todayStart -
          dayOffset * DAY_MS +
          (8 + ((wi * 3 + k * 5) % 11)) * 3600000 +
          ((wi * 17 + k * 29) % 60) * 60000;
      if (at > now) continue;
      final isCorrect = k / total >= 1 - rightRatio;
      final grade = isCorrect
          ? (k % 4 == 0 ? Grade.easy : Grade.good)
          : Grade.hard;
      logs.add(ReviewLog(
        id: 'seedlog_${wi}_$k',
        wordId: word.id,
        grade: grade,
        at: at,
        intervalBefore: srs.intervalDays - 1 > 0 ? srs.intervalDays - 1 : 0,
        intervalAfter: srs.intervalDays,
      ));
    }
  }

  logs.sort((a, b) => a.at - b.at);
  return logs;
}

/// The first-run snapshot: one list, the demo deck, a synthetic review history
/// and every record marked pending (nothing has been uploaded yet).
///
/// The TS went through `journal.touch()` to keep `pending` owned by one module.
/// `journal.dart` is outside this task's write scope, so the same effect is
/// spelled out here: `pending` lists every created id, in creation order
/// (words, then the list, then the logs — the order the TS's `touch` calls
/// produced).
AppData seedData(int now) {
  final words = <Word>[];
  for (var i = 0; i < _seed.length; i++) {
    final s = _seed[i];
    words.add(Word(
      id: 'seed_$i',
      term: s.term,
      pos: s.pos,
      definition: s.definition,
      definition2: s.definition2 ?? '',
      example: s.example ?? '',
      exampleZh: s.exampleZh,
      note: '',
      status: s.status,
      favorite: s.favorite,
      listId: DEFAULT_LIST_ID,
      sourceLang: 'en',
      targetLang: 'zh-CN',
      listenCount: s.status == WordStatus.mastered
          ? 120
          : (s.status == WordStatus.learning ? 30 : 0),
      srs: _makeSrs(s.srs, now),
      createdAt: now - (_seed.length - i) * 3600000,
      updatedAt: now - i * 600000,
    ));
  }

  final logs = _makeLogs(words, now);

  final data = AppData(
    version: DATA_VERSION,
    lists: [
      WordList(
        id: DEFAULT_LIST_ID,
        name: '示例词库 · 英语',
        sourceLang: 'en',
        targetLang: 'zh-CN',
        createdAt: now - 7 * DAY_MS,
        updatedAt: now - 7 * DAY_MS,
      ),
    ],
    words: words,
    logs: logs,
    settings: const Settings(),
    settingsUpdatedAt: now - 7 * DAY_MS,
    tombstones: const Tombstones(),
    pending: PendingChanges(
      words: [for (final w in words) w.id],
      lists: const [DEFAULT_LIST_ID],
      logs: [for (final l in logs) l.id],
      settings: false,
    ),
  );
  return data;
}
