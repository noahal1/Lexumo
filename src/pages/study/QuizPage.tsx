/**
 * 测验页：看词选义 / 看义选词两种方向，4 选 1 即时反馈，
 * 结束页给出得分环、正确率、用时与错题回顾。测验不写入 SRS。
 */
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { CSSProperties } from "react";
import { EmptyState, PageShell, ProgressBar, Ring, Segmented, useToast } from "@/components/ui";
import { Icon } from "@/components/Icon";
import { useT } from "@/i18n";
import { useRouter } from "@/app/router";
import { getData, useAppData } from "@/lib/store";
import {
  buildQuiz,
  QUIZ_CHOICES,
  QUIZ_ROUND,
  quizEligibleWords,
  type QuizDirection,
  type QuizQuestion,
} from "@/lib/quiz";
import { speak, speechSupported, stopSpeaking } from "@/lib/tts";

type Phase = "idle" | "active" | "done";

const LETTERS = ["A", "B", "C", "D"];
const KEY_TO_INDEX: Record<string, number | undefined> = {
  a: 0,
  b: 1,
  c: 2,
  d: 3,
  "1": 0,
  "2": 1,
  "3": 2,
  "4": 3,
};

const OPTION_STATES: Record<"idle" | "correct" | "wrong" | "dim", CSSProperties> = {
  idle: {
    border: "1px solid var(--line)",
    background: "var(--surface)",
    color: "var(--ink)",
  },
  correct: {
    border: "1px solid var(--jade)",
    background: "var(--jade-soft)",
    color: "var(--jade-ink)",
  },
  wrong: {
    border: "1px solid var(--rose)",
    background: "var(--rose-soft)",
    color: "var(--ink)",
  },
  dim: {
    border: "1px solid var(--line)",
    background: "var(--surface)",
    color: "var(--ink-3)",
    opacity: 0.55,
  },
};

function formatDuration(ms: number): string {
  const seconds = Math.max(0, Math.round(ms / 1000));
  const mm = Math.floor(seconds / 60);
  const ss = seconds % 60;
  return `${mm}:${String(ss).padStart(2, "0")}`;
}

