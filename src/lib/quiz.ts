/** 测验出题：纯函数，不触碰 store，也不写入 SRS。 */
import type { Word } from "./types";
import { shuffle } from "./utils";

export type QuizDirection = "termToDef" | "defToTerm";

export const QUIZ_CHOICES = 4;
export const QUIZ_ROUND = 10;

export interface QuizQuestion {
  wordId: string;
  /** 题干：看词选义时为词形，看义选词时为释义。 */
  prompt: string;
  /** 正确答案文本。 */
  answer: string;
  /** 四个选项，顺序已打乱。 */
  options: string[];
  answerIndex: number;
}

/**
 * 一轮测验出不了题的原因。
 *
 * `buildQuiz` 曾经只用空数组表示失败，于是"词不够""干扰项不够""这一轮根本
 * 没意义"三种情况在调用方看来一模一样，只能再数一遍词去猜。把原因做成
 * 返回值，判断就只留在这个模块里。
 */
export type QuizShortfall =
  | "empty-round"
  | "no-eligible-words"
  | "not-enough-words"
  | "not-enough-distractors";

interface QuizPlan {
  questions: QuizQuestion[];
  /** null 表示这一轮可以出题。 */
  shortfall: QuizShortfall | null;
}

function answerOf(word: Word, direction: QuizDirection): string {
  return direction === "termToDef" ? word.definition.trim() : word.term.trim();
}

/** 只有词形与释义都齐全的词才能参与出题。 */
export function quizEligibleWords(words: Word[]): Word[] {
  return words.filter((word) => word.term.trim() !== "" && word.definition.trim() !== "");
}

/**
 * 生成一轮测验：每题 4 选 1，干扰项取自其它词的释义（或词形），
 * 按文本去重；选项顺序随机。
 *
 * 单个词凑不齐干扰项时跳过它（一轮可能因此不满），整轮一题都出不了时
 * 用 `shortfall` 说明原因，而不是让调用方对着空数组猜。
 */
function planQuiz(
  words: Word[],
  direction: QuizDirection,
  count: number,
): QuizPlan {
  const pool = quizEligibleWords(words);
  if (count <= 0) return { questions: [], shortfall: "empty-round" };
  if (pool.length === 0) return { questions: [], shortfall: "no-eligible-words" };
  if (pool.length < QUIZ_CHOICES) return { questions: [], shortfall: "not-enough-words" };

  const picked = shuffle(pool).slice(0, count);
  const questions: QuizQuestion[] = [];

  for (const word of picked) {
    const answer = answerOf(word, direction);
    if (!answer) continue;

    const seen = new Set<string>([answer.toLocaleLowerCase()]);
    const distractors: string[] = [];
    for (const other of shuffle(pool)) {
      if (other.id === word.id) continue;
      const text = answerOf(other, direction);
      if (!text) continue;
      const key = text.toLocaleLowerCase();
      if (seen.has(key)) continue;
      seen.add(key);
      distractors.push(text);
      if (distractors.length >= QUIZ_CHOICES - 1) break;
    }
    if (distractors.length < QUIZ_CHOICES - 1) continue;

    const options = shuffle([answer, ...distractors]);
    questions.push({
      wordId: word.id,
      prompt: direction === "termToDef" ? word.term : word.definition,
      answer,
      options,
      answerIndex: options.indexOf(answer),
    });
  }

  return {
    questions,
    shortfall: questions.length === 0 ? "not-enough-distractors" : null,
  };
}

/** 这一轮的问题；出不了题时是空数组，原因见 `quizShortfall`。 */
export function buildQuiz(
  words: Word[],
  direction: QuizDirection,
  count: number = QUIZ_ROUND,
): QuizQuestion[] {
  return planQuiz(words, direction, count).questions;
}

/** 这一轮为什么出不了题；能出题时返回 null。 */
export function quizShortfall(
  words: Word[],
  direction: QuizDirection,
  count: number = QUIZ_ROUND,
): QuizShortfall | null {
  return planQuiz(words, direction, count).shortfall;
}
