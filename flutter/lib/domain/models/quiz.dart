/// 测验出题：纯函数，不触碰 store，也不写入 SRS。
///
/// Ported from the web build's `quiz.ts`. The tests only assert the properties a round
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
    this.promptSecondary,
    required this.answer,
    required this.options,
    required this.answerIndex,
  });

  final String wordId;

  /// 题干：看词选义时为词形，看义选词时为释义。
  final String prompt;

  /// 题干下方的一行补充释义，只有看义选词、且这个词记了第二层含义时才有。
  ///
  /// 题干只放主释义是为了让它保持一句话那么短；但用户记住的可能是第二层
  /// 含义，只显示主释义会让他认不出这道题在问哪个词。
  final String? promptSecondary;

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

/// 释义里用来分隔各层义项的符号。
///
/// 「开始；着手」「开始，着手」「开始/着手」都是同一种写法，判断两个词是否
/// 撞义项时必须先切开再比，否则整串比较只会漏掉所有真实重叠。
final RegExp _senseSeparator = RegExp(r'[;；,，、/|｜]');

/// 一层义项的比较形式：去空白、压小写、去掉收尾标点。
String _senseKey(String raw) => raw
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[.。!！?？…\s]+$'), '')
    .trim();

/// 一个词条记下的全部义项：主释义与补充释义，各自再按分隔符切开。
///
/// 这是判断「另一个词的释义是不是也说得通」的依据。[definition2] 参与比较
/// 而不是只参与显示：用户记的第二层含义同样会让别人的选项看起来是对的。
Set<String> _sensesOf(Word word) {
  final senses = <String>{};
  for (final String field in <String>[word.definition, word.definition2]) {
    for (final String part in field.split(_senseSeparator)) {
      final key = _senseKey(part);
      if (key.isNotEmpty) senses.add(key);
    }
  }
  return senses;
}

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
/// 干扰项还要过一道「义项」检查：与本题词共享任何一层含义的词不选，
/// 与已选中的其它干扰项共享含义的也不选。文本去重只能挡住一字不差的重复，
/// 挡不住「开始」与「开始；着手」这种——同框时用户面对的是两个都对（撞答案）
/// 或两个一样（撞彼此）的选项。这条规则两个方向共用：看词选义时挡的是释义
/// 重叠，看义选词时挡的是同一个意思有两个词形。
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

    final ownSenses = _sensesOf(word);
    // Senses already spoken for on this question — the right answer's first,
    // then every distractor picked so far. A candidate that overlaps any of
    // them is out: as a distractor it would be a second right answer (when it
    // overlaps the answer) or a duplicate of another distractor (when it
    // overlaps a neighbour), and both read as a broken question.
    final takenSenses = <String>{...ownSenses};
    final seen = <String>{answer.toLowerCase()};
    final distractors = <String>[];
    for (final other in shuffle(pool, random)) {
      if (other.id == word.id) continue;
      final otherSenses = _sensesOf(other);
      if (otherSenses.any(takenSenses.contains)) continue;
      final text = _answerOf(other, direction);
      if (text.isEmpty) continue;
      final key = text.toLowerCase();
      if (seen.contains(key)) continue;
      seen.add(key);
      takenSenses.addAll(otherSenses);
      distractors.add(text);
      if (distractors.length >= QUIZ_CHOICES - 1) break;
    }
    if (distractors.length < QUIZ_CHOICES - 1) continue;

    final options = shuffle([answer, ...distractors], random);
    final secondary = direction == QuizDirection.defToTerm
        ? word.definition2.trim()
        : '';
    questions.add(QuizQuestion(
      wordId: word.id,
      prompt: direction == QuizDirection.termToDef
          ? word.term
          : word.definition,
      promptSecondary: secondary.isEmpty ? null : secondary,
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
