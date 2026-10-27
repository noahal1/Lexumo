/**
 * First-run demo content: a small, curated English → Chinese deck so the
 * app opens alive instead of empty. Users can wipe it in Settings.
 */
import type { AppData, Grade, ReviewLog, SrsState, Word, WordStatus } from "./types";
import { DATA_VERSION, DEFAULT_LIST_ID, DEFAULT_SETTINGS } from "./types";
import { touch } from "./journal";
import { DAY_MS } from "./srs";

interface SeedWord {
  term: string;
  definition: string;
  definition2?: string;
  example?: string;
  /** Translation of `example`; the demo deck shows both faces of the card. */
  exampleZh?: string;
  tags: string[];
  status: WordStatus;
  favorite?: boolean;
  /** [ease, intervalDays, daysUntilDue, reviewCount, correctCount] */
  srs?: [number, number, number, number, number];
}

const SEED: SeedWord[] = [
  {
    term: "serendipity",
    definition: "意外发现美好事物的运气",
    definition2: "机缘巧合；不期而遇的惊喜",
    example: "Finding that little bookshop was pure serendipity.",
    exampleZh: "发现那家小书店纯属机缘巧合。",
    tags: ["抽象", "文学"],
    status: "learning",
    favorite: true,
    srs: [2.35, 9, 2, 5, 4],
  },
  {
    term: "resilient",
    definition: "有韧性的；能迅速恢复的",
    definition2: "形容人或材料受挫后仍能复原",
    example: "Children are remarkably resilient.",
    exampleZh: "孩子的恢复力强得惊人。",
    tags: ["形容词", "性格"],
    status: "reviewing",
    srs: [2.5, 4, 0, 2, 2],
  },
  {
    term: "ubiquitous",
    definition: "无处不在的；普遍存在的",
    example: "Smartphones have become ubiquitous.",
    exampleZh: "智能手机已经无处不在。",
    tags: ["形容词", "学术"],
    status: "mastered",
    srs: [2.5, 34, 12, 8, 8],
  },
  {
    term: "meticulous",
    definition: "一丝不苟的；极其仔细的",
    definition2: "对细节近乎挑剔的认真",
    example: "She kept meticulous notes.",
    exampleZh: "她的笔记做得一丝不苟。",
    tags: ["形容词", "工作"],
    status: "learning",
    srs: [2.2, 11, 1, 4, 3],
  },
  {
    term: "ephemeral",
    definition: "短暂的；转瞬即逝的",
    example: "Fame can be ephemeral.",
    exampleZh: "名声可能是短暂的。",
    tags: ["形容词", "文学"],
    status: "new",
  },
  {
    term: "candid",
    definition: "坦率的；直言不讳的",
    definition2: "不加修饰地说出真实想法",
    example: "Thank you for your candid feedback.",
    exampleZh: "谢谢你坦率的反馈。",
    tags: ["形容词", "沟通"],
    status: "reviewing",
    srs: [2.5, 2, 0, 1, 1],
  },
  {
    term: "nuance",
    definition: "细微差别；微妙之处",
    example: "The translation misses the nuance.",
    exampleZh: "这个翻译丢掉了原文的细微差别。",
    tags: ["名词", "语言"],
    status: "learning",
    srs: [2.3, 8, 3, 3, 3],
  },
  {
    term: "pragmatic",
    definition: "务实的；讲求实际的",
    example: "We need a pragmatic solution.",
    exampleZh: "我们需要一个务实的方案。",
    tags: ["形容词", "工作"],
    status: "mastered",
    srs: [2.5, 26, 20, 6, 6],
  },
  {
    term: "ambiguous",
    definition: "模棱两可的；含糊不清的",
    example: "His answer was deliberately ambiguous.",
    exampleZh: "他的回答是故意含糊的。",
    tags: ["形容词", "学术"],
    status: "new",
  },
  {
    term: "diligent",
    definition: "勤勉的；用功的",
    example: "A diligent student reviews every day.",
    exampleZh: "勤勉的学生每天都会复习。",
    tags: ["形容词", "性格"],
    status: "reviewing",
    srs: [2.5, 3, 0, 2, 1],
  },
  {
    term: "empathy",
    definition: "共情；同理心",
    definition2: "理解他人感受的能力",
    example: "Good design starts with empathy.",
    exampleZh: "好的设计始于共情。",
    tags: ["名词", "心理"],
    status: "learning",
    srs: [2.1, 7, 0, 3, 2],
  },
  {
    term: "tenacious",
    definition: "顽强的；坚持不懈的",
    example: "A tenacious researcher rarely gives up.",
    exampleZh: "顽强的研究者很少放弃。",
    tags: ["形容词", "性格"],
    status: "new",
    favorite: true,
  },
  {
    term: "concise",
    definition: "简洁的；简明的",
    example: "Keep the summary concise.",
    exampleZh: "摘要保持简洁。",
    tags: ["形容词", "写作"],
    status: "mastered",
    srs: [2.5, 40, 25, 9, 9],
  },
  {
    term: "inevitable",
    definition: "不可避免的；必然发生的",
    example: "Change is inevitable.",
    exampleZh: "变化是不可避免的。",
    tags: ["形容词", "哲学"],
    status: "reviewing",
    srs: [2.5, 5, 4, 2, 2],
  },
];

