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

function answerOf(word: Word, direction: QuizDirection): string {
  return direction === "termToDef" ? word.definition.trim() : word.term.trim();
}

/** 只有词形与释义都齐全的词才能参与出题。 */
export function quizEligibleWords(words: Word[]): Word[] {
  return words.filter((word) => word.term.trim() !== "" && word.definition.trim() !== "");
}

/**
 * 生成一轮测验：每题 4 选 1，干扰项取自其它词的释义（或词形），
 * 按文本去重；选项顺序随机。词语不足或干扰项不足时返回空数组。
 */
export function buildQuiz(
  words: Word[],
  direction: QuizDirection,
  count: number = QUIZ_ROUND,
): QuizQuestion[] {
  const pool = quizEligibleWords(words);
  if (pool.length < QUIZ_CHOICES || count <= 0) return [];

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

  return questions;
}