export function QuizPage() {
  const t = useT();
  const { navigate } = useRouter();
  const data = useAppData();
  const settings = data.settings;
  const toast = useToast();

  const [direction, setDirection] = useState<QuizDirection>("termToDef");
  const [phase, setPhase] = useState<Phase>("idle");
  const [questions, setQuestions] = useState<QuizQuestion[]>([]);
  const [index, setIndex] = useState(0);
  const [answers, setAnswers] = useState<(number | null)[]>([]);
  const [selected, setSelected] = useState<number | null>(null);
  const [startedAt, setStartedAt] = useState(0);
  const [elapsed, setElapsed] = useState(0);

  const timerRef = useRef<number | null>(null);
  const wordById = useMemo(
    () => new Map(data.words.map((word) => [word.id, word])),
    [data.words],
  );

  const eligible = quizEligibleWords(data.words);
  const enough = eligible.length >= QUIZ_CHOICES;
  const canSpeak = speechSupported();

  const clearTimer = useCallback(() => {
    if (timerRef.current !== null) {
      window.clearTimeout(timerRef.current);
      timerRef.current = null;
    }
  }, []);

  const start = useCallback(
    (dir: QuizDirection) => {
      const built = buildQuiz(getData().words, dir, QUIZ_ROUND);
      if (built.length === 0) {
        toast("词语不足，暂时无法生成测验", "info");
        return;
      }
      clearTimer();
      setQuestions(built);
      setAnswers(built.map(() => null));
      setIndex(0);
      setSelected(null);
      setStartedAt(Date.now());
      setElapsed(0);
      setPhase("active");
    },
    [clearTimer, toast],
  );

  const finish = useCallback(
    (from: number) => {
      clearTimer();
      stopSpeaking();
      setSelected(null);
      setElapsed(Date.now() - from);
      setPhase("done");
    },
    [clearTimer],
  );

  const goNext = useCallback(() => {
    clearTimer();
    if (index + 1 >= questions.length) {
      finish(startedAt);
      return;
    }
    setIndex(index + 1);
    setSelected(null);
  }, [clearTimer, finish, index, questions.length, startedAt]);

  const choose = useCallback(
    (option: number) => {
      if (selected !== null) return;
      setSelected(option);
      setAnswers((prev) => {
        const next = prev.slice();
        next[index] = option;
        return next;
      });
      clearTimer();
      timerRef.current = window.setTimeout(() => {
        timerRef.current = null;
        goNext();
      }, 900);
    },
    [clearTimer, goNext, index, selected],
  );

  useEffect(
    () => () => {
      if (timerRef.current !== null) window.clearTimeout(timerRef.current);
      stopSpeaking();
    },
    [],
  );

  // 键盘 A–D / 1–4 选项，回车进入下一题。
  useEffect(() => {
    if (phase !== "active") return;
    const onKey = (event: KeyboardEvent) => {
      if (event.metaKey || event.ctrlKey || event.altKey) return;
      const target = event.target as HTMLElement | null;
      if (
        target &&
        (target.tagName === "INPUT" ||
          target.tagName === "TEXTAREA" ||
          target.isContentEditable)
      ) {
        return;
      }
      if (selected !== null) {
        if (event.key === "Enter") {
          event.preventDefault();
          goNext();
        }
        return;
      }
      const option = KEY_TO_INDEX[event.key.toLowerCase()];
      if (option === undefined) return;
      event.preventDefault();
      choose(option);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [phase, selected, choose, goNext]);

  const question: QuizQuestion | undefined = questions[index];
  const answered = selected !== null;
  const score = questions.reduce(
    (acc, item, i) => acc + (answers[i] === item.answerIndex ? 1 : 0),
    0,
  );
  const accuracy = questions.length > 0 ? score / questions.length : 0;
  const isLast = index + 1 >= questions.length;
  const currentWord = question ? wordById.get(question.wordId) : undefined;
  const directionLabel =
    direction === "termToDef" ? t("quiz.termToDef") : t("quiz.defToTerm");

  const playWord = (term: string, lang: string) => {
    speak(term, { lang, rate: settings.ttsRate, voiceURI: settings.ttsVoiceURI });
  };

  const actions =
    phase !== "active" ? (
      <Segmented
        value={direction}
        options={[
          { value: "termToDef", label: t("quiz.termToDef") },
          { value: "defToTerm", label: t("quiz.defToTerm") },
        ]}
        onChange={(next) => setDirection(next)}
        ariaLabel={t("quiz.direction")}
      />
    ) : undefined;

  return (
    <PageShell title={t("quiz.title")} subtitle={t("quiz.subtitle")} actions={actions}>
      {phase === "idle" && !enough && (
        <EmptyState
          icon="quiz"
          title={t("quiz.noWords")}
          text={t("quiz.noWordsHint")}
          action={
            <button className="btn btn-primary" type="button" onClick={() => navigate("words")}>
              <Icon name="plus" size={16} />
              去词库添加词语
            </button>
          }
        />
      )}

      {phase === "idle" && enough && (
        <div
          className="card rise"
          style={{
            display: "flex",
            flexDirection: "column",
            alignItems: "center",
            gap: 18,
            padding: "clamp(32px, 6vw, 56px) 24px",
            textAlign: "center",
          }}
        >
          <div
            style={{
              width: 64,
              height: 64,
              borderRadius: "50%",
              background: "var(--jade-soft)",
              color: "var(--jade-ink)",
              display: "grid",
              placeItems: "center",
            }}
          >
            <Icon name="quiz" size={28} />
          </div>
          <div
            style={{
              fontFamily: "var(--font-display)",
              fontSize: 28,
              fontWeight: 600,
              letterSpacing: "-0.01em",
            }}
          >
            {t("quiz.start")}
          </div>
          <p className="muted" style={{ maxWidth: 420 }}>
            {directionLabel} · {t("quiz.chooseCount")} {Math.min(QUIZ_ROUND, eligible.length)}
          </p>
          <button
            className="btn btn-primary btn-lg"
            type="button"
            onClick={() => start(direction)}
            style={{ minWidth: 200 }}
          >
            {t("quiz.start")}
          </button>
          <div className="tiny muted">
            键盘 <span className="kbd">A</span>–<span className="kbd">D</span> 作答 ·{" "}
            <span className="kbd">1</span>–<span className="kbd">4</span> 同样可用
          </div>
        </div>
      )}

      {phase === "active" && question && (
        <div className="stack" style={{ gap: 16 }}>
          <div className="row-flex" style={{ gap: 10 }}>
            <span className="tiny muted mono">
              {t("quiz.question", { i: index + 1, n: questions.length })}
            </span>
            <span className="chip chip-tag">{directionLabel}</span>
            <div className="spacer" />
            {canSpeak && currentWord && (
              <button
                type="button"
                className="btn btn-icon btn-ghost"
                aria-label={`播放 ${currentWord.term}`}
                onClick={() => playWord(currentWord.term, currentWord.sourceLang)}
              >
                <Icon name="volume" size={16} />
              </button>
            )}
          </div>

          <ProgressBar value={index + (answered ? 1 : 0)} max={questions.length} />

          <div
            className="card"
            style={{
              padding: "clamp(24px, 4.5vw, 40px)",
              display: "flex",
              flexDirection: "column",
              alignItems: "center",
              justifyContent: "center",
              gap: 12,
              minHeight: 150,
              textAlign: "center",
            }}
          >
            <div className="tiny muted" style={{ letterSpacing: "0.1em", textTransform: "uppercase" }}>
              {direction === "termToDef" ? t("flashcards.front") : t("flashcards.back")}
            </div>
            <div
              style={{
                fontFamily: "var(--font-display)",
                fontSize: direction === "termToDef" ? "clamp(32px, 5vw, 46px)" : "clamp(20px, 3vw, 26px)",
                lineHeight: 1.4,
                letterSpacing: direction === "termToDef" ? "-0.02em" : "0",
                wordBreak: "break-word",
                maxWidth: 640,
              }}
            >
              {question.prompt}
            </div>
          </div>

          <div
            style={{
              display: "grid",
              gridTemplateColumns: "repeat(auto-fit, minmax(220px, 1fr))",
              gap: 10,
            }}
          >
            {question.options.map((option, i) => {
              const isCorrect = i === question.answerIndex;
              const isPicked = selected === i;
              const state: keyof typeof OPTION_STATES =
                selected === null ? "idle" : isCorrect ? "correct" : isPicked ? "wrong" : "dim";
              return (
                <button
                  key={`${question.wordId}-${i}`}
                  type="button"
                  disabled={answered}
                  onClick={() => choose(i)}
                  style={{
                    ...OPTION_STATES[state],
                    display: "flex",
                    alignItems: "center",
                    gap: 10,
                    width: "100%",
                    padding: "12px 14px",
                    borderRadius: "var(--r-md)",
                    textAlign: "left",
                    fontSize: 14.5,
                    lineHeight: 1.5,
                    cursor: answered ? "default" : "pointer",
                    transition: "background var(--dur-2) var(--ease-out), border-color var(--dur-2) var(--ease-out)",
                  }}
                >
                  <span
                    className="mono"
                    style={{
                      flex: "0 0 auto",
                      width: 22,
                      height: 22,
                      borderRadius: "var(--r-xs)",
                      display: "grid",
                      placeItems: "center",
                      fontSize: 11,
                      fontWeight: 600,
                      background:
                        state === "correct"
                          ? "var(--jade)"
                          : state === "wrong"
                            ? "var(--rose)"
                            : "var(--surface-2)",
                      color:
                        state === "correct" || state === "wrong" ? "#fff" : "var(--ink-3)",
                    }}
                  >
                    {LETTERS[i]}
                  </span>
                  <span style={{ flex: 1 }}>{option}</span>
                  {selected !== null && isCorrect && <Icon name="check" size={15} />}
                  {selected !== null && isPicked && !isCorrect && <Icon name="x" size={15} />}
                </button>
              );
            })}
          </div>

          <div
            style={{
              minHeight: 40,
              display: "flex",
              alignItems: "center",
              gap: 12,
              flexWrap: "wrap",
            }}
          >
            {answered ? (
              <div className="row-flex" style={{ gap: 8, flex: 1, minWidth: 220 }}>
                {selected === question.answerIndex ? (
                  <>
                    <span style={{ color: "var(--jade)", display: "grid", placeItems: "center" }}>
                      <Icon name="check" size={17} />
                    </span>
                    <span style={{ color: "var(--jade-ink)", fontWeight: 560 }}>
                      {t("quiz.correct")}
                    </span>
                  </>
                ) : (
                  <>
                    <span style={{ color: "var(--rose)", display: "grid", placeItems: "center" }}>
                      <Icon name="x" size={17} />
                    </span>
                    <span style={{ color: "var(--ink-2)" }}>{t("quiz.wrong")}</span>
                    <span className="tiny muted">
                      {t("quiz.correctAnswer")}：
                      <strong style={{ color: "var(--ink)", fontWeight: 560 }}>
                        {question.answer}
                      </strong>
                    </span>
                  </>
                )}
              </div>
            ) : (
              <div className="tiny muted" style={{ flex: 1 }}>
                键盘 <span className="kbd">A</span>–<span className="kbd">D</span> 作答
              </div>
            )}
            {answered && (
              <button className="btn btn-primary btn-sm" type="button" onClick={goNext}>
                {isLast ? t("quiz.finish") : t("quiz.next")}
                <Icon name="arrow-right" size={15} />
              </button>
            )}
          </div>
        </div>
      )}

      {phase === "done" && (
        <div className="stack" style={{ gap: 16 }}>
          <div
            className="card rise"
            style={{
              display: "flex",
              flexDirection: "column",
              alignItems: "center",
              gap: 18,
              padding: "clamp(28px, 5vw, 44px)",
              textAlign: "center",
            }}
          >
            <div className="tiny muted" style={{ letterSpacing: "0.12em", textTransform: "uppercase" }}>
              {t("quiz.result")}
            </div>
            <Ring value={score} max={Math.max(1, questions.length)} size={132} stroke={9}>
              <div>
                <div
                  style={{
                    fontFamily: "var(--font-display)",
                    fontSize: 32,
                    fontWeight: 600,
                    lineHeight: 1,
                  }}
                >
                  {Math.round(accuracy * 100)}%
                </div>
                <div className="tiny muted">{t("quiz.accuracy")}</div>
              </div>
            </Ring>

            <div style={{ fontFamily: "var(--font-display)", fontSize: 24, fontWeight: 600 }}>
              {accuracy === 1 ? t("quiz.perfect") : t("quiz.keepGoing")}
            </div>

            <div className="row-flex" style={{ gap: 36, justifyContent: "center", flexWrap: "wrap" }}>
              <div>
                <div style={{ fontFamily: "var(--font-display)", fontSize: 22, fontWeight: 600 }}>
                  {score} / {questions.length}
                </div>
                <div className="tiny muted">{t("quiz.score")}</div>
              </div>
              <div>
                <div style={{ fontFamily: "var(--font-display)", fontSize: 22, fontWeight: 600 }}>
                  {Math.round(accuracy * 100)}%
                </div>
                <div className="tiny muted">{t("quiz.accuracy")}</div>
              </div>
              <div>
                <div style={{ fontFamily: "var(--font-display)", fontSize: 22, fontWeight: 600 }}>
                  {formatDuration(elapsed)}
                </div>
                <div className="tiny muted">{t("quiz.timeSpent")}</div>
              </div>
            </div>

            <div className="row-flex" style={{ gap: 10, justifyContent: "center", flexWrap: "wrap" }}>
              <button className="btn btn-primary btn-lg" type="button" onClick={() => start(direction)}>
                <Icon name="refresh" size={16} />
                {t("quiz.again")}
              </button>
              <button className="btn btn-lg" type="button" onClick={() => setPhase("idle")}>
                {t("quiz.exit")}
              </button>
            </div>
          </div>

          {questions.some((item, i) => answers[i] !== item.answerIndex) && (
            <div className="card" style={{ padding: "18px 20px" }}>
              <div className="card-head">
                <div>
                  <div className="card-title" style={{ fontSize: 15 }}>
                    {t("quiz.missed")}
                  </div>
                  <div className="card-sub">
                    {t("quiz.reviewMistakes")}
                  </div>
                </div>
              </div>
              <div className="stack" style={{ gap: 0, marginTop: 6 }}>
                {questions.map((item, i) => {
                  if (answers[i] === item.answerIndex) return null;
                  const word = wordById.get(item.wordId);
                  const yourAnswer =
                    answers[i] === null ? "未作答" : item.options[answers[i] as number];
                  return (
                    <div
                      key={`${item.wordId}-${i}`}
                      style={{
                        display: "flex",
                        alignItems: "center",
                        gap: 12,
                        padding: "11px 0",
                        borderTop: "1px solid var(--line)",
                      }}
                    >
                      <div style={{ flex: 1, minWidth: 0 }}>
                        <div style={{ fontWeight: 560, fontSize: 14.5 }}>{word?.term ?? item.prompt}</div>
                        <div className="tiny muted" style={{ marginTop: 3 }}>
                          {t("quiz.yourAnswer")}：
                          <span style={{ color: "var(--rose)" }}>{yourAnswer}</span>
                          {" · "}
                          {t("quiz.correctAnswer")}：
                          <span style={{ color: "var(--jade-ink)" }}>{item.answer}</span>
                        </div>
                      </div>
                      {canSpeak && word && (
                        <button
                          type="button"
                          className="btn btn-icon btn-ghost"
                          aria-label={`播放 ${word.term}`}
                          onClick={() => playWord(word.term, word.sourceLang)}
                        >
                          <Icon name="volume" size={15} />
                        </button>
                      )}
                    </div>
                  );
                })}
              </div>
            </div>
          )}
        </div>
      )}
    </PageShell>
  );
}