function makeSrs(spec: SeedWord["srs"], now: number): SrsState | null {
  if (!spec) return null;
  const [ease, intervalDays, daysUntilDue, reviewCount, correctCount] = spec;
  return {
    ease,
    intervalDays,
    dueAt: now + daysUntilDue * DAY_MS,
    reviewCount,
    correctCount,
    lastReviewedAt: now - Math.max(1, intervalDays) * DAY_MS,
  };
}

/**
 * Synthesise a believable review history so the statistics page has
 * something to show on the very first launch (instead of an empty chart).
 */
function makeLogs(words: Word[], now: number): ReviewLog[] {
  const logs: ReviewLog[] = [];
  const midnight = new Date(now);
  midnight.setHours(0, 0, 0, 0);
  const todayStart = midnight.getTime();

  words.forEach((word, wi) => {
    const srs = word.srs;
    if (!srs || srs.reviewCount === 0) return;
    const total = Math.min(srs.reviewCount, 9);
    const rightRatio = srs.reviewCount > 0 ? srs.correctCount / srs.reviewCount : 0;
    for (let k = 0; k < total; k++) {
      // Older reviews land further back; the newest few are within the last days.
      const dayOffset = Math.round(((total - k) / total) * 22);
      const at =
        todayStart -
        dayOffset * DAY_MS +
        (8 + ((wi * 3 + k * 5) % 11)) * 3_600_000 +
        ((wi * 17 + k * 29) % 60) * 60_000;
      if (at > now) continue;
      const isCorrect = k / total >= 1 - rightRatio;
      const grade: Grade = isCorrect ? (k % 4 === 0 ? "easy" : "good") : "hard";
      logs.push({
        id: `seedlog_${wi}_${k}`,
        wordId: word.id,
        grade,
        at,
        intervalBefore: Math.max(0, srs.intervalDays - 1),
        intervalAfter: srs.intervalDays,
      });
    }
  });

  return logs.sort((a, b) => a.at - b.at);
}

export function seedData(now = Date.now()): AppData {
  const words: Word[] = SEED.map((s, i) => ({
    id: `seed_${i}`,
    term: s.term,
    definition: s.definition,
    definition2: s.definition2 ?? "",
    example: s.example ?? "",
    exampleZh: s.exampleZh,
    note: "",
    status: s.status,
    favorite: s.favorite ?? false,
    tags: s.tags,
    listId: DEFAULT_LIST_ID,
    sourceLang: "en",
    targetLang: "zh-CN",
    listenCount: s.status === "mastered" ? 120 : s.status === "learning" ? 30 : 0,
    srs: makeSrs(s.srs, now),
    createdAt: now - (SEED.length - i) * 3_600_000,
    updatedAt: now - i * 600_000,
  }));

  const logs = makeLogs(words, now);
  const data: AppData = {
    version: DATA_VERSION,
    lists: [
      {
        id: DEFAULT_LIST_ID,
        name: "示例词库 · 英语",
        sourceLang: "en",
        targetLang: "zh-CN",
        createdAt: now - 7 * DAY_MS,
        updatedAt: now - 7 * DAY_MS,
      },
    ],
    words,
    logs,
    settings: { ...DEFAULT_SETTINGS },
    settingsUpdatedAt: now - 7 * DAY_MS,
    tombstones: { words: {}, lists: {}, logs: {} },
    pending: { words: [], lists: [], logs: [], settings: false },
  };
  // The seed is created offline, so nothing has been uploaded yet and every
  // record is pending. Going through the journal keeps `pending` owned by one
  // module instead of a second hand-written copy that could drift from it.
  for (const word of words) touch(data, "word", word.id);
  touch(data, "list", DEFAULT_LIST_ID);
  for (const log of logs) touch(data, "log", log.id);
  return data;
}
