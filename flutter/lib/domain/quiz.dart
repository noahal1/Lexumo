/// 测验出题：纯函数，不触碰 store，也不写入 SRS。
///
/// Ported from `src/lib/quiz.ts`. The tests only assert the properties a round
/// must have (option count, answer position, de-duplication, direction), never
/// a specific random order — [shuffle] differs on every call.
library;

import 'dart:math';

import 'types.dart';
import 'utils.dart';

/// Which way round a question is asked.
enum QuizDirection {
  /// 看词选义 — prompt is the term, answer is the definition.
  termToDef('termToDef'),

  /// 看义选词 — prompt is the definition, answer is the term.
  defToTerm('defToTerm');

  const QuizDirection(this.wire);
  final String wire;
}

const int QUIZ_CHOICES = 4;
const int QUIZ_ROUND = 10;

/// 一轮测验出不了题的原因。
///
/// [buildQuiz] used to signal failure with an empty list only, so "词不够",
/// "干扰项不够" and "这一轮根本没意义" all looked identical to the caller, who
/// then had to count the words again to guess. Making the reason a return value
/// keeps that judgement inside this module.
enum QuizShortfall {
  emptyRound('empty-round'),
  noEligibleWords('no-eligible-words'),
  notEnoughWords('not-enough-words'),
  notEnoughDistractors('not-enough-distractors');

  const QuizShortfall(this.wire);
  final String wire;
}

/// One question: a prompt, the right answer, and four shuffled options.
class QuizQuestion {
  const QuizQuestion({
    required this.wordId,
    required this.prompt,
    required this.answer,
    required this.options,
    required this.answerIndex,
  });

  final String wordId;

  /// 题干：看词选义时为词形，看义选词时为释义。
  final String prompt;

  /// 正确答案文本。
  final String answer;

  /// 四个选项，顺序已打乱。
  final List<String> options;
  final int answerIndex;
}

class _QuizPlan {
  const _QuizPlan(this.questions, this.shortfall);

  final List<QuizQuestion> questions;

  /// null 表示这一轮可以出题。
  final QuizShortfall? shortfall;
}

String _answerOf(Word word, QuizDirection direction) =>
    direction == QuizDirection.termToDef
        ? word.definition.trim()
        : word.term.trim();

/// 只有词形与释义都齐全的词才能参与出题。
List<Word> quizEligibleWords(List<Word> words) => words
    .where((word) => word.term.trim() != '' && word.definition.trim() != '')
    .toList();

/// 生成一轮测验：每题 4 选 1，干扰项取自其它词的释义（或词形），
/// 按文本去重；选项顺序随机。
///
/// 单个词凑不齐干扰项时跳过它（一轮可能因此不满），整轮一题都出不了时
/// 用 [QuizShortfall] 说明原因，而不是让调用方对着空数组猜。
///
/// [random] is an optional seed hook so a caller (or a test) can pin the
/// order; production passes nothing and gets the shared unpredictable source.
_QuizPlan _planQuiz(
  List<Word> words,
  QuizDirection direction,
  int count, {
  Random? random,
}) {
  final pool = quizEligibleWords(words);
  if (count <= 0) return const _QuizPlan([], QuizShortfall.emptyRound);
  if (pool.isEmpty) return const _QuizPlan([], QuizShortfall.noEligibleWords);
  if (pool.length < QUIZ_CHOICES) {
    return const _QuizPlan([], QuizShortfall.notEnoughWords);
  }

  final picked = shuffle(pool, random).take(count).toList();
  final questions = <QuizQuestion>[];

  for (final word in picked) {
    final answer = _answerOf(word, direction);
    if (answer.isEmpty) continue;

    final seen = <String>{answer.toLowerCase()};
    final distractors = <String>[];
    for (final other in shuffle(pool, random)) {
      if (other.id == word.id) continue;
      final text = _answerOf(other, direction);
      if (text.isEmpty) continue;
      final key = text.toLowerCase();
      if (seen.contains(key)) continue;
      seen.add(key);
      distractors.add(text);
      if (distractors.length >= QUIZ_CHOICES - 1) break;
    }
    if (distractors.length < QUIZ_CHOICES - 1) continue;

    final options = shuffle([answer, ...distractors], random);
    questions.add(QuizQuestion(
      wordId: word.id,
      prompt: direction == QuizDirection.termToDef
          ? word.term
          : word.definition,
      answer: answer,
      options: options,
      answerIndex: options.indexOf(answer),
    ));
  }

  return _QuizPlan(
    questions,
    questions.isEmpty ? QuizShortfall.notEnoughDistractors : null,
  );
}

/// 这一轮的问题；出不了题时是空数组，原因见 [quizShortfall]。
List<QuizQuestion> buildQuiz(
  List<Word> words,
  QuizDirection direction, {
  int count = QUIZ_ROUND,
  Random? random,
}) =>
    _planQuiz(words, direction, count, random: random).questions;

/// 这一轮为什么出不了题；能出题时返回 null。
QuizShortfall? quizShortfall(
  List<Word> words,
  QuizDirection direction, {
  int count = QUIZ_ROUND,
}) =>
    _planQuiz(words, direction, count).shortfall;
