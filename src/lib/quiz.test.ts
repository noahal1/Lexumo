/**
 * 测验出题是纯函数，测试直接构造词表。
 *
 * 只断言"一轮题必须成立的性质"（选项数量、答案位置、去重、方向），不锁死
 * 随机顺序 —— `shuffle` 每次结果不同，断言具体顺序只会得到脆弱的测试。
 */
import { describe, expect, it } from "vitest";
import {
  QUIZ_CHOICES,
  QUIZ_ROUND,
  buildQuiz,
  quizEligibleWords,
  quizShortfall,
} from "./quiz";
import type { Word } from "./types";

function word(id: string, term: string, definition: string): Word {
  return {
    id,
    term,
    definition,
    definition2: "",
    example: "",
    note: "",
    status: "new",
    favorite: false,
    listId: "list_default",
    sourceLang: "en",
    targetLang: "zh-CN",
    listenCount: 0,
    srs: null,
    createdAt: 0,
    updatedAt: 0,
  };
}

/** 一批词形与释义都互不相同的词，任何一题都能凑齐干扰项。 */
function deck(n: number): Word[] {
  return Array.from({ length: n }, (_, i) => word(`w${i}`, `term${i}`, `def${i}`));
}

describe("quizEligibleWords", () => {
  it("只保留词形与释义都非空的词", () => {
    const words = [
      word("w1", "apple", "苹果"),
      word("w2", "banana", ""),
      word("w3", "", "樱桃"),
      word("w4", "   ", "   "),
      word("w5", " date ", "枣 "),
    ];

    expect(quizEligibleWords(words).map((w) => w.id)).toEqual(["w1", "w5"]);
  });

  it("全空的词表得到空数组", () => {
    expect(quizEligibleWords([])).toEqual([]);
  });
});

describe("buildQuiz", () => {
  it("每题给出 4 个互不相同的选项，正确答案恰好出现一次", () => {
    const questions = buildQuiz(deck(10), "termToDef");

    expect(questions.length).toBeGreaterThan(0);
    for (const q of questions) {
      expect(q.options).toHaveLength(QUIZ_CHOICES);
      expect(new Set(q.options).size).toBe(QUIZ_CHOICES);
      expect(q.options.filter((option) => option === q.answer)).toHaveLength(1);
    }
  });

  it("answerIndex 正好指向正确答案", () => {
    for (const q of buildQuiz(deck(10), "defToTerm")) {
      expect(q.answerIndex).toBeGreaterThanOrEqual(0);
      expect(q.answerIndex).toBeLessThan(q.options.length);
      expect(q.options[q.answerIndex]).toBe(q.answer);
    }
  });

  it("看词选义：题干是词形，答案是释义", () => {
    const words = deck(6);
    const byId = new Map(words.map((w) => [w.id, w]));

    for (const q of buildQuiz(words, "termToDef")) {
      const source = byId.get(q.wordId)!;
      expect(q.prompt).toBe(source.term);
      expect(q.answer).toBe(source.definition);
    }
  });

  it("看义选词：题干是释义，答案是词形", () => {
    const words = deck(6);
    const byId = new Map(words.map((w) => [w.id, w]));

    for (const q of buildQuiz(words, "defToTerm")) {
      const source = byId.get(q.wordId)!;
      expect(q.prompt).toBe(source.definition);
      expect(q.answer).toBe(source.term);
    }
  });

  it("同一轮里每个词最多出现一次", () => {
    const questions = buildQuiz(deck(20), "termToDef");
    const ids = questions.map((q) => q.wordId);

    expect(ids).toHaveLength(QUIZ_ROUND);
    expect(new Set(ids).size).toBe(ids.length);
  });

  it("轮次大小受 count 限制", () => {
    expect(buildQuiz(deck(15), "termToDef")).toHaveLength(QUIZ_ROUND);
    expect(buildQuiz(deck(15), "termToDef", 3)).toHaveLength(3);
  });

  it("释义相同的词不会成为同一题的重复选项", () => {
    // 两个词共用一个释义：互相不能当对方的干扰项，选项文本仍然唯一。
    const words = [
      word("w0", "a", "same"),
      word("w1", "b", "same"),
      word("w2", "c", "x"),
      word("w3", "d", "y"),
      word("w4", "e", "z"),
    ];

    for (const q of buildQuiz(words, "termToDef")) {
      expect(new Set(q.options).size).toBe(q.options.length);
    }
  });

  it("可用词不足 4 个时返回空数组", () => {
    expect(buildQuiz(deck(3), "termToDef")).toEqual([]);
  });

  it("count 不为正时返回空数组", () => {
    expect(buildQuiz(deck(10), "termToDef", 0)).toEqual([]);
    expect(buildQuiz(deck(10), "termToDef", -1)).toEqual([]);
  });

  it("没有可用词时返回空数组", () => {
    const words = [word("w0", "a", ""), word("w1", "b", "  "), word("w2", "", "c")];
    expect(buildQuiz(words, "termToDef")).toEqual([]);
  });
});

describe("quizShortfall", () => {
  it("能出题时返回 null", () => {
    expect(quizShortfall(deck(10), "termToDef")).toBeNull();
  });

  it("一个可用词都没有时说明是 no-eligible-words", () => {
    expect(quizShortfall(deck(0), "termToDef")).toBe("no-eligible-words");
    expect(
      quizShortfall([word("w0", "a", ""), word("w1", "", "b")], "termToDef"),
    ).toBe("no-eligible-words");
  });

  it("可用词不足 4 个时说明是 not-enough-words", () => {
    expect(quizShortfall(deck(3), "termToDef")).toBe("not-enough-words");
    // 有词但释义缺失，原因仍应是"词不够"而不是"一个都没有"。
    expect(
      quizShortfall([...deck(3), word("w9", "term9", "")], "termToDef"),
    ).toBe("not-enough-words");
  });

  it("这一轮没有意义时说明是 empty-round", () => {
    expect(quizShortfall(deck(10), "termToDef", 0)).toBe("empty-round");
  });

  it("词够多但干扰项文本全都重复时说明是 not-enough-distractors", () => {
    // 四个可用词，却只有三个不同的释义：每个词都凑不齐三个干扰项。
    const words = [
      word("w0", "a", "same"),
      word("w1", "b", "same"),
      word("w2", "c", "same"),
      word("w3", "d", "same"),
    ];

    expect(quizShortfall(words, "termToDef")).toBe("not-enough-distractors");
    expect(buildQuiz(words, "termToDef")).toEqual([]);
  });

  it("空结果与 shortfall 判断始终一致", () => {
    const cases: Array<[Word[], number]> = [
      [deck(10), QUIZ_ROUND],
      [deck(3), QUIZ_ROUND],
      [deck(0), QUIZ_ROUND],
      [deck(10), 0],
      [deck(4), QUIZ_ROUND],
    ];

    for (const [words, count] of cases) {
      const questions = buildQuiz(words, "termToDef", count);
      expect(questions.length === 0).toBe(quizShortfall(words, "termToDef", count) !== null);
    }
  });
});
