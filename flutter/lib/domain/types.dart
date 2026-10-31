/// Core domain types for Lexumo. Persisted as a single versioned snapshot.
///
/// Ported from `src/lib/types.ts`. The Dart port keeps the exact field names
/// and the JSON shape, so a snapshot exported by the web build (or by the old
/// Tauri shell) loads here without a transformation step.
library;

/// How well a card is known, as a badge on the list.
enum WordStatus {
  new_('new'),
  reviewing('reviewing'),
  learning('learning'),
  mastered('mastered');

  const WordStatus(this.wire);
  final String wire;

  /// Ladder position. The order is load-bearing: "never demote" compares indices.
  int get rank => index;

  static WordStatus fromWire(String? raw) => switch (raw) {
        'reviewing' => WordStatus.reviewing,
        'learning' => WordStatus.learning,
        'mastered' => WordStatus.mastered,
        _ => WordStatus.new_,
      };
}

enum Grade {
  hard('hard'),
  good('good'),
  easy('easy');

  const Grade(this.wire);
  final String wire;

  static Grade fromWire(String? raw) => switch (raw) {
        'hard' => Grade.hard,
        'easy' => Grade.easy,
        _ => Grade.good,
      };
}

enum ThemeMode_ {
  light('light'),
  dark('dark'),
  system('system');

  const ThemeMode_(this.wire);
  final String wire;

  static ThemeMode_ fromWire(String? raw) => switch (raw) {
        'light' => ThemeMode_.light,
        'dark' => ThemeMode_.dark,
        _ => ThemeMode_.system,
      };
}

enum UiLang {
  zhCN('zh-CN'),
  en('en');

  const UiLang(this.wire);
  final String wire;

  static UiLang fromWire(String? raw) =>
      raw == 'en' ? UiLang.en : UiLang.zhCN;
}

/// What a card's schedule looks like. Mirrors `SrsState`.
class SrsState {
  const SrsState({
    required this.ease,
    required this.intervalDays,
    required this.dueAt,
    required this.reviewCount,
    required this.correctCount,
    this.lastReviewedAt,
  });

  /// SM-2 ease factor, clamped to [1.3, 2.5].
  final double ease;

  /// Current interval in days.
  final int intervalDays;

  /// Epoch ms when the card is next due.
  final int dueAt;
  final int reviewCount;
  final int correctCount;
  final int? lastReviewedAt;

  SrsState copyWith({
    double? ease,
    int? intervalDays,
    int? dueAt,
    int? reviewCount,
    int? correctCount,
    int? lastReviewedAt,
  }) {
    return SrsState(
      ease: ease ?? this.ease,
      intervalDays: intervalDays ?? this.intervalDays,
      dueAt: dueAt ?? this.dueAt,
      reviewCount: reviewCount ?? this.reviewCount,
      correctCount: correctCount ?? this.correctCount,
      lastReviewedAt: lastReviewedAt ?? this.lastReviewedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'ease': ease,
        'intervalDays': intervalDays,
        'dueAt': dueAt,
        'reviewCount': reviewCount,
        'correctCount': correctCount,
        'lastReviewedAt': lastReviewedAt,
      };

  static SrsState? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = raw.cast<String, dynamic>();
    return SrsState(
      ease: (m['ease'] as num?)?.toDouble() ?? 2.5,
      intervalDays: (m['intervalDays'] as num?)?.toInt() ?? 0,
      dueAt: (m['dueAt'] as num?)?.toInt() ?? 0,
      reviewCount: (m['reviewCount'] as num?)?.toInt() ?? 0,
      correctCount: (m['correctCount'] as num?)?.toInt() ?? 0,
      lastReviewedAt: (m['lastReviewedAt'] as num?)?.toInt(),
    );
  }
}

