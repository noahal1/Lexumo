import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { Icon } from "@/components/Icon";
import {
  EmptyState,
  PageShell,
  ProgressBar,
  Ring,
  Segmented,
  ShortcutRow,
  StatTile,
  useToast,
} from "@/components/ui";
import { useRouter } from "@/app/router";
import { useT } from "@/i18n";
import {
  QUIZ_CHOICES,
  QUIZ_ROUND,
  buildQuiz,
  quizEligibleWords,
  type QuizDirection,
  type QuizQuestion,
} from "@/lib/quiz";
import { getData, useAppData } from "@/lib/store";
import { speak, speechSupported, stopSpeaking } from "@/lib/tts";
import type { Word } from "@/lib/types";
import { cx } from "@/lib/utils";
import "@/styles/study.css";

type Phase = "idle" | "active" | "done";

const LETTERS = ["A", "B", "C", "D"];

const KEY_TO_INDEX: Record<string, number> = {
  a: 0,
  b: 1,
  c: 2,
  d: 3,
  "1": 0,
  "2": 1,
  "3": 2,
  "4": 3,
};

function formatDuration(ms: number): string {
  const total = Math.max(0, Math.round(ms / 1000));
  const minutes = Math.floor(total / 60);
  const seconds = total % 60;
  return `${minutes}:${String(seconds).padStart(2, "0")}`;
}