/// One vocabulary record.
class Word {
  const Word({
    required this.id,
    required this.term,
    this.phonetic,
    this.pos,
    required this.definition,
    required this.definition2,
    required this.example,
    this.exampleZh,
    required this.note,
    required this.status,
    required this.favorite,
    required this.listId,
    required this.sourceLang,
    required this.targetLang,
    required this.listenCount,
    required this.srs,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String term;
  final String? phonetic;
  final String? pos;
  final String definition;
  final String definition2;
  final String example;
  final String? exampleZh;
  final String note;
  final WordStatus status;
  final bool favorite;
  final String listId;
  final String sourceLang;
  final String targetLang;
  final int listenCount;
  final SrsState? srs;
  final int createdAt;
  final int updatedAt;

  bool get isNew => status == WordStatus.new_;
  bool get hasSrs => srs != null && (srs?.reviewCount ?? 0) > 0;

  Word copyWith({
    String? term,
    String? phonetic,
    String? pos,
    String? definition,
    String? definition2,
    String? example,
    String? exampleZh,
    String? note,
    WordStatus? status,
    bool? favorite,
    String? listId,
    String? sourceLang,
    String? targetLang,
    int? listenCount,
    SrsState? srs,
    bool clearSrs = false,
    int? createdAt,
    int? updatedAt,
  }) {
    return Word(
      id: id,
      term: term ?? this.term,
      phonetic: phonetic ?? this.phonetic,
      pos: pos ?? this.pos,
      definition: definition ?? this.definition,
      definition2: definition2 ?? this.definition2,
      example: example ?? this.example,
      exampleZh: exampleZh ?? this.exampleZh,
      note: note ?? this.note,
      status: status ?? this.status,
      favorite: favorite ?? this.favorite,
      listId: listId ?? this.listId,
      sourceLang: sourceLang ?? this.sourceLang,
      targetLang: targetLang ?? this.targetLang,
      listenCount: listenCount ?? this.listenCount,
      srs: clearSrs ? null : (srs ?? this.srs),
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'term': term,
        if (phonetic != null) 'phonetic': phonetic,
        if (pos != null) 'pos': pos,
        'definition': definition,
        'definition2': definition2,
        'example': example,
        if (exampleZh != null) 'exampleZh': exampleZh,
        'note': note,
        'status': status.wire,
        'favorite': favorite,
        'listId': listId,
        'sourceLang': sourceLang,
        'targetLang': targetLang,
        'listenCount': listenCount,
        'srs': srs?.toJson(),
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  static Word fromJson(Map<String, dynamic> m) => Word(
        id: m['id'] as String? ?? '',
        term: m['term'] as String? ?? '',
        phonetic: m['phonetic'] as String?,
        pos: m['pos'] as String?,
        definition: m['definition'] as String? ?? '',
        definition2: m['definition2'] as String? ?? '',
        example: m['example'] as String? ?? '',
        exampleZh: m['exampleZh'] as String?,
        note: m['note'] as String? ?? '',
        status: WordStatus.fromWire(m['status'] as String?),
        favorite: m['favorite'] as bool? ?? false,
        listId: m['listId'] as String? ?? DEFAULT_LIST_ID,
        sourceLang: m['sourceLang'] as String? ?? 'en',
        targetLang: m['targetLang'] as String? ?? 'zh-CN',
        listenCount: (m['listenCount'] as num?)?.toInt() ?? 0,
        srs: SrsState.fromJson(m['srs']),
        createdAt: (m['createdAt'] as num?)?.toInt() ?? 0,
        updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
      );
}

class WordList {
  const WordList({
    required this.id,
    required this.name,
    required this.sourceLang,
    required this.targetLang,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String sourceLang;
  final String targetLang;
  final int createdAt;
  final int updatedAt;

  WordList copyWith({String? name, int? updatedAt}) => WordList(
        id: id,
        name: name ?? this.name,
        sourceLang: sourceLang,
        targetLang: targetLang,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'sourceLang': sourceLang,
        'targetLang': targetLang,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  static WordList fromJson(Map<String, dynamic> m) => WordList(
        id: m['id'] as String? ?? '',
        name: m['name'] as String? ?? '',
        sourceLang: m['sourceLang'] as String? ?? 'en',
        targetLang: m['targetLang'] as String? ?? 'zh-CN',
        createdAt: (m['createdAt'] as num?)?.toInt() ?? 0,
        updatedAt: (m['updatedAt'] as num?)?.toInt() ??
            (m['createdAt'] as num?)?.toInt() ??
            0,
      );
}

class ReviewLog {
  const ReviewLog({
    required this.id,
    required this.wordId,
    required this.grade,
    required this.at,
    required this.intervalBefore,
    required this.intervalAfter,
  });

  final String id;
  final String wordId;
  final Grade grade;

  /// Epoch ms of the review.
  final int at;
  final int intervalBefore;
  final int intervalAfter;

  Map<String, dynamic> toJson() => {
        'id': id,
        'wordId': wordId,
        'grade': grade.wire,
        'at': at,
        'intervalBefore': intervalBefore,
        'intervalAfter': intervalAfter,
      };

  static ReviewLog fromJson(Map<String, dynamic> m) => ReviewLog(
        id: m['id'] as String? ?? '',
        wordId: m['wordId'] as String? ?? '',
        grade: Grade.fromWire(m['grade'] as String?),
        at: (m['at'] as num?)?.toInt() ?? 0,
        intervalBefore: (m['intervalBefore'] as num?)?.toInt() ?? 0,
        intervalAfter: (m['intervalAfter'] as num?)?.toInt() ?? 0,
      );
}

class Settings {
  const Settings({
    this.theme = ThemeMode_.system,
    this.uiLang = UiLang.zhCN,
    this.dailyGoal = 20,
    this.ttsRate = 0.95,
    this.ttsVoiceURI = '',
    this.autoPlayAudio = true,
    this.audioFirst = false,
    this.newCardsPerDay = 15,
    this.reviewOrder = 'due',
    this.autoSync = true,
  });

  final ThemeMode_ theme;
  final UiLang uiLang;
  final int dailyGoal;
  final double ttsRate;
  final String ttsVoiceURI;
  final bool autoPlayAudio;

  /// Show the translation on the flashcard front (listening mode).
  final bool audioFirst;
  final int newCardsPerDay;

  /// `"due"` or `"random"`.
  final String reviewOrder;
  final bool autoSync;

  Settings copyWith({
    ThemeMode_? theme,
    UiLang? uiLang,
    int? dailyGoal,
    double? ttsRate,
    String? ttsVoiceURI,
    bool? autoPlayAudio,
    bool? audioFirst,
    int? newCardsPerDay,
    String? reviewOrder,
    bool? autoSync,
  }) {
    return Settings(
      theme: theme ?? this.theme,
      uiLang: uiLang ?? this.uiLang,
      dailyGoal: dailyGoal ?? this.dailyGoal,
      ttsRate: ttsRate ?? this.ttsRate,
      ttsVoiceURI: ttsVoiceURI ?? this.ttsVoiceURI,
      autoPlayAudio: autoPlayAudio ?? this.autoPlayAudio,
      audioFirst: audioFirst ?? this.audioFirst,
      newCardsPerDay: newCardsPerDay ?? this.newCardsPerDay,
      reviewOrder: reviewOrder ?? this.reviewOrder,
      autoSync: autoSync ?? this.autoSync,
    );
  }

  Map<String, dynamic> toJson() => {
        'theme': theme.wire,
        'uiLang': uiLang.wire,
        'dailyGoal': dailyGoal,
        'ttsRate': ttsRate,
        'ttsVoiceURI': ttsVoiceURI,
        'autoPlayAudio': autoPlayAudio,
        'audioFirst': audioFirst,
        'newCardsPerDay': newCardsPerDay,
        'reviewOrder': reviewOrder,
        'autoSync': autoSync,
      };

  static Settings fromJson(Map<String, dynamic>? m) {
    if (m == null) return const Settings();
    const d = Settings();
    return Settings(
      theme: ThemeMode_.fromWire(m['theme'] as String?),
      uiLang: UiLang.fromWire(m['uiLang'] as String?),
      dailyGoal: (m['dailyGoal'] as num?)?.toInt() ?? d.dailyGoal,
      ttsRate: (m['ttsRate'] as num?)?.toDouble() ?? d.ttsRate,
      ttsVoiceURI: m['ttsVoiceURI'] as String? ?? d.ttsVoiceURI,
      autoPlayAudio: m['autoPlayAudio'] as bool? ?? d.autoPlayAudio,
      audioFirst: m['audioFirst'] as bool? ?? d.audioFirst,
      newCardsPerDay: (m['newCardsPerDay'] as num?)?.toInt() ?? d.newCardsPerDay,
      reviewOrder: m['reviewOrder'] as String? ?? d.reviewOrder,
      autoSync: m['autoSync'] as bool? ?? d.autoSync,
    );
  }
}

/// Deletion tombstones. A delete cannot be expressed by absence (the other
/// device would just re-upload the record), so removals are recorded here.
class Tombstones {
  const Tombstones({
    this.words = const {},
    this.lists = const {},
    this.logs = const {},
  });

  final Map<String, int> words;
  final Map<String, int> lists;
  final Map<String, int> logs;

  Map<String, dynamic> toJson() => {'words': words, 'lists': lists, 'logs': logs};

  static Tombstones fromJson(Map<String, dynamic>? m) {
    Map<String, int> conv(Object? raw) {
      if (raw is! Map) return const {};
      return raw.map((k, v) => MapEntry('$k', (v as num?)?.toInt() ?? 0));
    }

    return Tombstones(
      words: conv(m?['words']),
      lists: conv(m?['lists']),
      logs: conv(m?['logs']),
    );
  }
}

/// Records that changed locally and still need to be pushed to the server.
class PendingChanges {
  const PendingChanges({
    this.words = const [],
    this.lists = const [],
    this.logs = const [],
    this.settings = false,
  });

  final List<String> words;
  final List<String> lists;
  final List<String> logs;
  final bool settings;

  /// How many records still owe the server a push. Mirrors the web build's
  /// `pendingTotal` — `settings` counts once because it is one document.
  int total() => words.length + lists.length + logs.length + (settings ? 1 : 0);

  /// True when nothing is waiting, i.e. this device is fully synced.
  bool get isEmpty => total() == 0;

  Map<String, dynamic> toJson() => {
        'words': words,
        'lists': lists,
        'logs': logs,
        'settings': settings,
      };

  static PendingChanges fromJson(Map<String, dynamic>? m) {
    List<String> conv(Object? raw) =>
        raw is List ? raw.map((e) => '$e').toList() : const [];
    return PendingChanges(
      words: conv(m?['words']),
      lists: conv(m?['lists']),
      logs: conv(m?['logs']),
      settings: m?['settings'] as bool? ?? false,
    );
  }
}

class AppData {
  const AppData({
    this.version = DATA_VERSION,
    this.lists = const [],
    this.words = const [],
    this.logs = const [],
    this.settings = const Settings(),
    this.settingsUpdatedAt = 0,
    this.tombstones = const Tombstones(),
    this.pending = const PendingChanges(),
  });

  final int version;
  final List<WordList> lists;
  final List<Word> words;
  final List<ReviewLog> logs;
  final Settings settings;
  final int settingsUpdatedAt;
  final Tombstones tombstones;
  final PendingChanges pending;

  AppData copyWith({
    int? version,
    List<WordList>? lists,
    List<Word>? words,
    List<ReviewLog>? logs,
    Settings? settings,
    int? settingsUpdatedAt,
    Tombstones? tombstones,
    PendingChanges? pending,
  }) {
    return AppData(
      version: version ?? this.version,
      lists: lists ?? this.lists,
      words: words ?? this.words,
      logs: logs ?? this.logs,
      settings: settings ?? this.settings,
      settingsUpdatedAt: settingsUpdatedAt ?? this.settingsUpdatedAt,
      tombstones: tombstones ?? this.tombstones,
      pending: pending ?? this.pending,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'lists': lists.map((l) => l.toJson()).toList(),
        'words': words.map((w) => w.toJson()).toList(),
        'logs': logs.map((l) => l.toJson()).toList(),
        'settings': settings.toJson(),
        'settingsUpdatedAt': settingsUpdatedAt,
        'tombstones': tombstones.toJson(),
        'pending': pending.toJson(),
      };

  /// Bring any older snapshot up to the current shape. A snapshot from a future
  /// version is rejected rather than half-read — the web build's rule.
  static AppData? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = raw.cast<String, dynamic>();
    final rawWords = m['words'];
    final rawLists = m['lists'];
    if (rawWords is! List || rawLists is! List) return null;
    final version = (m['version'] as num?)?.toInt();
    if (version == null || version > DATA_VERSION) return null;

    final words = <Word>[];
    for (final w in rawWords) {
      if (w is Map) words.add(Word.fromJson(w.cast<String, dynamic>()));
    }
    final lists = <WordList>[];
    for (final l in rawLists) {
      if (l is Map) lists.add(WordList.fromJson(l.cast<String, dynamic>()));
    }
    final logs = <ReviewLog>[];
    final rawLogs = m['logs'];
    if (rawLogs is List) {
      for (final l in rawLogs) {
        if (l is Map) logs.add(ReviewLog.fromJson(l.cast<String, dynamic>()));
      }
    }
    return AppData(
      version: DATA_VERSION,
      lists: lists,
      words: words,
      logs: logs,
      settings: Settings.fromJson((m['settings'] as Map?)?.cast<String, dynamic>()),
      settingsUpdatedAt: (m['settingsUpdatedAt'] as num?)?.toInt() ?? 0,
      tombstones:
          Tombstones.fromJson((m['tombstones'] as Map?)?.cast<String, dynamic>()),
      pending: PendingChanges.fromJson((m['pending'] as Map?)?.cast<String, dynamic>()),
    );
  }
}

/// Bump this whenever the persisted shape changes in a way an old snapshot
/// should be migrated out of.
///
/// 3 — `Word.tags` removed. The bump is what makes an old snapshot's leftover
/// `tags` arrays get dropped on load instead of being carried forever.
const int DATA_VERSION = 3;

const String DEFAULT_LIST_ID = 'list_default';