export function QuizPage() {
  const data = useAppData();
  const settings = data.settings;
  const t = useT();
  const router = useRouter();
  const toast = useToast();

  const [direction, setDirection] = useState<QuizDirection>("termToDef");
  const [phase, setPhase] = useState<Phase>("idle");
  const [questions, setQuestions] = useState<QuizQuestion[]>([]);
  const [index, setIndex] = useState(0);
  const [answers, setAnswers] = useState<Array<number | null>>([]);
  const [selected, setSelected] = useState<number | null>(null);
  const [elapsed, setElapsed] = useState(0);

  const startedAtRef = useRef(0);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const eligible = quizEligibleWords(data.words);
  const enough = eligible.length >= QUIZ_CHOICES;
  const current = phase === "active" ? questions[index] : undefined;
  const answered = selected !== null;

  const wordById = useMemo(
    () => new Map<string, Word>(data.words.map((word) => [word.id, word])),
    [data.words],
  );

  const score = questions.reduce(
    (acc, question, questionIndex) =>
      acc + (answers[questionIndex] === question.answerIndex ? 1 : 0),
    0,
  );
  const answeredCount = answers.filter((answer) => answer !== null).length;
  const accuracy = questions.length > 0 ? score / questions.length : 0;
  const mistakes = questions
    .map((question, questionIndex) => ({
      question,
      answer: answers[questionIndex] ?? null,
      key: `${question.wordId}-${questionIndex}`,
    }))
    .filter((item) => item.answer !== item.question.answerIndex);

  const directionLabel =
    direction === "termToDef" ? t("quiz.termToDef") : t("quiz.defToTerm");
  const canSpeak = speechSupported();

  const play = useCallback(
    (target: Word) => {
      speak(target.term, {
        lang: target.sourceLang,
        rate: settings.ttsRate,
        voiceURI: settings.ttsVoiceURI,
      });
    },
    [settings.ttsRate, settings.ttsVoiceURI],
  );

  const clearTimer = useCallback(() => {
    if (timerRef.current) {
      clearTimeout(timerRef.current);
      timerRef.current = null;
    }
  }, []);

  const finish = useCallback(() => {
    clearTimer();
    stopSpeaking();
    setElapsed(Date.now() - startedAtRef.current);
    setPhase("done");
  }, [clearTimer]);

  const goNext = useCallback(() => {
    clearTimer();
    if (index + 1 >= questions.length) {
      finish();
      return;
    }
    setIndex(index + 1);
    setSelected(null);
  }, [clearTimer, finish, index, questions.length]);

  const start = useCallback(
    (dir: QuizDirection) => {
      const built = buildQuiz(getData().words, dir, QUIZ_ROUND);
      if (built.length === 0) {
        toast("词语不足，暂时无法生成测验", "info");
        return;
      }
      setQuestions(built);
      setAnswers(new Array<number | null>(built.length).fill(null));
      setIndex(0);
      setSelected(null);
      setElapsed(0);
      startedAtRef.current = Date.now();
      setPhase("active");
    },
    [toast],
  );

  const choose = useCallback(
    (option: number) => {
      if (selected !== null) return;
      setSelected(option);
      setAnswers((prev) => {
        const next = prev.slice();
        next[index] = option;
        return next;
      });
      timerRef.current = setTimeout(() => {
        timerRef.current = null;
        goNext();
      }, 900);
    },
    [selected, index, goNext],
  );

  useEffect(() => () => {
    clearTimer();
    stopSpeaking();
  }, [clearTimer]);

  /* 1–4 / A–D pick an option · Enter advances */
  useEffect(() => {
    if (phase !== "active") return;
    const onKeyDown = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement | null;
      if (
        target &&
        (target.tagName === "INPUT" ||
          target.tagName === "TEXTAREA" ||
          target.isContentEditable)
      ) {
        return;
      }

      if (event.key === "Enter") {
        if (selected !== null) {
          event.preventDefault();
          goNext();
        }
        return;
      }

      const mapped = KEY_TO_INDEX[event.key.toLowerCase()];
      if (mapped !== undefined) {
        event.preventDefault();
        choose(mapped);
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [phase, selected, choose, goNext]);

  const sidePanel = (
    <aside className="study-side">
      <StatTile
        label={t("quiz.score")}
        value={`${score} / ${answeredCount}`}
        sub={
          questions.length > 0
            ? t("quiz.question", {
                i: Math.min(index + 1, questions.length),
                n: questions.length,
              })
            : `${eligible.length} 个可用词语`
        }
        icon="target"
      />
      <div className="card card-pad stack">
        <div className="card-title">{t("settings.shortcuts")}</div>
        <div className="shortcuts">
          <ShortcutRow keys={["A", "B", "C", "D"]} label="选择答案" />
          <ShortcutRow keys={["1", "2", "3", "4"]} label="选择答案（数字）" />
          <ShortcutRow keys={["Enter"]} label={t("quiz.next")} />
        </div>
      </div>
    </aside>
  );

  return (
    <PageShell
      title={t("quiz.title")}
      subtitle={t("quiz.subtitle")}
      actions={
        phase === "active" ? (
          <button type="button" className="btn btn-quiet" onClick={finish}>
            {t("quiz.finish")}
          </button>
        ) : (
          <Segmented<QuizDirection>
            value={direction}
            options={[
              { value: "termToDef", label: t("quiz.termToDef") },
              { value: "defToTerm", label: t("quiz.defToTerm") },
            ]}
            onChange={setDirection}
            ariaLabel={t("quiz.direction")}
          />
        )
      }
    >
      {phase === "idle" ? (
        <div className="study-split">
          <div className="study-main">
            {enough ? (
              <div className="card fc-intro rise">
                <div className="fc-intro-ico">
                  <Icon name="quiz" size={26} />
                </div>
                <div className="stack">
                  <h2 className="fc-intro-title">{t("quiz.start")}</h2>
                  <p className="fc-intro-text">
                    {directionLabel} · {t("quiz.chooseCount")}{" "}
                    {Math.min(QUIZ_ROUND, eligible.length)}
                  </p>
                </div>
                <div className="row-flex wrap">
                  <span className="chip chip-tag">{directionLabel}</span>
                  <span className="chip chip-new">
                    {eligible.length} 个可用词语
                  </span>
                </div>
                <div className="study-actions">
                  <button
                    type="button"
                    className="btn btn-primary btn-lg"
                    onClick={() => start(direction)}
                  >
                    {t("quiz.start")}
                    <Icon name="arrow-right" size={17} />
                  </button>
                </div>
                <p className="tiny muted">
                  键盘 A–D 或 1–4 选择 · Enter 下一题
                </p>
              </div>
            ) : (
              <div className="card">
                <EmptyState
                  icon="quiz"
                  title={t("quiz.noWords")}
                  text={t("quiz.noWordsHint")}
                  action={
                    <button
                      type="button"
                      className="btn btn-primary"
                      onClick={() => router.navigate("words")}
                    >
                      <Icon name="plus" size={16} />
                      {t("words.addWord")}
                    </button>
                  }
                />
              </div>
            )}
          </div>
          {sidePanel}
        </div>
      ) : phase === "active" && current ? (
        <div className="study-split">
          <div className="study-main">
            <div className="study-bar">
              <div className="study-bar-row">
                <span className="study-bar-label mono">
                  {t("quiz.question", { i: index + 1, n: questions.length })}
                </span>
                <span className="chip chip-tag">{directionLabel}</span>
                <span className="spacer" />
                <span className="chip chip-mastered mono">
                  {t("quiz.score")} {score}
                </span>
              </div>
              <ProgressBar
                value={index + (answered ? 1 : 0)}
                max={questions.length}
                thick
              />
            </div>

            <div className="card quiz-prompt rise">
              <div className="row-flex">
                <span className="fc-face-label">
                  {direction === "termToDef"
                    ? t("flashcards.front")
                    : t("flashcards.back")}
                </span>
                <span className="spacer" />
                {canSpeak && wordById.get(current.wordId) && (
                  <button
                    type="button"
                    className="btn btn-quiet btn-icon btn-sm"
                    title={t("flashcards.autoPlay")}
                    aria-label={t("flashcards.autoPlay")}
                    onClick={() => {
                      const target = wordById.get(current.wordId);
                      if (target) play(target);
                    }}
                  >
                    <Icon name="volume" size={16} />
                  </button>
                )}
              </div>
              <div
                className={cx(
                  "quiz-prompt-text",
                  direction === "termToDef" ? "is-term" : "is-def",
                )}
              >
                {current.prompt}
              </div>
            </div>

            <div className="quiz-options">
              {current.options.map((option, optionIndex) => {
                const isAnswer = optionIndex === current.answerIndex;
                const isPicked = selected === optionIndex;
                const state = !answered
                  ? ""
                  : isAnswer
                    ? "is-correct"
                    : isPicked
                      ? "is-wrong"
                      : "is-dim";
                return (
                  <button
                    key={`${current.wordId}-${optionIndex}`}
                    type="button"
                    className={cx("btn", "quiz-option", state)}
                    onClick={() => choose(optionIndex)}
                    disabled={answered}
                  >
                    <span className="quiz-key">{LETTERS[optionIndex]}</span>
                    <span className="quiz-opt-text">{option}</span>
                    {answered && isAnswer && (
                      <span className="quiz-opt-ico t-jade">
                        <Icon name="check" size={16} />
                      </span>
                    )}
                    {answered && isPicked && !isAnswer && (
                      <span className="quiz-opt-ico t-rose">
                        <Icon name="x" size={16} />
                      </span>
                    )}
                  </button>
                );
              })}
            </div>

            <div className="quiz-foot">
              {answered ? (
                <>
                  <div
                    className={cx(
                      "notice",
                      selected === current.answerIndex ? "is-ok" : "is-bad",
                    )}
                  >
                    <span className="notice-ico">
                      <Icon
                        name={selected === current.answerIndex ? "check" : "x"}
                        size={15}
                      />
                    </span>
                    <span>
                      {selected === current.answerIndex
                        ? t("quiz.correct")
                        : `${t("quiz.wrong")} · ${t("quiz.correctAnswer")}：${
                            current.options[current.answerIndex]
                          }`}
                    </span>
                  </div>
                  <button
                    type="button"
                    className="btn btn-primary"
                    onClick={goNext}
                  >
                    {index + 1 >= questions.length
                      ? t("quiz.finish")
                      : t("quiz.next")}
                    <span className="kbd">Enter</span>
                  </button>
                </>
              ) : (
                <p className="tiny muted">
                  按 <span className="kbd">A</span>–<span className="kbd">D</span>{" "}
                  或 <span className="kbd">1</span>–<span className="kbd">4</span>{" "}
                  选择答案
                </p>
              )}
            </div>
          </div>
          {sidePanel}
        </div>
      ) : (
        <div className="study-split">
          <div className="study-main">
            <div className="card fc-done rise">
              <Ring
                value={score}
                max={Math.max(questions.length, 1)}
                size={140}
                stroke={9}
              >
                <div className="fc-done-num">{Math.round(accuracy * 100)}%</div>
                <div className="tiny muted">{t("quiz.accuracy")}</div>
              </Ring>
              <div className="stack">
                <h2 className="fc-intro-title">
                  {score === questions.length && questions.length > 0
                    ? t("quiz.perfect")
                    : t("quiz.keepGoing")}
                </h2>
                <p className="fc-intro-text">{t("quiz.result")}</p>
              </div>
              <div className="fc-stats">
                <StatTile
                  label={t("quiz.score")}
                  value={`${score} / ${questions.length}`}
                />
                <StatTile
                  label={t("quiz.accuracy")}
                  value={`${Math.round(accuracy * 100)}%`}
                />
                <StatTile
                  label={t("quiz.timeSpent")}
                  value={formatDuration(elapsed)}
                />
              </div>
              <div className="study-actions">
                <button
                  type="button"
                  className="btn btn-primary btn-lg"
                  onClick={() => start(direction)}
                >
                  {t("quiz.again")}
                  <Icon name="refresh" size={16} />
                </button>
                <button
                  type="button"
                  className="btn btn-quiet"
                  onClick={() => {
                    setPhase("idle");
                    setQuestions([]);
                    setAnswers([]);
                    setIndex(0);
                    setSelected(null);
                  }}
                >
                  {t("quiz.exit")}
                </button>
              </div>
            </div>

            {mistakes.length > 0 && (
              <div className="card card-flush">
                <div className="card-head">
                  <span className="card-title">{t("quiz.missed")}</span>
                  <span className="card-sub">{mistakes.length}</span>
                </div>
                <div className="quiz-mistakes">
                  {mistakes.map((item) => {
                    const target = wordById.get(item.question.wordId);
                    return (
                      <div className="quiz-mistake" key={item.key}>
                        <div className="quiz-mistake-main">
                          <div className="quiz-mistake-term">
                            {item.question.prompt}
                          </div>
                          <div className="quiz-mistake-ans">
                            <span>
                              {t("quiz.yourAnswer")}：
                              <b
                                className={
                                  item.answer === null ? undefined : "t-rose"
                                }
                              >
                                {item.answer === null
                                  ? "未作答"
                                  : item.question.options[item.answer]}
                              </b>
                            </span>
                            <span>·</span>
                            <span>
                              {t("quiz.correctAnswer")}：
                              <b className="t-jade">
                                {item.question.options[item.question.answerIndex]}
                              </b>
                            </span>
                          </div>
                        </div>
                        {canSpeak && target && (
                          <button
                            type="button"
                            className="btn btn-quiet btn-icon btn-sm"
                            title={t("flashcards.autoPlay")}
                            aria-label={t("flashcards.autoPlay")}
                            onClick={() => play(target)}
                          >
                            <Icon name="volume" size={16} />
                          </button>
                        )}
                      </div>
                    );
                  })}
                </div>
              </div>
            )}
          </div>
          {sidePanel}
        </div>
      )}
    </PageShell>
  );
}
